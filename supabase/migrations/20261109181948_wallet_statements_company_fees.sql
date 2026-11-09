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

-- One read model per wallet. Historical routing snapshots, never current settings,
-- decide whether an earning belongs in the Cash statement.
create or replace function private.wallet_history_for_member(uid uuid,p_wallet text,p_filter text,p_from date,p_to date,p_page integer,p_limit integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; current_balance numeric;
begin
 if uid is null then raise exception 'Sign in required';end if;
 if p_wallet is null or p_wallet not in('cash','proceed','shopping','promotion') then raise exception 'Invalid wallet';end if;
 if p_filter is null or p_filter not in('all','received','sent','package','other') then raise exception 'Invalid activity filter';end if;
 if p_page is null or p_page<1 or p_page>100000 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Invalid page';end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'From date must not follow To date';end if;
 if p_wallet='cash' then select balance into current_balance from public.mio_wallet_accounts where member_id=uid;
 else select case p_wallet when 'proceed' then proceed_mio when 'shopping' then shopping_points else promotion_points end into current_balance from public.member_income_wallets where member_id=uid;end if;
 current_balance:=coalesce(current_balance,0);
 with movements as (
  select l.id,l.created_at,l.amount,l.action,l.reason,l.transfer_id,l.activation_id,l.counterparty_id,
   route.metadata,case when l.action='proceed_conversion' then c.id end conversion_id,
   case when l.action='package_activation' then 'package' when l.amount>0 then 'received' else 'sent' end activity_type
  from public.mio_ledger l
  left join lateral(select i.metadata,i.wallet_kind from public.income_wallet_ledger i
   where i.member_id=l.member_id and i.entry_kind in('network_earning','ecommerce_earning') and
   ((l.bonus_transaction_id is not null and i.source_bonus_id=l.bonus_transaction_id)
    or (i.source_reward_id is not null and l.idempotency_key='ecommerce:'||i.source_reward_id))
   order by i.created_at,i.id limit 1) route on true
  left join public.proceed_wallet_conversions c on c.member_id=uid and l.idempotency_key='proceed-cash:'||c.id
  where p_wallet='cash' and l.member_id=uid
   and coalesce(route.wallet_kind,'cash')='cash'
   and not exists(select 1 from private.proceed_fee_reclassifications a where a.legacy_ledger_id=l.id or a.adjustment_ledger_id=l.id)
  union all
  select i.id,i.created_at,i.amount,i.entry_kind,i.note,null::uuid,null::uuid,null::uuid,i.metadata,i.conversion_id,
   case when i.amount>0 then 'received' else 'sent' end
  from public.income_wallet_ledger i where p_wallet<>'cash' and i.member_id=uid and i.wallet_kind=p_wallet
 ), ledger as (
  select l.*,current_balance-coalesce(sum(l.amount) over(order by l.created_at desc,l.id desc rows between unbounded preceding and 1 preceding),0) balance_after
  from movements l
 ), filtered as (
  select * from ledger where (p_filter='all' or activity_type=p_filter or(p_filter='other' and action not in('transfer_in','transfer_out','package_activation')))
   and(p_from is null or created_at>=p_from::timestamp at time zone 'Asia/Karachi')
   and(p_to is null or created_at<(p_to+1)::timestamp at time zone 'Asia/Karachi')
 ), totals as(select count(*) total,coalesce(sum(amount)filter(where amount>0),0) credited,coalesce(-sum(amount)filter(where amount<0),0) debited from filtered),
 selected as(select * from filtered order by created_at desc,id desc limit p_limit offset(p_page-1)*p_limit),
 details as(
  select l.id,l.created_at,l.amount::text,l.action,l.activity_type,l.reason,l.transfer_id,l.activation_id,l.conversion_id,l.metadata,
   l.balance_after::text,(l.balance_after-l.amount)::text balance_before,
   own.full_name member_name,own.member_code,coalesce(cp.full_name,peer.full_name) counterparty_name,coalesce(cp.member_code,peer.member_code) counterparty_code,
   a.package_code,v.display_name package_name,prev.package_code previous_package_code,pv.display_name previous_package_name,
   case when l.amount<0 then own.full_name else coalesce(cp.full_name,peer.full_name) end sender_name,
   case when l.amount<0 then own.member_code else coalesce(cp.member_code,peer.member_code) end sender_code,
   case when l.amount>0 then own.full_name else coalesce(cp.full_name,peer.full_name) end receiver_name,
   case when l.amount>0 then own.member_code else coalesce(cp.member_code,peer.member_code) end receiver_code,
   case when l.conversion_id is not null then 'proceed' else coalesce(t.source_wallet,p_wallet) end source_wallet,
   coalesce(t.destination_wallet,p_wallet) destination_wallet,'Completed'::text status,
   case when c.id is not null then jsonb_build_object('proceed',c.proceed_amount::text,'cash',c.cash_amount::text,'shopping',c.shopping_amount::text,'promotion',c.promotion_amount::text,'fee',c.fee_amount::text) end split
  from selected l join public.member_profiles own on own.user_id=uid
  left join public.member_profiles cp on cp.user_id=l.counterparty_id
  left join private.exchange_transfers t on t.id=l.transfer_id and uid in(t.actor_id,t.recipient_id)
  left join public.member_profiles peer on peer.user_id=case when t.actor_id=uid then t.recipient_id else t.actor_id end
  left join public.proceed_wallet_conversions c on c.id=l.conversion_id and c.member_id=uid
  left join public.package_activations a on a.id=l.activation_id and a.member_id=uid
  left join public.package_versions v on v.package_code=a.package_code and v.version=a.package_version
  left join lateral(select pa.package_code,pa.package_version from public.package_activations pa where pa.member_id=uid and pa.status='approved' and(pa.activated_at,pa.id)<(a.activated_at,a.id) order by pa.activated_at desc,pa.id desc limit 1) prev on true
  left join public.package_versions pv on pv.package_code=prev.package_code and pv.version=prev.package_version
 ) select jsonb_build_object('wallet',p_wallet,'balance',current_balance::text,'total',totals.total,'page',p_page,'limit',p_limit,'credited',totals.credited::text,'debited',totals.debited::text,'rows',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at desc,d.id desc) from details d),'[]'::jsonb)) into result from totals;
 return result;
end $$;
revoke all on function private.wallet_history_for_member(uuid,text,text,date,date,integer,integer) from public,anon,authenticated;

create or replace function public.my_wallet_history(p_wallet text default 'cash',p_filter text default 'all',p_from date default null,p_to date default null,p_page integer default 1,p_limit integer default 20)
returns jsonb language sql stable security definer set search_path='' as $$
 select private.wallet_history_for_member(auth.uid(),p_wallet,p_filter,p_from,p_to,p_page,p_limit);
$$;
revoke all on function public.my_wallet_history(text,text,date,date,integer,integer) from public,anon;
grant execute on function public.my_wallet_history(text,text,date,date,integer,integer) to authenticated;

create or replace function public.my_cash_wallet_history(p_filter text default 'all',p_page integer default 1,p_limit integer default 20)
returns jsonb language sql stable security definer set search_path='' as $$
 select private.wallet_history_for_member(auth.uid(),'cash',p_filter,null,null,p_page,p_limit);
$$;
revoke all on function public.my_cash_wallet_history(text,integer,integer) from public,anon;
grant execute on function public.my_cash_wallet_history(text,integer,integer) to authenticated;

create or replace function public.admin_member_wallet_history(p_member_id uuid,p_wallet text default 'cash',p_filter text default 'all',p_from date default null,p_to date default null,p_page integer default 1,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return private.wallet_history_for_member(p_member_id,p_wallet,p_filter,p_from,p_to,p_page,p_limit);
end $$;
revoke all on function public.admin_member_wallet_history(uuid,text,text,date,date,integer,integer) from public,anon;
grant execute on function public.admin_member_wallet_history(uuid,text,text,date,date,integer,integer) to authenticated;

create or replace function public.admin_proceed_fee_history(p_from date default null,p_to date default null,p_page integer default 1,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path='' as $$declare result jsonb;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_page is null or p_page<1 or p_page>100000 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Invalid page';end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Invalid date range';end if;
 with filtered as(select c.*,p.full_name,p.member_code from public.proceed_wallet_conversions c join public.member_profiles p on p.user_id=c.member_id where c.fee_amount>0
 and(p_from is null or c.created_at>=p_from::timestamp at time zone 'Asia/Karachi') and(p_to is null or c.created_at<(p_to+1)::timestamp at time zone 'Asia/Karachi')),
 selected as(select * from filtered order by created_at desc,id desc limit p_limit offset(p_page-1)*p_limit)
 select jsonb_build_object('balance',coalesce((select sum(fee_amount) from public.proceed_wallet_conversions),0)::text,'total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(jsonb_build_object('id',id,'created_at',created_at,'member_name',full_name,'member_code',member_code,'amount',fee_amount::text,'proceed_amount',proceed_amount::text,'fee_rate',config_snapshot->'fee_rate') order by created_at desc,id desc) from selected),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function public.admin_proceed_fee_history(date,date,integer,integer) from public,anon;
grant execute on function public.admin_proceed_fee_history(date,date,integer,integer) to authenticated;
