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
const manager=uid(1),child=uid(2),grand=uid(3),as=id=>q("select set_config('request.jwt.claim.sub',$1,false)",[id]);
async function member(id,name,sponsor=null){const meta={full_name:name,phone:'00000000',terms_accepted:true};if(sponsor)meta.referral_code=await one('select referral_code from public.member_profiles where user_id=$1',[sponsor]);await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3,$4)",[id,sponsor?name.toLowerCase()+'@example.invalid':'m.shujaat1993@gmail.com',JSON.stringify(meta),JSON.stringify(sponsor?{}:{provider:'google'})]);await q("update public.member_profiles set sponsor_id=$2,status='active',terms_accepted_at=now() where user_id=$1",[id,sponsor]);}
async function activate(id,key,code='PREMIUM'){await q(`insert into public.package_activations(member_id,package_code,package_version,source,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,idempotency_key)
 select $1,package_code,version,'ADMIN',base_value,company_fee,base_value+company_fee,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,'approved',now(),$2 from public.package_versions where package_code=$3 and is_active order by version desc limit 1`,[id,key,code]);}

// Load the existing opening-earnings table and access policies; unrelated restore helpers are not needed.
await db.exec((await readFile(source+'/schema/admin_member_management.sql','utf8')).split('alter table public.point_ledger add column admin_change_id')[0]);
await db.exec(await readFile(source+'/supabase/migrations/20261115165331_qualification_earnings_package.sql','utf8'));
console.log('PASS migration applies to baseline schema');
await member(manager,'Admin');await activate(manager,'qa-admin');
await member(child,'Gold');await activate(child,'qa-gold','ADVANCED_2');
await member(grand,'Platinum');await activate(grand,'qa-platinum');
await q("insert into public.user_roles(user_id,role) values($1,'admin') on conflict do nothing",[manager]);
await as(manager);await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);
const ranks=(await q('select * from public.leadership_rank_definitions order by sort_order')).rows;
assert.deepEqual(ranks.map(r=>Number(r.required_total_earnings)),[1000,2000,3000,4000,5000,6000]);
assert.deepEqual(ranks.map(r=>r.minimum_package),['ADVANCED_2','PREMIUM','PREMIUM','PREMIUM','PREMIUM','PREMIUM']);
assert.equal((await one('select private.current_team_manager_rules()')).required_total_earnings,2000);
// Isolate new conditions by configuring the original numerical criteria to zero.
for(const rank of ranks.slice(0,2))await one('select public.admin_upsert_leadership_rank($1)',[JSON.stringify({...rank,left_brp:0,right_brp:0,direct_left:0,direct_right:0,required_dp:0})]);
let rules=await one('select private.current_team_manager_rules()');
await one('select public.admin_set_team_manager_rules($1,$2)',[JSON.stringify({...rules,required_directs:0,required_direct_dp:0,required_tngp:0,required_qualified_lines:0}),rules.version]);
const opening=(id,amount)=>q("insert into public.member_opening_earnings(member_id,category,amount) values($1,'other',$2) on conflict(member_id,category) do update set amount=excluded.amount",[id,amount]);
const achieved=id=>one('select achieved_rank from public.member_profiles where user_id=$1',[id]);
await opening(child,999.9999);assert.equal(await achieved(child),null);
await opening(child,1000);assert.equal(await achieved(child),'leader');
await opening(child,2000);assert.equal(await achieved(child),'leader');
await opening(grand,1999.9999);assert.equal(await achieved(grand),'leader');
assert.equal((await one('select private.team_manager_metrics($1)',[grand])).qualified_now,false);
await opening(grand,2000);assert.equal(await achieved(grand),'team_leader');
assert.equal((await one('select private.team_manager_metrics($1)',[grand])).qualified_now,true);
assert.equal(await one('select exists(select 1 from private.team_manager_qualifications where member_id=$1)',[grand]),true);
console.log('PASS exact thresholds, Platinum accepts Gold minimum, Gold rejects Platinum requirement, earning changes automatically award');
await opening(grand,500);assert.equal(await achieved(grand),'team_leader');
const metrics=await one('select private.team_manager_metrics($1)',[grand]);assert.equal(metrics.qualified_now,false);assert.equal(metrics.criteria_progress.total_earnings,25);
assert.equal(await one('select exists(select 1 from private.team_manager_qualifications where member_id=$1)',[grand]),true);
await q('update public.mio_wallet_accounts set balance=99999 where member_id=$1',[grand]);
assert.equal(Number(await one('select private.member_total_earnings($1)',[grand])),500);
console.log('PASS earning reductions update progress, achievements retained, wallet balance excluded');
// Real earning tables: posted network + maintenance + opening, without pending/reversed credits.
for(const [status,amount] of [['posted',200],['pending',300],['reversed',400]])await q(`insert into public.bonus_transactions(beneficiary_id,method,source_activation_id,qualifying_base,gross_amount,payable_amount,formula_version,calculation_trace,status,idempotency_key) values($1,'team_manager',null,500,$2,$2,'qualification-test','{}',$3,$3)`,[grand,amount,status]);
const annual=await one("insert into public.annual_maintenance_payments(member_id,idempotency_key,amount_mio,company_mio,config_snapshot,old_due_at,new_due_at) values($1,'test-annual',100,0,'{}',now(),now()+interval '1 year') returning id",[grand]);
await q("insert into public.maintenance_generation_payouts(beneficiary_id,maintenance_kind,annual_payment_id,generation,base_mio,rate,amount_mio) values($1,'annual',$2,1,100,1,100)",[grand,annual]);
assert.equal(Number(await one('select private.member_total_earnings($1)',[grand])),800);
await q("update public.bonus_transactions set status='posted' where idempotency_key='pending'");
assert.equal(Number(await one('select private.member_total_earnings($1)',[grand])),1100);
await q("update public.bonus_transactions set status='reversed' where idempotency_key='posted'");
assert.equal(Number(await one('select private.member_total_earnings($1)',[grand])),900);
console.log('PASS posted/pending/reversed transitions and maintenance earnings match dashboard sources');

rules=await one('select private.current_team_manager_rules()');
await one('select public.admin_set_team_manager_rules($1,$2)',[JSON.stringify({...rules,required_total_earnings:400}),rules.version]);
assert.equal((await one('select private.team_manager_metrics($1)',[grand])).qualified_now,true);
await assert.rejects(()=>one('select public.admin_set_team_manager_rules($1,$2)',[JSON.stringify({...rules,required_total_earnings:400}),rules.version]),/Rules changed/);
rules=await one('select private.current_team_manager_rules()');
await assert.rejects(()=>one('select public.admin_set_team_manager_rules($1,$2)',[JSON.stringify({...rules,required_total_earnings:-1}),rules.version]),/Invalid total earnings/);
await assert.rejects(()=>one('select public.admin_upsert_leadership_rank($1)',[JSON.stringify({...ranks[0],minimum_package:'BASIC_2'})]),/check constraint/);
await assert.rejects(()=>one('select public.admin_upsert_leadership_rank($1)',[JSON.stringify({...ranks[0],required_total_earnings:-1})]),/check constraint/);
await as(child);await assert.rejects(()=>one('select public.admin_upsert_leadership_rank($1)',[JSON.stringify(ranks[0])]),/Admin access/);
const status=await one('select public.my_manager_status()');assert.equal(status.total_earnings,2000);assert.equal(status.rank_qualification.metrics.total_earnings,2000);assert.equal(status.rank_qualification.ranks[0].minimum_package,'ADVANCED_2');
for(const role of ['anon','authenticated'])assert.equal(await one("select has_function_privilege($1,'private.member_total_earnings(uuid)','execute')",[role]),false);
await as('');await assert.rejects(()=>one('select public.my_manager_status()'),/Sign in required/);
console.log('PASS admin edit validation, optimistic concurrency, self-only metrics and private helper permissions');
await as(manager);
assert.equal((await one('select private.support_manager_status($1)',[child])).rank_qualification.metrics.total_earnings,2000);
// A new higher rank starts at 10,000 but remains completely editable.
let higher={...ranks[5],rank_code:'senior_director',display_name:'Senior Director',sort_order:70};delete higher.required_total_earnings;delete higher.minimum_package;
higher=await one('select public.admin_upsert_leadership_rank($1)',[JSON.stringify(higher)]);
assert.equal(higher.required_total_earnings,10000);assert.equal(higher.minimum_package,'PREMIUM');
for(const limit of [8000,12000,15000]){
 higher=await one('select public.admin_upsert_leadership_rank($1)',[JSON.stringify({...higher,required_total_earnings:limit})]);
 assert.equal(higher.required_total_earnings,limit);
 assert.equal((await one('select public.my_manager_status()')).rank_qualification.ranks.at(-1).required_total_earnings,limit);
}
console.log('PASS new higher-rank default 10000 stays editable to 8000, 12000 and 15000');

await db.close();
