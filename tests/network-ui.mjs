import {JSDOM} from 'jsdom';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
let setup=(await readFile('tests/interface.mjs','utf8')).split('const q=w.qa;')[0].replace(/^import .*;\n/gm,'');
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const {w,q}=await new AsyncFunction('JSDOM','readFile','assert',setup+';return {w,q:w.qa};')(JSDOM,readFile,assert);
await new Promise(r=>setTimeout(r,50));
q.setSession({user:{id:'root'}});q.setAdmin(false);q.go('network-graphical');
const root={id:'root',full_name:'Example Member',member_code:'MIO-EXAMPLE',package:'PREMIUM',depth:0,country_code:'PK',profile_photo_url:'https://mio.example.test/assets/avatar-male.svg',status:'active'};
const nodes=[root,...[1,2,3].map((i)=>({id:'member-'+i,parent_id:i===1?'root':'member-'+(i-1),full_name:'Paid Member '+i,member_code:'MIO-MEMBER'+i,package:'BASIC_1',side:'LEFT',placement_path:'L'.repeat(i),depth:i,country_code:'PK',status:'active'}))];
for(const kind of ['generation','binary','single_line','vendor']){
 q.el('networkKind').value=kind;
 for(const b of w.document.querySelectorAll('[data-network-kind]')){b.classList.toggle('active',b.dataset.networkKind===kind);b.setAttribute('aria-selected',String(b.dataset.networkKind===kind));}
 const data=kind==='vendor'?[root,...[1,2,3].map(i=>({id:'vendor-'+i,parent_id:'root',depth:1,full_name:'Vendor '+i,business_name:'Vendor '+i,node_type:'vendor',status:'active',country_code:'PK'}))]:nodes;
 q.drawNetwork(data,kind);
 assert.equal(q.el('networkVisual').querySelectorAll('[data-tree-info]').length,4);
 assert.equal(q.el('networkVisual').querySelectorAll('.network-country-flag').length,4);
 if(kind==='binary'||kind==='single_line'){
  const y=i=>+q.el('networkVisual').querySelector(`[data-tree-info="${i}"]`).parentElement.parentElement.getAttribute('y');
  assert.equal(y('member-1')-y('root'),142);
  assert.equal(y('member-2')-y('member-1'),142);
 }
 q.el('networkVisual').querySelector('[data-tree-info="root"]').click();
 assert.ok(q.el('treeMemberDetails').querySelector('.country-badge .network-country-flag'));
 assert.equal(q.el('treeMemberDetails').querySelector('.tree-profile-picture').getAttribute('src'),'https://mio.example.test/assets/avatar-male.svg');
 if(process.env.MIO_NETWORK_PREVIEW){
  await mkdir(process.env.MIO_NETWORK_PREVIEW,{recursive:true});
  const clone=w.document.documentElement.cloneNode(true);clone.querySelectorAll('script').forEach(x=>x.remove());
  clone.querySelectorAll('img').forEach(i=>{if(i.src.startsWith('https://mio.example.test/assets/'))i.src=new URL(i.src).pathname});clone.classList.remove('route-restoring');clone.querySelector('#routeLoading')?.remove();
  await writeFile(process.env.MIO_NETWORK_PREVIEW+'/'+kind+'.html','<!doctype html>'+clone.outerHTML);
 }
}
console.log('PASS original four tree layouts, three level-one vendors, Pakistan images, root photo and continuous paid chain');
w.close();
