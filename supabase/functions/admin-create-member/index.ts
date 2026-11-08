import { createClient } from 'npm:@supabase/supabase-js@2.57.4';
const origins = new Set(['https://marketisonline.com','https://www.marketisonline.com']);
Deno.serve(async (req: Request) => {
 const origin=req.headers.get('origin')||'';
 const headers={'Content-Type':'application/json','Access-Control-Allow-Origin':origins.has(origin)?origin:'https://www.marketisonline.com','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
 const respond=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST'||(origin&&!origins.has(origin)))return respond({error:'Request not allowed'},403);
 try {
  const authorization=req.headers.get('authorization');if(!authorization?.startsWith('Bearer '))return respond({error:'Sign in required'},401);
  const url=Deno.env.get('SUPABASE_URL')!,anon=Deno.env.get('SUPABASE_ANON_KEY')!;
  const caller=createClient(url,anon,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:user,error:authError}=await caller.auth.getUser();if(authError||!user.user)return respond({error:'Sign in required'},401);
  const body=await req.json();
  const args={p_key:body.key,p_details:body.details,p_reason:body.reason};
  const {data:reservation,error:reserveError}=await caller.rpc('admin_prepare_member',args);
  if(reserveError)return respond({error:reserveError.message},400);
  let memberId=reservation.member_id;
  if(!memberId){
   const admin=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
   const random=new Uint8Array(48);crypto.getRandomValues(random);
   const password=Array.from(random,v=>v.toString(16).padStart(2,'0')).join('');
   const {data:created,error:createError}=await admin.auth.admin.createUser({email:reservation.email,password,email_confirm:false,app_metadata:{admin_provisioning:reservation.token},user_metadata:{full_name:body.details.full_name,phone:body.details.phone}});
   if(createError){const retry=await caller.rpc('admin_prepare_member',args);if(!retry.data?.member_id)return respond({error:'Account could not be created. Check email and placement, then retry the same request.'},400);memberId=retry.data.member_id;}
   else memberId=created.user.id;
  }
  // Email delivery is explicitly selected by the administrator in the creation form.
  let emailStatus='not_requested';
  if(body.send_setup_email===true){const delivery=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});const {error}=await delivery.auth.resetPasswordForEmail(reservation.email,{redirectTo:'https://www.marketisonline.com/#reset'});emailStatus=error?'failed':'sent';}
  return respond({member_id:memberId,email_status:emailStatus});
 }catch{return respond({error:'Request could not be completed'},400);}
});
