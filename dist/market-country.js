(function(){
'use strict';
function create(api){
 const key='mio-market-country-v1',valid=c=>api.codes.includes(c),label=c=>api.name(c);
 let country='',source='',ready=null,revision=0,changing=false;
 const host=document.getElementById('marketCountryBar'),select=document.getElementById('marketCountry');
 if(select){select.innerHTML=api.options(country);select.value=country;api.search(select);select.addEventListener('change',()=>change(select.value));}
 function render(){if(select&&select.value!==country){select.value=country;select.dispatchEvent(new Event('change'));}const note=document.getElementById('marketCountryStatus');if(note)note.textContent=country?`Shopping in ${label(country)} · ${source}. Products and promotions are local to this country.`:'Select your country to see local stores and products.';}
 async function init(){
  if(ready)return ready;
  ready=(async()=>{
   if(revision)return country;
   const ticket=revision;
   let detected='';
   const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),3000);
   try{
    const r=await fetch('/api/market-country',{cache:'no-store',signal:controller.signal});if(r.ok)detected=(await r.json()).country;
   }catch{}finally{clearTimeout(timeout);}
   if(ticket!==revision)return country;
   if(valid(detected)){country=detected;source='Detected location';}
   else{
    let saved='';
    try{saved=localStorage.getItem(key);}catch{}
    const profile=api.profile?.();
    if(valid(saved)){country=saved;source='Your selection';}
    else if(valid(profile)){country=profile;source='Profile country';}
   }
   render();
   return country;
  })();
  return ready;
 }
 async function change(code){if(!valid(code)||code===country){render();return;}revision++;country=code;source='Your selection';try{localStorage.setItem(key,country);}catch{}render();changing=true;host?.setAttribute('aria-busy','true');try{await api.changed(country);}catch{const note=document.getElementById('marketCountryStatus');if(note)note.textContent='Could not load this country. Please retry.';}finally{changing=false;host?.removeAttribute('aria-busy');}}
 render();return {init,current:()=>country,revision:()=>revision,label:()=>country?label(country):'your country',change,busy:()=>changing};
}
window.MioMarketCountry={create};
})();
