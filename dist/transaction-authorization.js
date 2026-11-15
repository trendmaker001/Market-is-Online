/* Password reauthentication is isolated from the user's signed-in/MFA session. */
window.MioTransactionAuthorization={create({createClient,url,key,session,rpc}){
 const sessionId=s=>{try{return JSON.parse(atob(s.access_token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/'))).session_id}catch{return null}};
 async function withPassword(password,work){
  const current=session(),owner=current?.user?.id,email=current?.user?.email,sid=sessionId(current);
  if(!owner||!email||!sid)throw Error('Sign in again before confirming this transaction.');
  if(typeof password!=='string'||!password)throw Error('Enter your account password.');
  const client=createClient(url,key,{auth:{storageKey:'mio-transaction-'+crypto.randomUUID(),persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
  const unchanged=()=>owner===session()?.user?.id&&sid===sessionId(session());
  try{
   const result=await client.auth.signInWithPassword({email,password});
   if(result.error){if(result.error.code==='invalid_credentials'||/invalid login credentials/i.test(result.error.message))throw Error('Incorrect password. Please try again.');throw result.error;}
   if(!unchanged()||result.data?.user?.id!==owner)throw Error('Account changed. Please try again.');
   const value=await work(client,sid);if(!unchanged())throw Error('Account changed. Please try again.');return value;
  }finally{password='';await client.auth.signOut({scope:'local'}).catch(()=>{});}
 }
 async function authorize(pin,password,reset=false){
  if(!reset&&!/^\d{4}$/.test(pin||''))throw Error('Enter exactly 4 digits for your transaction PIN.');
  return withPassword(password,async(client,sid)=>{const r=await client.rpc('authorize_transaction',{p_pin:reset?null:pin,p_session_id:sid,p_pin_reset:reset});if(r.error)throw r.error;if(typeof r.data!=='string'||!/^txauth_[0-9a-f]{64}$/.test(r.data))throw Error('Transaction verification failed. Please try again.');return r.data;});
 }
 async function setup(pin,password){if(!/^\d{4}$/.test(pin||''))throw Error('Enter exactly 4 digits for your transaction PIN.');return withPassword(password,async client=>{const r=await client.rpc('set_transaction_pin',{p_pin:pin});if(r.error)throw r.error;});}
 async function change(pin,previous,password,reset=false){if(!/^\d{4}$/.test(pin||''))throw Error('Enter exactly 4 digits for your new PIN.');const owner=session()?.user?.id,proof=await authorize(previous,password,reset);if(owner!==session()?.user?.id)throw Error('Account changed. Please try again.');const r=await rpc('change_transaction_pin',{p_new_pin:pin,p_current_pin:proof});if(r.error)throw r.error;}
 return {authorize,setup,change};
}};
