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

const adminSource=await readFile(source+'/schema/admin_member_management.sql','utf8');
await db.exec(adminSource.slice(adminSource.indexOf('create or replace function private.member_restore_active'),adminSource.indexOf('-- Suppress business-event')));
await db.exec(adminSource.slice(adminSource.indexOf('create or replace function private.direct_dp_summary'),adminSource.indexOf('do $patch$ declare body text;k text;fragment')));
await db.exec(await readFile(source+'/schema/platinum_exchange_wallet.sql','utf8'));
await q("update public.system_config set config_value='false'::jsonb where config_key='WELCOME_BONUS'");
await member(manager,'Admin');await activate(manager,'admin-premium');
await q("insert into public.user_roles(user_id,role) values($1,'admin') on conflict do nothing",[manager]);
await as(manager);await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);
const chain=[manager];
for(let depth=1;depth<=13;depth++){const id=uid(100+depth);chain.push(id);await member(id,'Depth'+depth,chain[depth-1]);await activate(id,'depth-'+depth,depth===2?'ADVANCED_1':depth===3?'ADVANCED_2':'PREMIUM');}
const dpBefore=Number(await one('select total_dp from private.direct_dp_summary($1)',[manager]));
const ledgerBefore=await one("select md5(coalesce(string_agg(row_to_json(b)::text,',' order by id),'')) from public.bonus_transactions b");
const gpAt=async depth=>Number(await one("select sum(gp) from public.package_activations where member_id=$1 and status='approved'",[chain[depth]]));
let expected10=0;for(let d=2;d<=10;d++)expected10+=await gpAt(d);
const migration=await readFile(source+'/supabase/migrations/20261115203935_dynamic_tngp_and_whole_point_transfers.sql','utf8');
await db.exec('begin;'+migration+'commit;');
assert.equal(Number(await one('select private.member_tngp($1)',[manager])),expected10);
assert.equal(Number(await one('select total_dp from private.direct_dp_summary($1)',[manager])),dpBefore);
assert.equal(await one("select md5(coalesce(string_agg(row_to_json(b)::text,',' order by id),'')) from public.bonus_transactions b"),ledgerBefore);
assert.ok(Number(await one("select count(*) from public.audit_logs where action='TNGP_GENERATION_RANGE_CORRECTED'"))>0);
const code=await one('select member_code from public.member_profiles where user_id=$1',[manager]);
let result=await one('select public.my_generation_member_details($1)',[code]);assert.equal(result.tngp,expected10);assert.equal(result.generations.length,10);
assert.equal((await one('select private.team_manager_metrics($1)',[manager])).tngp,expected10);
assert.equal(Number(await one('select private.member_tngp($1)',[chain[12]])),0);

console.log('PASS direct GP excluded; complete GP counted; audited historical correction; DP/paid bonuses unchanged; dashboard/manager agree');
async function configure(levels){
 const cfg=await one('select private.current_mlm_rules()');
 const plan={...cfg,...cfg.plans.PREMIUM,max_generations:levels,generation_required_directs:0,generation_required_dp:0,generation_bonus_rate:.45,generation_rates:Object.fromEntries(Array.from({length:levels-1},(_,i)=>[i+2,levels===12&&i>0?.04:.05]))};
 return await one("select public.admin_save_plan('PREMIUM',$1,$2)",[JSON.stringify(plan),cfg.version]);
}
let cfg=await configure(12);assert.equal(Object.values(cfg.plans.PREMIUM.generation_rates).reduce((a,b)=>a+b,0).toFixed(2),'0.45');
let expected12=expected10+await gpAt(11)+await gpAt(12);
assert.equal(Number(await one('select private.member_tngp($1)',[manager])),expected12);
result=await one('select public.my_generation_member_details($1)',[code]);assert.equal(result.tngp,expected12);assert.equal(result.generations.length,12);assert.equal(result.network_generation_limit,12);
let metrics=await one('select private.team_manager_metrics($1)',[manager]);assert.equal(metrics.tngp,expected12);assert.equal(metrics.rules.max_generations,12);assert.equal(metrics.line_breakdown[0].tngp,expected12);
for(const depth of [2,3,10,11,12,13]){
 const rows=(await q("select * from private.mlm_point_candidates($1,100,100,private.current_mlm_rules()) where beneficiary=$2",[chain[depth],manager])).rows;
 if(depth===13)assert.equal(rows.length,0);else {assert.equal(rows.length,1);assert.equal(Number(rows[0].nominal),depth===2?5:4);assert.equal(Number(rows[0].qualifying_base),100);}
}
console.log('PASS admin 12 levels, 5% + 10 x 4% =45%, generations 11/12 included, 13 excluded, bonus rates never scale TNGP');
cfg=await configure(10);assert.equal(Object.values(cfg.plans.PREMIUM.generation_rates).reduce((a,b)=>a+b,0).toFixed(2),'0.45');
assert.equal(Number(await one('select private.member_tngp($1)',[manager])),expected10);
assert.equal((await one('select private.current_team_manager_rules()')).max_generations,10);
assert.equal((await q("select * from private.mlm_point_candidates($1,100,100,private.current_mlm_rules()) where beneficiary=$2",[chain[11],manager])).rows.length,0);
for(const role of ['anon','authenticated'])for(const fn of ['private.network_generation_limit(jsonb)','private.network_generation_line_points(uuid)','private.member_tngp(uuid)'])assert.equal(await one("select has_function_privilege($1,$2,'execute')",[role,fn]),false);
console.log('PASS restored 10 levels, nine x 5% =45%, helpers inaccessible directly');
// Existing decimal balances remain intact while every user transfer route accepts whole points only.
await q('update public.mio_wallet_accounts set balance=1000.49 where member_id=$1',[manager]);
for(const kind of ['fund','exchange_send','cash_send'])for(const amount of ['110.49','0','-1','NaN','Infinity','1000000001']){
 await assert.rejects(()=>one('select private.exchange_move($1,$2,$3,$4)',[kind,chain[2],amount,'invalid-amount-key']),/whole points/);
}
const funded=await one("select private.exchange_move('fund',null,110,'valid-fund-0001')");
assert.equal(await one("select private.exchange_move('fund',null,110,'valid-fund-0001')"),funded);
assert.equal(Number(await one('select balance from public.mio_wallet_accounts where member_id=$1',[manager])),890.49);
await one("select private.exchange_move('exchange_send',$1,10,'valid-member-0001')",[chain[2]]);
await one("select private.exchange_move('exchange_send',$1,10,'valid-platinum-0001')",[chain[1]]);
await as(chain[2]);await one("select private.exchange_move('cash_send',$1,5,'valid-cash-0001')",[manager]);
assert.equal(Number(await one('select count(*) from private.exchange_transfers')),4);
console.log('PASS integer transfers across Cash/Exchange/Platinum/member, replay, fractional balance retained, invalid inputs make no ledger entries');
await db.close();
