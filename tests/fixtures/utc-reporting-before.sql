CREATE OR REPLACE FUNCTION public.my_exchange_wallet(p_year integer DEFAULT NULL::integer, p_direction text DEFAULT 'all'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.admin_distribute_binary_pool(p_share_value numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  cutoff timestamptz := private.financial_reset_at();
  pend timestamptz := clock_timestamp();
  pstart timestamptz;
  cycle uuid := gen_random_uuid();
  code text;
  wallet numeric := 0;
  shares numeric := 0;
  pool numeric := 0;
  m record;
  gross numeric;
  pay numeric;
  txn uuid;
  k text;
begin
  if auth.uid() is null or not private.has_role('admin') then
    raise exception 'Admin access required';
  end if;
  if p_share_value is null or p_share_value <= 0 then
    raise exception 'Enter a share price greater than zero';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('mio-binary-settlement', 0));
  select coalesce(max(ends_at), cutoff) into pstart
  from public.binary_cycles
  where status in ('posted', 'unallocated') and created_at > cutoff;

  select greatest(
    0,
    coalesce((select sum(binary_reserve_mio) from public.package_activations
      where status = 'approved' and source <> 'SHOPPING_PPV'
        and coalesce(activated_at, requested_at) > cutoff), 0)
    + coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events
      where created_at > cutoff), 0)
    - coalesce((select sum(pool_amount) from public.binary_cycles
      where status in ('posted', 'unallocated') and created_at > cutoff), 0)
  ) into wallet;

  select coalesce(sum(completed_shares), 0) into shares
  from private.binary_live_shares(pend);

  if shares <= 0 then raise exception 'No payable binary shares are available'; end if;
  pool := trunc(p_share_value * shares, 4);
  if pool > wallet + .00000001 then
    raise exception 'Share price exceeds current binary pool wallet';
  end if;

  code := 'REALTIME-' || to_char(pend at time zone 'Asia/Karachi', 'YYYYMMDD-HH24MISS-MS');
  insert into public.binary_cycles(
    id, cycle_code, starts_at, ends_at, cycle_timezone, eligible_base,
    pool_rate, pool_amount, total_completed_shares, gross_share_value, status
  ) values (
    cycle, code, pstart, pend, 'Asia/Karachi', 0,
    0, pool, shares, p_share_value, 'frozen'
  );

  for m in
    select * from private.binary_live_shares(pend)
    where completed_shares > 0
    order by member_id
  loop
    gross := trunc(p_share_value * m.completed_shares, 4);
    pay := gross;

    insert into public.binary_member_results(
      cycle_id, member_id, package_code, package_version,
      left_available, right_available, completed_shares, entitlement,
      gross_amount, member_amount, company_retention,
      consumed_left, consumed_right, carry_left, carry_right,
      qualification_snapshot
    ) values (
      cycle, m.member_id, m.package_code, m.package_version,
      m.left_available, m.right_available, m.completed_shares, m.binary_entitlement,
      gross, pay, 0,
      m.consumed_each, m.consumed_each,
      m.left_available - m.consumed_each, m.right_available - m.consumed_each,
      jsonb_build_object(
        'qualification', 'realtime_package_weighted_share',
        'share_increment', .1,
        'share_price', p_share_value,
        'awarded_shares', m.completed_shares,
        'package_entitlement_snapshot', m.binary_entitlement,
        'consumed_each_side', m.consumed_each,
        'lifetime_bp_preserved', true
      )
    );

    if pay > 0 then
      k := 'binary:' || cycle::text || ':' || m.member_id::text;
      insert into public.bonus_transactions(
        beneficiary_id, method, cycle_id, qualifying_base, rate,
        gross_amount, payable_amount, currency, formula_version,
        calculation_trace, status, idempotency_key
      ) values (
        m.member_id, 'binary_pool_share', cycle, gross, m.binary_entitlement,
        gross, pay, 'MIO', 'realtime-binary-pool-v4',
        jsonb_build_object(
          'awarded_shares', m.completed_shares,
          'share_price', p_share_value,
          'package_entitlement_snapshot', m.binary_entitlement,
          'consumed_each_side', m.consumed_each,
          'pool_before', wallet,
          'pool_after', wallet - pool,
          'company_retention', 0
        ),
        'posted', k
      ) returning id into txn;

      update public.mio_wallet_accounts
      set balance = balance + pay, updated_at = now()
      where member_id = m.member_id;
      if not found then raise exception 'Member wallet missing'; end if;

      insert into public.mio_ledger(
        member_id, amount, action, bonus_transaction_id, cycle_id,
        reason, idempotency_key
      ) values (
        m.member_id, pay, 'bonus_credit', txn, cycle,
        'Real-time Binary Pool Share', 'binary-mio:' || txn::text
      );
    end if;
  end loop;

  update public.binary_cycles
  set status = 'posted', closed_at = clock_timestamp()
  where id = cycle;

  insert into public.audit_logs(actor_id, action, entity_type, entity_id, after_data)
  values (
    auth.uid(), 'BINARY_REALTIME_DISTRIBUTED', 'binary_cycle', cycle,
    jsonb_build_object(
      'pool_before', wallet,
      'distributed_pool', pool,
      'pool_after', wallet - pool,
      'awarded_shares', shares,
      'share_price', p_share_value
    )
  );

  return jsonb_build_object(
    'cycle_id', cycle,
    'cycle_code', code,
    'share_price', p_share_value,
    'distributed_shares', shares,
    'distributed_amount', pool,
    'remaining_pool', wallet - pool
  );
end
$function$;

CREATE OR REPLACE FUNCTION private.wallet_history_for_member(uid uuid, p_wallet text, p_filter text, p_from date, p_to date, p_page integer, p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb; current_balance numeric;
begin
 if uid is null then raise exception 'Sign in required';end if;
 if p_wallet is null or p_wallet not in('cash','proceed','shopping','promotion') then raise exception 'Invalid wallet';end if;
 if p_filter is null or p_filter not in('all','received','sent','package','other','proceeded') then raise exception 'Invalid activity filter';end if;
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
  select * from ledger where (p_filter='all' or (p_filter='proceeded' and p_wallet='proceed' and conversion_id is not null and amount<0) or activity_type=p_filter or(p_filter='other' and action not in('transfer_in','transfer_out','package_activation')))
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
end $function$;

CREATE OR REPLACE FUNCTION public.admin_proceed_fee_history(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_page integer DEFAULT 1, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare result jsonb;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_page is null or p_page<1 or p_page>100000 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Invalid page';end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Invalid date range';end if;
 with filtered as(select c.*,p.full_name,p.member_code from public.proceed_wallet_conversions c join public.member_profiles p on p.user_id=c.member_id where c.fee_amount>0
 and(p_from is null or c.created_at>=p_from::timestamp at time zone 'Asia/Karachi') and(p_to is null or c.created_at<(p_to+1)::timestamp at time zone 'Asia/Karachi')),
 selected as(select * from filtered order by created_at desc,id desc limit p_limit offset(p_page-1)*p_limit)
 select jsonb_build_object('balance',coalesce((select sum(fee_amount) from public.proceed_wallet_conversions),0)::text,'total',(select count(*) from filtered),'rows',coalesce((select jsonb_agg(jsonb_build_object('id',id,'created_at',created_at,'member_name',full_name,'member_code',member_code,'amount',fee_amount::text,'proceed_amount',proceed_amount::text,'fee_rate',config_snapshot->'fee_rate') order by created_at desc,id desc) from selected),'[]'::jsonb)) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_binary_pool_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  admin_id uuid := auth.uid();
  cutoff timestamptz := private.financial_reset_at();
  last_end timestamptz;
  period_start timestamptz;
  period_end timestamptz := clock_timestamp();
  total_generated numeric := 0;
  total_distributed numeric := 0;
  pool_wallet numeric := 0;
  current_cycle_balance numeric := 0;
  last_distributed numeric := 0;
  total_shares numeric := 0;
  package_json jsonb := '[]'::jsonb;
  detail_json jsonb := '[]'::jsonb;
  cfg jsonb;
  share_points numeric;
begin
  if admin_id is null or not private.has_role('admin') then
    raise exception 'Admin access required';
  end if;

  cfg := private.current_mlm_rules();
  share_points := coalesce((cfg->>'binary_share_points_each_side')::numeric, 50);
  if share_points <= 0 then share_points := 50; end if;

  select max(ends_at) into last_end
  from public.binary_cycles
  where status in ('posted', 'unallocated') and created_at > cutoff;
  period_start := coalesce(last_end, cutoff);

  select
    coalesce((select sum(binary_reserve_mio) from public.package_activations
      where status = 'approved' and source <> 'SHOPPING_PPV'
        and coalesce(activated_at, requested_at) > cutoff), 0)
    + coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events
      where created_at > cutoff), 0)
  into total_generated;

  select coalesce(sum(pool_amount), 0) into total_distributed
  from public.binary_cycles
  where status in ('posted', 'unallocated') and created_at > cutoff;
  pool_wallet := greatest(0, total_generated - total_distributed);

  select
    coalesce((select sum(binary_reserve_mio) from public.package_activations
      where status = 'approved' and source <> 'SHOPPING_PPV'
        and coalesce(activated_at, requested_at) > period_start), 0)
    + coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events
      where created_at > period_start), 0)
  into current_cycle_balance;

  select coalesce(sum(completed_shares), 0) into total_shares
  from private.binary_live_shares(period_end);

  select coalesce(jsonb_agg(jsonb_build_object(
    'package_code', package_code,
    'shares', shares
  ) order by package_code), '[]'::jsonb)
  into package_json
  from (
    select package_code, sum(completed_shares) shares
    from private.binary_live_shares(period_end)
    group by package_code
    having sum(completed_shares) > 0
  ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
    'member_id', s.member_id,
    'member_name', mp.full_name,
    'member_code', mp.member_code,
    'package_code', s.package_code,
    'left_bp', s.left_available,
    'right_bp', s.right_available,
    'raw_shares', trunc(least(s.left_available, s.right_available) / share_points, 1),
    'entitlement', s.binary_entitlement,
    'entitlement_percent', trunc(s.binary_entitlement * 100, 2),
    'final_shares', s.completed_shares,
    'consumed_each_side', s.consumed_each
  ) order by s.completed_shares desc, mp.member_code), '[]'::jsonb)
  into detail_json
  from private.binary_live_shares(period_end) s
  left join public.member_profiles mp on mp.user_id = s.member_id
  where s.completed_shares > 0;

  select coalesce(pool_amount, 0) into last_distributed
  from public.binary_cycles
  where status = 'posted' and created_at > cutoff
  order by ends_at desc
  limit 1;

  return jsonb_build_object(
    'total_pool_generated', total_generated,
    'total_distributed', total_distributed,
    'total_pool_wallet', pool_wallet,
    'current_cycle_balance', current_cycle_balance,
    'last_distributed', last_distributed,
    'total_shares', total_shares,
    'shares_by_package', package_json,
    'share_details', detail_json,
    'share_points_each_side', share_points,
    'period_start', period_start,
    'period_end', period_end,
    'can_distribute', total_shares > 0 and pool_wallet > 0,
    'default_share_value', 0,
    'next_cycle_code', 'ONDEMAND-' || to_char(period_end at time zone 'Asia/Karachi', 'YYYYMMDD-HH24MISS')
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.my_vendor_report(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_vendor uuid DEFAULT NULL::uuid, p_page integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid:=auth.uid(); result jsonb;
begin
 if u is null or not exists(select 1 from public.member_profiles where user_id=u and status not in('suspended','closed')) then raise exception 'Member access required';end if;
 if p_from>p_to then raise exception 'Start date must not follow end date';end if;
 if p_vendor is not null and not exists(select 1 from public.vendors where id=p_vendor and introduced_by=u) then raise exception 'Vendor access denied';end if;
 with stores as (select id,business_name,status,created_at from public.vendors where introduced_by=u and (p_vendor is null or id=p_vendor)),
 items as (select i.*,o.order_code,o.created_at order_date,o.status::text order_status,o.payment_status::text payment_status,
 (o.status::text='delivered' and o.payment_status::text='confirmed' and i.fulfillment_status not in('cancelled','refunded','returned')) successful
 from public.order_items i join stores v on v.id=i.vendor_id join public.orders o on o.id=i.order_id
 where (p_from is null or o.created_at>=p_from::timestamp at time zone 'Asia/Karachi') and (p_to is null or o.created_at<(p_to+1)::timestamp at time zone 'Asia/Karachi')),
 rewards as (select r.*,i.vendor_id from public.ecommerce_rewards r join items i on i.id=r.order_item_id where r.beneficiary_id=u and r.reward_kind='vendor_introducer'),
 vendor_rows as (select v.*,
 coalesce((select sum(line_total_pkr) from items where vendor_id=v.id and successful),0) sales,
 coalesce((select sum(quantity) from items where vendor_id=v.id and successful),0) units,
 (select count(distinct order_id) from items where vendor_id=v.id) orders,
 coalesce((select sum(amount) from rewards where vendor_id=v.id and status='posted'),0) credited,
 coalesce((select sum(amount) from rewards where vendor_id=v.id and status in('pending_delivery','held_activation')),0) pending from stores v),
 order_rows as (select order_id id,order_code,order_date created_at,order_status status,payment_status,sum(line_total_pkr) amount,
 jsonb_agg(jsonb_build_object('name',product_name_snapshot,'quantity',quantity,'amount',line_total_pkr,'status',fulfillment_status) order by id) items,
 coalesce((select sum(r.amount) from rewards r where r.order_id=i.order_id and r.status='posted'),0) credited,
 coalesce((select sum(r.amount) from rewards r where r.order_id=i.order_id and r.status in('pending_delivery','held_activation')),0) pending
 from items i group by order_id,order_code,order_date,order_status,payment_status)
 select jsonb_build_object('vendors',coalesce((select jsonb_agg(v order by business_name,id) from vendor_rows v),'[]'::jsonb),
 'summary',jsonb_build_object('vendors',(select count(*) from stores),'sales',coalesce((select sum(line_total_pkr) from items where successful),0),'units',coalesce((select sum(quantity) from items where successful),0),'orders',(select count(*) from order_rows),'credited',coalesce((select sum(amount) from rewards where status='posted'),0),'pending',coalesce((select sum(amount) from rewards where status in('pending_delivery','held_activation')),0),'cancelled',(select count(*) from order_rows where status in('cancelled','refunded','returned'))),
 'orders',coalesce((select jsonb_agg(x) from (select * from order_rows order by created_at desc,id limit 50 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*50)x),'[]'::jsonb)) into result;
 return result;
end $function$;
