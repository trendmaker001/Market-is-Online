/* Wallet-scoped, server-filtered statements. Rendering never moves balances. */
window.createMioWalletHistory=(options={})=>{
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const fmt=v=>{const [a,b='']=String(v??'0').replace(/^-/, '').split('.');return a+'.'+b.padEnd(2,'0').slice(0,Math.max(2,b.replace(/0+$/,'').length))};
 const balance=v=>v==null||v===''||!Number.isFinite(Number(v))?'—':(Number(v)<0?'−':'')+esc(fmt(v));
 const date=v=>new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Karachi',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(v));
 const names={cash:'Cash Wallet',proceed:'Proceed Wallet',shopping:'Shopping Points',promotion:'Promotion Points',exchange:'Exchange Wallet',company:'Company Proceed Fees'};
 const walletKinds=['proceed','cash','shopping','promotion'];
 const bonusNames={direct_sponsor:'Direct Sponsor Bonus',welcome_bonus:'Welcome Bonus',generation:'Generation Bonus',team_manager:'Team Manager Bonus',community_share:'Community Share Bonus',self_cashback:'Shopping Cashback',affiliate_level1:'Affiliate Bonus'};
 let api,uid=null,turn=0,page=1,filter='all',from='',to='',kind=options.company?'company':'cash',rows=[];
 const host=()=>options.host?options.host():document.getElementById('mioHistory');
 const key=()=>`mio-wallet-view:${options.company?'company:':options.admin?'admin:':''}${uid}`;
 function save(){try{sessionStorage.setItem(key(),JSON.stringify({page,filter,from,to,kind}))}catch{}}
 function setIdentity(id){if(uid===id)return;turn++;uid=id;rows=[];page=1;filter='all';from='';to='';kind=options.company?'company':'cash';window.MioTransferReceipt?.clear();host()?.replaceChildren();if(uid){try{const p=JSON.parse(sessionStorage.getItem(key())||'{}');page=Math.max(1,Math.min(100000,Number(p.page)||1));filter=['all','received','sent','package','other'].includes(p.filter)?p.filter:'all';kind=options.company?'company':walletKinds.includes(p.kind)?p.kind:'cash';from=/^\d{4}-\d{2}-\d{2}$/.test(p.from)?p.from:'';to=/^\d{4}-\d{2}-\d{2}$/.test(p.to)?p.to:''}catch{}}}
 function setWallet(value){if(!walletKinds.includes(value))return;turn++;kind=value;page=1;filter='all';rows=[];host()?.replaceChildren();save()}
 function mount(value){
  api=value;
  const target=host();
  if(!target)return;
  target.classList.remove('list');
  target.closest('.card')?.classList.add('cash-history-card');
  if(!options.company&&!options.admin)target.classList.add('member-wallet-statement');
  target.addEventListener('submit',e=>{
   if(!e.target.matches('[data-wallet-filters]'))return;
   e.preventDefault();
   const f=e.target,nextFrom=f.elements.from.value,nextTo=f.elements.to.value;
   if(nextFrom&&nextTo&&nextFrom>nextTo){api.error?.(Error('From date must not follow To date'));return}
   from=nextFrom;to=nextTo;filter=f.elements.activity.value;
   page=1;save();refresh();
  });
  target.addEventListener('change',e=>{
   if(!e.target.matches('[data-wallet-picker]'))return;
   setWallet(e.target.value);
   refresh().then(()=>host()?.querySelector('[data-wallet-picker]')?.focus({preventScroll:true}));
  });
  target.addEventListener('click',e=>{
   const b=e.target.closest('[data-cash-page],[data-cash-receipt],[data-cash-retry],[data-wallet-kind],[data-wallet-clear]');
   if(!b||b.disabled)return;
   if(b.hasAttribute('data-cash-receipt')){const row=rows.find(x=>x.id===b.dataset.cashReceipt);if(row&&uid)receipt(row);return}
   if(b.dataset.walletKind)setWallet(b.dataset.walletKind);
   if(b.hasAttribute('data-wallet-clear')){from='';to='';filter='all';page=1}
   if(b.hasAttribute('data-cash-page'))page+=Number(b.dataset.cashPage);
   save();refresh();
  });
 }
 async function refresh(){const target=host();if(!target||!api||!uid)return;const ticket=++turn,owner=uid;target.setAttribute('aria-busy','true');if(!target.children.length)target.innerHTML='<p class="helper" role="status">Updating wallet activity…</p>';try{const args={p_wallet:kind,p_filter:filter,p_from:from||null,p_to:to||null,p_page:page,p_limit:20};if(options.admin)args.p_member_id=uid;if(options.company){delete args.p_wallet;delete args.p_filter;}const {data,error}=await api.rpc(options.company?'admin_proceed_fee_history':options.admin?'admin_member_wallet_history':'my_wallet_history',args);if(ticket!==turn||owner!==uid)return;if(error)throw error;if(!data||!Array.isArray(data.rows))throw Error('Wallet history is unavailable');const pages=Math.max(1,Math.ceil(data.total/20));if(page>pages){page=pages;save();return refresh()}rows=data.rows;render(data)}catch(e){if(ticket===turn&&owner===uid){rows=[];target.innerHTML='<p role="alert">Wallet history could not be refreshed.</p><button class="btn small" data-cash-retry>Retry</button>';api.error?.(e)}}finally{if(ticket===turn)target.removeAttribute('aria-busy')}}
 function label(r){if(options.company)return 'Proceed processing fee';if(r.activity_type==='package')return 'Self Package '+(r.previous_package_code?'Upgrade':'Activation')+' · '+(r.package_name||r.package_code||'Package');if(r.conversion_id)return kind==='proceed'?'Converted to wallets':'Proceed allocation';const route=r.metadata?.routing_key;if(route)return bonusNames[route]||route.replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase());return ({admin_mint:'Company credit',admin_burn:'Account adjustment',proceed_conversion:'Proceed allocation',transfer_in:'Transfer received',transfer_out:'Transfer sent'})[r.action]||r.reason||'Wallet activity'}
 function render(data){const target=host(),pages=Math.max(1,Math.ceil(data.total/20)),unit=['shopping','promotion'].includes(kind)?'points':'MIO';const heading=target.closest('.card')?.querySelector('.card-head');if(heading)heading.innerHTML='';
 const member=!options.company&&!options.admin;
 const balanceText=value=>balance(value)+(value!=null&&value!==''&&Number.isFinite(Number(value))?' '+unit:'');
 const balancePair=r=>`<div class="wallet-mobile-balances"><span>Balance Before <b>${balanceText(r.balance_before)}</b></span><span>Balance After <b>${balanceText(r.balance_after)}</b></span></div>`;
 const picker=member?`<label class="wallet-picker">Wallet<select name="wallet" data-wallet-picker>${walletKinds.map(k=>`<option value="${k}" ${k===kind?'selected':''}>${names[k]}</option>`).join('')}</select></label>`:'';
 target.innerHTML=`<nav ${options.admin?'':'hidden'} class="wallet-history-tabs" aria-label="Wallet history">${(options.admin?walletKinds:[]).map(k=>`<button type="button" data-wallet-kind="${k}" aria-pressed="${k===kind}" class="${k===kind?'active':''}">${names[k]}</button>`).join('')}</nav><div class="wallet-statement-heading"><h2>${names[kind]} history</h2><span>Balance <b>${fmt(data.balance)} ${unit}</b></span></div><form class="wallet-history-filters" data-wallet-filters><label class="wallet-from">From<input name="from" type="date" aria-label="From date" value="${esc(from)}"></label><label class="wallet-to">To<input name="to" type="date" aria-label="To date" value="${esc(to)}"></label>${picker}<label class="wallet-activity" ${options.company?'hidden':''}>Activity<select name="activity">${[['all','All activity'],['received','Received'],['sent','Paid'],...(kind==='cash'?[['package','Package charges']]:[])].map(([v,t])=>`<option value="${v}" ${filter===v?'selected':''}>${t}</option>`).join('')}</select></label><button class="btn primary small" type="submit">Apply</button><button class="btn small" type="button" data-wallet-clear>Clear</button></form><div class="cash-history-scroll" tabindex="0" aria-label="${names[kind]} transactions"><table class="cash-history-table ${options.company?'':'has-wallet-balances'}"><thead><tr>${['Date & time','Detail','Amount',...(!options.company?['Balance Before','Balance After']:[]),'Receipt'].map(t=>`<th ${t.startsWith('Balance ')?'class="wallet-balance-column"':''}>${t}</th>`).join('')}</tr></thead><tbody>${rows.length?rows.map(r=>`<tr><td>${esc(date(r.created_at))}</td><td><strong>${esc(label(r))}</strong>${r.counterparty_name||options.company?`<small>${esc(options.company?r.member_name:r.counterparty_name)}</small>`:''}${!options.company?balancePair(r):''}</td><td class="cash-amount"><strong>${fmt(r.amount)} ${unit}</strong><small class="wallet-direction ${Number(r.amount)>0?'received':'paid'}">${Number(r.amount)>0?'Received':kind==='proceed'&&r.conversion_id?'Converted':'Paid'}</small></td>${!options.company?`<td class="wallet-balance-column wallet-balance-before">${balanceText(r.balance_before)}</td><td class="wallet-balance-column wallet-balance-after"><strong>${balanceText(r.balance_after)}</strong></td>`:''}<td><button type="button" class="btn small" data-cash-receipt="${esc(r.id)}">View</button></td></tr>`).join(''):`<tr><td colspan="${options.company?4:6}" class="ex-empty">No activity in this period.</td></tr>`}</tbody></table></div><div class="ex-pagination"><button type="button" class="btn small" data-cash-page="-1" ${page<=1?'disabled':''}>Previous</button><span>${data.total?((page-1)*20+1):0}–${Math.min(page*20,data.total)} of ${data.total} · PKT</span><button type="button" class="btn small" data-cash-page="1" ${page>=pages?'disabled':''}>Next</button></div>${kind==='proceed'&&!options.admin?'<button type="button" class="btn small" data-page="wallet">Convert to Cash Wallet</button>':''}`}
 function receipt(r){const packageCharge=r.activity_type==='package',transfer=['transfer_in','transfer_out'].includes(r.action),unit=['shopping','promotion'].includes(kind)?'points':'MIO';let details;if(options.company){window.MioTransferReceipt?.show({id:r.id,date:date(r.created_at),amount:fmt(r.amount),heading:'Company Income Receipt',direction:'Processing fee received',details:[['Member',r.member_name],['MIO ID',r.member_code],['Source','Proceed conversion'],['Converted amount',fmt(r.proceed_amount)+' MIO'],['Fee rate',(Number(r.fee_rate)*100).toFixed(2)+'%'],['Destination','Company treasury']]});return;}
 if(packageCharge)details=[['Activity',r.previous_package_code?'Self Package Upgradation':'Self Package Activation'],['Member',r.member_name],['MIO ID',r.member_code],['Package',(r.previous_package_name||r.previous_package_code||'Free')+' → '+(r.package_name||r.package_code||'Package')],['Paid from','Cash Wallet']];
 else details=[['Member',r.member_name],['MIO ID',r.member_code],['Activity',label(r)],['Wallet',names[kind]],...(transfer?[['From',r.sender_name||'Member'],['To',r.receiver_name||'Member']]:[])];
 if(r.split)details.push(['Converted total',fmt(r.split.proceed)+' MIO'],['Cash allocation',fmt(r.split.cash)+' MIO'],['Shopping allocation',fmt(r.split.shopping)+' points'],['Promotion allocation',fmt(r.split.promotion)+' points'],['Company fee',fmt(r.split.fee)+' MIO']);
 details.push(['Balance before',(Number(r.balance_before)<0?'−':'')+fmt(r.balance_before)+' '+unit],['Balance after',(Number(r.balance_after)<0?'−':'')+fmt(r.balance_after)+' '+unit]);
 window.MioTransferReceipt?.show({id:r.conversion_id||r.transfer_id||r.activation_id||r.id,date:date(r.created_at),amount:fmt(r.amount),unit,heading:packageCharge?'Package Receipt':r.conversion_id?'Proceed Receipt':transfer?'Transfer Receipt':'Wallet Receipt',direction:Number(r.amount)>0?'Amount received':r.conversion_id&&kind==='proceed'?'Amount converted':'Amount paid',details})}
 return {mount,setIdentity,setWallet,refresh,dispose(){turn++;uid=null;rows=[]}};
};
window.MioCashHistory=window.createMioWalletHistory();
