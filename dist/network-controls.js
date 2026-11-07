(function(){
 'use strict';
 window.MioNetworkControls={create({root,rpc,authorized,identity,escape:esc,savePrice}){
  let summary=null,owner=null,active='',offset=0,filter='',search='',fee='subscription',sequence=0;
  const $=id=>root.querySelector('#'+id),amount=n=>Number(n||0).toLocaleString('en-PK',{minimumFractionDigits:2,maximumFractionDigits:4});
  const tiers=[['free','Free'],['BASIC_1','Starter'],['BASIC_2','Basic'],['ADVANCED_1','Silver'],['ADVANCED_2','Gold'],['PREMIUM','Platinum']];
  const title=code=>tiers.find(t=>t[0]===code)?.[1]||code;
  const labels={subscription:'Subscription Fee',proceed:'Proceed Fee',withdrawal:'Withdrawal Fee',orders:'E-commerce / Orders Fee'};
  const content=()=>$('networkQuickContent');
  async function call(name,args){const r=await rpc(name,args);if(r.error)throw r.error;return r.data;}
  function cards(){root.querySelectorAll('[data-network-value]').forEach(node=>{const k=node.dataset.networkValue;node.textContent=!summary?'—':k==='members'?Number(summary.members).toLocaleString():k==='mio-price'?'PKR '+amount(summary.mio_price):k==='fees'?amount(summary.fees.combined)+' MIO':amount(summary[k])+(k==='shopping'||k==='promotion'?' pts':' MIO');});}
  function clear(){sequence++;summary=null;owner=null;active='';cards();content().replaceChildren();$('networkQuickDetail').classList.add('hidden');}
  async function refresh(){
   if(!authorized()){clear();return;}const uid=identity();if(owner!==uid){clear();owner=uid;}
   const data=await call('admin_network_control_summary');if(!authorized()||identity()!==uid)return;
   summary=data;cards();$('networkSummaryStatus').textContent='Updated '+new Date(data.as_of).toLocaleTimeString()+' · Member counts exclude company';
   if(active)await render();
  }
  function pager(total){return `<div class="network-ledger-pager"><span>${total?offset+1:0}–${Math.min(offset+25,total)} of ${total}</span><button class="btn small" type="button" data-ledger-page="-1" ${offset===0?'disabled':''}>Previous</button><button class="btn small" type="button" data-ledger-page="1" ${offset+25>=total?'disabled':''}>Next</button></div>`;}
  async function render(){
   if(!authorized()){clear();return;}const token=++sequence,uid=identity(),key=active;
   const valid=()=>authorized()&&uid===identity()&&token===sequence&&active===key;
   if(!summary){content().textContent='Loading live totals…';return;}
   if(key==='mio-price'){
    content().innerHTML=`<form id="networkMioPriceForm" class="network-rate-form"><p>Current price: <strong>PKR ${amount(summary.mio_price)} per MIO</strong></p><label>New price in PKR<input name="price" type="number" min="0.01" max="1000000" step="0.01" value="${Number(summary.mio_price)}" required></label><p class="helper">Updates current product PPV and new shopping calculations. Existing orders and transactions retain their saved rate. USD exchange settings are separate.</p><button class="btn primary" type="submit">Save MIO price</button><p data-rate-message role="status"></p></form>`;return;
   }
   if(!['members','proceed','cash','exchange','shopping','promotion','fees'].includes(key)){content().innerHTML='<p class="network-setup-note">This section is ready. Details and actions will be configured next.</p>';return;}
   const fees=key==='fees';
   content().innerHTML=fees?`<div class="network-fees-total"><span>Combined company fees</span><strong>${amount(summary.fees.combined)} MIO</strong><small>Collected Subscription + Proceed fees since the financial reset. Member balances are separate.</small></div><div class="network-fee-grid">${Object.entries(labels).map(([id,label])=>`<button type="button" class="network-fee-card ${fee===id?'selected':''}" data-fee-kind="${id}" ${summary.fees[id]===null?'disabled':''}><span>${label}</span><strong>${summary.fees[id]===null?'Awaiting rules':amount(summary.fees[id])+' MIO'}</strong></button>`).join('')}</div><h4>${labels[fee]} records</h4><div id="networkLedger" aria-live="polite">Loading records…</div>`:
    `${key==='members'?`<div class="network-tier-grid">${tiers.map(([code,label])=>`<button type="button" class="network-tier ${filter===code?'selected':''}" data-tier="${code}"><span>${label}</span><strong>${Number(summary.packages[code]||0)}</strong></button>`).join('')}</div>`:`<div class="network-fees-total"><span>Combined current balance</span><strong>${amount(summary[key])} ${['shopping','promotion'].includes(key)?'points':'MIO'}</strong><small>${key==='exchange'?'Current exchange balances across all accounts, including company. This is the outstanding balance, not total received or sent.':'Includes company and founder accounts among all registered members.'}</small></div>`}<form id="networkMemberSearch" class="network-member-search"><label>Find a member<input name="search" type="search" maxlength="100" placeholder="Name or MIO ID" value="${esc(search)}"></label><button class="btn small" type="submit">Search</button><button class="btn small" type="button" data-clear-members>Show all</button></form>${filter?`<p>Package: ${esc(title(filter))}</p>`:''}<div id="networkLedger" aria-live="polite">Loading members…</div>`;
   try{
    const data=key==='exchange'?await call('admin_network_control_exchange',{p_offset:offset,p_limit:25,p_search:search}):fees?await call('admin_network_control_fees',{p_kind:fee,p_offset:offset,p_limit:25}):await call(key==='members'?'admin_network_control_registered_members':'admin_network_control_members',{p_offset:offset,p_limit:25,p_package:filter||null,p_search:search});if(!valid())return;
    const cols=key==='members'?['proceed','cash','shopping','promotion']:fees?[]:[key];
    $('networkLedger').innerHTML=`<div class="network-ledger-scroll"><table class="admin-preview-table"><thead><tr><th>Member</th><th>${fees?'Date':'Package'}</th>${fees?'<th>Reference</th><th>Fee (MIO)</th>':cols.map(k=>`<th>${({proceed:'Proceed (MIO)',cash:'Cash (MIO)',exchange:'Exchange (MIO)',shopping:'Shopping points',promotion:'Promotion points'})[k]}</th>`).join('')}</tr></thead><tbody>${data.rows.map(r=>`<tr><td><strong>${esc(r.full_name||'Member')}</strong><small>${esc(r.member_code||'—')}</small></td><td>${fees?esc(new Date(r.created_at).toLocaleString()):esc(title(r.package_code))}</td>${fees?`<td>${esc(title(r.reference))}</td><td>${amount(r.amount)}</td>`:cols.map(k=>`<td>${amount(r[k])}</td>`).join('')}</tr>`).join('')||`<tr><td colspan="6">No matching records.</td></tr>`}</tbody></table></div>${pager(data.total)}`;
   }catch(e){if(valid())$('networkLedger').textContent='Could not load records: '+e.message;}
  }
  async function open(key){if(owner!==identity()){clear();owner=identity();}active=key;offset=0;filter='';search='';fee='subscription';if(!summary||owner!==identity()){await refresh();}else await render();}
  root.addEventListener('click',e=>{
   const b=e.target.closest('button');if(!b)return;
   if(b.hasAttribute('data-network-close')){active='';sequence++;return;}
   if(b.hasAttribute('data-network-refresh')){b.disabled=true;refresh().catch(err=>{$('networkSummaryStatus').textContent='Could not refresh: '+err.message;}).finally(()=>b.disabled=false);return;}
   if(!authorized())return;
   if(b.dataset.tier){filter=b.dataset.tier;offset=0;render();}
   if(b.dataset.feeKind){fee=b.dataset.feeKind;offset=0;render();}
   if(b.dataset.ledgerPage){offset=Math.max(0,offset+Number(b.dataset.ledgerPage)*25);render();}
   if(b.hasAttribute('data-clear-members')){filter='';search='';offset=0;render();}
  });
  root.addEventListener('submit',async e=>{
   if(e.target.id==='networkMemberSearch'){e.preventDefault();search=e.target.elements.search.value.trim();offset=0;await render();}
   if(e.target.id==='networkMioPriceForm'){
    e.preventDefault();if(!authorized())return;const form=e.target,button=form.querySelector('button'),message=form.querySelector('[data-rate-message]');button.disabled=true;
    try{const price=Number(form.elements.price.value);if(!Number.isFinite(price)||price<=0||price>1000000||Math.abs(price*100-Math.round(price*100))>1e-6)throw Error('Enter a valid price with up to two decimals');await savePrice(price);await refresh();content().querySelector('[data-rate-message]').textContent='MIO price saved. New shopping calculations now use this rate.';}catch(err){message.textContent=err.message;}finally{button.disabled=false;}
   }
  });
  return {refresh,open,clear};
 }};
})();
