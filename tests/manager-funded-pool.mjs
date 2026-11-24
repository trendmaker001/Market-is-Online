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
for(const file of ['20261103161000_maintenance_foundation.sql','20261103163000_maintenance_bonus_eligibility.sql','20261104150000_super_member_program.sql'])
 await db.exec(await readFile(source+'/supabase/migrations/'+file,'utf8'));
const manager=uid(1),child=uid(2),grand=uid(3),as=id=>q("select set_config('request.jwt.claim.sub',$1,false)",[id]);
async function member(id,name,sponsor=null){const meta={full_name:name,phone:'00000000',terms_accepted:true};if(sponsor)meta.referral_code=await one('select referral_code from public.member_profiles where user_id=$1',[sponsor]);await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3,$4)",[id,sponsor?name.toLowerCase()+'@example.invalid':'m.shujaat1993@gmail.com',JSON.stringify(meta),JSON.stringify(sponsor?{}:{provider:'google'})]);await q("update public.member_profiles set sponsor_id=$2,status='active',terms_accepted_at=now() where user_id=$1",[id,sponsor]);}
async function activate(id,key,code='PREMIUM'){await q(`insert into public.package_activations(member_id,package_code,package_version,source,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,idempotency_key)
 select $1,package_code,version,'ADMIN',base_value,company_fee,base_value+company_fee,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,'approved',now(),$2 from public.package_versions where package_code=$3 and is_active order by version desc limit 1`,[id,key,code]);}

await db.exec(`create or replace function private.member_restore_active(uuid) returns boolean language sql as $$select false$$;`);
if(!await one("select to_regprocedure('private.network_generation_limit()')"))await db.exec('create function private.network_generation_limit() returns integer language sql as $$select 10$$');
await db.exec(await readFile(source+'/tests/fixtures/production-manager-funding-guard.sql','utf8'));
await db.exec(await readFile(source+'/supabase/migrations/20261124082839_manager_bonus_pool_and_exclusive_points.sql','utf8'));
// Production uses a deferred routing trigger (not included in the numeric schema snapshot).
if(!await one("select exists(select 1 from pg_trigger where tgname='route_bonus_to_income_wallet')"))await db.exec('create constraint trigger route_bonus_to_income_wallet after insert or update on public.bonus_transactions deferrable initially deferred for each row execute function private.route_bonus_to_income_wallet()');
const qualify=async id=>{await q("insert into private.team_manager_qualifications(member_id,qualified_at,rule_version,qualification_snapshot) values($1,now(),1,'{}') on conflict do nothing",[id]);await q('insert into private.team_manager_balances(member_id) values($1) on conflict do nothing',[id]);};
const bal=async (id=manager)=>(await q('select manager_track_points::float8 mdp,manager_network_generation_points::float8 mngp from private.team_manager_balances where member_id=$1',[id])).rows[0];
await member(manager,'Manager');await activate(manager,'manager-active');
await member(child,'Direct',manager);await activate(child,'before-qualification');
assert.equal(Number(await one('select count(*) from public.manager_point_ledger')),0);
await qualify(manager);
assert.deepEqual(await bal(),{mdp:0,mngp:0});
await member(grand,'Indirect',child);await activate(grand,'indirect-activity');
const gp=Number(await one("select gp from public.package_activations where idempotency_key='indirect-activity'"));
assert.deepEqual(await bal(),{mdp:0,mngp:gp});
const direct2=uid(4);await member(direct2,'Direct Two',manager);await activate(direct2,'direct-activity');
const dp=Number(await one("select dp from public.package_activations where idempotency_key='direct-activity'"));
assert.deepEqual(await bal(),{mdp:dp,mngp:gp});
assert.equal(Number(await one("select count(*) from public.manager_point_ledger where source_member_id=$1 and point_kind='MNGP'",[direct2])),0);
await qualify(child);
const next=uid(5);await member(next,'Breakaway Child',child);await activate(next,'breakaway-activity');
assert.deepEqual(await bal(),{mdp:dp,mngp:gp});assert.deepEqual(await bal(child),{mdp:dp,mngp:0});
// An inactive manager remains the breakaway boundary.
await q("update public.member_profiles set status='inactive' where user_id=$1",[child]);
const deep=uid(6);await member(deep,'Inactive Branch',grand);await activate(deep,'inactive-branch');
assert.deepEqual(await bal(),{mdp:dp,mngp:gp});assert.deepEqual(await bal(child),{mdp:dp,mngp:0});
await q("update public.member_profiles set status='active' where user_id=$1",[child]);
// Depth 10 counts; depth 11 does not. No direct managers in this separate branch.
let parent=direct2;
for(let depth=2;depth<=11;depth++){const id=uid(20+depth);await member(id,'Depth '+depth,parent);await activate(id,'depth-'+depth);parent=id;}
assert.deepEqual(await bal(),{mdp:dp,mngp:gp*10});
assert.equal(Number(await one("select count(*) from public.manager_point_ledger where generation>10")),0);
assert.equal(Number(await one("select count(*) from public.bonus_transactions where method='team_manager'")),0,'No payment before admin distributes');
await q("insert into public.user_roles(user_id,role) values($1,'admin') on conflict do nothing",[manager]);await as(manager);
await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);
const before=await one('select public.admin_manager_bonus_wallet()');assert.ok(Number(before.available_mio)>=Number(before.payable_mio));
const unrelated=await one("select jsonb_agg(to_jsonb(s) order by source_type,source_id,category) from private.company_treasury_sources() s where category not in('generation_manager_pending','binary_manager_pending')");
const expected=Number(before.payable_mio);
await q("select set_config('request.jwt.claims','{}',false)");
await assert.rejects(one("select public.admin_distribute_manager_bonus('totp-required')"),/TOTP|authenticator|verification|two.factor/i);
await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);
const result=await one("select public.admin_distribute_manager_bonus(' manager-funded-test ')");assert.equal(Number(result.total_mio),expected);
const after=await one('select public.admin_manager_bonus_wallet()');assert.equal(Number(after.distributed_mio),expected);assert.equal(Number(after.available_mio),Number(before.available_mio)-expected);
assert.deepEqual(await bal(),{mdp:0,mngp:0});assert.deepEqual(await bal(child),{mdp:0,mngp:0});
assert.deepEqual(await one("select jsonb_agg(to_jsonb(s) order by source_type,source_id,category) from private.company_treasury_sources() s where category not in('generation_manager_pending','binary_manager_pending')"),unrelated);
const ledgerCount=Number(await one("select count(*) from public.bonus_transactions where method='team_manager'"));
assert.equal((await one("select public.admin_distribute_manager_bonus('manager-funded-test')")).duplicate,true);
assert.equal(Number(await one("select count(*) from public.bonus_transactions where method='team_manager'")),ledgerCount);
const hist=await one('select public.my_manager_bonus_history()');assert.ok(hist.rows.length);assert.equal(hist.pending_mdp,0);assert.equal(hist.lifetime_mdp,dp);assert.equal(hist.lifetime_mngp,gp*10);
for(const d of after.distributions){assert.equal(d.target_wallet,'proceed');}
assert.equal(Number(await one("select sum(amount) from public.income_wallet_ledger where metadata->>'method'='team_manager'")),expected);
await assert.rejects(one("select public.admin_distribute_manager_bonus('empty-second-cycle')"),/No eligible/);
// A failed budget check leaves all balances and payment records intact.
await q('update private.team_manager_balances set manager_track_points=100000000 where member_id=$1',[manager]);
const failedBefore=await bal();await assert.rejects(one("select public.admin_distribute_manager_bonus('insufficient-test')"),/Manager Bonus Wallet/);assert.deepEqual(await bal(),failedBefore);
assert.equal(Number(await one("select count(*) from public.bonus_transactions where method='team_manager'")),ledgerCount);
await as(grand);await assert.rejects(one('select public.admin_manager_bonus_wallet()'),/Admin access/);assert.equal((await one('select public.my_manager_bonus_history()')).rows.length,0);
await as('');await assert.rejects(one('select public.my_manager_bonus_history()'),/Sign in/);
assert.equal(await one("select has_function_privilege('anon','public.admin_manager_bonus_wallet(integer)','execute')"),false);
assert.equal(await one("select has_function_privilege('authenticated','private.manager_bonus_pool_sources()','execute')"),false);
console.log('PASS manager points after qualification only; direct MDP vs indirect MNGP; level 10/11; breakaway including inactive managers; admin-only funded payout; retry; wallet routing; lifetime/member history; source isolation; rollback and permissions');await db.close();
