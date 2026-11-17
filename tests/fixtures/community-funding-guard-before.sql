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
 if new.method='binary_pool_share' then
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
