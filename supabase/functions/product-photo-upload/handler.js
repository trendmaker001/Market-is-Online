import {inspectImage,readLimitedBody} from './image-policy.js';
const origins=new Set(['https://marketisonline.com','https://www.marketisonline.com']);
export function createHandler({createClient,env,uuid=()=>crypto.randomUUID()}){return async req=>{
 const origin=req.headers.get('origin')||'',headers={'Content-Type':'application/json','Access-Control-Allow-Origin':origins.has(origin)?origin:'https://marketisonline.com','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info, x-vendor-id','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
 const reply=(data,status=200)=>new Response(JSON.stringify(data),{status,headers});
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 if(req.method!=='POST'||(origin&&!origins.has(origin)))return reply({error:'Request not allowed'},403);
 try{
  const authorization=req.headers.get('authorization');if(!authorization?.startsWith('Bearer '))return reply({error:'Sign in to upload product photos'},401);
  const url=env('SUPABASE_URL'),caller=createClient(url,env('SUPABASE_ANON_KEY'),{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
  const {data:identity,error:authError}=await caller.auth.getUser();if(authError||!identity?.user)return reply({error:'Your session has expired. Sign in again to upload photos'},401);
  const vendor=req.headers.get('x-vendor-id');if(!/^[a-f0-9-]{36}$/i.test(vendor||''))return reply({error:'Choose your store before uploading photos'},400);
  const {data:allowed,error:accessError}=await caller.rpc('can_upload_product_photo',{p_vendor_id:vendor});if(accessError||allowed!==true)return reply({error:'Active seller access required'},403);
  const bytes=await readLimitedBody(req),info=inspectImage(bytes,req.headers.get('content-type')?.split(';')[0]||'');
  const admin=createClient(url,env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}}),path=`${vendor}/${uuid()}.${info.extension}`;
  const bucket=admin.storage.from('product-images'),{error:uploadError}=await bucket.upload(path,bytes,{contentType:info.type,cacheControl:'31536000',upsert:false});if(uploadError)return reply({error:'Photo upload failed. Please retry'},503);
  const photoURL=bucket.getPublicUrl(path).data.publicUrl;
  const {error:recordError}=await admin.rpc('record_verified_product_photo',{p_vendor_id:vendor,p_actor_id:identity.user.id,p_url:photoURL,p_width:info.width,p_height:info.height,p_bytes:info.bytes,p_mime:info.type});
  if(recordError){await bucket.remove([path]);return reply({error:'Photo verification could not be saved. Please retry'},503)}
  return reply({url:photoURL,width:info.width,height:info.height,size:info.bytes});
 }catch(error){return reply({error:error instanceof Error?error.message:'Photo upload failed. Please retry'},400)}
}}
