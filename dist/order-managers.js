/* Vendor-scoped operations. Authorization and amounts are validated by the server. */
window.MioOrderManagers = (() => {
  const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
  const money = value => 'Rs ' + Number(value || 0).toLocaleString('en-PK', {maximumFractionDigits:2});
  const amount = value => Number(value || 0).toLocaleString('en-PK', {maximumFractionDigits:4});
  const label = value => String(value || '').replaceAll('_',' ').replace(/^./, c => c.toUpperCase());
  const when = value => value ? new Date(value).toLocaleDateString('en-GB', {year:'numeric', month:'short', day:'numeric'}) : '';
  const action = (key, title, value='', primary=false) => `<button type="button" class="btn${primary?' primary':''}" data-om="${esc(key)}" data-value="${esc(value)}">${esc(title)}</button>`;
  const opt = (value, title, selected=false) => `<option value="${esc(value)}"${selected?' selected':''}>${esc(title)}</option>`;
  const empty = copy => `<p class="om-empty">${esc(copy)}</p>`;
  const status = value => `<span class="om-state">${esc(label(value))}</span>`;
  const field = (title, control) => `<label class="om-field"><span>${title}</span>${control}</label>`;
  const detail = (title,value) => `<div><dt>${esc(title)}</dt><dd>${esc(value)}</dd></div>`;
  const stages = ['placed','confirmed','processing','shipped','delivered'];
  // Price and rate are decimals. Match the database's four-place truncation.
  function quote(pkr,rate) {
    const fraction=value=>{
      const m=String(value).match(/^(\d+)(?:\.(\d+))?$/);
      return m?[BigInt(m[1]+(m[2]||'')),10n**BigInt((m[2]||'').length)]:[0n,1n];
    };
    const [n,nd]=fraction(pkr),[d,dd]=fraction(rate);
    if(d===0n)return '0.0000';
    const units=n*dd*10000n/(d*nd);
    return String(units/10000n)+'.'+String(units%10000n).padStart(4,'0');
  }
  function create({db,userId,notify,confirmSensitive}) {
    let generation=0, modal, directory, finances, memberLookup=0, lastRoute=null, financeOffset=0, earningsOnly=false, lastOrders='',refreshing=false;
    let vendor='', phase='', offset=0, activeTab='orders', adminTab='managers';
    const $ = id => document.getElementById(id);
    async function rpc(name, args={}) {
      const uid=userId();
      if(!uid) throw Error('Please sign in to continue.');
      const {data,error}=await db.rpc(name,args);
      if(uid!==userId()) throw Error('Your session has changed.');
      if(error) throw error;
      return data;
    }
    function close() { if(modal){modal.close();modal.remove();modal=null;} }
    function navigate(name) {
      if(name && name===lastRoute)return;
      lastRoute=name;watchOrders();close();
      generation++;
    }
    function clear() {
      navigate(); directory=finances=null;lastOrders='';financeOffset=0;earningsOnly=false; vendor=phase='';offset=0;activeTab='orders';adminTab='managers';
      for(const id of ['om-member','om-admin']) $(id)?.replaceChildren();
    }
    function open(title, html) {
      close();
      modal=document.createElement('dialog');
      modal.className='om-dialog';modal.setAttribute('aria-labelledby','om-dialog-title');
      modal.innerHTML=`<div class="om-dialog-head"><h2 id="om-dialog-title">${esc(title)}</h2>${action('close','Close')}</div><div class="om-dialog-body">${html}</div><p class="om-error" role="alert"></p>`;
      document.body.append(modal);
      modal.addEventListener('close',function(){if(modal===this)modal=null;this.remove();});
      modal.showModal();
      return modal;
    }
    function target(page) {
      const member=page==='member',id='om-'+page;
      if(!$(id)) {
        const node=document.createElement('div');node.id=id;node.className='om-workspace';
        $(member?'page-order-manager':'control-order-managers').append(node);
      }
      return $(id);
    }
    async function load(page, task) {
      const root=target(page),turn=++generation,uid=userId();
      root.setAttribute('aria-busy','true');
      root.innerHTML='<p role="status">Loading…</p>';
      try {
        const draw=await task();
        if(turn===generation&&uid===userId())root.innerHTML=draw();
      } catch(error) {
        if(turn===generation&&uid===userId()){
          const missing=['PGRST202','42883'].includes(error.code);
          root.innerHTML=empty(missing?'Order management is awaiting activation.':error.message || 'Unable to load this page.')+action(page==='member'?'member-refresh':'admin-refresh','Refresh');
        }
      } finally {if(turn===generation)root.removeAttribute('aria-busy');}
    }
    const tabs = (active,entries) => '<div class="om-tabs">'+entries.map(([key,text])=>`<button type="button" data-om="tab" data-value="${key}" aria-pressed="${active===key}">${text}</button>`).join('')+'</div>';
    function admin() {
      return load('admin',async()=>{
        const tab=adminTab;
        if(tab==='returns')return ()=>adminTabs()+returnLookup();
        const result=tab==='managers'?await rpc('admin_order_manager_directory',{p_search:''}):await rpc('admin_manager_withdrawals');
        return ()=>{
          const nav=adminTabs();
          if(tab==='withdrawals')return nav+adminWithdrawals(result);
          directory=result;
          const managers=result.managers||[];
          return nav+`<div class="om-heading"><div><h3>Manager assignments</h3><p>${Number(result.unassigned_count||0)} unassigned · Admin oversight</p></div>${action('add','Add manager','',true)}</div>`+
            (managers.map(m=>`<article class="om-row"><div><strong>${esc(m.name)}</strong><small>${esc(m.member_code)} · ${m.active?'Active':'Inactive'} · ${Number(m.open_count||0)} open</small></div><div class="om-actions">${m.active?action('vendors','Vendors ('+Number(m.vendor_count||0)+')',m.id)+action('deactivate','Deactivate',m.id):action('activate','Reactivate',m.id)}</div></article>`).join('')||empty('No order managers assigned yet.'));
        };
      });
    }
    function adminTabs(){return tabs(adminTab,[['managers','Managers'],['withdrawals','Withdrawals'],['returns','Fee adjustments']]);}
    function returnLookup() {
      return '<h3>Adjust a fee for refunded items</h3><p>Use this after an item refund has been issued.</p><form data-om-form="return-lookup">'+field('Order code','<input name="order_code" required maxlength="100">')+'<button class="btn" type="submit">Find order fees</button></form><div id="om-return-results" aria-live="polite"></div>';
    }
    function adminWithdrawals(rows) {
      return '<h3>Manager withdrawal requests</h3>'+((rows||[]).map(r=>`<article class="om-row"><div><strong>${esc(r.member_name)} · ${money(r.amount_pkr)}</strong><small>${esc(when(r.created_at))} · ${esc(r.bank?.bank_name)} · ${esc(r.bank?.account_title)} · ${esc(r.bank?.account_number)}</small></div><div class="om-actions">${status(r.status)} ${r.status==='pending'?action('approve','Approve',r.id)+action('reject','Reject',r.id):r.status==='approved'?action('pay','Mark paid',r.id):''}</div></article>`).join('')||empty('No manager withdrawal requests.'));
    }
    async function previewHandover(form,ids) {
      const turn=String(Number(form.dataset.preview||0)+1);
      form.dataset.preview=turn;
      const preview=form.querySelector('[data-om-preview]'),save=form.querySelector('[type="submit"]');
      if(!ids.length){preview.textContent='';save.disabled=form.dataset.omForm==='vendors';return;}
      preview.textContent='Checking open shipments and pending fees…';save.disabled=true;
      try{
        const data=await rpc('admin_manager_handover_preview',{p_vendors:ids});
        if(!form.isConnected||form.dataset.preview!==turn)return;
        preview.textContent=Number(data.vendor_count)+' vendors · '+Number(data.open_shipments)+' open shipments · '+money(data.pending_pkr)+' pending fees affected';
        save.disabled=false;
      }catch(error){
        if(!form.isConnected||form.dataset.preview!==turn)return;
        preview.textContent=error.message||'Unable to load the handover summary.';
        const retry=document.createElement('button');retry.type='button';retry.className='btn';retry.textContent='Retry preview';retry.onclick=()=>previewHandover(form,ids);preview.append(' ',retry);
      }
    }
    function vendorPicker(id) {
      const manager=directory.managers.find(m=>m.id===id);
      const current=new Map(directory.managers.map(m=>[m.id,m.name]));
      const vendors=directory.vendors||[];
      const dlg=open('Vendors · '+manager.name,`<form data-om-form="vendors">${field('Search vendors','<input type="search" name="search" autocomplete="off">')}<div class="om-picker">${vendors.map(v=>`<label><input name="vendor" type="checkbox" value="${esc(v.id)}" ${v.manager_id===id?'checked':''}><span><strong>${esc(v.name)}</strong><small>${esc(current.get(v.manager_id)||'Unassigned')}</small></span></label>`).join('')||empty('No vendors available.')}</div><div class="om-transfer-note" role="status"></div><p data-om-preview role="status"></p><button type="submit" class="btn primary" disabled>Save changes</button></form>`);
      const form=dlg.querySelector('form');form.dataset.member=id;
      form.elements.search.oninput=()=>{const term=form.elements.search.value.trim().toLowerCase();form.querySelectorAll('.om-picker label').forEach(row=>{row.hidden=!row.textContent.toLowerCase().includes(term);});};
      form.onchange=()=>{
        const checked=new Set(new FormData(form).getAll('vendor'));
        const transferred=vendors.filter(v=>checked.has(v.id)&&v.manager_id&&v.manager_id!==id);
        const removed=vendors.filter(v=>!checked.has(v.id)&&v.manager_id===id);
        const summary=transferred.map(v=>v.name+' from '+current.get(v.manager_id)+' to '+manager.name);
        if(removed.length)summary.push('Move to Unassigned: '+removed.map(v=>v.name).join(', '));
        dlg.querySelector('.om-transfer-note').textContent=summary.join(' · ');
        previewHandover(form,vendors.filter(v=>checked.has(v.id)!==(v.manager_id===id)).map(v=>v.id));
      };
    }
    function addMember() {
      const dlg=open('Add order manager',`<form data-om-form="search">${field('Member name or MIO ID','<input name="query" type="search" required minlength="2" autocomplete="off">')}<button class="btn" type="submit">Find member</button></form><div class="om-results" aria-live="polite"></div>`);
      dlg.querySelector('input').focus();
    }
    function deactivate(id) {
      const m=directory.managers.find(row=>row.id===id);
      const others=directory.managers.filter(row=>row.active&&row.id!==id);
      const dlg=open('Deactivate '+m.name,`<form data-om-form="deactivate" data-member="${esc(id)}"><p>${Number(m.vendor_count||0)} assigned vendors · ${Number(m.open_count||0)} open orders</p>${field('Move vendors and open orders to','<select name="replacement">'+opt('','Unassigned · Admin oversight')+others.map(row=>opt(row.id,row.name)).join('')+'</select>')}<p data-om-preview role="status"></p><button class="btn primary" type="submit">Confirm deactivation</button></form>`);
      previewHandover(dlg.querySelector('form'),directory.vendors.filter(v=>v.manager_id===id).map(v=>v.id));
    }
    const orderParams=()=>({p_vendor:vendor||null,p_status:phase||null,p_offset:offset});
    async function refreshVisibleOrders() {
      const root=$('om-member');
      if(refreshing||document.hidden||lastRoute!=='order-manager'||activeTab!=='orders'||earningsOnly||modal||
        !userId()||!root||root.getAttribute('aria-busy')==='true'||root.contains(document.activeElement))return;
      refreshing=true;
      const turn=generation;
      try {
        const result=await rpc('my_order_manager_orders',orderParams());
        const snapshot=JSON.stringify(result);
        if(turn===generation&&snapshot!==lastOrders&&!modal&&!root.contains(document.activeElement)){
          lastOrders=snapshot;root.innerHTML=tabs('orders',[['orders','Orders & vendors'],['earnings','My earnings']])+orders(result);
        }
      } catch(error) {
        if(turn===generation&&/manager access required/i.test(error.message||'')){
          lastOrders='';root.innerHTML=empty('Manager access has changed. Return to your member dashboard.');
        }
      } finally {refreshing=false;}
    }
    let poll=null;
    function watchOrders() {
      clearInterval(poll);poll=null;
      if(lastRoute==='order-manager'&&activeTab==='orders'&&!earningsOnly)poll=setInterval(refreshVisibleOrders,30000);
    }
    document.addEventListener('visibilitychange',refreshVisibleOrders);
    function member(only=earningsOnly) {
      earningsOnly=only;if(only)activeTab='earnings';watchOrders();
      return load('member',async()=>{
        const tab=activeTab;
        const result=tab==='orders'?await rpc('my_order_manager_orders',orderParams()):await rpc('order_manager_finances',{p_offset:financeOffset});
        return ()=>{
          const nav=earningsOnly?'<h3>My earnings</h3>':tabs(tab,[['orders','Orders & vendors'],['earnings','My earnings']]);
          if(tab==='earnings'){finances=result;return nav+earnings(result);}
          lastOrders=JSON.stringify(result);return nav+orders(result);
        };
      });
    }
    const metrics=[['total','All orders'],['pending','Awaiting approval'],['dispatch','To dispatch'],['shipped','Shipped'],['delivered','Delivered']];
    function orders(data){
      const tiles=metrics.map(([key,text])=>`<button type="button" data-om="phase" data-value="${key==='total'?'':key}" aria-pressed="${(phase||'total')===key}"><span>${text}</span><strong>${Number(data.counts?.[key]||0)}</strong></button>`).join('');
      const rows=(data.orders||[]).map(row=>`<article class="om-row"><div><strong>${esc(row.order_code)}</strong><small>${esc(row.vendor_name)} · ${esc(when(row.created_at))}</small></div><div>${status(row.status)}<small>${esc(label(row.payment_status))} · ${money(row.total_pkr)}</small></div>${action('shipment','Manage',row.shipment_id)}</article>`).join('');
      return `<div class="om-stats">${tiles}</div><div class="om-heading"><h3>Vendor shipments</h3>${field('Assigned vendors ('+Number(data.vendors?.length||0)+')','<select data-om-vendor>'+opt('','All assigned vendors')+(data.vendors||[]).map(v=>opt(v.id,v.name,v.id===vendor)).join('')+'</select>')}</div>`+
        (rows||empty('No shipments match this selection.'))+`<div class="om-actions">${offset?action('prev','Previous'):''}${data.has_more?action('next','Next'):''}</div>`;
    }
    async function shipment(id) {
      const dlg=open('Shipment details','<p role="status">Loading shipment…</p>');
      const s=await rpc('manager_order_shipment',{p_shipment:id});
      if(!s||modal!==dlg)return;
      const next=stages[stages.indexOf(s.status)+1],advance=s.advance,closed=['returned','cancelled'].includes(s.status);
      const allowed=stages.includes(s.status)&&next&&(s.status!=='placed'||s.funding_ready);
      const nextTitle={confirmed:'Approve shipment',processing:'Start processing',shipped:'Mark shipped',delivered:'Mark delivered'};
      dlg.querySelector('.om-dialog-body').innerHTML=`<strong>${esc(s.order_code)} · ${esc(s.vendor_name)}</strong><p>${status(s.status)} · ${money(s.total_pkr)}</p><dl class="om-details">${detail('Customer',s.customer_name)}${detail('Phone',s.phone)}${detail('Delivery address',[s.address,s.city].filter(Boolean).join(', '))}${detail('Payment',label(s.payment_status))}</dl><h3>Items</h3><ul>${(s.items||[]).map(i=>`<li>${esc(i.name)} × ${Number(i.quantity)} · ${money(i.unit_price)}</li>`).join('')}</ul>`+
       (closed||s.status==='delivered'?'':`<form data-om-form="tracking" data-id="${esc(id)}">${field('Shipment tracking','<input name="tracking" maxlength="200" required value="'+esc(s.tracking)+'">')}<button class="btn" type="submit">Save tracking</button></form>`)+
       (allowed?action('advance',nextTitle[next],id,true):'')+
       (!s.funding_ready&&s.status==='placed'?empty('Funding confirmation is required before shipment approval.'):'')+
       (s.single_vendor&&advance?.status==='submitted'?`<form data-om-form="advance-review" data-id="${esc(s.id)}"><h3>Advance payment</h3><p>${esc(advance.reference)} · ${money(advance.amount)}</p>${advance.proof?`<button type="button" class="btn" data-shopping-proof="${esc(advance.proof)}">View proof</button>`:''}${field('Verified amount (PKR)','<input type="number" name="amount" step=".01" min="0" value="'+esc(advance.amount)+'">')}${field('Review note','<input name="note" maxlength="500">')}<div class="om-actions"><button class="btn primary" type="submit" value="approve">Approve payment</button><button class="btn" type="submit" value="reject">Reject payment</button></div></form>`:'')+
       (s.single_vendor&&s.status==='delivered'&&!['paid','confirmed'].includes(s.payment_status)?action('confirm-payment','Confirm COD received',s.id):'')+
       (!s.single_vendor?empty('The admin reviews combined order payments.'):'')+
       (s.single_vendor&&['placed','confirmed','processing'].includes(s.status)&&!['paid','confirmed'].includes(s.payment_status)&&advance?.status!=='submitted'?action('cancel-order','Cancel unpaid order',s.id):'')+
       (s.single_vendor&&advance?.status==='refund_due'?`<form data-om-form="refund" data-id="${esc(s.id)}">${field('Refund payment reference','<input name="reference" maxlength="180" required>')}<button class="btn" type="submit">Record issued refund</button></form>`:'');
      dlg.dataset.shipment=id;dlg.dataset.next=next||'';
    }
    function earnings(f) {
      return `<div class="om-stats"><div><span>Pending fee</span><strong>${money(f.pending_pkr)}</strong></div><div><span>Available balance</span><strong>${money(f.available_pkr)}</strong></div><div><span>Withdrawal reserved</span><strong>${money(f.reserved_pkr)}</strong></div><div><span>Total earned</span><strong>${money(f.earned_pkr)}</strong></div></div>`+
        (Number(f.available_pkr)>0?`<div class="om-actions">${action('payout','Convert to MIO','convert',true)}${action('payout','Withdraw to bank','withdraw')}</div>`:'')+
        '<h3>Fees by order</h3>'+((f.fees||[]).map(r=>`<article class="om-row"><div><strong>${esc(r.order_code)}</strong><small>${esc(r.vendor_name)} · ${esc(when(r.created_at))}</small></div>${status(r.state)}<strong>${money(r.fee_pkr)}</strong></article>`).join('')||empty('No management fees yet.'))+
        '<h3>Transfers & withdrawals</h3>'+((f.transactions||[]).map(r=>`<article class="om-row"><div><strong>${esc(label(r.kind))}</strong><small>${esc(when(r.created_at))} · ${esc(r.id)}</small></div>${status(r.status)}<strong>${money(r.amount_pkr)}${r.kind==='convert'?' · '+amount(r.amount_mio)+' MIO':''}</strong></article>`).join('')||empty('No transactions yet.'))+
        '<div class="om-actions">'+(financeOffset?action('finance-prev','Previous'):'' )+(f.has_more?action('finance-next','Next'):'')+'</div>';
    }
    function payout(kind) {
      const convert=kind==='convert',rate=Number(finances.rate);
      if(convert&&!(rate>0))throw Error('Conversion rate unavailable. Refresh your earnings.');
      const dlg=open(convert?'Transfer to Cash Wallet':'Withdraw to bank',`<form data-om-form="payout" data-kind="${kind}"><p>Available · ${money(finances.available_pkr)}</p>${field('Amount (PKR)','<input type="number" inputmode="decimal" name="amount" min=".01" step=".01" max="'+esc(finances.available_pkr)+'" required>')}${convert?`<p>1 MIO = ${money(rate)}</p><output aria-live="polite"></output>`:field('Bank name','<input name="bank_name" required minlength="2" maxlength="100">')+field('Account holder','<input name="account_title" required minlength="2" maxlength="120">')+field('Account number or IBAN','<input name="account_number" required minlength="6" maxlength="42">')}<button class="btn primary" type="submit">${convert?'Confirm transfer':'Request withdrawal'}</button></form>`);
      const form=dlg.querySelector('form');
      form.dataset.request=crypto.randomUUID();
      if(convert)form.oninput=()=>{form.querySelector('output').textContent='Cash Wallet receives '+quote(form.elements.amount.value,finances.rate)+' MIO';};
    }
    async function handleClick(key,value) {
      if(key==='close')return close();
      if(key==='admin-refresh')return admin();
      if(key==='member-refresh')return member();
      if(key==='tab'){
        if(value==='orders'||value==='earnings'){activeTab=value;return member();}
        adminTab=value;return admin();
      }
      if(key==='finance-prev'||key==='finance-next'){financeOffset=Math.max(0,financeOffset+(key==='finance-next'?100:-100));return member();}
      if(key==='phase'){phase=value;offset=0;return member();}
      if(key==='prev'||key==='next'){offset=Math.max(0,offset+(key==='next'?25:-25));return member();}
      if(key==='add')return addMember();
      if(key==='vendors')return vendorPicker(value);
      if(key==='deactivate')return deactivate(value);
      if(key==='activate'){
        await confirmSensitive('Grant Order Manager access to this member');
        await rpc('admin_set_order_manager',{p_member:value,p_active:true,p_replacement:null});close();return admin();
      }
      if(key==='shipment')return shipment(value);
      if(key==='advance'){
        await rpc('advance_vendor_shipment',{p_shipment:value,p_status:modal.dataset.next});
        close();notify('Shipment updated.');return member();
      }
      if(key==='cancel-order'){open('Cancel unpaid order',`<form data-om-form="cancel-order" data-id="${esc(value)}"><p>Cancel this order before dispatch?</p><button class="btn" type="submit">Confirm cancellation</button></form>`);return;}
      if(key==='confirm-payment'){
        open('Confirm payment received',`<form data-om-form="confirm-payment" data-id="${esc(value)}"><p>Confirm that the COD payment for this order has been received in full.</p><button class="btn primary" type="submit">Confirm receipt</button></form>`);return;
      }
      if(key==='payout')return payout(value);
      const reviews={approve:['Approve withdrawal','approved'],reject:['Reject withdrawal','rejected'],pay:['Mark withdrawal paid','paid']};
      if(reviews[key]){
        const [title,state]=reviews[key];
        open(title,`<form data-om-form="review" data-id="${esc(value)}" data-state="${state}">${field(state==='paid'?'Bank payment reference':state==='rejected'?'Reason for rejection':'Approval note','<input name="note" maxlength="500" '+(state==='approved'?'':'required')+'>')}<button type="submit" class="btn primary">${title}</button></form>`);
      }
    }
    async function handleForm(form,submitter) {
      const kind=form.dataset.omForm,values=new FormData(form),get=k=>String(values.get(k)||'').trim();
      if(kind==='search'){
        const dlg=modal,turn=++memberLookup;
        const data=await rpc('admin_order_manager_directory',{p_search:get('query')});
        if(dlg!==modal||turn!==memberLookup)return;
        const assigned=new Set((data.managers||[]).filter(m=>m.active).map(m=>m.id));
        dlg.querySelector('.om-results').innerHTML=(data.members||[]).map(m=>`<div class="om-row"><div><strong>${esc(m.name)}</strong><small>${esc(m.member_code)}</small></div>${assigned.has(m.id)?status('active'):action('activate','Grant access',m.id)}</div>`).join('')||empty('No matching members.');
        return;
      }
      if(kind==='vendors'){
        const allowed=values.getAll('vendor'),expected=Object.fromEntries(directory.vendors.map(v=>[v.id,v.manager_id||null]));
        await confirmSensitive('Save vendor assignments and transfer affected open orders');
        await rpc('admin_set_manager_vendors',{p_member:form.dataset.member,p_vendors:allowed,p_expected:expected});
        close();notify('Vendor assignments saved.');return admin();
      }
      if(kind==='deactivate'){
        await confirmSensitive('Deactivate this order manager and reassign open orders');
        await rpc('admin_set_order_manager',{p_member:form.dataset.member,p_active:false,p_replacement:get('replacement')||null});
        close();return admin();
      }
      if(kind==='review'){
        await confirmSensitive('Update this manager withdrawal');
        await rpc('admin_review_manager_withdrawal',{p_id:form.dataset.id,p_status:form.dataset.state,p_note:get('note')});
        close();return admin();
      }
      if(kind==='payout'){
        const convert=form.dataset.kind==='convert',amountPKR=Number(get('amount'));
        const pin=await window.MioDashboard.requestTransactionPin(convert?'transferring management fees to Cash Wallet':'requesting a bank withdrawal');
        if(!pin||!form.isConnected)return;
        const result=await rpc('order_manager_request_payout',{p_kind:form.dataset.kind,p_amount:amountPKR,p_rate:convert?Number(finances.rate):null,p_bank:convert?null:{bank_name:get('bank_name'),account_title:get('account_title'),account_number:get('account_number')},p_request:form.dataset.request,p_pin:pin});
        close();await member();
        open(convert?'Cash Wallet receipt':'Withdrawal requested',`<dl class="om-details">${detail('Amount',money(result.amount_pkr))}${convert?detail('Cash Wallet credit',amount(result.amount_mio)+' MIO'):''}${detail('Status',label(result.status))}${detail('Reference',result.id)}</dl>`);
        return;
      }
      if(kind==='return-lookup'){
        const rows=await rpc('admin_manager_fee_items',{p_order_code:get('order_code')});
        const root=$('om-return-results');if(!root)return;
        root.innerHTML=(rows||[]).map(r=>`<article class="om-row"><div><strong>${esc(r.product_name)}</strong><small>${esc(r.vendor_name)} · ${esc(r.member_name)} · ${money(r.fee_pkr)}</small><small>${Number(r.returned_quantity)} of ${Number(r.quantity)} units returned</small></div>${r.state!=='reversed'&&r.returned_quantity<r.quantity?`<form data-om-form="return-fee" data-id="${esc(r.item_id)}">${field('Total units refunded','<input type="number" name="qty" min="'+(Number(r.returned_quantity)+1)+'" max="'+Number(r.quantity)+'" required>')}${field('Refund reference or reason','<input name="note" maxlength="300" required>')}<button class="btn" type="submit">Adjust fee</button></form>`:status(r.state)}</article>`).join('')||empty('No management fees for that order.');
        return;
      }
      if(kind==='return-fee'){
        await confirmSensitive('Adjust the manager fee for refunded items');
        await rpc('admin_return_manager_fee',{p_item:form.dataset.id,p_returned_quantity:Number(get('qty')),p_note:get('note')});
        notify('Fee adjustment saved.');return admin();
      }
      if(kind==='cancel-order')await rpc('cancel_unpaid_order',{p_order_id:form.dataset.id});
      if(kind==='refund')await rpc('admin_record_shopping_refund',{p_order_id:form.dataset.id,p_reference:get('reference')});
      if(kind==='tracking')await rpc('order_manager_tracking',{p_shipment:form.dataset.id,p_tracking:get('tracking')});
      if(kind==='confirm-payment')await rpc('admin_confirm_order_payment',{p_order_id:form.dataset.id});
      if(kind==='advance-review'){
        const approved=submitter?.value==='approve';
        if(approved&&!(Number(get('amount'))>0))throw Error('Enter the verified payment amount.');
        if(!approved&&!get('note'))throw Error('Enter a reason for rejecting this advance.');
        await rpc('admin_review_shopping_advance',{p_order_id:form.dataset.id,p_approve:approved,p_verified_pkr:approved?Number(get('amount')):null,p_note:get('note')});
      }
      close();notify('Order updated.');return member();
    }
    async function run(control,fn) {
      if(!control||control.disabled)return;
      control.disabled=true;
      try {await fn();}
      catch(error){const message=error?.message||'This action could not be completed.';if(modal)modal.querySelector('.om-error').textContent=message;else notify(message);}
      finally{control.disabled=false;}
    }
    document.addEventListener('click',e=>{
      const b=e.target.closest('button[data-om]');
      if(b)run(b,()=>handleClick(b.dataset.om,b.dataset.value));
    });
    document.addEventListener('submit',e=>{
      const f=e.target.closest('[data-om-form]');if(!f)return;e.preventDefault();
      const b=e.submitter||f.querySelector('[type="submit"]');
      if(f.dataset.submitting)return;
      f.dataset.submitting='true';
      run(b,()=>handleForm(f,b)).finally(()=>delete f.dataset.submitting);
    });
    document.addEventListener('change',e=>{
      if(e.target.matches('[data-om-vendor]')){vendor=e.target.value;offset=0;member();}
    });
    return {admin,member,clear,navigate,openWithdrawals(){adminTab='withdrawals';}};
  }
  return {create};
})();
