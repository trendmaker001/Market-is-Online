-- Separate company processing fees from member spendable balances. No ledger deletion.
-- Applied atomically; locks prevent a legacy conversion from being missed during migration.
lock table public.proceed_wallet_conversions,public.mio_wallet_accounts,public.mio_ledger in share row exclusive mode;
create table if not exists private.proceed_fee_reclassifications (
 legacy_ledger_id uuid primary key references public.mio_ledger(id),
 adjustment_ledger_id uuid not null unique references public.mio_ledger(id),
 conversion_id uuid not null unique references public.proceed_wallet_conversions(id),
 amount numeric not null check(amount>0),created_at timestamptz not null default now()
);
alter table private.proceed_fee_reclassifications enable row level security;
revoke all on private.proceed_fee_reclassifications from public,anon,authenticated;
CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_proceed()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select s.source_type,s.source_id,s.category,s.currency,s.amount
 from private.company_treasury_sources_before_maintenance() s
 where not (
  s.source_type='order' and s.category in ('shopping_conversion_leftover','ecommerce_conversion_leftover')
  and exists(select 1 from public.maintenance_orders m where m.order_id=s.source_id)
 )
 union all
 select 'order',m.order_id,'monthly_maintenance_leftover','MIO',m.leftover_mio
 from public.maintenance_orders m
 where m.processed_at is not null and m.leftover_mio>0;
$function$;

create or replace function private.company_treasury_sources()
returns table(source_type text,source_id uuid,category text,currency text,amount numeric)
language sql stable security definer set search_path='' as $$
 select * from private.company_treasury_sources_before_proceed()
 union all select 'proceed_conversion',c.id,'proceed_processing_fee','MIO',c.fee_amount
 from public.proceed_wallet_conversions c where c.fee_amount>0;
$$;
revoke all on function private.company_treasury_sources_before_proceed(),private.company_treasury_sources() from public,anon,authenticated;
CREATE OR REPLACE FUNCTION public.convert_proceed_wallet(p_amount numeric, p_transaction_pin text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();company uuid;cfg jsonb;cash_rate numeric;fee_rate numeric;shopping_rate numeric;promotion_rate numeric;minimum numeric;cash_amount numeric;fee_amount numeric;shopping_amount numeric;promotion_amount numeric;conversion uuid;remaining numeric;
begin
 if member is null or not private.registered_member(member)then raise exception 'Member account required';end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 if p_idempotency_key is null or length(trim(p_idempotency_key))<8 then raise exception 'Valid request reference required';end if;
 perform pg_advisory_xact_lock(hashtextextended('proceed-request:'||p_idempotency_key,0));
 if exists(select 1 from public.proceed_wallet_conversions where idempotency_key=p_idempotency_key and (member_id<>member or proceed_amount<>p_amount)) then raise exception 'Request reference already used';end if;
 select id into conversion from public.proceed_wallet_conversions where idempotency_key=p_idempotency_key and member_id=member;
 if conversion is not null then return(select jsonb_build_object('conversion_id',c.id,'cash_amount',c.cash_amount,'fee_amount',c.fee_amount,'shopping_amount',c.shopping_amount,'promotion_amount',c.promotion_amount)from public.proceed_wallet_conversions c where c.id=conversion);end if;
 cfg:=private.current_proceed_wallet_config();cash_rate:=(cfg->>'cash_rate')::numeric;fee_rate:=(cfg->>'fee_rate')::numeric;shopping_rate:=(cfg->>'shopping_rate')::numeric;promotion_rate:=(cfg->>'promotion_rate')::numeric;minimum:=(cfg->>'minimum_mio')::numeric;
 if p_amount is null or p_amount<minimum then raise exception 'Minimum Proceed withdrawal is % MIO',minimum;end if;
 if abs(cash_rate+fee_rate+shopping_rate+promotion_rate-1)>.000001 then raise exception 'Proceed split configuration is invalid';end if;
 perform pg_advisory_xact_lock(hashtextextended('proceed:'||member::text,0));
 update public.member_income_wallets set proceed_mio=proceed_mio-p_amount,updated_at=now()where member_id=member and proceed_mio>=p_amount returning proceed_mio into remaining;
 if remaining is null then raise exception 'Insufficient Proceed Wallet balance';end if;
 cash_amount:=trunc(p_amount*cash_rate,4);fee_amount:=trunc(p_amount*fee_rate,4);shopping_amount:=trunc(p_amount*shopping_rate,4);promotion_amount:=p_amount-cash_amount-fee_amount-shopping_amount;
 insert into public.proceed_wallet_conversions(member_id,proceed_amount,cash_amount,fee_amount,shopping_amount,promotion_amount,config_snapshot,idempotency_key)
 values(member,p_amount,cash_amount,fee_amount,shopping_amount,promotion_amount,cfg,p_idempotency_key)returning id into conversion;
 update public.mio_wallet_accounts set balance=balance+cash_amount,updated_at=now()where member_id=member;
 update public.member_income_wallets set shopping_points=shopping_points+shopping_amount,promotion_points=promotion_points+promotion_amount,updated_at=now()where member_id=member;
 select company_id into company from private.network_foundation where singleton;
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,conversion_id,note,metadata,idempotency_key)
 select member,v.wallet_kind,v.amount,v.entry_kind,conversion,v.note,cfg,v.idempotency_key from(values
  ('proceed'::text,-p_amount,'proceed_withdrawal'::text,'Withdrawn from Proceed Wallet'::text,'convert:debit:'||conversion),
  ('cash',cash_amount,'proceed_withdrawal','75% moved to Cash Wallet','convert:cash:'||conversion),
  ('shopping',shopping_amount,'proceed_withdrawal','10% Shopping Points allocation (locked)','convert:shopping:'||conversion),
  ('promotion',promotion_amount,'proceed_withdrawal','10% Promotion Points allocation (locked)','convert:promotion:'||conversion),
  ('fee',-fee_amount,'withdrawal_fee','5% Proceed Wallet withdrawal fee','convert:fee:'||conversion)
 )as v(wallet_kind,amount,entry_kind,note,idempotency_key)where v.amount<>0;
 insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key)values(member,cash_amount,'proceed_conversion','Proceed Wallet to Cash Wallet','proceed-cash:'||conversion);
 perform private.sync_company_treasury();
 return jsonb_build_object('conversion_id',conversion,'proceed_debited',p_amount,'cash_amount',cash_amount,'fee_amount',fee_amount,'shopping_amount',shopping_amount,'promotion_amount',promotion_amount,'remaining_proceed',remaining);
end$function$
;

do $$ declare r record; adjustment uuid;begin
 for r in select l.id,l.member_id,l.amount,c.id conversion_id
  from public.mio_ledger l join public.proceed_wallet_conversions c on l.idempotency_key='proceed-fee:'||c.id
  where l.action='withdrawal_fee' and l.amount>0 and l.amount=c.fee_amount
   and not exists(select 1 from private.proceed_fee_reclassifications a where a.legacy_ledger_id=l.id)
  order by l.created_at,l.id
 loop
  update public.mio_wallet_accounts set balance=balance-r.amount,updated_at=now() where member_id=r.member_id and balance>=r.amount;
  if not found then raise exception 'Company fee reclassification requires sufficient cash balance';end if;
  insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key)
  values(r.member_id,-r.amount,'admin_burn','Company fee reclassified to separate company treasury','company-fee-reclass:'||r.id)
  returning id into adjustment;
  insert into private.proceed_fee_reclassifications values(r.id,adjustment,r.conversion_id,r.amount,now());
 end loop;
 perform private.sync_company_treasury();
end $$;
revoke all on function public.convert_proceed_wallet(numeric,text,text) from public,anon;
grant execute on function public.convert_proceed_wallet(numeric,text,text) to authenticated;
