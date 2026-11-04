-- Dedicated audited maintenance transactions; ordinary product sales remain unchanged.
create table public.maintenance_orders (
 order_id uuid primary key references public.orders(id) on delete cascade,
 member_id uuid not null references public.member_profiles(user_id),
 package_code text not null,
 required_ppv numeric(18,4) not null check(required_ppv>0),
 ppv_earned numeric(18,4) not null default 0,
 distributed_mio numeric(20,8) not null default 0,
 leftover_mio numeric(20,8) not null default 0,
 config_snapshot jsonb not null,
 processed_at timestamptz,
 created_at timestamptz not null default now()
);
create index maintenance_orders_member_idx on public.maintenance_orders(member_id,created_at desc);
create table public.annual_maintenance_payments (
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.member_profiles(user_id),
 idempotency_key text not null,amount_mio numeric(20,8) not null check(amount_mio>0),
 company_mio numeric(20,8) not null check(company_mio>=0),
 distributed_mio numeric(20,8) not null default 0,
 leftover_mio numeric(20,8) not null default 0,
 old_due_at timestamptz not null,new_due_at timestamptz not null,
 config_snapshot jsonb not null,created_at timestamptz not null default now(),
 unique(member_id,idempotency_key)
);
create table public.maintenance_generation_payouts (
 id uuid primary key default gen_random_uuid(),maintenance_kind text not null check(maintenance_kind in('monthly','annual')),
 order_id uuid references public.maintenance_orders(order_id),
 annual_payment_id uuid references public.annual_maintenance_payments(id),
 beneficiary_id uuid not null references public.member_profiles(user_id),
 generation integer not null check(generation between 1 and 10),
 base_mio numeric(20,8) not null,rate numeric(12,8) not null,
 amount_mio numeric(20,8) not null check(amount_mio>0),
 created_at timestamptz not null default now(),
 check(num_nonnulls(order_id,annual_payment_id)=1),
 unique(order_id,beneficiary_id,generation),unique(annual_payment_id,beneficiary_id,generation)
);
create table public.maintenance_wallet_ledger (
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.member_profiles(user_id),
 kind text not null check(kind in('annual_fee','monthly_bonus','annual_bonus')),
 amount_mio numeric(20,8) not null check(amount_mio<>0),
 order_id uuid references public.maintenance_orders(order_id),
 annual_payment_id uuid references public.annual_maintenance_payments(id),
 payout_id uuid unique references public.maintenance_generation_payouts(id),
 created_at timestamptz not null default now(),
 unique(annual_payment_id,kind,member_id),
 check((kind='annual_fee' and annual_payment_id is not null and payout_id is null and amount_mio<0)
  or(kind in('monthly_bonus','annual_bonus') and payout_id is not null and amount_mio>0))
);
alter table public.maintenance_orders enable row level security;
alter table public.annual_maintenance_payments enable row level security;
alter table public.maintenance_generation_payouts enable row level security;
alter table public.maintenance_wallet_ledger enable row level security;
revoke all on public.maintenance_orders,public.annual_maintenance_payments,public.maintenance_generation_payouts,public.maintenance_wallet_ledger from public,anon,authenticated;
grant select on public.maintenance_orders,public.annual_maintenance_payments,public.maintenance_generation_payouts,public.maintenance_wallet_ledger to authenticated;
create policy "read own maintenance orders" on public.maintenance_orders for select to authenticated using(member_id=(select auth.uid()) or private.has_role('admin'));
create policy "read own annual payments" on public.annual_maintenance_payments for select to authenticated using(member_id=(select auth.uid()) or private.has_role('admin'));
create policy "read own maintenance bonuses" on public.maintenance_generation_payouts for select to authenticated using(beneficiary_id=(select auth.uid()) or private.has_role('admin'));
create policy "read own maintenance ledger" on public.maintenance_wallet_ledger for select to authenticated using(member_id=(select auth.uid()) or private.has_role('admin'));

create or replace function private.maintenance_credit(p_beneficiary uuid,p_kind text,p_base numeric,p_rate numeric,p_generation integer,p_order uuid,p_annual uuid)
returns numeric language plpgsql security definer set search_path='' as $$
declare amount numeric:=trunc(p_base*p_rate,8);pid uuid;
begin
 if amount<=0 then return 0;end if;
 insert into public.maintenance_generation_payouts(maintenance_kind,order_id,annual_payment_id,beneficiary_id,generation,base_mio,rate,amount_mio)
 values(p_kind,p_order,p_annual,p_beneficiary,p_generation,p_base,p_rate,amount)
 on conflict do nothing returning id into pid;
 if pid is null then return 0;end if;
 insert into public.member_income_wallets(member_id) values(p_beneficiary) on conflict do nothing;
 update public.member_income_wallets set proceed_mio=proceed_mio+amount,updated_at=now() where member_id=p_beneficiary;
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
 values(p_beneficiary,'proceed',amount,'network_earning',initcap(p_kind)||' maintenance generation '||p_generation,
 jsonb_build_object('maintenance_kind',p_kind,'generation',p_generation,'order_id',p_order,'annual_payment_id',p_annual),'maintenance-payout:'||pid);
 insert into public.maintenance_wallet_ledger(member_id,kind,amount_mio,order_id,annual_payment_id,payout_id)
 values(p_beneficiary,p_kind||'_bonus',amount,p_order,p_annual,pid);
 return amount;
end$$;

-- Existing checkout already guards stock, prices, balances, PIN and replay.
-- Apply the refundable 2 MIO guarantee to every maintenance COD option.
-- Keep regular checkout behavior unchanged.
do $$declare f text;begin
 f:=pg_get_functiondef('public.place_checkout_order(jsonb,text,text,text,text,text,text,text,text)'::regprocedure);
 if strpos(f,'if mode=''STANDARD'' and method=''COD'' then')=0 then raise exception 'Checkout signature changed; review COD hold integration';end if;
 f:=regexp_replace(f,'^CREATE OR REPLACE FUNCTION (public[.])?place_checkout_order[(]',
  'CREATE OR REPLACE FUNCTION private.place_maintenance_checkout(');
 f:=replace(f,'if mode=''STANDARD'' and method=''COD'' then','if method=''COD'' then');
 if strpos(f,'x.idempotency_key=p_idempotency_key')=0 then raise exception 'Checkout replay lookup changed';end if;
 f:=replace(f,'x.idempotency_key=p_idempotency_key','x.idempotency_key=member::text||'':''||p_idempotency_key');
 execute f;
end$$;

revoke all on function private.place_maintenance_checkout(jsonb,text,text,text,text,text,text,text,text) from public,anon,authenticated;

create or replace function public.place_maintenance_order(
 p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,
 p_idempotency_key text,p_checkout_mode text,p_balance_payment_method text,p_transaction_pin text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare member uuid:=auth.uid();r jsonb:=private.current_maintenance_rules();code text;target numeric;placed jsonb;oid uuid;ppv numeric;
begin
 if member is null or not private.package_eligible(member) then raise exception 'Active package required';end if;
 if coalesce((r->>'enabled')::boolean,false)=false then raise exception 'Maintenance is unavailable';end if;
 if upper(coalesce(p_checkout_mode,'')) not in('STANDARD','SHOPPING_POINTS') then raise exception 'Choose a valid payment option';end if;
 code:=private.current_package_code(member);target:=(r->'monthly_ppv'->>code)::numeric;
 if target is null or target<=0 then raise exception 'Package maintenance rule is missing';end if;
 placed:=private.place_maintenance_checkout(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,
  p_idempotency_key,p_checkout_mode,p_balance_payment_method,p_transaction_pin);
 oid:=(placed->>'order_id')::uuid;
 if coalesce((placed->>'duplicate')::boolean,false) then
  if not exists(select 1 from public.maintenance_orders where order_id=oid and member_id=member) then raise exception 'Order key already belongs to regular shopping';end if;
  return placed||jsonb_build_object('maintenance',true);
 end if;
 select coalesce(sum(ppv_per_unit_snapshot*quantity),0) into ppv from public.order_items where order_id=oid;
 if ppv<=0 then raise exception 'Select products with PPV for monthly maintenance';end if;
 insert into public.maintenance_orders(order_id,member_id,package_code,required_ppv,config_snapshot)
 values(oid,member,code,target,r);
 -- The maintenance buyer receives no cashback, affiliate or ordinary shopping reward.
 update public.ecommerce_rewards set status='cancelled' where order_id=oid and status in('pending_delivery','held_activation');
 return placed||jsonb_build_object('maintenance',true,'order_ppv',ppv,'required_ppv',target);
end$$;

create or replace function private.release_maintenance_order(p_order uuid) returns void language plpgsql security definer set search_path='' as $$
declare m public.maintenance_orders%rowtype;o public.orders%rowtype;state public.member_maintenance%rowtype;
 ppv numeric;funding numeric;base numeric;rate numeric;value numeric;paid numeric:=0;leftover numeric:=0;
 node uuid;recipient uuid;level integer;r jsonb;max_level integer;progress numeric;
begin
 select * into m from public.maintenance_orders where order_id=p_order for update;
 if m.order_id is null or m.processed_at is not null then return;end if;
 select * into o from public.orders where id=p_order for update;
 if o.status in('cancelled','returned') then return;end if;
 if o.status<>'delivered' or o.payment_status<>'confirmed' then return;end if;
 select coalesce(sum(ppv_per_unit_snapshot*quantity),0) into ppv from public.order_items where order_id=p_order;
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=p_order and a.share_kind='network_rewards';
 rate:=coalesce(o.mio_rate_snapshot,private.current_mio_reference_price());
 if ppv*rate>funding+.01 then raise exception 'Maintenance PPV exceeds funded network allocation';end if;
 base:=trunc(ppv,8);r:=m.config_snapshot;
 select sponsor_id into node from public.member_profiles where user_id=m.member_id;
 for level in 1..jsonb_array_length(r->'monthly_rates') loop
  value:=(r->'monthly_rates'->>(level-1))::numeric;
  if node is not null then
   recipient:=node;
   if value>0 and private.package_eligible(recipient) then
    select (r->'monthly_levels'->>private.current_package_code(recipient))::integer into max_level;
    if max_level>=level and exists(select 1 from public.member_maintenance x where x.member_id=recipient and x.monthly_due_at>now() and x.annual_due_at>now()) then
     paid:=paid+private.maintenance_credit(recipient,'monthly',base,value,level,p_order,null);
    end if;
   end if;
   select sponsor_id into node from public.member_profiles where user_id=recipient;
  end if;
 end loop;
 leftover:=greatest(0,base-paid);
 select * into state from public.member_maintenance where member_id=m.member_id for update;
 if state.member_id is null then raise exception 'Maintenance deadline missing';end if;
 progress:=state.monthly_progress_ppv+ppv;
 if progress>=m.required_ppv then
  update public.member_maintenance set monthly_progress_ppv=mod(progress,m.required_ppv),
   monthly_due_at=greatest(monthly_due_at,now())+interval '30 days'*floor(progress/m.required_ppv),updated_at=now() where member_id=m.member_id;
 else update public.member_maintenance set monthly_progress_ppv=progress,updated_at=now() where member_id=m.member_id;end if;
 update public.maintenance_orders set ppv_earned=ppv,distributed_mio=paid,leftover_mio=leftover,processed_at=now() where order_id=p_order;
 update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=p_order;
 perform private.notify_member(m.member_id,'shopping','Monthly maintenance updated',
  'Your qualifying shopping was recorded. Open the dashboard to see days remaining.','order',p_order,
  jsonb_build_object('ppv',ppv,'leftover_mio',leftover));
end$$;

-- Reuse the established delivery/payment trigger, but short-circuit normal
-- buyer cashback, ordinary DP/GP/BP, personal PPV and package activation.
do $$declare f text;old_text text:='select * into o from public.orders where id = new.id for update;';begin
 f:=pg_get_functiondef('private.release_order_rewards()'::regprocedure);
 if strpos(f,old_text)=0 then raise exception 'Order reward function changed; review maintenance hook';end if;
 f:=replace(f,old_text,
  'if exists(select 1 from public.maintenance_orders where order_id=new.id) then perform private.release_maintenance_order(new.id);return new;end if;'||chr(10)||old_text);
 execute f;
end$$;

create or replace function public.pay_annual_maintenance(p_transaction_pin text,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare member uuid:=auth.uid();r jsonb:=private.current_maintenance_rules();s public.member_maintenance%rowtype;
 fee numeric;company numeric;paid numeric:=0;leftover numeric;pid uuid;recipient uuid;node uuid;level integer;ratio numeric;existing uuid;
begin
 if member is null or not private.package_eligible(member) then raise exception 'Active package required';end if;
 if coalesce((r->>'enabled')::boolean,false)=false then raise exception 'Maintenance is unavailable';end if;
 if nullif(trim(p_idempotency_key),'') is null then raise exception 'Payment key required';end if;
 perform pg_advisory_xact_lock(hashtextextended('annual-maintenance:'||member::text,0));
 select id into existing from public.annual_maintenance_payments where member_id=member and idempotency_key=p_idempotency_key;
 if existing is not null then return jsonb_build_object('payment_id',existing,'duplicate',true);end if;
 select * into s from public.member_maintenance where member_id=member for update;
 if s.member_id is null then raise exception 'Maintenance deadline missing';end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 fee:=(r->>'annual_fee_mio')::numeric;company:=round(fee*(r->>'annual_company_rate')::numeric,8);
 update public.mio_wallet_accounts set balance=balance-fee,updated_at=now() where member_id=member and balance>=fee;
 if not found then raise exception 'Cash Wallet needs % MIO',fee;end if;
 insert into public.annual_maintenance_payments(member_id,idempotency_key,amount_mio,company_mio,old_due_at,new_due_at,config_snapshot)
 values(member,p_idempotency_key,fee,company,s.annual_due_at,greatest(s.annual_due_at,now())+interval '365 days',r) returning id into pid;
 insert into public.maintenance_wallet_ledger(member_id,kind,amount_mio,annual_payment_id) values(member,'annual_fee',-fee,pid);
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
 values(member,'cash',-fee,'annual_maintenance_fee','Annual maintenance · 20 MIO',jsonb_build_object('payment_id',pid),'annual-maintenance:'||pid);
 update public.member_maintenance set annual_due_at=greatest(annual_due_at,now())+interval '365 days',updated_at=now() where member_id=member;
 select sponsor_id into node from public.member_profiles where user_id=member;
 for level in 1..jsonb_array_length(r->'annual_rates') loop
  ratio:=(r->'annual_rates'->>(level-1))::numeric;
  if node is not null and ratio>0 then
   recipient:=node;
   if private.package_eligible(recipient) and exists(select 1 from public.member_maintenance x where x.member_id=recipient and x.monthly_due_at>now() and x.annual_due_at>now()) then
    paid:=paid+private.maintenance_credit(recipient,'annual',fee,ratio,level,null,pid);
   end if;
   select sponsor_id into node from public.member_profiles where user_id=recipient;
  end if;
 end loop;
 leftover:=greatest(0,fee-company-paid);
 update public.annual_maintenance_payments set distributed_mio=paid,leftover_mio=leftover where id=pid;
 perform private.notify_member(member,'wallet','Annual maintenance renewed',
  '20 MIO annual maintenance was paid from your Cash Wallet.','maintenance',pid,jsonb_build_object('new_due_at',greatest(s.annual_due_at,now())+interval '365 days'));
 return jsonb_build_object('payment_id',pid,'duplicate',false,'fee_mio',fee,'company_mio',company,'distributed_mio',paid,'leftover_mio',leftover,'annual_due_at',greatest(s.annual_due_at,now())+interval '365 days');
end$$;

revoke all on function private.maintenance_credit(uuid,text,numeric,numeric,integer,uuid,uuid),private.release_maintenance_order(uuid) from public,anon,authenticated;
revoke all on function public.place_maintenance_order(jsonb,text,text,text,text,text,text,text,text),public.pay_annual_maintenance(text,text) from public,anon;
grant execute on function public.place_maintenance_order(jsonb,text,text,text,text,text,text,text,text),public.pay_annual_maintenance(text,text) to authenticated;
notify pgrst,'reload schema';
