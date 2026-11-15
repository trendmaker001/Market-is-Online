import {JSDOM} from 'jsdom';
import {readFile,mkdir,writeFile,cp} from 'node:fs/promises';
import assert from 'node:assert/strict';
// Exercise the real renderer and click handlers with the existing isolated RPC double.
let setup=(await readFile('tests/interface.mjs','utf8')).split('const q=w.qa;')[0].replace(/^import .*;\n/gm,'').replace('window.qa={','window.qa={fitTreeToViewport,focusTreeRoot,treeState:()=>({root:treeRootPoint,pan:treePan,zoom:treeZoom,size:treeBaseSize}),');
const AsyncFunction=Object.getPrototypeOf(async function(){}).constructor;
const {w,q,dom,fixtures}=await new AsyncFunction('JSDOM','readFile','assert',setup+';return {w,q:w.qa,dom,fixtures:monthlyAdminFixtures};')(JSDOM,readFile,assert);
const tick=()=>new Promise(r=>setTimeout(r,60));await tick();
const root={id:'root',full_name:'DEMO MEMBER',member_code:'MIO-DEMO-ROOT',depth:0,gender:'male',package:'PREMIUM',country_code:'PK',joined_at:'2026-10-12T12:00:00Z',status:'active',binary_qualified:true,binary_qualified_at:'2026-11-15T12:00:00Z',left_direct_count:5,right_direct_count:3,left_dp:1350,right_dp:1100,left_team_count:7,right_team_count:8,left_bp:693.25,right_bp:1090,available_binary_shares:6.9,total_left_bp:1340,total_right_bp:1840,total_left_brp:1340,total_right_brp:1840};
const nodes=[root,{...root,id:'female',parent_id:'root',depth:1,side:'LEFT',full_name:'FEMALE DEMO',gender:'female',package:'ADVANCED_2'},{...root,id:'unknown',parent_id:'root',depth:1,side:'RIGHT',full_name:'UNSPECIFIED DEMO',gender:null,package:'ADVANCED_1'},{...root,id:'photo',parent_id:'female',depth:2,side:'LEFT',full_name:'PHOTO DEMO',gender:'female',profile_photo_url:'https://photos.example.test/uploaded.jpg'}];
fixtures.my_generation_member_details={package_name:'Platinum',tngp:1780,direct_count:8,active_direct_count:8,direct_points:2450,active_generations:8,allowed_generations:10,total_generation_network:15,generations:[],directs:[]};
fixtures.member_binary_placement_details={package_name:'Platinum',allowed_levels:30,total_team:15,left_team:7,right_team:8,levels:[]};
q.setSession({user:{id:'tree-demo'}});q.setProfile({full_name:root.full_name,status:'active'});q.setAdmin(false);q.updateAuthNavigation();q.go('network-graphical');await tick();
const draw=async(kind,items=nodes)=>{q.el('networkKind').value=kind;q.drawNetwork(items,kind);q.el('networkVisual').querySelector('[data-tree-info="root"]').click();await tick();};
const img=id=>q.el('networkVisual').querySelector('[data-tree-info="'+id+'"] img').getAttribute('src');
for(const kind of ['generation','binary','single_line']){await draw(kind);assert.equal(img('root'),'/assets/tree-member-male.svg');assert.equal(img('female'),'/assets/tree-member-female.svg');assert.equal(img('unknown'),'/assets/avatar-neutral.svg');assert.equal(img('photo'),'https://photos.example.test/uploaded.jpg');assert.equal(q.el('treeMemberDetails').querySelector('.tree-profile-picture').getAttribute('src'),'/assets/tree-member-male.svg');}
await draw('free_generation',nodes.map(n=>({...n,free_account:true,package:null})));assert.equal(img('root'),'/assets/avatar-free-male.svg');assert.equal(img('female'),'/assets/avatar-free-female.svg');assert.match(q.el('networkVisual').innerHTML,/#dc2626/);
await draw('vendor');assert.equal(img('female'),'/assets/avatar-female.svg');
await draw('binary');assert.equal(q.el('treeMemberDetails').querySelector('.tree-week-shares strong').textContent,'6.90');assert.doesNotMatch(q.el('treeMemberDetails').textContent,/Weekly requalification|Qualification completed permanently/);assert.match(q.el('treeMemberDetails').textContent,/15 Nov 2026/);assert.match(q.el('treeMemberDetails').textContent,/TNBP · Total Network Binary Points Till Now/);assert.match(q.el('treeMemberDetails').textContent,/BRP · Binary Rank Points Till Now/);
q.el('treeMemberDetails').querySelector('.tree-details-close').click();assert.ok(q.el('networkVisual').closest('.tree-workspace').classList.contains('tree-details-collapsed'));
await draw('binary',[{...root,binary_qualified:false}]);assert.match(q.el('treeMemberDetails').textContent,/Complete one active personal direct and 20 DP/);
console.log('PASS tree-only gender defaults, preserved photos/Free/Vendor colours, two-decimal shares, compact qualification and close interaction');
// An asymmetric tree must keep the member at the viewport midpoint on open, fit and resize.
const asymmetric=[...nodes,{...root,id:'far',parent_id:'unknown',depth:2,side:'RIGHT'},{...root,id:'farther',parent_id:'far',depth:3,side:'RIGHT'},{...root,id:'extra',parent_id:'unknown',depth:2,side:'LEFT'}];
const visual=q.el('networkVisual');
for(const width of [1366,390,360]){
 Object.defineProperty(visual,'clientWidth',{configurable:true,value:width});Object.defineProperty(visual,'clientHeight',{configurable:true,value:650});
 for(const kind of ['generation','binary','single_line']){
  await draw(kind,asymmetric);q.focusTreeRoot();await tick();
  const centers=new Map(Array.from(visual.querySelectorAll('foreignObject'),box=>[box.querySelector('[data-tree-info]').dataset.treeInfo,Number(box.getAttribute('x'))+68]));
  for(const parent of asymmetric){const xs=asymmetric.filter(n=>n.parent_id===parent.id).map(n=>centers.get(n.id));if(xs.length)assert.ok(Math.abs(centers.get(parent.id)-(Math.min(...xs)+Math.max(...xs))/2)<.01,kind+' parent centered over its own children: '+parent.id)}
  assert.equal(visual.querySelectorAll('[data-tree-info]').length,asymmetric.length,'no member omitted or invented');
  let state=q.treeState();assert.ok(Math.abs(state.pan.x+state.root.x*state.zoom-width/2)<.01,kind+' open');
  q.fitTreeToViewport();await tick();state=q.treeState();assert.ok(Math.abs(state.pan.x+state.root.x*state.zoom-width/2)<.01,kind+' fit');
  assert.ok(state.pan.x>=-1 && state.pan.x+state.size.width*state.zoom<=width+1,kind+' fit bounds');
 }
}
console.log('PASS asymmetric root stays centered for Generation/Binary/Placement at desktop and mobile sizes, including Fit');
if(process.env.MIO_TREE_PREVIEW){
 const out=process.env.MIO_TREE_PREVIEW;await mkdir(out+'/dist',{recursive:true});await mkdir(out+'/.openai',{recursive:true});await cp('dist',out+'/dist',{recursive:true});await writeFile(out+'/.openai/hosting.json',JSON.stringify({static:{directory:'dist'}}));
 for(const kind of ['binary','generation','single_line','free_generation','vendor']){
  await draw(kind,kind==='free_generation'?nodes.map(n=>({...n,free_account:true,package:null})):nodes);
  w.document.documentElement.classList.remove('route-restoring');
  const copy=new w.DOMParser().parseFromString(dom.serialize(),'text/html');copy.querySelectorAll('script').forEach(s=>s.remove());copy.querySelectorAll('img[src="https://photos.example.test/uploaded.jpg"]').forEach(img=>img.src='/assets/avatar-male.svg');
  copy.querySelectorAll('[data-network-kind]').forEach(b=>{b.classList.toggle('active',b.dataset.networkKind===kind);b.setAttribute('aria-selected',String(b.dataset.networkKind===kind));});
  const realControls=(await readFile('dist/app.js','utf8')).split('\n').filter(line=>/^function (setTreePan|sizeTreePanSurface|setTreeZoom|centerTreeInViewport|focusTreeRoot|fitTreeToViewport)\(/.test(line)).join('\n');
  const state=q.treeState();
  const boot=`<script>const el=id=>document.getElementById(id);let treeZoom=${state.zoom},treePan=${JSON.stringify(state.pan)},treeRootPoint=${JSON.stringify(state.root)},treeBaseSize=${JSON.stringify(state.size)};${realControls};focusTreeRoot();window.addEventListener('load',focusTreeRoot);window.addEventListener('resize',focusTreeRoot);document.addEventListener('click',e=>{const z=e.target.closest('[data-tree-zoom]');if(z){if(z.dataset.treeZoom==='0')fitTreeToViewport();else setTreeZoom(treeZoom*(z.dataset.treeZoom==='1'?1.25:.8));}});document.addEventListener('click',e=>{const ws=document.querySelector('.tree-workspace');if(e.target.closest('.tree-details-close'))ws.classList.add('tree-details-collapsed');if(e.target.closest('[data-tree-info],[data-tree-action="info"]'))ws.classList.remove('tree-details-collapsed');const t=e.target.closest('[data-network-kind]');if(t&&t.dataset.networkKind!=='manager')location.href='/'+t.dataset.networkKind+'.html';});</script>`;
  await writeFile(out+'/dist/'+kind+'.html','<!doctype html>'+copy.documentElement.outerHTML.replace('</body>',boot+'</body>'));
 }
 await writeFile(out+'/dist/index.html',`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Tree layout QA</title><style>body{margin:0;background:#e8eeea;font:14px system-ui}header{display:flex;gap:12px;padding:10px;background:#fff;align-items:center}button,select{padding:8px}iframe{display:block;margin:12px auto;border:1px solid #abbfb0;background:#fff}pre{white-space:pre-wrap;margin:12px}</style><header><b>Tree QA · synthetic data</b><label>Viewport <select id="size"><option>1366x650</option><option>390x744</option><option>390x844</option><option>360x640</option><option>320x568</option></select></label><button id="manager">Toggle Manager tab</button><button id="check">Check layout</button></header><iframe id="preview" title="Tree preview" src="/binary.html"></iframe><pre id="report"></pre><script>const f=document.getElementById('preview'),s=document.getElementById('size');function resize(){[f.width,f.height]=s.value.split('x')}resize();s.onchange=resize;document.getElementById('manager').onclick=()=>f.contentDocument.getElementById('managerTreeTab').classList.toggle('hidden');document.getElementById('check').onclick=()=>{const d=f.contentDocument,w=f.contentWindow,r=n=>{const b=n.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height,bottom:b.bottom}},panel=d.querySelector('.tree-member-details'),x=d.querySelector('.tree-details-close');document.getElementById('report').textContent=JSON.stringify({viewport:[w.innerWidth,w.innerHeight],panel:r(panel),content:panel.scrollHeight,client:panel.clientHeight,close:r(x),closeImage:w.getComputedStyle(x).backgroundImage,closeColour:w.getComputedStyle(x).color,rail:w.getComputedStyle(d.querySelector('.tree-action-rail')).display,tabs:[...d.querySelectorAll('.network-tree-tab')].filter(n=>!n.classList.contains('hidden')).map(n=>({label:n.textContent,...r(n)})),rootX:(()=>{const b=d.querySelector('[data-tree-info="root"]').getBoundingClientRect();return b.x+b.width/2})(),expectedRootX:(()=>{const b=d.getElementById('networkVisual').getBoundingClientRect();return b.x+b.width/2})(),horizontalOverflow:d.documentElement.scrollWidth>w.innerWidth},null,2)};</script>`);
 console.log('Preview ready:',out);
}
w.close();
