-- Exchange balances are separate from cash. No existing money is moved by this migration.
create table private.exchange_wallet_accounts (
 member_id uuid primary key references public.member_profiles(user_id),
 balance numeric(20,4) not null default 0 check(balance>=0),
 updated_at timestamptz not null default now()
);
create table private.exchange_transfers (
 id uuid primary key default gen_random_uuid(),
 actor_id uuid not null references public.member_profiles(user_id),
 recipient_id uuid not null references public.member_profiles(user_id),
 source_wallet text not null check(source_wallet in ('cash','exchange')),
 destination_wallet text not null check(destination_wallet in ('cash','exchange')),
 kind text not null check(kind in ('fund','cash_send','exchange_send')),
 amount numeric(20,4) not null check(amount>0),
 note text not null default '',
 idempotency_key text not null,
 created_at timestamptz not null default now(),
 unique(actor_id,idempotency_key)
);
create index exchange_received_idx on private.exchange_transfers(recipient_id,created_at desc,id);
create index exchange_sent_idx on private.exchange_transfers(actor_id,created_at desc,id);
alter table private.exchange_wallet_accounts enable row level security;
alter table private.exchange_transfers enable row level security;
revoke all on private.exchange_wallet_accounts,private.exchange_transfers from public,anon,authenticated;

create function private.exchange_move(p_kind text,p_recipient uuid,p_amount numeric,p_key text,p_note text default '') returns uuid
language plpgsql security definer set search_path='' as $$
declare sender uuid:=auth.uid(); dest uuid:=p_recipient; sp boolean; rp boolean; sw text; dw text; old private.exchange_transfers%rowtype; tx uuid:=gen_random_uuid(); cash numeric; bal numeric; locked uuid;
begin
 if sender is null then raise exception 'Authentication required';end if;
 if p_kind not in ('fund','cash_send','exchange_send') or p_kind is null then raise exception 'Invalid transfer type';end if;
 if p_amount is null or p_amount<=0 or p_amount>1000000000 or p_amount<>round(p_amount,4) then raise exception 'Invalid MIO amount';end if;
 if length(coalesce(p_key,''))<12 or length(p_key)>100 then raise exception 'Invalid idempotency key';end if;
 if length(coalesce(p_note,''))>300 then raise exception 'Note must be 300 characters or fewer';end if;
 if p_kind='fund' then dest:=sender;elsif dest is null or dest=sender then raise exception 'Choose another member';end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-request:'||sender::text||':'||p_key,0));
 -- Lock identity rows in the same order for every route.
 for locked in select user_id from public.member_profiles where user_id in(sender,dest) order by user_id for share loop null;end loop;
 if not exists(select 1 from public.member_profiles where user_id=sender and status in ('active','inactive') and terms_accepted_at is not null)
 or not exists(select 1 from public.member_profiles where user_id=dest and status in ('active','inactive') and terms_accepted_at is not null) then raise exception 'Registered, unblocked accounts required';end if;
 sp:=coalesce(private.current_package_code(sender)='PREMIUM',false);
 rp:=coalesce(private.current_package_code(dest)='PREMIUM',false);
 if p_kind='fund' then
  if not sp then raise exception 'Exchange Wallet is available only to Platinum members';end if;sw:='cash';dw:='exchange';
 elsif p_kind='cash_send' then
  if sp then raise exception 'Platinum members must fund their Exchange Wallet first, then send from Exchange Wallet';end if;
  if not rp then raise exception 'Cash Wallet transfers are allowed only to a Platinum Exchange Wallet';end if;sw:='cash';dw:='exchange';
 else
  if not sp then raise exception 'Exchange Wallet is available only to Platinum members';end if;sw:='exchange';dw:=case when rp then 'exchange' else 'cash' end;
 end if;
 select * into old from private.exchange_transfers where actor_id=sender and idempotency_key=p_key;
 if found then
  if old.kind<>p_kind or old.recipient_id<>dest or old.amount<>p_amount or old.note<>coalesce(p_note,'') then raise exception 'This request key was already used for a different transfer';end if;
  return old.id;
 end if;
 -- Prevent old cash-transfer requests from being replayed after rollout.
 if exists(select 1 from public.mio_ledger where idempotency_key=sender::text||':'||p_key||':out') then raise exception 'This transfer request was already processed';end if;
 -- Cash rows first, then exchange rows, both in member order: atomic balance checks.
 for locked in select member_id from public.mio_wallet_accounts where member_id in(sender,dest) order by member_id for update loop null;end loop;
 if not exists(select 1 from public.mio_wallet_accounts where member_id=sender) or not exists(select 1 from public.mio_wallet_accounts where member_id=dest) then raise exception 'Cash Wallet is not initialized';end if;
 insert into private.exchange_wallet_accounts(member_id) select v from (values(sender),(dest)) x(v) where (v=sender and sp) or (v=dest and rp) group by v order by v on conflict do nothing;
 for locked in select member_id from private.exchange_wallet_accounts where member_id in(sender,dest) order by member_id for update loop null;end loop;
 if sw='cash' then
  select balance into cash from public.mio_wallet_accounts where member_id=sender;
  if cash<p_amount then raise exception 'Insufficient Cash Wallet balance';end if;
  update public.mio_wallet_accounts set balance=balance-p_amount,updated_at=now() where member_id=sender;
 else
  select balance into bal from private.exchange_wallet_accounts where member_id=sender;
  if bal is null or bal<p_amount then raise exception 'Insufficient Exchange Wallet balance';end if;
  update private.exchange_wallet_accounts set balance=balance-p_amount,updated_at=now() where member_id=sender;
 end if;
 if dw='cash' then update public.mio_wallet_accounts set balance=balance+p_amount,updated_at=now() where member_id=dest;
 else update private.exchange_wallet_accounts set balance=balance+p_amount,updated_at=now() where member_id=dest;end if;
 insert into private.exchange_transfers(id,actor_id,recipient_id,source_wallet,destination_wallet,kind,amount,note,idempotency_key) values(tx,sender,dest,sw,dw,p_kind,p_amount,coalesce(p_note,''),p_key);
 if sw='cash' then insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,reason,idempotency_key) values(sender,-p_amount,'transfer_out',dest,tx,case when p_kind='fund' then 'Cash to own Exchange Wallet' else 'Cash to Platinum Exchange Wallet' end,sender::text||':'||p_key||':out');end if;
 if dw='cash' then insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,reason,idempotency_key) values(dest,p_amount,'transfer_in',sender,tx,'Received from Platinum Exchange Wallet',sender::text||':'||p_key||':in');end if;
 return tx;
end $$;
revoke all on function private.exchange_move(text,uuid,numeric,text,text) from public,anon,authenticated;

-- All existing PIN-protected transfer endpoints now enforce the same cash route.
create or replace function private.mio_transfer(p_recipient_id uuid,p_amount numeric,p_idempotency_key text) returns uuid language plpgsql security definer set search_path='' as $$begin
 return private.exchange_move('cash_send',p_recipient_id,p_amount,p_idempotency_key,'');
end $$;
revoke all on function private.mio_transfer(uuid,numeric,text) from public,anon,authenticated;
create function public.fund_exchange_wallet(p_amount numeric,p_idempotency_key text,p_transaction_pin text) returns uuid language plpgsql security definer set search_path='' as $$begin
 perform private.require_transaction_pin(p_transaction_pin,auth.uid());
 if private.has_role('admin') then perform private.require_recent_totp();end if;
 return private.exchange_move('fund',auth.uid(),p_amount,p_idempotency_key,'');
end $$;
create function public.send_exchange_mio(p_recipient_code text,p_amount numeric,p_idempotency_key text,p_transaction_pin text,p_note text default '') returns uuid language plpgsql security definer set search_path='' as $$declare recipient uuid;begin
 perform private.require_transaction_pin(p_transaction_pin,auth.uid());
 if private.has_role('admin') then perform private.require_recent_totp();end if;
 select user_id into recipient from public.member_profiles where upper(member_code)=upper(trim(p_recipient_code)) or upper(referral_code)=upper(trim(p_recipient_code));
 if recipient is null then raise exception 'Member code not found';end if;
 return private.exchange_move('exchange_send',recipient,p_amount,p_idempotency_key,p_note);
end $$;
create or replace function public.lookup_transfer_recipient(p_code text) returns table(member_code text,full_name text) language plpgsql stable security definer set search_path='' as $$begin
 if auth.uid() is null or not exists(select 1 from public.member_profiles where user_id=auth.uid() and status in ('active','inactive') and terms_accepted_at is not null) then raise exception 'Registered account required';end if;
 return query select m.member_code,m.full_name from public.member_profiles m where (upper(m.member_code)=upper(trim(p_code)) or upper(m.referral_code)=upper(trim(p_code))) and m.status in ('active','inactive') and m.terms_accepted_at is not null and m.user_id<>auth.uid()
 and (private.current_package_code(auth.uid())='PREMIUM' or private.current_package_code(m.user_id)='PREMIUM');
end $$;
create function public.my_exchange_wallet(p_year integer default null,p_direction text default 'all',p_offset integer default 0,p_limit integer default 25) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare member uuid:=auth.uid(); result jsonb;since_at timestamptz;until_at timestamptz;
begin
 if member is null then raise exception 'Sign in required';end if;
 if coalesce(private.current_package_code(member),'')<>'PREMIUM' then raise exception 'Exchange Wallet is available only to Platinum members';end if;
 if not exists(select 1 from public.member_profiles where user_id=member and status in ('active','inactive')) then raise exception 'Account unavailable';end if;
 if p_year is not null and (p_year<2000 or p_year>2200) then raise exception 'Invalid year';end if;
 if p_direction not in ('all','received','sent','fund') or p_direction is null then raise exception 'Invalid direction';end if;
 since_at:=case when p_year is not null then make_timestamptz(p_year,1,1,0,0,0,'Asia/Karachi') end;
 until_at:=case when p_year is not null then make_timestamptz(p_year+1,1,1,0,0,0,'Asia/Karachi') end;
 with entries as (
 select t.*,case when t.kind='fund' then 'fund' when t.actor_id=member then 'sent' else 'received' end direction,
 case when t.actor_id=member then t.recipient_id else t.actor_id end counterparty
 from private.exchange_transfers t where ((t.actor_id=member and (t.source_wallet='exchange' or t.kind='fund')) or (t.recipient_id=member and t.destination_wallet='exchange'))
 and (since_at is null or t.created_at>=since_at and t.created_at<until_at)
 ),filtered as(select * from entries where p_direction='all' or direction=p_direction),paged as (
 select f.*,m.full_name,m.member_code from filtered f join public.member_profiles m on m.user_id=f.counterparty order by f.created_at desc,f.id desc offset greatest(coalesce(p_offset,0),0) limit least(greatest(coalesce(p_limit,25),1),100)
 ) select jsonb_build_object(
 'balance',coalesce((select balance from private.exchange_wallet_accounts where member_id=member),0),
 'cash_balance',coalesce((select balance from public.mio_wallet_accounts where member_id=member),0),
 'received',coalesce((select sum(amount) from entries where direction='received'),0),
 'sent',coalesce((select sum(amount) from entries where direction='sent'),0),
 'funded',coalesce((select sum(amount) from entries where direction='fund'),0),
 'total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(to_jsonb(paged) - 'idempotency_key' - 'actor_id' - 'recipient_id' - 'counterparty' order by created_at desc,id desc) from paged),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function public.fund_exchange_wallet(numeric,text,text),public.send_exchange_mio(text,numeric,text,text,text),public.my_exchange_wallet(integer,text,integer,integer) from public,anon;
grant execute on function public.fund_exchange_wallet(numeric,text,text),public.send_exchange_mio(text,numeric,text,text,text),public.my_exchange_wallet(integer,text,integer,integer) to authenticated;
