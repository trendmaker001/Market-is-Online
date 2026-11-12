import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source=await readFile('dist/app.js','utf8');
const helpers=source.slice(source.indexOf('function missingAuthSession('),source.indexOf('// End session recovery helpers.'));
const bootCode=source.slice(source.indexOf('let authRevision=0,bootVersion=0;'),source.indexOf('async function submit('));
// Only the auth callback and boot function, not adjacent DOM event registration.
const actualBoot=bootCode.slice(0,bootCode.indexOf('\n}',bootCode.indexOf('async function boot('))+2);
let reads=0,signins=0,signouts=0,removed=[],listener;
const good={user:{id:'qa'},access_token:'test-only-token',refresh_token:'test-only-refresh'};
const auth={getSession:async()=>{reads++;return {data:{session:null},error:null}},signOut:async options=>{signouts++;assert.equal(options.scope,'local');return {error:null}},signInWithPassword:async()=>{signins++;return {data:{session:good},error:null}},onAuthStateChange:fn=>{listener=fn}};
const noop=()=>{};
const context=vm.createContext({db:{auth},AUTH_STORAGE_KEY:'test-auth',localStorage:{removeItem:k=>removed.push(k)},setTimeout,console,renderPackages:noop,window:{},shoppingAccount:{identify:async()=>{},isCustomer:true,refresh:noop},vendorPortal:{clear:noop},updateAuthNavigation:noop,syncCheckoutIdentity:noop,finishStartupRoute:noop,loadRequestedPage:async()=>{},resumeShoppingCheckout:async()=>{},loadMember:async()=>{},toast:noop,go:noop,location:{hash:'#login'}});
vm.runInContext('let session=null,profile=null,isAdmin=false,memberPackageCode=null,hasApprovedPackage=false,authenticating=false;'+helpers+actualBoot+';this.api={readAuthSession,signInWithReadySession,signOutCurrentSession,boot,get session(){return session},setSession(s){session=s},setAuthenticating(v){authenticating=v}};',context);
const api=context.api;
await api.signInWithReadySession({email:'qa@example.invalid',password:'not-a-real-password'});assert.equal(reads,1);assert.equal(signins,1);assert.equal(signouts,0);
auth.getSession=async()=>({error:{name:'AuthSessionMissingError',message:'Auth session missing!'}});auth.signOut=async options=>{assert.equal(options.scope,'local');signouts++;return {error:{name:'AuthSessionMissingError'}}};await api.signInWithReadySession({});assert.equal(signins,2);assert.deepEqual(removed,['test-auth']);
auth.getSession=async()=>({error:{code:'refresh_token_not_found',message:'Invalid Refresh Token: Refresh Token Not Found'}});assert.equal(await api.readAuthSession(),null);
auth.getSession=async()=>({error:{code:'network_error',message:'Network unavailable'}});await assert.rejects(api.readAuthSession(),{message:'Network unavailable'});const attempts=signins;
auth.getSession=async()=>({data:{session:null}});auth.signInWithPassword=async()=>{signins++;return {error:{code:'invalid_credentials',message:'Invalid login credentials'}}};await assert.rejects(api.signInWithReadySession({}),{message:'Invalid login credentials'});assert.equal(signins,attempts+1);
auth.signInWithPassword=async()=>({data:{session:null}});await assert.rejects(api.signInWithReadySession({}),/did not create a session/);
let recoveryAttempts=0;auth.signInWithPassword=async()=>++recoveryAttempts===1?{error:{code:'session_not_found'}}:{data:{session:good}};assert.equal((await api.signInWithReadySession({})).data.session.user.id,'qa');assert.equal(recoveryAttempts,2);
recoveryAttempts=0;auth.signInWithPassword=async()=>{recoveryAttempts++;return {error:{code:'session_not_found',message:'Session expired'}}};await assert.rejects(api.signInWithReadySession({}),{message:'Session expired'});assert.equal(recoveryAttempts,2);
// A late startup read must not erase a freshly signed-in account.
let resolveRead;auth.getSession=()=>new Promise(resolve=>resolveRead=resolve);api.setSession(null);const oldBoot=api.boot();api.setAuthenticating(true);listener('SIGNED_IN',good);await api.boot(good);resolveRead({data:{session:null}});await oldBoot;assert.equal(api.session.user.id,'qa');
// An INITIAL_SESSION(null) event is normal and must allow startup to finish.
let finished=0;context.finishStartupRoute=()=>finished++;api.setAuthenticating(false);api.setSession(null);auth.getSession=async()=>{listener('INITIAL_SESSION',null);return {data:{session:null}}};await api.boot();assert.equal(finished,1);
// Superseded queued sign-out cannot clear a newer sign-in.
let clears=0;context.loadMember=async()=>clears++;listener('SIGNED_OUT',null);api.setAuthenticating(true);listener('SIGNED_IN',good);await new Promise(r=>setTimeout(r,10));assert.equal(clears,0);assert.equal(api.session.user.id,'qa');
console.log('PASS auth recovery: stale/missing session, refresh-token failure, local-only logout, invalid credentials preserved, absent-session rejection and startup/sign-in race isolation');
