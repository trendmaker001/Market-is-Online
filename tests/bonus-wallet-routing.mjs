import {PGlite} from '@electric-sql/pglite';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const db=new PGlite(), q=(s,a=[])=>db.query(s,a), one=async(s,a=[])=>Object.values((await q(s,a)).rows[0])[0];
await db.exec(`create schema private;create schema auth;
create function auth.uid() returns uuid language sql stable as $$select '00000000-0000-0000-0000-000000000001'::uuid$$;
create function private.has_role(text) returns boolean language sql stable as $$select coalesce(current_setting('test.admin',true),'yes')='yes'$$;
create type public.bonus_method as enum('direct','generation','single_line','binary_pool_share','team_manager','community_share');
create table public.system_config(config_key text,version integer,config_value jsonb,effective_from timestamptz default now(),effective_to timestamptz,created_by uuid);
create table public.audit_logs(actor_id uuid,action text,entity_type text,before_data jsonb,after_data jsonb);
create table public.member_income_wallets(member_id uuid primary key,proceed_mio numeric default 0,updated_at timestamptz);
create table public.mio_wallet_accounts(member_id uuid primary key,balance numeric default 0,updated_at timestamptz);
create table public.income_wallet_ledger(member_id uuid,wallet_kind text,amount numeric,entry_kind text,source_bonus_id uuid,note text,metadata jsonb,idempotency_key text unique);
create table public.bonus_transactions(id uuid primary key,beneficiary_id uuid,method public.bonus_method,status text,payable_amount numeric,generation integer,calculation_trace jsonb);
`);
const base=await readFile('schema/20261027133422_dynamic_bonus_wallet_routing.sql','utf8');
await db.exec(base.slice(base.indexOf('create or replace function private.current_bonus_wallet_routing'),base.indexOf('create or replace function private.network_bonus_wallet_route_key')));
await db.exec(await readFile('schema/20261107100000_independent_bonus_wallet_routing.sql','utf8'));
await db.exec(await readFile('tests/fixtures/live-bonus-wallet-trigger.sql','utf8'));
await db.exec(`create trigger route_bonus after insert or update on public.bonus_transactions for each row execute function private.route_bonus_to_income_wallet();
insert into public.system_config(config_key,version,config_value) values('BONUS_WALLET_ROUTING',1,private.default_bonus_wallet_routes());`);
const member='00000000-0000-0000-0000-000000000001';await q('insert into public.mio_wallet_accounts values($1,0,now())',[member]);
const methods=['generation','team_manager','community_share'];let n=0;
for(let mask=0;mask<8;mask++){
 const snap=await one('select private.current_bonus_wallet_routing()');for(let i=0;i<3;i++)snap.routes[methods[i]]=mask&(1<<i)?'cash':'proceed';
 const saved=await one('select public.admin_set_bonus_wallet_routing($1,$2)',[JSON.stringify(snap.routes),snap.version]);
 for(const method of methods){
  const id=`00000000-0000-0000-0001-${String(++n).padStart(12,'0')}`;
  await q('update public.mio_wallet_accounts set balance=0');await q('update public.member_income_wallets set proceed_mio=0');
  await q("insert into public.bonus_transactions values($1,$2,$3,'pending',10,1,'{}')",[id,member,method]);
  assert.equal(Number(await one('select count(*) from public.income_wallet_ledger where source_bonus_id=$1',[id])),0);
  await q('update public.mio_wallet_accounts set balance=10');
  await q("update public.bonus_transactions set status='posted' where id=$1",[id]);
  assert.equal(await one('select wallet_kind from public.income_wallet_ledger where source_bonus_id=$1',[id]),snap.routes[method]);
  assert.equal(Number(await one('select balance from public.mio_wallet_accounts')),snap.routes[method]==='cash'?10:0);
  assert.equal(Number(await one('select proceed_mio from public.member_income_wallets')),snap.routes[method]==='proceed'?10:0);
  await q("update public.bonus_transactions set status='posted' where id=$1",[id]);
  await q("update public.bonus_transactions set status='pending' where id=$1",[id]);await q("update public.bonus_transactions set status='posted' where id=$1",[id]);
  assert.equal(Number(await one('select count(*) from public.income_wallet_ledger where source_bonus_id=$1',[id])),1);
  assert.equal(Number(await one('select balance from public.mio_wallet_accounts'))+Number(await one('select proceed_mio from public.member_income_wallets')),10);
 }
 await assert.rejects(one('select public.admin_set_bonus_wallet_routing($1,$2)',[JSON.stringify(snap.routes),snap.version]),/another session/);
}
console.log('PASS all 8 independent wallet combinations, 24 real trigger credits, pending gates and duplicate/repost protection');
const snap=await one('select private.current_bonus_wallet_routing()');
for(const invalid of [{...snap.routes,community_share:'invalid'},Object.fromEntries(Object.entries(snap.routes).filter(([k])=>k!=='team_manager')),{...snap.routes,unexpected:'cash'}])await assert.rejects(one('select public.admin_set_bonus_wallet_routing($1,$2)',[JSON.stringify(invalid),snap.version]));
await q("select set_config('test.admin','no',false)");await assert.rejects(one('select public.admin_set_bonus_wallet_routing($1,$2)',[JSON.stringify(snap.routes),snap.version]),/Admin access/);
assert.equal(await one("select private.network_bonus_wallet_route_key('direct','{\"bonus_component\":\"welcome_bonus\"}')"),'welcome_bonus');
console.log('PASS admin-only save, strict complete keys, version conflict rejection and unchanged welcome route');await db.close();
