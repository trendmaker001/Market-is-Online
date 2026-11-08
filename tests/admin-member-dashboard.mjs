import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
const source=new URL('..',import.meta.url).pathname.replace(/\/$/,'');
const db=new PGlite(),q=(sql,args=[])=>db.query(sql,args),one=async(sql,args=[])=>Object.values((await q(sql,args)).rows[0])[0];
const uid=n=>{const h=createHash('sha256').update('manager-program:'+n).digest('hex').slice(0,32);return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`};
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb,raw_app_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
alter default privileges grant execute on functions to anon,authenticated,service_role;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid() to anon,authenticated;`);
for(const file of (await readdir(source+'/schema')).filter(x=>/^\d+.*\.sql$/.test(x)).sort())await db.exec(await readFile(source+'/schema/'+file,'utf8'));
for(const file of ['20261016023905_activation_offer_member_dashboard.sql','20261016203000_dynamic_welcome_bonus_switch.sql','20261016213000_welcome_bonus_extra_rate_and_admin_scope.sql','20261103161000_maintenance_foundation.sql','20261103162000_maintenance_payments.sql','20261103163000_maintenance_bonus_eligibility.sql','20261104100000_monthly_maintenance_company_leftover.sql','20261104150000_super_member_program.sql','20261105091030_country_gender_marketplace_controls.sql'])
 await db.exec(await readFile(source+'/supabase/migrations/'+file,'utf8'));
// Existing production helper predates the checked-in migration set.
await db.exec(`create or replace function private.current_proceed_wallet_config() returns jsonb language sql stable security definer set search_path='' as $$ select '{"cash_rate":0.75,"fee_rate":0.05,"shopping_rate":0.10,"promotion_rate":0.10,"minimum_mio":10}'::jsonb||coalesce((select config_value from public.system_config where config_key='PROCEED_WALLET_CONFIG' and effective_from<=now() and(effective_to is null or effective_to>now()) order by version desc limit 1),'{}') $$`);
await db.exec(await readFile(source+'/schema/admin_member_dashboard.sql','utf8'));
const admin=uid(1),target=uid(2),other=uid(3),as=id=>q("select set_config('request.jwt.claim.sub',$1,false)",[id]);
async function activate(id,key,code='PREMIUM'){await q(`insert into public.package_activations(member_id,package_code,package_version,source,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,idempotency_key)
 select $1,package_code,version,'ADMIN',base_value,company_fee,base_value+company_fee,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,'approved',now(),$2 from public.package_versions where package_code=$3 and is_active order by version desc limit 1`,[id,key,code]);}
for(const [id,name] of [[admin,'Admin'],[target,'Target'],[other,'Other']]){
const meta={full_name:name,phone:'00000000',terms_accepted:true};if(id!==admin)meta.referral_code=await one('select referral_code from public.member_profiles where user_id=$1',[admin]);await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3,$4)",[id,id===admin?'m.shujaat1993@gmail.com':name.toLowerCase()+'@example.invalid',JSON.stringify(meta),JSON.stringify(id===admin?{provider:'google'}:{})]);await q("update public.member_profiles set status='active',terms_accepted_at=now() where user_id=$1",[id]);if(id===admin)await activate(admin,"support-admin-plan");
}
await q("insert into public.user_roles(user_id,role) values($1,'admin') on conflict do nothing",[admin]);
await q('update public.mio_wallet_accounts set balance=17 where member_id=$1',[target]);
await q('update public.mio_wallet_accounts set balance=999 where member_id=$1',[admin]);
await as(admin);const snap=await one('select public.admin_member_dashboard($1)',[target]);
assert.equal(snap.member_id,target);assert.equal(snap.summary.full_name,'Target');assert.equal(Number(snap.financial.balance),17);assert.notEqual(Number(snap.financial.balance),999);
assert.ok(snap.summary.generation);assert.ok(snap.summary.manager_program);assert.ok(snap.summary.community_share);assert.ok(snap.summary.super_member);assert.ok(snap.maintenanceStatus);assert.ok(snap.incomeWallets);
assert.doesNotMatch(JSON.stringify(snap),/transaction_pin_hash|totp_secret|encrypted_password/);
await assert.rejects(one('select public.admin_member_dashboard($1)',[uid(99)]),/Member not found/);
await as(other);await assert.rejects(one('select public.admin_member_dashboard($1)',[target]),/Admin access/);
await as('');await assert.rejects(one('select public.admin_member_dashboard($1)',[target]),/Admin access/);
assert.equal(await one("select has_function_privilege('anon','public.admin_member_dashboard(uuid)','execute')"),false);
assert.equal(await one("select has_function_privilege('authenticated','private.support_member_dashboard(uuid)','execute')"),false);
assert.equal(await one("select prosecdef from pg_proc where oid='public.admin_member_dashboard(uuid)'::regprocedure"),false);
console.log('PASS admin target identity, selected balance, all dashboard sections, missing member, anonymous/nonadmin denial and private helper isolation');await db.close();
