-- Audited marketplace wallet checkout, COD guarantees, rank releases and notifications.

alter table public.orders drop constraint if exists orders_payment_method_check;
alter table public.orders add constraint orders_payment_method_check
 check(payment_method in('COD','MANUAL','MIO','SHOPPING_MIO','SHOPPING_COD'));
alter table public.orders
 add column if not exists checkout_mode text not null default 'STANDARD'
  check(checkout_mode in('STANDARD','SHOPPING_POINTS')),
 add column if not exists balance_payment_method text not null default 'COD'
  check(balance_payment_method in('COD','MIO')),
 add column if not exists mio_rate_snapshot numeric(14,2),
 add column if not exists shopping_points_used numeric(14,2) not null default 0 check(shopping_points_used>=0),
 add column if not exists cash_mio_used numeric(20,8) not null default 0 check(cash_mio_used>=0),
 add column if not exists cod_due_pkr numeric(14,2) not null default 0 check(cod_due_pkr>=0);

create table public.order_payment_allocations(
 order_id uuid primary key references public.orders(id) on delete cascade,
 member_id uuid not null references public.member_profiles(user_id),
 checkout_mode text not null check(checkout_mode in('STANDARD','SHOPPING_POINTS')),
 balance_payment_method text not null check(balance_payment_method in('COD','MIO')),
 mio_rate_snapshot numeric(14,2) not null check(mio_rate_snapshot>0),
 shopping_points_used numeric(14,2) not null default 0 check(shopping_points_used>=0),
 cash_mio_used numeric(20,8) not null default 0 check(cash_mio_used>=0),
 cod_due_pkr numeric(14,2) not null default 0 check(cod_due_pkr>=0),
 refunded_at timestamptz,
 created_at timestamptz not null default now()
);
create index order_payment_allocations_member_idx on public.order_payment_allocations(member_id,created_at desc);

create table public.order_payment_ledger(
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id) on delete cascade,
 member_id uuid not null references public.member_profiles(user_id),
 wallet_kind text not null check(wallet_kind in('cash','shopping')),
 amount numeric(20,8) not null check(amount<>0),
 entry_kind text not null check(entry_kind in('checkout_debit','checkout_refund','guarantee_hold','guarantee_refund')),
 note text not null,
 metadata jsonb not null default '{}'::jsonb,
 idempotency_key text not null unique,
 created_at timestamptz not null default now()
);
create index order_payment_ledger_member_idx on public.order_payment_ledger(member_id,created_at desc);
create index order_payment_ledger_order_idx on public.order_payment_ledger(order_id,created_at);

create table public.member_cod_guarantees(
 order_id uuid primary key references public.orders(id) on delete cascade,
 buyer_id uuid not null references public.member_profiles(user_id),
 sponsor_id uuid references public.member_profiles(user_id),
 payer_id uuid references public.member_profiles(user_id),
 funding_wallet text check(funding_wallet is null or funding_wallet in('cash','shopping')),
 mio_amount numeric(20,8) not null default 2 check(mio_amount=2),
 wallet_amount numeric(20,8),
 mio_rate_snapshot numeric(14,2) not null check(mio_rate_snapshot>0),
 status text not null check(status in('pending_sponsor','held','declined','released','cancelled_refunded')),
 requested_at timestamptz not null default now(),
 confirmed_at timestamptz,
 released_at timestamptz,
 updated_at timestamptz not null default now()
);
create index member_cod_guarantees_sponsor_idx on public.member_cod_guarantees(sponsor_id,status,requested_at desc);

create table public.promotion_rank_releases(
 id uuid primary key default gen_random_uuid(),
 rank_history_id uuid not null unique references public.member_rank_history(id) on delete cascade,
 member_id uuid not null references public.member_profiles(user_id),
 rank_code text not null references public.leadership_rank_definitions(rank_code),
 amount numeric(20,8) not null check(amount>0),
 created_at timestamptz not null default now()
);
create index promotion_rank_releases_member_idx on public.promotion_rank_releases(member_id,created_at desc);

create table public.member_notifications(
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references public.member_profiles(user_id) on delete cascade,
 category text not null check(category in('income','outgoing','wallet','shopping','refund','promotion','rank','order','guarantee','manager','community')),
 title text not null check(length(trim(title)) between 2 and 120),
 message text not null check(length(trim(message)) between 2 and 500),
 entity_type text,
 entity_id uuid,
 metadata jsonb not null default '{}'::jsonb,
 read_at timestamptz,
 created_at timestamptz not null default now()
);
create index member_notifications_member_idx on public.member_notifications(member_id,read_at,created_at desc);

alter table public.order_payment_allocations enable row level security;
alter table public.order_payment_ledger enable row level security;
alter table public.member_cod_guarantees enable row level security;
alter table public.promotion_rank_releases enable row level security;
alter table public.member_notifications enable row level security;

create policy "members read own payment allocations" on public.order_payment_allocations for select to authenticated
 using(member_id=(select auth.uid()) or private.has_role('admin'));
create policy "members read own payment ledger" on public.order_payment_ledger for select to authenticated
 using(member_id=(select auth.uid()) or private.has_role('admin'));
create policy "members read related cod guarantees" on public.member_cod_guarantees for select to authenticated
 using(buyer_id=(select auth.uid()) or sponsor_id=(select auth.uid()) or payer_id=(select auth.uid()) or private.has_role('admin'));
create policy "members read own promotion releases" on public.promotion_rank_releases for select to authenticated
 using(member_id=(select auth.uid()) or private.has_role('admin'));
create policy "members read own notifications" on public.member_notifications for select to authenticated
 using(member_id=(select auth.uid()));

revoke all on public.order_payment_allocations,public.order_payment_ledger,public.member_cod_guarantees,public.promotion_rank_releases,public.member_notifications from public,anon,authenticated;
grant select on public.order_payment_allocations,public.order_payment_ledger,public.member_cod_guarantees,public.promotion_rank_releases,public.member_notifications to authenticated;

create or replace function private.current_mio_reference_price() returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce((select (config_value#>>'{}')::numeric from public.system_config
  where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null order by version desc limit 1),300)::numeric
$$;

create or replace function private.notify_member(p_member uuid,p_category text,p_title text,p_message text,p_entity_type text default null,p_entity_id uuid default null,p_metadata jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path='' as $$
begin
 if p_member is null then return;end if;
 insert into public.member_notifications(member_id,category,title,message,entity_type,entity_id,metadata)
 values(p_member,p_category,p_title,p_message,p_entity_type,p_entity_id,coalesce(p_metadata,'{}'::jsonb));
end$$;

create or replace function public.place_checkout_order(
 p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,
 p_idempotency_key text,p_checkout_mode text,p_balance_payment_method text,p_transaction_pin text default null
)returns jsonb language plpgsql security definer set search_path='' as $$
declare member uuid:=auth.uid();oid uuid;o public.orders%rowtype;mode text:=upper(trim(coalesce(p_checkout_mode,'STANDARD')));
 method text:=upper(trim(coalesce(p_balance_payment_method,'COD')));rate numeric;shopping numeric:=0;cash numeric:=0;cod numeric:=0;
 sponsor uuid;sponsor_cash numeric:=0;sponsor_shopping numeric:=0;existing public.order_payment_allocations%rowtype;
begin
 if member is null then raise exception 'Sign in before placing an order';end if;
 if mode not in('STANDARD','SHOPPING_POINTS') then raise exception 'Choose a valid shopping mode';end if;
 if method not in('COD','MIO') then raise exception 'Choose MIO advance payment or Cash on Delivery';end if;
 perform pg_advisory_xact_lock(hashtextextended('checkout:'||member::text||':'||p_idempotency_key,0));
 select a.* into existing from public.order_payment_allocations a join public.orders x on x.id=a.order_id
  where x.buyer_id=member and x.idempotency_key=p_idempotency_key;
 if existing.order_id is not null then
  return jsonb_build_object('order_id',existing.order_id,'checkout_mode',existing.checkout_mode,'payment_method',existing.balance_payment_method,'duplicate',true);
 end if;
 rate:=private.current_mio_reference_price();
 oid:=public.place_affiliate_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key,null);
 select * into o from public.orders where id=oid for update;
 insert into public.member_income_wallets(member_id) values(member) on conflict(member_id) do nothing;
 if mode='SHOPPING_POINTS' then
  shopping:=round(o.subtotal_pkr*.5,2);
  update public.member_income_wallets set shopping_points=shopping_points-shopping,updated_at=now()
   where member_id=member and shopping_points>=shopping;
  if not found then raise exception 'Shopping Points need at least PKR % for this order',shopping;end if;
  insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
   values(oid,member,'shopping',-shopping,'checkout_debit','50% paid with Shopping Points',jsonb_build_object('pkr_value',shopping),'shopping-checkout:'||oid);
 end if;
 if method='MIO' then
  perform private.require_transaction_pin(p_transaction_pin,member);
  cash:=round((o.total_pkr-shopping)/rate,8);
  update public.mio_wallet_accounts set balance=balance-cash,updated_at=now() where member_id=member and balance>=cash;
  if not found then raise exception 'Cash Wallet needs % MIO for this order',cash;end if;
  insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
   values(oid,member,'cash',-cash,'checkout_debit','Marketplace advance payment',jsonb_build_object('pkr_value',o.total_pkr-shopping,'mio_rate',rate),'cash-checkout:'||oid);
 else
  cod:=o.total_pkr-shopping;
 end if;
 insert into public.order_payment_allocations(order_id,member_id,checkout_mode,balance_payment_method,mio_rate_snapshot,shopping_points_used,cash_mio_used,cod_due_pkr)
 values(oid,member,mode,method,rate,shopping,cash,cod);
 update public.orders set checkout_mode=mode,balance_payment_method=method,mio_rate_snapshot=rate,shopping_points_used=shopping,
  cash_mio_used=cash,cod_due_pkr=cod,payment_method=case when mode='SHOPPING_POINTS' and method='MIO' then 'SHOPPING_MIO' when mode='SHOPPING_POINTS' then 'SHOPPING_COD' when method='MIO' then 'MIO' else 'COD' end,
  payment_status=case when method='MIO' then 'confirmed'::public.payment_status else 'unconfirmed'::public.payment_status end,updated_at=now() where id=oid;
 -- Only a normal full-COD order uses the 2 MIO guarantee. Split Shopping Points + COD never does.
 if mode='STANDARD' and method='COD' then
  if coalesce((select balance from public.mio_wallet_accounts where member_id=member),0)>=2 then
   perform private.require_transaction_pin(p_transaction_pin,member);
   update public.mio_wallet_accounts set balance=balance-2,updated_at=now() where member_id=member and balance>=2;
   insert into public.member_cod_guarantees(order_id,buyer_id,payer_id,funding_wallet,wallet_amount,mio_rate_snapshot,status,confirmed_at)
    values(oid,member,member,'cash',2,rate,'held',now());
   insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
    values(oid,member,'cash',-2,'guarantee_hold','Refundable COD guarantee',jsonb_build_object('mio_amount',2),'cod-guarantee-hold:'||oid);
  else
   select sponsor_id into sponsor from public.member_profiles where user_id=member;
   if sponsor is null then raise exception 'A direct sponsor is required because your Cash Wallet has less than 2 MIO';end if;
   select coalesce(balance,0) into sponsor_cash from public.mio_wallet_accounts where member_id=sponsor;
   select coalesce(shopping_points,0) into sponsor_shopping from public.member_income_wallets where member_id=sponsor;
   if coalesce(sponsor_cash,0)<2 and coalesce(sponsor_shopping,0)<2*rate then
    raise exception 'Sponsor cannot receive this request: 2 MIO or equivalent Shopping Points are required';
   end if;
   insert into public.member_cod_guarantees(order_id,buyer_id,sponsor_id,mio_rate_snapshot,status)
    values(oid,member,sponsor,rate,'pending_sponsor');
   perform private.notify_member(sponsor,'guarantee','COD guarantee request','A direct member needs a refundable 2 MIO order guarantee.','order',oid,jsonb_build_object('buyer_id',member));
  end if;
 end if;
 perform private.notify_member(member,'order','Order placed','Your marketplace order has been placed.','order',oid,jsonb_build_object('checkout_mode',mode,'balance_method',method));
 return jsonb_build_object('order_id',oid,'checkout_mode',mode,'payment_method',method,'shopping_points_used',shopping,'cash_mio_used',cash,'cod_due_pkr',cod,'duplicate',false);
end$$;

create or replace function public.my_cod_guarantee_requests() returns table(
 order_id uuid,order_code text,buyer_name text,total_pkr numeric,status text,mio_rate_snapshot numeric,
 sponsor_cash_mio numeric,sponsor_shopping_points numeric,requested_at timestamptz
)language sql stable security definer set search_path='' as $$
 select g.order_id,o.order_code,p.full_name,o.total_pkr,g.status,g.mio_rate_snapshot,
  coalesce(w.balance,0),coalesce(i.shopping_points,0),g.requested_at
 from public.member_cod_guarantees g join public.orders o on o.id=g.order_id
 join public.member_profiles p on p.user_id=g.buyer_id
 left join public.mio_wallet_accounts w on w.member_id=g.sponsor_id
 left join public.member_income_wallets i on i.member_id=g.sponsor_id
 where g.sponsor_id=auth.uid() order by g.requested_at desc
$$;

create or replace function public.review_cod_guarantee(p_order_id uuid,p_approve boolean,p_wallet text,p_transaction_pin text,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare member uuid:=auth.uid();g public.member_cod_guarantees%rowtype;wallet text:=lower(trim(coalesce(p_wallet,'cash')));amount numeric;
begin
 if member is null then raise exception 'Sign in first';end if;
 perform pg_advisory_xact_lock(hashtextextended('cod-guarantee:'||p_order_id::text,0));
 select * into g from public.member_cod_guarantees where order_id=p_order_id for update;
 if g.order_id is null or g.sponsor_id<>member or g.status<>'pending_sponsor' then raise exception 'Pending sponsor guarantee request not found';end if;
 if not p_approve then
  update public.member_cod_guarantees set status='declined',updated_at=now() where order_id=p_order_id;
  perform private.notify_member(g.buyer_id,'guarantee','Guarantee declined','Your sponsor declined the COD guarantee request.','order',p_order_id);
  return jsonb_build_object('order_id',p_order_id,'status','declined');
 end if;
 if wallet not in('cash','shopping') then raise exception 'Choose Cash Wallet or Shopping Points';end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 amount:=case when wallet='cash' then 2 else 2*g.mio_rate_snapshot end;
 if wallet='cash' then
  update public.mio_wallet_accounts set balance=balance-amount,updated_at=now() where member_id=member and balance>=amount;
 else
  insert into public.member_income_wallets(member_id) values(member) on conflict(member_id)do nothing;
  update public.member_income_wallets set shopping_points=shopping_points-amount,updated_at=now() where member_id=member and shopping_points>=amount;
 end if;
 if not found then raise exception 'Selected sponsor wallet has insufficient balance';end if;
 insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
 values(p_order_id,member,wallet,-amount,'guarantee_hold','Refundable sponsor COD guarantee',jsonb_build_object('mio_amount',2,'mio_rate',g.mio_rate_snapshot),p_idempotency_key);
 update public.member_cod_guarantees set payer_id=member,funding_wallet=wallet,wallet_amount=amount,status='held',confirmed_at=now(),updated_at=now() where order_id=p_order_id;
 perform private.notify_member(g.buyer_id,'guarantee','COD guarantee approved','Your sponsor approved the refundable order guarantee.','order',p_order_id,jsonb_build_object('wallet',wallet));
 return jsonb_build_object('order_id',p_order_id,'status','held','wallet',wallet,'amount',amount);
end$$;

create or replace function private.guard_cod_order_progress() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if (new.status<>old.status or new.payment_status<>old.payment_status) and exists(
  select 1 from public.member_cod_guarantees g where g.order_id=new.id and g.status not in('held','released','cancelled_refunded')
 ) and new.status not in('cancelled','returned') then raise exception 'COD guarantee approval is required before processing this order';end if;
 return new;
end$$;
create trigger zx_guard_cod_order_progress before update of status,payment_status on public.orders
 for each row execute function private.guard_cod_order_progress();

create or replace function private.refund_checkout_and_guarantee() returns trigger language plpgsql security definer set search_path='' as $$
declare a public.order_payment_allocations%rowtype;g public.member_cod_guarantees%rowtype;
begin
 if new.status not in('cancelled','returned') and not(new.status='delivered' and new.payment_status='confirmed') then return new;end if;
 select * into g from public.member_cod_guarantees where order_id=new.id for update;
 if g.order_id is not null and g.status='held' then
  if g.funding_wallet='cash' then update public.mio_wallet_accounts set balance=balance+g.wallet_amount,updated_at=now() where member_id=g.payer_id;
  else update public.member_income_wallets set shopping_points=shopping_points+g.wallet_amount,updated_at=now() where member_id=g.payer_id;end if;
  insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
   values(new.id,g.payer_id,g.funding_wallet,g.wallet_amount,'guarantee_refund','COD guarantee returned',jsonb_build_object('mio_amount',2),'cod-guarantee-refund:'||new.id) on conflict(idempotency_key)do nothing;
  update public.member_cod_guarantees set status=case when new.status in('cancelled','returned') then 'cancelled_refunded' else 'released' end,released_at=now(),updated_at=now() where order_id=new.id;
  perform private.notify_member(g.payer_id,'refund','COD guarantee returned','The refundable order guarantee has returned to its original wallet.','order',new.id);
 elsif g.order_id is not null and g.status='pending_sponsor' and new.status in('cancelled','returned') then
  update public.member_cod_guarantees set status='cancelled_refunded',released_at=now(),updated_at=now() where order_id=new.id;
 end if;
 if new.status in('cancelled','returned') then
  select * into a from public.order_payment_allocations where order_id=new.id for update;
  if a.order_id is not null and a.refunded_at is null then
   if a.cash_mio_used>0 then
    update public.mio_wallet_accounts set balance=balance+a.cash_mio_used,updated_at=now() where member_id=a.member_id;
    insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,idempotency_key)
     values(new.id,a.member_id,'cash',a.cash_mio_used,'checkout_refund','Marketplace Cash Wallet refund','cash-checkout-refund:'||new.id) on conflict do nothing;
   end if;
   if a.shopping_points_used>0 then
    update public.member_income_wallets set shopping_points=shopping_points+a.shopping_points_used,updated_at=now() where member_id=a.member_id;
    insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,idempotency_key)
     values(new.id,a.member_id,'shopping',a.shopping_points_used,'checkout_refund','Marketplace Shopping Points refund','shopping-checkout-refund:'||new.id) on conflict do nothing;
   end if;
   update public.order_payment_allocations set refunded_at=now() where order_id=new.id;
   perform private.notify_member(a.member_id,'refund','Order payment refunded','Wallet payments for the closed order were returned.','order',new.id);
  end if;
 end if;
 return new;
end$$;
create trigger zz_refund_checkout_and_guarantee after update of status,payment_status on public.orders
 for each row execute function private.refund_checkout_and_guarantee();

create or replace function private.release_promotion_on_rank() returns trigger language plpgsql security definer set search_path='' as $$
declare amount numeric;inserted integer;
begin
 insert into public.member_income_wallets(member_id) values(new.member_id) on conflict(member_id)do nothing;
 select promotion_points into amount from public.member_income_wallets where member_id=new.member_id for update;
 if coalesce(amount,0)<=0 then return new;end if;
 insert into public.promotion_rank_releases(rank_history_id,member_id,rank_code,amount) values(new.id,new.member_id,new.rank_code,amount) on conflict(rank_history_id)do nothing;
 get diagnostics inserted=row_count;if inserted=0 then return new;end if;
 update public.member_income_wallets set promotion_points=0,proceed_mio=proceed_mio+amount,updated_at=now() where member_id=new.member_id;
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key) values
 (new.member_id,'promotion',-amount,'rank_release','Promotion Points released on rank achievement',jsonb_build_object('rank_code',new.rank_code),'promotion-rank-out:'||new.id),
 (new.member_id,'proceed',amount,'rank_release','Rank promotion transferred to Proceed Wallet',jsonb_build_object('rank_code',new.rank_code),'promotion-rank-in:'||new.id);
 perform private.notify_member(new.member_id,'rank','New rank achieved','Your Promotion Points moved to Proceed Wallet.','rank_history',new.id,jsonb_build_object('rank_code',new.rank_code,'amount',amount));
 return new;
end$$;
create trigger zz_release_promotion_on_rank after insert on public.member_rank_history
 for each row execute function private.release_promotion_on_rank();

create or replace function private.notify_income_wallet_entry() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform private.notify_member(new.member_id,case when new.amount>=0 then 'income' else 'outgoing' end,
  case when new.amount>=0 then 'Wallet credited' else 'Wallet deducted' end,
  coalesce(new.note,replace(new.entry_kind,'_',' ')),'income_wallet_ledger',new.id,
  jsonb_build_object('wallet',new.wallet_kind,'amount',new.amount));return new;
end$$;
create trigger zz_notify_income_wallet_entry after insert on public.income_wallet_ledger
 for each row execute function private.notify_income_wallet_entry();

create or replace function private.notify_order_update() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.buyer_id is not null and (new.status<>old.status or new.payment_status<>old.payment_status) then
  perform private.notify_member(new.buyer_id,'order','Order updated','Order '||new.order_code||' is now '||replace(new.status::text,'_',' ')||'.','order',new.id,jsonb_build_object('status',new.status,'payment_status',new.payment_status));
 end if;return new;
end$$;
create trigger zz_notify_order_update after update of status,payment_status on public.orders
 for each row execute function private.notify_order_update();

create or replace function public.my_notifications(p_limit integer default 50) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('unread',count(*) filter(where read_at is null),'rows',coalesce(jsonb_agg(to_jsonb(n) order by created_at desc),'[]'::jsonb))
 from(select id,category,title,message,entity_type,entity_id,metadata,read_at,created_at from public.member_notifications
  where member_id=auth.uid() order by created_at desc limit least(greatest(coalesce(p_limit,50),1),100))n
$$;
create or replace function public.mark_notifications_read() returns integer language plpgsql security definer set search_path='' as $$
declare changed integer;begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 update public.member_notifications set read_at=now() where member_id=auth.uid() and read_at is null;get diagnostics changed=row_count;return changed;
end$$;

create or replace function public.my_income_wallets() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare member uuid:=auth.uid();cfg jsonb;result jsonb;begin
 if member is null or not private.registered_member(member)then raise exception 'Member account required';end if;
 cfg:=private.current_proceed_wallet_config();
 select jsonb_build_object('cash_mio',coalesce(m.balance,0),'proceed_mio',coalesce(w.proceed_mio,0),'shopping_points',coalesce(w.shopping_points,0),'promotion_points',coalesce(w.promotion_points,0),'shopping_locked',false,'promotion_locked',false,'config',cfg,
  'ledger',coalesce((select jsonb_agg(x order by x.created_at desc)from(select id,wallet_kind,amount,entry_kind,note,metadata,created_at from public.income_wallet_ledger where member_id=member order by created_at desc limit 200)x),'[]'::jsonb),
  'promotion_releases',coalesce((select jsonb_agg(x order by x.created_at desc)from(select r.id,r.rank_code,d.display_name,r.amount,r.created_at from public.promotion_rank_releases r join public.leadership_rank_definitions d on d.rank_code=r.rank_code where r.member_id=member order by r.created_at desc limit 100)x),'[]'::jsonb)) into result
 from public.member_profiles p left join public.mio_wallet_accounts m on m.member_id=p.user_id left join public.member_income_wallets w on w.member_id=p.user_id where p.user_id=member;
 return coalesce(result,'{}');end$$;

revoke all on function public.place_checkout_order(jsonb,text,text,text,text,text,text,text,text),public.my_cod_guarantee_requests(),public.review_cod_guarantee(uuid,boolean,text,text,text),public.my_notifications(integer),public.mark_notifications_read() from public,anon;
grant execute on function public.place_checkout_order(jsonb,text,text,text,text,text,text,text,text),public.my_cod_guarantee_requests(),public.review_cod_guarantee(uuid,boolean,text,text,text),public.my_notifications(integer),public.mark_notifications_read() to authenticated;
revoke all on function private.current_mio_reference_price(),private.notify_member(uuid,text,text,text,text,uuid,jsonb),private.guard_cod_order_progress(),private.refund_checkout_and_guarantee(),private.release_promotion_on_rank(),private.notify_income_wallet_entry(),private.notify_order_update() from public,anon,authenticated;

notify pgrst,'reload schema';
