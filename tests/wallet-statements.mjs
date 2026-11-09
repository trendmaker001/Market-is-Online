import {PGlite} from '@electric-sql/pglite';import {readFile} from 'node:fs/promises';import assert from 'node:assert/strict';
const db=new PGlite(),id=n=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`,sql=f=>readFile(f,'utf8'),q=(s,a=[])=>db.query(s,a),one=async(s,a=[])=>(await q(s,a)).rows[0].v;
await db.exec(`create schema auth;create schema private;create role anon;create role authenticated;
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
create function private.has_role(text) returns boolean language sql stable as $$select auth.uid()='${id(1)}'$$;
create function private.registered_member(uuid) returns boolean language sql stable as $$select $1 is not null$$;
create function private.require_transaction_pin(text,uuid) returns void language plpgsql as $$begin if $1<>'1234' then raise exception 'Invalid PIN';end if;end$$;
create function private.current_proceed_wallet_config() returns jsonb language sql stable as $$select '{"cash_rate":0.75,"fee_rate":0.05,"shopping_rate":0.10,"promotion_rate":0.10,"minimum_mio":10}'::jsonb$$;
create table member_profiles(user_id uuid primary key,full_name text,member_code text);
create table mio_wallet_accounts(member_id uuid primary key,balance numeric not null check(balance>=0),updated_at timestamptz);
create table member_income_wallets(member_id uuid primary key,proceed_mio numeric check(proceed_mio>=0),shopping_points numeric,promotion_points numeric,updated_at timestamptz);
create table mio_ledger(id uuid primary key default gen_random_uuid(),member_id uuid,amount numeric,action text,reason text,transfer_id uuid,activation_id uuid,created_at timestamptz default now(),counterparty_id uuid,bonus_transaction_id uuid,idempotency_key text unique);
create table income_wallet_ledger(id uuid primary key default gen_random_uuid(),member_id uuid,wallet_kind text,amount numeric,entry_kind text,source_bonus_id uuid,source_reward_id uuid,conversion_id uuid,note text,metadata jsonb default '{}',idempotency_key text unique,created_at timestamptz default now());
create table proceed_wallet_conversions(id uuid primary key default gen_random_uuid(),member_id uuid,proceed_amount numeric,cash_amount numeric,fee_amount numeric,shopping_amount numeric,promotion_amount numeric,config_snapshot jsonb,idempotency_key text unique,created_at timestamptz default now());
create table package_activations(id uuid primary key,member_id uuid,package_code text,package_version integer,status text,activated_at timestamptz);
create table package_versions(package_code text,version integer,display_name text);
create table private.exchange_transfers(id uuid primary key,actor_id uuid,recipient_id uuid,source_wallet text,destination_wallet text);
create table private.network_foundation(singleton boolean,company_id uuid);
create table company_treasury_positions(source_type text,source_id uuid,category text,currency text,amount numeric,updated_at timestamptz,primary key(source_type,source_id,category,currency));
create table company_treasury_ledger(id bigint generated always as identity,company_id uuid,source_type text,source_id uuid,category text,currency text,amount numeric,created_at timestamptz default now());
create function private.company_treasury_sources_before_maintenance() returns table(source_type text,source_id uuid,category text,currency text,amount numeric) language sql as $$select null::text,null::uuid,null::text,null::text,null::numeric where false$$;
create table maintenance_orders(order_id uuid,processed_at timestamptz,leftover_mio numeric);
insert into member_profiles values('${id(1)}','Operations','MIO-1'),('${id(2)}','Member','MIO-2');insert into private.network_foundation values(true,'${id(1)}');
insert into mio_wallet_accounts values('${id(1)}',230,now()),('${id(2)}',0,now());
insert into member_income_wallets values('${id(1)}',0,5,5,now()),('${id(2)}',100,0,0,now());
insert into proceed_wallet_conversions values('${id(10)}','${id(1)}',50,37.5,2.5,5,5,private.current_proceed_wallet_config(),'legacy-conversion','2026-11-09 17:39:00Z');
insert into mio_ledger(id,member_id,amount,action,reason,created_at,bonus_transaction_id,idempotency_key) values
('${id(20)}','${id(1)}',40,'admin_mint','Opening','2026-11-09 10:00:00Z',null,'opening'),
('${id(21)}','${id(1)}',150,'bonus_credit','Sponsor','2026-11-09 17:23:00Z','${id(31)}','sponsor'),
('${id(22)}','${id(1)}',50,'bonus_credit','Welcome','2026-11-09 17:23:00Z','${id(32)}','welcome'),
('${id(23)}','${id(1)}',37.5,'proceed_conversion','Proceed','2026-11-09 17:39:00Z',null,'proceed-cash:${id(10)}'),
('${id(24)}','${id(1)}',2.5,'withdrawal_fee','Fee','2026-11-09 17:39:00Z',null,'proceed-fee:${id(10)}');
insert into income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,source_bonus_id,metadata,created_at) values
('${id(1)}','cash',150,'network_earning','${id(31)}','{"routing_key":"direct_sponsor","target_wallet":"cash"}','2026-11-09 17:23:00Z'),
('${id(1)}','proceed',50,'network_earning','${id(32)}','{"routing_key":"welcome_bonus","target_wallet":"proceed"}','2026-11-09 17:23:00Z');
insert into income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,conversion_id,created_at) values
('${id(1)}','proceed',-50,'proceed_withdrawal','${id(10)}','2026-11-09 17:39:00Z'),
('${id(1)}','cash',37.5,'proceed_withdrawal','${id(10)}','2026-11-09 17:39:00Z'),
('${id(1)}','shopping',5,'proceed_withdrawal','${id(10)}','2026-11-09 17:39:00Z'),
('${id(1)}','promotion',5,'proceed_withdrawal','${id(10)}','2026-11-09 17:39:00Z');`);
await db.exec(await sql('tests/fixtures/live-company-treasury-sync.sql'));
await db.exec('begin;'+await sql('schema/company_proceed_income.sql')+'commit;');await db.exec(await sql('schema/wallet_history.sql'));
const as=uid=>q("select set_config('test.uid',$1,false)",[uid||'']);const history=(kind='cash',from=null,to=null)=>one('select my_wallet_history($1,\'all\',$2,$3,1,20) v',[kind,from,to]);
await as(id(1));let h=await history();assert.equal(Number(h.balance),227.5);assert.equal(h.total,3);assert.deepEqual(h.rows.map(r=>Number(r.amount)),[37.5,150,40]);assert.deepEqual(h.rows.map(r=>Number(r.balance_after)),[227.5,190,40]);assert.equal(h.rows[0].split.fee,'2.5');
assert.equal((await history('proceed')).total,2);assert.equal((await history('shopping')).total,1);assert.equal((await history('promotion')).total,1);assert.equal((await history('cash','2026-11-10','2026-11-10')).total,0);assert.equal((await history('cash','2026-11-09','2026-11-09')).total,3);await assert.rejects(history('cash','2026-11-10','2026-11-09'),/From date/);
assert.equal(Number(await one('select sum(amount) v from company_treasury_positions')),2.5);assert.equal(Number(await one('select sum(amount) v from company_treasury_ledger')),2.5);
// Replaying the migration is safe: no second debit or duplicated treasury credit.
await db.exec('begin;'+await sql('schema/company_proceed_income.sql')+'commit;');assert.equal(Number((await history()).balance),227.5);assert.equal(Number(await one('select count(*) v from private.proceed_fee_reclassifications')),1);
await as(id(2));await assert.rejects(one("select convert_proceed_wallet(50,'0000','new-conversion') v"),/PIN/);const converted=await one("select convert_proceed_wallet(50,'1234','new-conversion') v");assert.equal(Number(converted.cash_amount),37.5);assert.equal(Number((await history()).balance),37.5);assert.equal((await history()).total,1);assert.equal(Number(await one(`select balance v from mio_wallet_accounts where member_id='${id(1)}'`)),227.5);
await one("select convert_proceed_wallet(50,'1234','new-conversion') v");assert.equal(Number((await history()).balance),37.5);await assert.rejects(one("select convert_proceed_wallet(60,'1234','new-conversion') v"),/already used/);assert.equal(Number(await one('select sum(amount) v from company_treasury_positions')),5);
await assert.rejects(one('select admin_proceed_fee_history() v'),/Admin access/);await assert.rejects(one('select admin_member_wallet_history($1) v',[id(1)]),/Admin access/);
await as(id(1));await assert.rejects(one("select convert_proceed_wallet(50,'1234','new-conversion') v"),/already used/);assert.equal((await one('select admin_proceed_fee_history() v')).total,2);assert.equal(Number((await one('select admin_member_wallet_history($1) v',[id(2)])).balance),37.5);
// E-commerce routed to Proceed is also excluded; historic Cash welcome remains.
await q(`insert into mio_ledger(member_id,amount,action,idempotency_key,created_at) values($1,7,'bonus_credit',$2,'2026-11-09 11:00Z')`,[id(1),'ecommerce:'+id(90)]);await q(`insert into income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,source_reward_id) values($1,'proceed',7,'ecommerce_earning',$2)`,[id(1),id(90)]);assert.equal((await history()).total,3);
await q(`insert into mio_ledger(member_id,amount,action,bonus_transaction_id,created_at) values($1,5,'bonus_credit',$2,'2026-11-09 11:30Z')`,[id(1),id(91)]);await q(`insert into income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,source_bonus_id,metadata) values($1,'cash',5,'network_earning',$2,'{"routing_key":"welcome_bonus","target_wallet":"cash"}')`,[id(1),id(91)]);await q('update mio_wallet_accounts set balance=balance+5 where member_id=$1',[id(1)]);assert.equal((await history()).total,4);
// Inclusive local day boundary: 19:00 UTC is next day in Pakistan.
await q(`insert into mio_ledger(member_id,amount,action,created_at) values($1,1,'admin_mint','2026-11-09 19:00Z')`,[id(1)]);await q('update mio_wallet_accounts set balance=balance+1 where member_id=$1',[id(1)]);assert.equal((await history('cash','2026-11-10','2026-11-10')).total,1);
await as(null);await assert.rejects(history(),/Sign in/);assert.equal(await one("select has_function_privilege('anon','public.my_wallet_history(text,text,date,date,integer,integer)','execute') v"),false);assert.equal(await one("select has_function_privilege('authenticated','private.wallet_history_for_member(uuid,text,text,date,date,integer,integer)','execute') v"),false);
console.log('PASS wallet separation, balances, fee reclassification/replay, conversion/retries, receipt split, historical routing, ecommerce, local-date bounds and admin/own access');await db.close();
