(()=>{
 const instances=new Map(),keys=['required_left_directs','required_right_directs','required_left_dp','required_right_dp'];
 const labels=['Left directs','Right directs','Left DP','Right DP'];
 const num=n=>Number(n).toLocaleString('en-US',{maximumFractionDigits:4});
 const validRules=r=>r&&Number.isInteger(r.version)&&keys.every(k=>Number.isFinite(Number(r[k]))&&Number(r[k])>=1);
 function mount(root,{rpc,owner,allowed,confirm,changed=()=>{}}){
  instances.get(root)?.();const identity=owner();let dead=false,busy=false,saving=false,data=null,editVersion=null,request=0;
  root.innerHTML=`<div class="binding-card-main"><svg class="binding-card-icon" viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><circle cx="11" cy="10" r="4"/><path d="M3 27v-4a8 8 0 0 1 16 0v4H3zM22 6a4 4 0 0 1 0 8m1 5a7 7 0 0 1 6 7v1h-6"/></svg><div class="binding-card-copy"><h3>Active Binding Members</h3><p>Binary qualification complete</p><p data-binding-rules>Loading current rules…</p><button type="button" class="binding-edit" data-binding-edit aria-expanded="false">Edit qualification rules</button></div><div class="binding-card-total"><span data-binding-live>Updating…</span><strong data-binding-count>—</strong><small>members</small><small>Updates automatically</small></div></div><p data-binding-status role="status" hidden></p><form class="binding-rules-form" hidden><h4>Binary Qualification Rules</h4><div class="binding-rule-inputs">${keys.map((k,i)=>`<label>${labels[i]}<input name="${k}" type="number" min="1" max="${i<2?'1000':'1000000'}" step="${i<2?'1':'0.0001'}" required></label>`).join('')}</div><p class="helper">Changes apply to members who have not qualified yet. Earned qualifications remain valid.</p><button type="submit" class="btn primary">Save qualification rules</button><button type="button" class="btn" data-binding-cancel>Cancel</button></form>`;
  const q=s=>root.querySelector(s),form=q('form'),status=q('[data-binding-status]'),toggle=q('[data-binding-edit]');
  const valid=()=>!dead&&root.isConnected&&owner()===identity&&allowed();
  const visible=()=>!document.hidden&&root.getClientRects().length>0;
  function message(text){status.textContent=text;status.hidden=!text;}
  function render(payload){
   if(!validRules(payload?.rules)||!Number.isInteger(payload.active_members)||payload.active_members<0)throw Error('Invalid qualification response');
   data=payload;const r=data.rules;
   q('[data-binding-count]').textContent=num(data.active_members);
   q('[data-binding-rules]').textContent=`${num(r.required_left_directs)} Left Direct${r.required_left_directs===1?'':'s'} + ${num(r.required_right_directs)} Right Direct${r.required_right_directs===1?'':'s'} · ${num(r.required_left_dp)} DP Left + ${num(r.required_right_dp)} DP Right`;
   q('[data-binding-live]').textContent='● Live';toggle.disabled=false;
  }
  async function refresh(force=false){
   if(!valid()){dispose();return;}if(busy||saving||(!force&&!visible()))return;
   busy=true;const ticket=++request;
   try{const result=await rpc('admin_binary_qualification_summary');if(ticket!==request)return;if(!valid()){dispose();return;}if(result.error)throw result.error;render(result.data);if(form.hidden)message('');}
   catch{if(valid()){q('[data-binding-live]').textContent='Update unavailable';message('Could not refresh qualification details. Retrying automatically.');}}
   finally{busy=false;}
  }
  function close(){form.hidden=true;toggle.setAttribute('aria-expanded','false');}
  function click(event){
   if(event.target.closest('[data-binding-edit]')&&data&&!saving){if(!form.hidden){close();return;}keys.forEach(k=>form.elements[k].value=data.rules[k]);editVersion=data.rules.version;form.hidden=false;toggle.setAttribute('aria-expanded','true');message('');}
   if(event.target.closest('[data-binding-cancel]')&&!saving)close();
  }
  async function save(event){
   event.preventDefault();if(!valid()||saving||!form.reportValidity())return;
   saving=true;request++;const rules=Object.fromEntries(keys.map(k=>[k,Number(form.elements[k].value)]));
   form.querySelectorAll('button,input').forEach(b=>b.disabled=true);message('');
   try{
    await confirm(`Save binary qualification: ${rules.required_left_directs} left directs, ${rules.required_right_directs} right directs, ${rules.required_left_dp} left DP and ${rules.required_right_dp} right DP. Existing qualifications remain valid.`);
    if(!valid()){dispose();return;}
    const result=await rpc('admin_save_binary_qualification_rules',{p_rules:rules,p_expected_version:editVersion});
    if(!valid()){dispose();return;}if(result.error)throw result.error;
    render(result.data);close();message('Qualification rules saved.');changed();
   }catch(error){if(valid())message(error?.message||'Rules could not be saved.');}
   finally{saving=false;if(!dead)form.querySelectorAll('button,input').forEach(b=>b.disabled=false);}
  }
  const onVisible=()=>refresh(),timer=setInterval(onVisible,30000);
  function dispose(){if(dead)return;dead=true;clearInterval(timer);window.removeEventListener('focus',onVisible);document.removeEventListener('visibilitychange',onVisible);root.removeEventListener('click',click);form.removeEventListener('submit',save);root.replaceChildren();instances.delete(root);}
  dispose.identity=identity;instances.set(root,dispose);root.addEventListener('click',click);form.addEventListener('submit',save);window.addEventListener('focus',onVisible);document.addEventListener('visibilitychange',onVisible);toggle.disabled=true;refresh(true);
 }
 window.MioBinaryQualification={mount,setIdentity(identity){for(const dispose of [...instances.values()])if(dispose.identity!==identity)dispose();},clear(){for(const dispose of [...instances.values()])dispose();}};
})();
