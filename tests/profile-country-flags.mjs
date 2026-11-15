import {JSDOM} from 'jsdom';
import {readFile,mkdir,writeFile,cp} from 'node:fs/promises';
import assert from 'node:assert/strict';
let setup=(await readFile('tests/interface.mjs','utf8')).split('const q=w.qa;')[0].replace(/^import .*;\n/gm,'');
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const {w,q,calls,fixtures}=await new AsyncFunction('JSDOM','readFile','assert',setup+';return {w,q:w.qa,calls,fixtures:monthlyAdminFixtures};')(JSDOM,readFile,assert);
w.HTMLDialogElement.prototype.showModal=function(){this.open=true};w.HTMLDialogElement.prototype.close=function(){this.open=false;this.dispatchEvent(new w.Event('close'))};
w.eval(await readFile('dist/member-management.js','utf8'));const errors=[];w.addEventListener('error',e=>errors.push(e.error));
await new Promise(r=>setTimeout(r,60));
q.setSession({user:{id:'profile-demo'}});q.setProfile({full_name:'DEMO MEMBER',phone:'+923001234567',country_code:'PK',gender:'male'});
const edit=w.document.createElement('button');edit.dataset.editOwnProfile='';w.document.body.append(edit);edit.click();
const dialog=w.document.querySelector('.member-management-dialog'),form=dialog.querySelector('form'),trigger=form.querySelector('.country-search-trigger'),search=form.querySelector('[type=search]');
assert.ok(trigger);assert.equal(form.elements.country.value,'PK');assert.equal(trigger.querySelector('img').getAttribute('src'),'/assets/flag-pk.svg');assert.equal(trigger.querySelector('.country-picker-name').textContent,'Pakistan');
trigger.click();search.value='United Arab';search.dispatchEvent(new w.Event('input'));const choice=form.querySelector('[data-country=AE]');assert.ok(choice);assert.equal(choice.querySelector('img').getAttribute('src'),'https://flagcdn.com/w40/ae.png');choice.click();assert.equal(form.elements.country.value,'AE');assert.equal(trigger.querySelector('.country-picker-name').textContent,'United Arab Emirates');assert.equal(trigger.getAttribute('aria-expanded'),'false');
trigger.click();search.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert.equal(trigger.getAttribute('aria-expanded'),'false');
fixtures.save_my_profile={__error:{message:'Retry example'}};
form.dispatchEvent(new w.Event('submit',{bubbles:true,cancelable:true}));assert.equal(form.querySelector('[type=submit]').disabled,true);assert.equal(trigger.disabled,false);
await new Promise(r=>setTimeout(r,20));const save=calls.find(c=>c.rpc==='save_my_profile');assert.equal(save.args.p_country,'AE');assert.equal(save.args.p_name,'DEMO MEMBER');assert.equal(form.querySelector('[type=submit]').disabled,false);assert.match(dialog.textContent,/Retry example/);
dialog.querySelector('[data-close]').click();assert.equal(w.document.querySelector('.member-management-dialog'),null);assert.deepEqual(errors,[]);
console.log('PASS profile real-flag picker, search, selection, Escape, country-code payload and submit/retry button state');
if(process.env.MIO_PROFILE_PREVIEW){
 const out=process.env.MIO_PROFILE_PREVIEW;await mkdir(out+'/dist',{recursive:true});await mkdir(out+'/.openai',{recursive:true});await cp('dist',out+'/dist',{recursive:true});await writeFile(out+'/.openai/hosting.json',JSON.stringify({static:{directory:'dist'}}));
 const source=await readFile('dist/app.js','utf8'),helpers=source.slice(source.indexOf('const COUNTRY_CODES='),source.indexOf('function setupCountryFields()')),options=source.split('\n').find(l=>l.startsWith('function countrySelectOptions('));
 const doc=new JSDOM(await readFile('dist/index.html','utf8'));const css=[...doc.window.document.querySelectorAll('link[rel=stylesheet]')].map(n=>n.outerHTML).join('');
 await writeFile(out+'/dist/profile.html',`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">${css}<title>Profile country preview</title><body><header class="top"><div class="wrap top-main"><img src="/market-is-online-logo-header.svg" alt="Market Is Online" width="245"></div></header><main class="wrap"><h1>My profile</h1><button id="edit" class="btn primary">Edit my profile</button></main><script src="/member-management.js"></script><script>const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));${helpers}\n${options}\nconst api={root:document.body,esc,countryOptions:countrySelectOptions,countrySearch:enableCountrySearch,identity:()=> 'demo',authorized:()=>true,db:{rpc:async()=>({error:{message:'Preview only — no profile is saved.'}})}};document.getElementById('edit').onclick=()=>MioMemberManagement.editSelf(api,{full_name:'DEMO MEMBER',phone:'+923001234567',country_code:'PK',gender:'male'},()=>{});document.getElementById('edit').click();</script></body>`);
 await writeFile(out+'/dist/index.html',`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Profile country QA</title><style>body{margin:0;background:#e8eeea;font:14px system-ui}header{padding:10px;background:white}select{padding:8px}iframe{display:block;border:1px solid #abbfb0;margin:12px auto}</style><header>Profile QA · synthetic data <select id="size" aria-label="Viewport"><option>1366x650</option><option>390x744</option><option>320x568</option></select></header><iframe id="preview" title="Profile preview" src="/profile.html"></iframe><script>const f=document.getElementById('preview'),s=document.getElementById('size');function resize(){[f.width,f.height]=s.value.split('x')}resize();s.onchange=resize;</script>`);
 console.log('Preview ready:',out);doc.window.close();
}
w.close();
