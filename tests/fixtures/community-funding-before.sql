CREATE OR REPLACE FUNCTION public.company_master_dashboard_before_ecommerce()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;cutoff timestamptz:=private.financial_reset_at();
begin
 if not private.has_role('admin') then raise exception 'Master account access required';end if;
 perform private.sync_company_treasury();
 select jsonb_build_object(
 'company',(select m.full_name from private.network_foundation n join public.member_profiles m on m.user_id=n.company_id),
 'founder',(select m.full_name from private.network_foundation n join public.member_profiles m on m.user_id=n.founder_id),
 'sales_pkr',coalesce((select sum(subtotal_pkr) from public.orders where payment_status='confirmed' and created_at>cutoff),0),
 'shipping_pkr',coalesce((select sum(delivery_fee_pkr) from public.orders where payment_status='confirmed' and created_at>cutoff),0),
 'verified_package_receipts_pkr',coalesce((select sum(expected_pkr) from public.premium_purchase_requests where status='approved' and created_at>cutoff),0),
 'package_volume_mio',coalesce((select sum(payable_price) from public.package_activations where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0),
 'credited_network_mio',coalesce((select sum(payable_amount) from public.bonus_transactions where status='posted' and created_at>cutoff),0),
 'held_network_mio',coalesce((select sum(payable_amount) from public.bonus_transactions where status='pending' and created_at>cutoff),0),
 'member_commission_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where share_kind in('affiliate','sponsor','second_upline','introducer') and status in('earned','paid') and beneficiary_id is not null and created_at>cutoff),0),
 'paid_commission_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where share_kind in('affiliate','sponsor','second_upline','introducer') and status='paid' and created_at>cutoff),0),
 'held_commission_pkr',coalesce((select sum(amount_pkr) from public.commission_allocations where share_kind in('affiliate','sponsor','second_upline','introducer') and status='held' and created_at>cutoff),0),
 'external_vendor_proceeds_pkr',coalesce((select sum(l.net_pkr) from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id where not i.company_owned_snapshot and l.created_at>cutoff),0),
 'vendor_withdrawals_paid_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where status='paid' and created_at>cutoff),0),
 'vendor_withdrawals_reserved_pkr',coalesce((select sum(amount_pkr) from public.vendor_withdrawals where status in('pending','approved') and created_at>cutoff),0),
 'binary_reserved_mio',coalesce((select sum(binary_reserve_mio) from public.shopping_reward_events where created_at>cutoff),0)+coalesce((select sum(binary_reserve_mio) from public.package_activations where status='approved' and source<>'SHOPPING_PPV' and coalesce(activated_at,requested_at)>cutoff),0)-coalesce((select sum(pool_amount) from public.binary_cycles where status in('posted','unallocated') and created_at>cutoff),0),
 'company_network_mio',coalesce((select sum(b.payable_amount) from public.bonus_transactions b where b.status='posted' and b.created_at>cutoff and b.beneficiary_id=(select company_id from private.network_foundation where singleton)),0),
 'company_bonus_sources',coalesce((select jsonb_agg(r) from(select m.full_name,m.member_code,b.method,b.payable_amount amount from public.bonus_transactions b left join public.package_activations a on a.id=b.source_activation_id left join public.orders o on o.id=b.source_order_id join public.member_profiles m on m.user_id=coalesce(a.member_id,o.buyer_id) where b.status='posted' and b.created_at>cutoff and b.beneficiary_id=(select company_id from private.network_foundation where singleton) order by b.created_at desc limit 30)r),'[]'),
 'company_pkr',coalesce((select sum(amount) from public.company_treasury_positions where currency='PKR'),0),
 'company_mio',coalesce((select sum(amount) from public.company_treasury_positions where currency='MIO'),0),
 'company_sources',coalesce((select jsonb_agg(r) from(select category,currency,sum(amount) amount from public.company_treasury_positions where amount<>0 group by 1,2 order by 1,2)r),'[]'),
 'distributed_sources',coalesce((select jsonb_agg(r) from(select method,sum(payable_amount) amount from public.bonus_transactions where status='posted' and created_at>cutoff group by method order by method)r),'[]'),
 'top_network',coalesce((select jsonb_agg(r) from(select m.member_code,m.full_name,sum(b.payable_amount) income from public.bonus_transactions b join public.member_profiles m on m.user_id=b.beneficiary_id where b.status='posted' and b.created_at>cutoff and m.user_id<>(select company_id from private.network_foundation where singleton) group by m.user_id order by sum(b.payable_amount) desc,m.member_code limit 10)r),'[]'),
 'top_ecommerce',coalesce((select jsonb_agg(r) from(select m.member_code,m.full_name,sum(a.amount_pkr) income from public.commission_allocations a join public.member_profiles m on m.user_id=a.beneficiary_id where a.share_kind in('affiliate','sponsor','second_upline','introducer') and a.status in('earned','paid') and a.created_at>cutoff group by m.user_id order by sum(a.amount_pkr) desc,m.member_code limit 10)r),'[]')
 ) into result;
 return result;
end
$function$;
CREATE OR REPLACE FUNCTION public.admin_distribute_community_share(p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 next_cycle integer;pool numeric;actual_total integer;gift_total integer;shares_total integer;per_share numeric;cycle_id uuid;
 r record;amount numeric;paid numeric:=0;idx integer:=0;members integer:=0;dist_id uuid;tx_id uuid;existing uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if nullif(trim(p_idempotency_key),'') is null then raise exception 'Distribution key required';end if;
 perform pg_advisory_xact_lock(hashtextextended('global-community-share-distribution',0));
 select id into existing from public.community_share_cycles where idempotency_key=trim(p_idempotency_key);if existing is not null then return jsonb_build_object('cycle_id',existing,'duplicate',true);end if;
 for r in select user_id from public.member_profiles where status='active' loop perform private.refresh_community_share_grants(r.user_id);end loop;
 next_cycle:=private.current_community_cycle()+1;
 select coalesce(sum(installment_mio+case when end_cycle=next_cycle then final_remainder_mio else 0 end),0) into pool from public.community_fund_contributions where start_cycle<=next_cycle and end_cycle>=next_cycle;
 select coalesce(sum(quantity) filter(where share_kind='actual'),0),coalesce(sum(quantity) filter(where share_kind='gift'),0) into actual_total,gift_total from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle and private.maintenance_active(member_id);
 shares_total:=actual_total+gift_total;if pool<=0 then raise exception 'No Community Share installment is due for cycle %',next_cycle;end if;if shares_total<=0 then raise exception 'No active Community Shares for cycle %',next_cycle;end if;
 per_share:=pool/shares_total;
 select count(*) into members from (select member_id from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle and private.maintenance_active(member_id) group by member_id) x;
 insert into public.community_share_cycles(cycle_number,idempotency_key,fund_pool_mio,active_actual_shares,active_gift_shares,total_active_shares,per_share_mio,distributed_mio,member_count,distributed_by)
 values(next_cycle,trim(p_idempotency_key),pool,actual_total,gift_total,shares_total,per_share,0,members,auth.uid()) returning id into cycle_id;
 for r in
  select member_id,coalesce(sum(quantity) filter(where share_kind='actual'),0)::integer actual_shares,coalesce(sum(quantity) filter(where share_kind='gift'),0)::integer gift_shares
  from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle and private.maintenance_active(member_id) group by member_id order by member_id
 loop
  idx:=idx+1;amount:=case when idx=members then round(pool-paid,8) else round(per_share*(r.actual_shares+r.gift_shares),8) end;
  insert into public.community_share_distributions(cycle_id,member_id,actual_shares,gift_shares,amount_mio) values(cycle_id,r.member_id,r.actual_shares,r.gift_shares,amount) returning id into dist_id;
  insert into public.mio_wallet_accounts(member_id,balance) values(r.member_id,amount) on conflict(member_id) do update set balance=public.mio_wallet_accounts.balance+excluded.balance,updated_at=now();
  insert into public.bonus_transactions(beneficiary_id,method,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key)
  values(r.member_id,'community_share',r.actual_shares+r.gift_shares,per_share,amount,amount,'MIO','community-share-v1',jsonb_build_object('bonus_component','global_community_share','cycle_id',cycle_id,'cycle_number',next_cycle,'actual_shares',r.actual_shares,'gift_shares',r.gift_shares,'per_share_mio',per_share),'posted','community-share:'||cycle_id||':'||r.member_id) returning id into tx_id;
  update public.community_share_distributions set bonus_transaction_id=tx_id where id=dist_id;
  insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,community_distribution_id,reason,idempotency_key) values(r.member_id,amount,'bonus_credit',tx_id,dist_id,'Global Community Share · cycle '||next_cycle,'community-mio:'||dist_id);
  paid:=paid+amount;
 end loop;
 update public.community_share_cycles set distributed_mio=paid where id=cycle_id;
 return jsonb_build_object('cycle_id',cycle_id,'cycle_number',next_cycle,'duplicate',false,'fund_pool_mio',pool,'actual_shares',actual_total,'gift_shares',gift_total,'total_shares',shares_total,'per_share_mio',per_share,'distributed_mio',paid,'member_count',members);
end$function$;
CREATE OR REPLACE FUNCTION public.admin_community_share_program()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;rules jsonb;cycle_no integer;next_cycle integer;due_pool numeric;actual_count integer;gift_count integer;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 for r in select user_id from public.member_profiles where status='active' loop perform private.refresh_community_share_grants(r.user_id);end loop;
 rules:=private.current_community_share_rules();cycle_no:=private.current_community_cycle();next_cycle:=cycle_no+1;
 select coalesce(sum(installment_mio+case when end_cycle=next_cycle then final_remainder_mio else 0 end),0) into due_pool from public.community_fund_contributions where start_cycle<=next_cycle and end_cycle>=next_cycle;
 select coalesce(sum(quantity) filter(where share_kind='actual'),0),coalesce(sum(quantity) filter(where share_kind='gift'),0) into actual_count,gift_count from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle;
 return jsonb_build_object(
  'rules',rules,'current_cycle',cycle_no,'next_cycle',next_cycle,'due_pool_mio',due_pool,'active_actual_shares',actual_count,'active_gift_shares',gift_count,'active_total_shares',actual_count+gift_count,
  'total_fund_mio',coalesce((select sum(amount_mio) from public.community_fund_contributions),0),
  'released_mio',coalesce((select sum(fund_pool_mio) from public.community_share_cycles),0),
  'reserved_mio',coalesce((select sum(amount_mio) from public.community_fund_contributions),0)-coalesce((select sum(fund_pool_mio) from public.community_share_cycles),0),
  'members',coalesce((select jsonb_agg(jsonb_build_object('member_id',g.member_id,'member_code',m.member_code,'full_name',m.full_name,'actual_shares',g.actual_shares,'gift_shares',g.gift_shares,'total_shares',g.actual_shares+g.gift_shares) order by m.member_code) from (select member_id,coalesce(sum(quantity) filter(where share_kind='actual'),0)::integer actual_shares,coalesce(sum(quantity) filter(where share_kind='gift'),0)::integer gift_shares from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle group by member_id) g join public.member_profiles m on m.user_id=g.member_id),'[]'::jsonb),
  'contributions',coalesce((select jsonb_agg(to_jsonb(f) order by created_at desc) from public.community_fund_contributions f),'[]'::jsonb),
  'cycles',coalesce((select jsonb_agg(to_jsonb(c) order by cycle_number desc) from public.community_share_cycles c),'[]'::jsonb)
 );
end$function$;
CREATE OR REPLACE FUNCTION public.admin_add_community_fund(p_amount_mio numeric, p_note text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare rules jsonb:=private.current_community_share_rules();cycles integer;current_cycle integer;installment numeric;remainder numeric;row_id uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if p_amount_mio is null or p_amount_mio<=0 or p_amount_mio>1000000000 then raise exception 'Enter a valid Community Share fund amount';end if;
 if length(trim(coalesce(p_note,''))) not between 3 and 500 then raise exception 'Fund note must be 3 to 500 characters';end if;
 if nullif(trim(p_idempotency_key),'') is null then raise exception 'Fund key required';end if;
 select id into row_id from public.community_fund_contributions where idempotency_key=trim(p_idempotency_key);if row_id is not null then return jsonb_build_object('contribution_id',row_id,'duplicate',true);end if;
 cycles:=(rules->>'fund_installments')::integer;current_cycle:=private.current_community_cycle();installment:=trunc(p_amount_mio/cycles,8);remainder:=round(p_amount_mio-installment*cycles,8);
 insert into public.community_fund_contributions(amount_mio,installment_count,installment_mio,final_remainder_mio,start_cycle,end_cycle,note,idempotency_key,created_by)
 values(round(p_amount_mio,8),cycles,installment,remainder,current_cycle+1,current_cycle+cycles,trim(p_note),trim(p_idempotency_key),auth.uid()) returning id into row_id;
 return jsonb_build_object('contribution_id',row_id,'duplicate',false,'amount_mio',round(p_amount_mio,8),'installment_mio',installment,'start_cycle',current_cycle+1,'end_cycle',current_cycle+cycles);
end$function$;
CREATE OR REPLACE FUNCTION private.company_treasury_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$begin perform private.sync_company_treasury();return null;end $function$;
CREATE OR REPLACE FUNCTION private.sync_company_treasury()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare company uuid;r record;delta numeric;target numeric;
begin
 select company_id into company from private.network_foundation where singleton;
 if company is null then return;end if;
 perform pg_advisory_xact_lock(hashtextextended('company-treasury-sync',0));
 for r in
  with expected as(select source_type,source_id,category,currency,sum(amount) amount from private.company_treasury_sources() group by 1,2,3,4)
  select coalesce(e.source_type,p.source_type) typ,coalesce(e.source_id,p.source_id) sid,
   coalesce(e.category,p.category) cat,coalesce(e.currency,p.currency) cur,
   coalesce(e.amount,0) target,coalesce(p.amount,0) previous
  from expected e full join public.company_treasury_positions p using(source_type,source_id,category,currency)
 loop
  target:=round(r.target,4);delta:=round(target-r.previous,4);
  if delta is null or abs(delta)<.0001 then continue;end if;
  insert into public.company_treasury_positions(source_type,source_id,category,currency,amount)
  values(r.typ,r.sid,r.cat,r.cur,target)
  on conflict(source_type,source_id,category,currency) do update set amount=excluded.amount,updated_at=now();
  insert into public.company_treasury_ledger(company_id,source_type,source_id,category,currency,amount)
  values(company,r.typ,r.sid,r.cat,r.cur,delta);
 end loop;
end
$function$;
CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_award()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select * from private.company_treasury_sources_before_ecommerce()
 union all select 'ecommerce',id,'ecommerce_missing_recipient','MIO',amount from public.ecommerce_rewards where status='company_leftover'
 union all select 'order',o.id,'ecommerce_conversion_leftover','PKR',greatest(0,(select coalesce(sum(a.amount_pkr),0) from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards')-o.reward_ppv_total*coalesce(nullif(o.usd_to_pkr_rate,0),300)) from public.orders o where o.reward_version=2 and o.reward_mode='MIO' and o.rewards_credited_at is not null;
$function$;
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
CREATE OR REPLACE FUNCTION private.financial_reset_at()
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(
    (select (config_value->>'reset_at')::timestamptz
       from public.system_config
      where config_key='FINANCIAL_RESET' and effective_to is null
      order by version desc limit 1),
    '-infinity'::timestamptz
  );
$function$;
CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_activation_offer()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with funding as(
  select 'order'::text typ,s.order_id id,s.bv base,s.dp,s.gp,s.bp,s.binary_reserve_mio reserve,o.rules_snapshot cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all select 'package',a.id,least(a.bv,a.base_value,a.payable_price-a.company_fee),a.dp,a.gp,a.bp,a.binary_reserve_mio,a.rules_snapshot from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV'
 ),spend as(
  select f.*,coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='direct'),0) direct_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='generation'),0) gen_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='single_line'),0) placement_paid from funding f
 )
 select typ,id,'generation_levels_pending','MIO',greatest(0,trunc(gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4)-gen_paid) from spend
 union all select typ,id,'generation_manager_pending','MIO',trunc(gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'generation_global_pending','MIO',trunc(gp*coalesce((cfg->>'generation_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'binary_placement_pending','MIO',greatest(0,trunc(bp*coalesce((cfg->>'single_line_cap')::numeric,.10),4)-placement_paid) from spend
 union all select typ,id,'binary_pool_pending','MIO',reserve from spend
 union all select typ,id,'binary_manager_pending','MIO',trunc(bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'binary_global_pending','MIO',trunc(bp*coalesce((cfg->>'binary_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'network_formula_leftover','MIO',greatest(0,dp-gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45)-gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05)-gp*coalesce((cfg->>'generation_global_rate')::numeric,.20)-bp*coalesce((cfg->>'binary_pool_rate')::numeric,.35)-bp*coalesce((cfg->>'single_line_cap')::numeric,.10)-bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05)-bp*coalesce((cfg->>'binary_global_rate')::numeric,.20)-direct_paid) from spend
 union all select 'order',s.order_id,'shopping_conversion_leftover','PKR',greatest(0,s.funded_pkr-s.bv*coalesce(nullif(o.usd_to_pkr_rate,0),300)) from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',id,'package_company_fee','MIO',company_fee from public.package_activations where status='approved' and source<>'SHOPPING_PPV'
 union all select 'cycle',c.id,'binary_retention','MIO',coalesce((select sum(company_retention) from public.binary_member_results where cycle_id=c.id),0) from public.binary_cycles c where c.status='posted'
 union all select 'cycle',c.id,'binary_pool_leftover','MIO',greatest(0,c.pool_amount-coalesce((select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=c.id),0)) from public.binary_cycles c where c.status in('posted','unallocated')
 union all select 'commission',a.id,'vendor_company_share','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='company' and o.payment_status='confirmed'
 union all select 'commission',a.id,'ecommerce_leftover','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='unallocated' and o.payment_status='confirmed'
 union all select 'vendor_sale',l.id,'company_brand_proceeds','PKR',l.net_pkr from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id join public.orders o on o.id=i.order_id where i.company_owned_snapshot and o.payment_status='confirmed'
 union all select 'order',id,'shipping_receipts','PKR',delivery_fee_pkr from public.orders where payment_status='confirmed';
$function$;
CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_ecommerce()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with package_spend as (
  select a.id,a.company_fee,a.dp,a.gp,a.bp,a.rules_snapshot cfg,
   coalesce(sum(b.payable_amount) filter(where b.method='direct' and b.status in('posted','pending')),0) direct_paid,
   least(a.company_fee,coalesce(sum(b.payable_amount) filter(where b.method='direct' and b.status in('posted','pending')
    and (b.formula_version='activation-welcome-v1' or b.calculation_trace->>'bonus_component'='welcome_bonus')),0)) welcome_fee
  from public.package_activations a left join public.bonus_transactions b on b.source_activation_id=a.id
  where a.status='approved' and a.source<>'SHOPPING_PPV'
  group by a.id
 ), package_balances as (
  select p.id,greatest(0,p.company_fee-p.welcome_fee) net_fee,
   greatest(0,p.dp
    -p.gp*(coalesce((p.cfg->>'generation_bonus_rate')::numeric,.45)+coalesce((p.cfg->>'generation_manager_rate')::numeric,.05)+coalesce((p.cfg->>'generation_global_rate')::numeric,.20))
    -p.bp*(coalesce((p.cfg->>'binary_pool_rate')::numeric,.35)+coalesce((p.cfg->>'single_line_cap')::numeric,.10)+coalesce((p.cfg->>'binary_manager_rate')::numeric,.05)+coalesce((p.cfg->>'binary_global_rate')::numeric,.20))
    -p.direct_paid+p.welcome_fee) network_leftover
  from package_spend p
 )
 select s.source_type,s.source_id,s.category,s.currency,
  case when s.source_type='package' and s.currency='MIO' and p.id is not null then
   case s.category when 'package_company_fee' then p.net_fee
    when 'network_formula_leftover' then p.network_leftover else s.amount end
  else s.amount end
 from private.company_treasury_sources_before_activation_offer() s
 left join package_balances p on p.id=s.source_id and s.source_type='package';
$function$;
CREATE OR REPLACE FUNCTION private.company_treasury_sources()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select * from private.company_treasury_sources_before_proceed()
 union all select 'proceed_conversion',c.id,'proceed_processing_fee','MIO',c.fee_amount
 from public.proceed_wallet_conversions c where c.fee_amount>0;
$function$;
CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_maintenance()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select s.source_type,s.source_id,s.category,s.currency,s.amount
  from private.company_treasury_sources_before_award() s
  where private.financial_source_after_reset(s.source_type,s.source_id)
  union all
  select 'order_item',i.id,
         case when i.award_scope_snapshot='product' then 'product_award_leftover' else 'vendor_award_leftover' end,
         'PKR',i.award_policy_leftover_pkr
  from public.order_items i
  join public.orders o on o.id=i.order_id
  where o.rewards_credited_at is not null
    and o.payment_status='confirmed'
    and i.awarded_rate_snapshot is not null
    and private.financial_source_after_reset('order_item',i.id);
$function$;
