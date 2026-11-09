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
