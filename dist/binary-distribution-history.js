/* Historical pool statements. No payout or wallet mutation is performed here. */
(()=>{
  const instances=new Map();
  const esc=value=>String(value??'').replace(/[&<>"']/g,char=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const number=value=>value==null||value===''||!Number.isFinite(Number(value))?'Unavailable':Number(value).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:10});
  const date=(value,zone)=>{const d=new Date(value);return Number.isNaN(d.getTime())?'Date unavailable':d.toLocaleString('en-GB',{timeZone:zone,day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',hour12:false});};
  function statement(c,index){
    const members=Array.isArray(c.members)?c.members:[],retained=Number(c.pool_amount)-Number(c.total_paid);
    return `<details class="binary-distribution" ${index===0?'open':''}><summary><span><strong>${esc(date(c.distributed_at,'Asia/Karachi'))} PKT</strong><small>${esc(date(c.distributed_at,'UTC'))} UTC</small></span><span class="binary-distribution-status">${c.status==='unallocated'?'Unallocated':'Completed'}</span><b>${number(c.total_paid)} MIO</b></summary><div class="binary-distribution-body"><div class="binary-distribution-stats"><div><span>Shares distributed</span><b>${number(c.total_shares)}</b></div><div><span>Rate per share</span><b>${number(c.share_price)} MIO</b></div><div><span>Total paid</span><b>${number(c.total_paid)} MIO</b></div><div><span>Recipients</span><b>${esc(c.recipient_count)}</b></div></div><div class="binary-distribution-scroll" role="region" aria-label="Distribution recipients" tabindex="0"><table class="binary-distribution-table"><thead><tr><th>Member</th><th class="binary-distribution-id">MIO ID</th><th class="numeric">Shares</th><th class="numeric">Rate <small>(MIO)</small></th><th class="numeric">Paid <small>(MIO)</small></th></tr></thead><tbody>${members.length?members.map(m=>`<tr><td><strong>${esc(m.name)}</strong><small class="binary-distribution-mobile-id">${esc(m.mio_id||'ID unavailable')}</small></td><td class="binary-distribution-id">${esc(m.mio_id||'ID unavailable')}</td><td class="numeric"><span class="binary-share-tag">${number(m.shares)}</span></td><td class="numeric"><span class="binary-share-tag">${number(m.share_price)}</span></td><td class="numeric binary-distribution-paid">${number(m.paid)}</td></tr>`).join(''):'<tr><td colspan="5">No member payouts in this distribution.</td></tr>'}</tbody><tfoot><tr><th><span>Total</span><small>${esc(c.recipient_count)} recipients</small></th><td class="binary-distribution-id"></td><td class="numeric">${number(c.total_shares)}</td><td></td><td class="numeric">${number(c.total_paid)}</td></tr></tfoot></table></div>${retained>0.000001?`<p class="helper">Pool allocated: ${number(c.pool_amount)} MIO · Retained / unallocated: ${number(retained)} MIO</p>`:''}<p class="binary-distribution-reference">${esc(c.cycle_code)}</p></div></details>`;
  }
  function mount(root,{rpc,owner,allowed}){
    instances.get(root)?.();
    const toggle=root.querySelector('#binaryDistributionToggle'),box=root.querySelector('#binaryDistributionHistory');
    if(!toggle||!box)return;
    const identity=owner();let version=0,loaded=false,offset=0,busy=false;
    const valid=()=>root.isConnected&&owner()===identity&&allowed();
    const dispose=()=>{version++;root.removeEventListener('click',click);box.replaceChildren();box.hidden=true;toggle.setAttribute('aria-expanded','false');instances.delete(root);};
    async function load(next=0){
      if(!valid()){dispose();return;}
      const request=++version;busy=true;box.setAttribute('aria-busy','true');
      box.innerHTML='<p role="status">Loading distribution history…</p>';
      try{
        const {data,error}=await rpc('admin_binary_distribution_history',{p_limit:10,p_offset:next});
        if(request!==version)return;if(!valid()){dispose();return;}if(error)throw error;
        if(!data||!Array.isArray(data.cycles))throw Error('Invalid statement response');
        offset=next;loaded=true;
        box.innerHTML=`<div class="binary-distribution-heading"><div><h3>Distribution History</h3><p>Completed distributions · latest first</p></div><button type="button" class="btn small" data-distribution-refresh>Refresh</button></div>${data.cycles.length?data.cycles.map(statement).join(''):'<p class="empty">No completed distributions yet.</p>'}<nav class="binary-distribution-pages" aria-label="Distribution pages"><button type="button" class="btn small" data-distribution-prev ${offset===0?'disabled':''}>Previous</button><span>${data.total_cycles?offset+1:0}–${Math.min(offset+data.cycles.length,data.total_cycles)} of ${esc(data.total_cycles)} distributions</span><button type="button" class="btn small" data-distribution-next ${offset+data.cycles.length>=data.total_cycles?'disabled':''}>Next</button></nav>`;
      }catch{
        if(request!==version)return;if(!valid()){dispose();return;}loaded=false;
        box.innerHTML='<p role="alert">Distribution history could not be loaded.</p><button type="button" class="btn small" data-distribution-refresh>Try again</button>';
      }finally{if(request===version){busy=false;box.removeAttribute('aria-busy');}}
    }
    function click(event){
      const button=event.target.closest('button');if(!button||!root.contains(button))return;
      if(button===toggle){if(!valid()){dispose();return;}box.hidden=!box.hidden;toggle.setAttribute('aria-expanded',String(!box.hidden));if(!box.hidden&&!loaded&&!busy)load();}
      if(busy)return;
      if(button.hasAttribute('data-distribution-refresh'))load(offset);
      if(button.hasAttribute('data-distribution-prev'))load(Math.max(0,offset-10));
      if(button.hasAttribute('data-distribution-next'))load(offset+10);
    }
    dispose.identity=identity;root.addEventListener('click',click);instances.set(root,dispose);
  }
  window.MioBinaryDistributions={mount,setIdentity(identity){for(const dispose of [...instances.values()])if(dispose.identity!==identity)dispose();},clear(){for(const dispose of [...instances.values()])dispose();}};
})();
