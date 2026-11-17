CREATE OR REPLACE FUNCTION private.guard_bonus_funding()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare spent numeric;ceiling numeric;cfg jsonb;trace_cfg jsonb;dp_base numeric;gp_base numeric;bp_base numeric;
begin
 if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;
 if new.payable_amount<0 then raise exception 'Negative bonus is invalid';end if;
 if new.method='community_share' then
  select fund_pool_mio into ceiling from public.community_share_cycles
   where id=(new.calculation_trace->>'cycle_id')::uuid for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions
   where method='community_share' and calculation_trace->>'cycle_id'=new.calculation_trace->>'cycle_id'
    and status in('posted','pending');
 elsif new.method='binary_pool_share' then
  select pool_amount into ceiling from public.binary_cycles where id=new.cycle_id for update;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions where cycle_id=new.cycle_id and status in('posted','pending');
 else
  if new.source_order_id is not null then
   select s.dp,s.gp,s.bp,o.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where s.order_id=new.source_order_id for update of s;
  else
   select a.dp,a.gp,a.bp,a.rules_snapshot into dp_base,gp_base,bp_base,cfg from public.package_activations a where a.id=new.source_activation_id and a.status='approved' and a.source<>'SHOPPING_PPV' for update;
  end if;
  trace_cfg:=coalesce(new.calculation_trace->'plan_rules','{}'::jsonb);
  if new.method='direct' then
   ceiling:=trunc(dp_base*coalesce((trace_cfg->>'activation_offer_rate')::numeric,new.rate),4);
  elsif new.method='generation' then ceiling:=trunc(gp_base*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4);
  else ceiling:=trunc(bp_base*coalesce((cfg->>'single_line_cap')::numeric,.10),4);end if;
  select coalesce(sum(payable_amount),0) into spent from public.bonus_transactions
   where status in('posted','pending')
    and ((new.source_order_id is not null and source_order_id=new.source_order_id) or (new.source_activation_id is not null and source_activation_id=new.source_activation_id))
    and method=new.method;
 end if;
 if ceiling is null or spent+new.payable_amount>ceiling+.0001 then raise exception 'Bonus would exceed its funded source budget';end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.company_treasury_sources()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with original as (select * from private.company_treasury_sources_before_proceed()
 union all select 'proceed_conversion',c.id,'proceed_processing_fee','MIO',c.fee_amount
 from public.proceed_wallet_conversions c where c.fee_amount>0)
select source_type,source_id,category,currency,amount from original where category not in('generation_global_pending','binary_global_pending')
 union all select 'community_hold',company_id,'global_community_hold','MIO',
 coalesce((select sum(amount) from original where category in('generation_global_pending','binary_global_pending') and currency='MIO'),0)
 -coalesce((select sum(amount_mio) from public.community_fund_contributions),0)
 from private.network_foundation where singleton
 union all select 'community_fund',f.id,'community_cycle_reserved','MIO',
 greatest(0,f.amount_mio-coalesce((select sum(f.installment_mio+case when c.cycle_number=f.end_cycle then f.final_remainder_mio else 0 end)
 from public.community_share_cycles c where c.cycle_number between f.start_cycle and f.end_cycle),0))
 from public.community_fund_contributions f;
$function$;

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
 perform pg_advisory_xact_lock(hashtextextended('global-community-share-distribution',0));
 perform pg_advisory_xact_lock(hashtextextended('company-treasury-sync',0));
 select id into row_id from public.community_fund_contributions where idempotency_key=trim(p_idempotency_key);if row_id is not null then return jsonb_build_object('contribution_id',row_id,'duplicate',true);end if;
 if round(p_amount_mio,8)<=0 or round(p_amount_mio,8)>coalesce((select sum(amount) from private.company_treasury_sources() where category='global_community_hold' and currency='MIO'),0) then raise exception 'Insufficient Global Community Share Hold balance';end if;
 cycles:=(rules->>'fund_installments')::integer;current_cycle:=private.current_community_cycle();installment:=trunc(p_amount_mio/cycles,8);remainder:=round(p_amount_mio-installment*cycles,8);
 insert into public.community_fund_contributions(amount_mio,installment_count,installment_mio,final_remainder_mio,start_cycle,end_cycle,note,idempotency_key,created_by)
 values(round(p_amount_mio,8),cycles,installment,remainder,current_cycle+1,current_cycle+cycles,trim(p_note),trim(p_idempotency_key),auth.uid()) returning id into row_id;
 perform private.sync_company_treasury();
 return jsonb_build_object('contribution_id',row_id,'duplicate',false,'amount_mio',round(p_amount_mio,8),'installment_mio',installment,'start_cycle',current_cycle+1,'end_cycle',current_cycle+cycles);
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
  'hold_balance_mio',coalesce((select sum(amount) from private.company_treasury_sources() where category='global_community_hold' and currency='MIO'),0),
  'rules',rules,'current_cycle',cycle_no,'next_cycle',next_cycle,'due_pool_mio',due_pool,'active_actual_shares',actual_count,'active_gift_shares',gift_count,'active_total_shares',actual_count+gift_count,
  'total_fund_mio',coalesce((select sum(amount_mio) from public.community_fund_contributions),0),
  'released_mio',coalesce((select sum(fund_pool_mio) from public.community_share_cycles),0),
  'reserved_mio',coalesce((select sum(amount_mio) from public.community_fund_contributions),0)-coalesce((select sum(fund_pool_mio) from public.community_share_cycles),0),
  'members',coalesce((select jsonb_agg(jsonb_build_object('member_id',g.member_id,'member_code',m.member_code,'full_name',m.full_name,'actual_shares',g.actual_shares,'gift_shares',g.gift_shares,'total_shares',g.actual_shares+g.gift_shares) order by m.member_code) from (select member_id,coalesce(sum(quantity) filter(where share_kind='actual'),0)::integer actual_shares,coalesce(sum(quantity) filter(where share_kind='gift'),0)::integer gift_shares from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle group by member_id) g join public.member_profiles m on m.user_id=g.member_id),'[]'::jsonb),
  'contributions',coalesce((select jsonb_agg(to_jsonb(f) order by created_at desc) from public.community_fund_contributions f),'[]'::jsonb),
  'cycles',coalesce((select jsonb_agg(to_jsonb(c) order by cycle_number desc) from public.community_share_cycles c),'[]'::jsonb)
 );
end$function$;
select private.sync_company_treasury();
notify pgrst,'reload schema';
