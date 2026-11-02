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
const manager=uid(1),child=uid(2),grand=uid(3),as=id=>q("select set_config('request.jwt.claim.sub',$1,false)",[id]);
async function member(id,name,sponsor=null){const meta={full_name:name,phone:'00000000',terms_accepted:true};if(sponsor)meta.referral_code=await one('select referral_code from public.member_profiles where user_id=$1',[sponsor]);await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3,$4)",[id,sponsor?name.toLowerCase()+'@example.invalid':'m.shujaat1993@gmail.com',JSON.stringify(meta),JSON.stringify(sponsor?{}:{provider:'google'})]);await q("update public.member_profiles set sponsor_id=$2,status='active',terms_accepted_at=now() where user_id=$1",[id,sponsor]);}
async function activate(id,key,code='PREMIUM'){await q(`insert into public.package_activations(member_id,package_code,package_version,source,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,idempotency_key)
 select $1,package_code,version,'ADMIN',base_value,company_fee,base_value+company_fee,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,'approved',now(),$2 from public.package_versions where package_code=$3 and is_active order by version desc limit 1`,[id,key,code]);}
await member(manager,'Manager');await activate(manager,'manager-active');
await q("insert into private.team_manager_qualifications(member_id,rule_version,qualification_snapshot) values($1,1,'{}')",[manager]);await q('insert into private.team_manager_balances(member_id) values($1)',[manager]);
await member(child,'Child',manager);await activate(child,'child-points');
const childDp=Number(await one("select dp from public.package_activations where idempotency_key='child-points'")),childGp=Number(await one("select gp from public.package_activations where idempotency_key='child-points'"));
let balance=(await q('select manager_track_points mtp,manager_network_generation_points mngp from private.team_manager_balances where member_id=$1',[manager])).rows[0];
assert.equal(Number(balance.mtp),childDp);assert.equal(Number(balance.mngp),childGp);console.log('PASS qualified manager accrues audited MTP from direct DP and MNGP from nearest non-manager branch GP');
await q("insert into private.team_manager_qualifications(member_id,rule_version,qualification_snapshot) values($1,1,'{}')",[child]);await q('insert into private.team_manager_balances(member_id) values($1)',[child]);await member(grand,'Grand',child);await activate(grand,'grand-breakaway');
const grandDp=Number(await one("select dp from public.package_activations where idempotency_key='grand-breakaway'")),grandGp=Number(await one("select gp from public.package_activations where idempotency_key='grand-breakaway'"));
balance=(await q('select manager_track_points mtp,manager_network_generation_points mngp from private.team_manager_balances where member_id=$1',[manager])).rows[0];const childBalance=(await q('select manager_track_points mtp,manager_network_generation_points mngp from private.team_manager_balances where member_id=$1',[child])).rows[0];
assert.equal(Number(balance.mngp),childGp);assert.equal(Number(childBalance.mtp),grandDp);assert.equal(Number(childBalance.mngp),grandGp);console.log('PASS breakaway stops Manager GP at the first qualified downstream manager and starts that manager’s own counters');
assert.equal(Number(await one('select count(*) from public.leadership_rank_definitions where active')),6);assert.equal(Number(await one("select required_dp from public.leadership_rank_definitions where rank_code='director'")),20000);console.log('PASS six editable leadership rank defaults include the agreed editable Director DP value');
await q("insert into public.user_roles(user_id,role) values($1,'admin') on conflict do nothing",[manager]);await as(manager);await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);
const first=await one("select public.admin_distribute_manager_bonus('manager-cycle-test')"),bonusCount=Number(await one("select count(*) from public.bonus_transactions where method='team_manager'"));assert.equal(first.duplicate,false);assert.equal(Number(await one('select coalesce(sum(manager_track_points+manager_network_generation_points),0) from private.team_manager_balances')),0);
const second=await one("select public.admin_distribute_manager_bonus('manager-cycle-test')");assert.equal(second.duplicate,true);assert.equal(Number(await one("select count(*) from public.bonus_transactions where method='team_manager'")),bonusCount);console.log('PASS atomic admin distribution applies 5%/10%, resets counters only after success and rejects duplicate payment');
assert.equal(await one("select has_function_privilege('anon','public.my_manager_status()','execute')"),false);assert.equal(await one("select has_function_privilege('authenticated','public.my_manager_status()','execute')"),true);console.log('PASS Manager status is self-service authenticated data and private calculation functions remain closed');
await db.close();
