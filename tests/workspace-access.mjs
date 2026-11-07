import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=await readFile('dist/app.js','utf8');
const start=source.indexOf('async function requireWorkspaceAccess()');
const end=source.indexOf('\n',source.indexOf('async function confirmSensitive(',start));
const code=source.slice(start,end);
function setup({admin=false,reply={data:true,error:null},uid='company',factor=true}={}){
 const nodes=new Map();let queries=0;
 const c={session:uid?{user:{id:uid}}:null,isAdmin:admin,actionResolver:null,
  db:{rpc:async name=>{assert.equal(name,'current_user_is_admin');queries++;return typeof reply==='function'?reply(c):reply}},
  updateAuthNavigation(){},verifiedFactor:async()=>typeof factor==='function'?factor(c):factor,
  go(page){c.page=page},el(id){if(!nodes.has(id))nodes.set(id,{textContent:'',value:'',showModal(){this.open=true},focus(){}});return nodes.get(id)}};
 vm.createContext(c);vm.runInContext(code,c);return {c,nodes,queries:()=>queries};
}
let t=setup();assert.equal(await t.c.requireWorkspaceAccess(),'company');assert.equal(t.c.isAdmin,true);assert.equal(t.queries(),1);
t=setup({admin:true,reply:{data:false,error:null}});await assert.rejects(t.c.requireWorkspaceAccess(),/requires the company admin/);assert.equal(t.c.isAdmin,false);
t=setup({uid:null});await assert.rejects(t.c.requireWorkspaceAccess(),/sign in/);assert.equal(t.queries(),0);
t=setup({admin:true,reply:{data:null,error:{message:'network'}}});await assert.rejects(t.c.confirmSensitive('Create'),/Unable to verify/);assert.equal(t.nodes.has('verifyActionDialog'),false);
t=setup({reply:c=>{c.session=null;return {data:true}}});await assert.rejects(t.c.requireWorkspaceAccess(),/session changed/);assert.equal(t.c.isAdmin,false);
t=setup({factor:c=>{c.session={user:{id:'other'}};return true}});await assert.rejects(t.c.confirmSensitive('Create'),/session changed/);assert.equal(t.nodes.has('verifyActionDialog'),false);
t=setup({factor:false});await assert.rejects(t.c.confirmSensitive('Create'),/Set up your authenticator/);assert.equal(t.c.page,'security');
t=setup();const pending=t.c.confirmSensitive('Create 1 MIO');await new Promise(r=>setImmediate(r));assert.equal(t.nodes.get('verifyActionDialog').open,true);assert.equal(t.nodes.get('verifyActionSummary').textContent,'Create 1 MIO');assert.ok(t.c.actionResolver);t.c.actionResolver.reject(new Error('Action cancelled'));await assert.rejects(pending,/cancelled/);
assert.match(source,/admin_mint_own_mio/);
console.log('PASS workspace access: stale state recovery, revoked access, missing session, RPC failure, identity races, authenticator requirement, cancellable confirmation; no mint performed');
