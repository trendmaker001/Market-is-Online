import {readFile} from 'node:fs/promises';import vm from 'node:vm';import assert from 'node:assert/strict';import {webcrypto} from 'node:crypto';
let handler,calls=[],mode='ok',existing=false;
const client={
 auth:{
  getUser:async()=>mode==='invalid'?{error:{message:'Invalid JWT'}}:{data:{user:{id:'admin'}}},
  admin:{createUser:async args=>{calls.push({create:args});return {data:{user:{id:'new-member'}}};}}
 },
 rpc:async(name,args)=>{calls.push({rpc:name,args});return mode==='denied'?{error:{message:'Admin access required'}}:mode==='totp'?{error:{message:'Verify current authenticator code'}}:{data:{token:'reserved-token',email:'new@example.invalid',member_id:existing?'existing-member':null}};}
};
const delivery={auth:{resetPasswordForEmail:async(email,args)=>{calls.push({email,args});return {error:null}}}};
let source=(await readFile('supabase/functions/admin-create-member/index.ts','utf8')).replace(/^import .*\n/,'').replace('req: Request','req').replace('value:unknown','value').replaceAll("')!","')");
vm.runInNewContext(source,{Deno:{serve:fn=>handler=fn,env:{get:name=>name==='SUPABASE_URL'?'https://example.invalid':name}},createClient:(url,key,options)=>options?.global||key==='SUPABASE_SERVICE_ROLE_KEY'?client:delivery,Request,Response,Set,Uint8Array,crypto:webcrypto});
const body={key:'request-key',details:{email:'new@example.invalid',full_name:'Member',phone:'03001234567'},reason:'Verified migration'};
const req=(authorization='Bearer real-user-jwt',origin='https://www.marketisonline.com',data=body)=>new Request('https://example.invalid/functions/v1/admin-create-member',{method:'POST',headers:{origin,...(authorization?{authorization}:{})},body:JSON.stringify(data)});
assert.equal((await handler(req(''))).status,401);mode='invalid';assert.equal((await handler(req())).status,401);mode='denied';assert.match(await (await handler(req())).text(),/Admin access/);mode='totp';assert.match(await (await handler(req())).text(),/authenticator/);assert.equal(calls.filter(c=>c.create).length,0);
mode='ok';let response=await handler(req());let data=await response.json();assert.equal(data.member_id,'new-member');assert.equal(data.email_status,'not_requested');const created=calls.find(c=>c.create).create;assert.equal(created.email_confirm,false);assert.equal(created.app_metadata.admin_provisioning,'reserved-token');assert.ok(created.password.length>=64);assert.equal(calls.filter(c=>c.email).length,0);assert.equal(JSON.stringify(data).includes(created.password),false);
existing=true;response=await handler(req());assert.equal((await response.json()).member_id,'existing-member');assert.equal(calls.filter(c=>c.create).length,1);
response=await handler(req(undefined,undefined,{...body,send_setup_email:true}));assert.equal((await response.json()).email_status,'sent');assert.equal(calls.filter(c=>c.email).length,1);assert.equal((await handler(req(undefined,'https://evil.example'))).status,403);
console.log('PASS Edge creation: verified user plus admin/TOTP RPC, server-only credentials, no auto-confirmation, duplicate retry and explicit email selection');
