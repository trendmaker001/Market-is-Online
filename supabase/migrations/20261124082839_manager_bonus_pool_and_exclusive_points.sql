-- Manager reserves fund only explicit administrator distributions.
create table private.manager_bonus_pool_allocations(
 cycle_id uuid not null references public.manager_bonus_cycles(id),
 source_type text not null,source_id uuid not null,
 category text not null check(category in ('generation_manager_pending','binary_manager_pending')),
 amount numeric(20,4) not null check(amount>0),created_at timestamptz not null default now(),
 primary key(cycle_id,source_type,source_id,category));
alter table private.manager_bonus_pool_allocations enable row level security;
revoke all on private.manager_bonus_pool_allocations from public,anon,authenticated;
create index manager_pool_source_idx on private.manager_bonus_pool_allocations(source_type,source_id,category);

alter function private.company_treasury_sources() rename to company_treasury_sources_before_manager_pool;
create function private.company_treasury_sources()
returns table(source_type text,source_id uuid,category text,currency text,amount numeric)
language sql stable security definer set search_path='' as $$
 select s.source_type,s.source_id,s.category,s.currency,
 s.amount-case when s.currency='MIO' and s.category in('generation_manager_pending','binary_manager_pending')
 then coalesce((select sum(a.amount) from private.manager_bonus_pool_allocations a
 where a.source_type=s.source_type and a.source_id=s.source_id and a.category=s.category),0) else 0 end
 from private.company_treasury_sources_before_manager_pool() s
$$;
revoke all on function private.company_treasury_sources(),private.company_treasury_sources_before_manager_pool() from public,anon,authenticated;

create function private.manager_bonus_pool_sources()
returns table(source_type text,source_id uuid,category text,amount numeric)
language sql stable security definer set search_path='' as $$
 select s.source_type,s.source_id,s.category,s.amount from private.company_treasury_sources() s
 where s.category in('generation_manager_pending','binary_manager_pending') and s.currency='MIO'
$$;
revoke all on function private.manager_bonus_pool_sources() from public,anon,authenticated;

-- Keep all other bonus budget branches byte-for-byte unchanged.
do $patch$
declare fn text;anchor text:=' if new.method=''community_share'' then';
begin
 select pg_get_functiondef('private.guard_bonus_funding()'::regprocedure) into fn;
 if position(anchor in fn)=0 then raise exception 'Review current funding guard before applying';end if;
 fn:=replace(fn,anchor,$guard$
 if new.method='team_manager' then
  select d.amount into ceiling from public.manager_bonus_distributions d
  where d.id=(new.calculation_trace->>'manager_distribution_id')::uuid
   and d.cycle_id=(new.calculation_trace->>'cycle_id')::uuid
   and d.member_id=new.beneficiary_id and d.bonus_transaction_id is null
   and d.amount=new.payable_amount for update;
  if ceiling is null or new.status<>'posted' or new.source_activation_id is not null or new.source_order_id is not null
   then raise exception 'Manager bonus requires an authorized funded distribution';end if;
  if exists(select 1 from public.bonus_transactions b where b.method='team_manager'
   and b.calculation_trace->>'manager_distribution_id'=new.calculation_trace->>'manager_distribution_id')
   then raise exception 'Manager distribution already paid';end if;
  select coalesce(sum(a.amount),0) into ceiling from private.manager_bonus_pool_allocations a
   where a.cycle_id=(new.calculation_trace->>'cycle_id')::uuid;
  select coalesce(sum(b.payable_amount),0) into spent from public.bonus_transactions b
   where b.method='team_manager' and b.calculation_trace->>'cycle_id'=new.calculation_trace->>'cycle_id'
   and b.status in('posted','pending');
  if spent+new.payable_amount>ceiling then raise exception 'Manager bonus exceeds reserved pool funding';end if;
  return new;
 end if;
$guard$||anchor);
 execute fn;
end $patch$;

CREATE OR REPLACE FUNCTION private.manager_point_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare source_member uuid;sponsor uuid;ancestor uuid;depth integer:=0;
BEGIN if private.member_restore_active(new.member_id) then return new;end if;
 if new.entry_kind<>'credit' or new.amount<=0 or new.point_type not in('DP','GP','BRP') then return new;end if;source_member:=new.member_id;
 if new.point_type='DP' then
  select sponsor_id into sponsor from public.member_profiles where user_id=source_member;
  if sponsor is not null and exists(select 1 from private.team_manager_qualifications where member_id=sponsor and qualified_at<=new.created_at) and private.maintenance_active(sponsor) and private.package_eligible(sponsor) and not exists(select 1 from private.team_manager_qualifications where member_id=source_member) then
   insert into public.manager_point_ledger(manager_id,source_member_id,point_kind,amount,source_point_id,generation) values(sponsor,source_member,'MTP',new.amount,new.id,1) on conflict do nothing;
   if found then insert into private.team_manager_balances(member_id,manager_track_points) values(sponsor,new.amount) on conflict(member_id) do update set manager_track_points=private.team_manager_balances.manager_track_points+excluded.manager_track_points,updated_at=now();end if;
  end if;
 end if;
 if new.point_type='GP' and not exists(select 1 from private.team_manager_qualifications where member_id=source_member) then
  select sponsor_id into ancestor from public.member_profiles where user_id=source_member;
  while ancestor is not null and depth<10 loop depth:=depth+1;
   -- A qualified manager is a boundary even while maintenance is inactive.
   if exists(select 1 from private.team_manager_qualifications where member_id=ancestor and qualified_at<=new.created_at) then
    if depth>=2 and private.maintenance_active(ancestor) and private.package_eligible(ancestor) then
     insert into public.manager_point_ledger(manager_id,source_member_id,point_kind,amount,source_point_id,generation)
     values(ancestor,source_member,'MNGP',new.amount,new.id,depth) on conflict do nothing;
     if found then insert into private.team_manager_balances(member_id,manager_network_generation_points)
      values(ancestor,new.amount) on conflict(member_id) do update
      set manager_network_generation_points=private.team_manager_balances.manager_network_generation_points+excluded.manager_network_generation_points,updated_at=now();end if;
    end if;
    exit;
   end if;select sponsor_id into ancestor from public.member_profiles where user_id=ancestor;end loop;
 end if;
 perform private.refresh_leadership_rank(new.member_id);
 ancestor:=source_member;depth:=0;while ancestor is not null and depth<=private.network_generation_limit() loop perform private.refresh_team_manager_qualification(ancestor);select sponsor_id into ancestor from public.member_profiles where user_id=ancestor;depth:=depth+1;end loop;
 return new;
end$function$
;
CREATE OR REPLACE FUNCTION public.admin_distribute_manager_bonus(p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;rules jsonb:=private.current_team_manager_rules();cycle uuid;tx uuid;dist uuid;amount numeric;cnt integer:=0;tm numeric:=0;ng numeric:=0;total numeric:=0;need numeric:=0;available numeric:=0;take numeric:=0;fund record;
begin if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();if nullif(trim(p_idempotency_key),'') is null then raise exception 'Distribution key required';end if;perform pg_advisory_xact_lock(hashtextextended('manager-bonus-distribution',0));p_idempotency_key:=trim(p_idempotency_key);select id into cycle from public.manager_bonus_cycles where idempotency_key=p_idempotency_key;if cycle is not null then return jsonb_build_object('cycle_id',cycle,'duplicate',true);end if;
 insert into public.manager_bonus_cycles(idempotency_key,distributed_by) values(trim(p_idempotency_key),auth.uid()) returning id into cycle;
 -- Lock every payable balance before checking and reserving the pool.
 perform 1 from private.team_manager_balances b where b.manager_track_points>0 or b.manager_network_generation_points>0 order by b.member_id for update;
 perform pg_advisory_xact_lock(hashtextextended('company-treasury-sync',0));
 select coalesce(sum(round(b.manager_track_points*(rules->>'track_rate')::numeric+b.manager_network_generation_points*(rules->>'network_rate')::numeric,4)),0)
 into need from private.team_manager_balances b
 where private.maintenance_active(b.member_id) and private.package_eligible(b.member_id)
 and exists(select 1 from private.team_manager_qualifications q where q.member_id=b.member_id);
 if need<=0 then raise exception 'No eligible Manager Bonus is pending';end if;
 select coalesce(sum(s.amount),0) into available from private.manager_bonus_pool_sources() s;
 if need>available then raise exception 'Manager Bonus Wallet: available % MIO, required % MIO. No balances changed.',available,need;end if;
 for fund in select s.* from private.manager_bonus_pool_sources() s where s.amount>0 order by s.source_type,s.source_id,s.category loop
  exit when need<=0;take:=least(fund.amount,need);
  insert into private.manager_bonus_pool_allocations(cycle_id,source_type,source_id,category,amount)
  values(cycle,fund.source_type,fund.source_id,fund.category,take);
  need:=need-take;
 end loop;
 if need<>0 then raise exception 'Manager Bonus reserve changed; retry';end if;
 for r in select b.*,m.member_code from private.team_manager_balances b join public.member_profiles m on m.user_id=b.member_id where (b.manager_track_points>0 or b.manager_network_generation_points>0) and private.maintenance_active(b.member_id) and private.package_eligible(b.member_id) and exists(select 1 from private.team_manager_qualifications q where q.member_id=b.member_id) for update of b loop
  amount:=round(r.manager_track_points*(rules->>'track_rate')::numeric+r.manager_network_generation_points*(rules->>'network_rate')::numeric,4);if amount<=0 then continue;end if;
  insert into public.manager_bonus_distributions(cycle_id,member_id,mtp,mngp,track_rate,network_rate,amount) values(cycle,r.member_id,r.manager_track_points,r.manager_network_generation_points,(rules->>'track_rate')::numeric,(rules->>'network_rate')::numeric,amount) returning id into dist;
  insert into public.mio_wallet_accounts(member_id,balance) values(r.member_id,amount) on conflict(member_id) do update set balance=public.mio_wallet_accounts.balance+excluded.balance,updated_at=now();
  insert into public.bonus_transactions(beneficiary_id,method,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key) values(r.member_id,'team_manager',r.manager_track_points+r.manager_network_generation_points,null,amount,amount,'MIO','team-manager-v1',jsonb_build_object('bonus_component','team_manager','manager_track_points',r.manager_track_points,'manager_network_generation_points',r.manager_network_generation_points,'track_rate',rules->>'track_rate','network_rate',rules->>'network_rate','cycle_id',cycle,'manager_distribution_id',dist,'funding_source','manager_bonus_pool'),'posted','manager-bonus:'||cycle||':'||r.member_id) returning id into tx;
  update public.manager_bonus_distributions set bonus_transaction_id=tx where id=dist;
  insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,manager_distribution_id,reason,idempotency_key) values(r.member_id,amount,'bonus_credit',tx,dist,'Team Manager bonus distribution','manager-mio:'||dist);
  update private.team_manager_balances set manager_track_points=0,manager_network_generation_points=0,updated_at=now() where member_id=r.member_id;cnt:=cnt+1;tm:=tm+r.manager_track_points;ng:=ng+r.manager_network_generation_points;total:=total+amount;
 end loop;perform private.sync_company_treasury();update public.manager_bonus_cycles set manager_count=cnt,total_mtp=tm,total_mngp=ng,total_mio=total where id=cycle;return jsonb_build_object('cycle_id',cycle,'duplicate',false,'manager_count',cnt,'total_mtp',tm,'total_mngp',ng,'total_mio',total);end$function$
;

create function public.admin_manager_bonus_wallet(p_page integer default 1)
returns jsonb language plpgsql security definer set search_path='' as $$
declare rules jsonb; funded numeric;paid numeric;pending numeric;payable numeric;result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_page<1 or p_page is null then raise exception 'Invalid page';end if;
 rules:=private.current_team_manager_rules();
 select coalesce(sum(amount),0) into funded from private.company_treasury_sources_before_manager_pool()
 where category in('generation_manager_pending','binary_manager_pending') and currency='MIO';
 select coalesce(sum(amount),0) into paid from private.manager_bonus_pool_allocations;
 select coalesce(sum(round(b.manager_track_points*(rules->>'track_rate')::numeric+b.manager_network_generation_points*(rules->>'network_rate')::numeric,4)),0),
 coalesce(sum(round(b.manager_track_points*(rules->>'track_rate')::numeric+b.manager_network_generation_points*(rules->>'network_rate')::numeric,4))
 filter(where private.maintenance_active(b.member_id) and private.package_eligible(b.member_id)
 and exists(select 1 from private.team_manager_qualifications q where q.member_id=b.member_id)),0)
 into pending,payable from private.team_manager_balances b;
 return jsonb_build_object('funded_mio',funded,'distributed_mio',paid,'available_mio',funded-paid,'pending_mio',pending,
 'payable_mio',payable,'target_wallet',private.current_bonus_wallet_routing()->'routes'->>'team_manager',
 'page',p_page,'page_size',50,
 'distribution_count',(select count(*) from public.manager_bonus_distributions),
 'sources',coalesce((select jsonb_agg(to_jsonb(s)) from (
 select r.source_type,r.source_id,r.category,r.amount funded_mio,
 coalesce((select sum(a.amount) from private.manager_bonus_pool_allocations a where a.source_type=r.source_type and a.source_id=r.source_id and a.category=r.category),0) paid_mio
 from private.company_treasury_sources_before_manager_pool() r where r.category in('generation_manager_pending','binary_manager_pending') and r.currency='MIO' and r.amount>0
 order by r.source_type,r.source_id,r.category limit 50 offset (p_page-1)*50) s),'[]'::jsonb),
 'source_count',(select count(*) from private.company_treasury_sources_before_manager_pool() where category in('generation_manager_pending','binary_manager_pending') and currency='MIO' and amount>0),
 'pending',coalesce((select jsonb_agg(to_jsonb(x)) from(
 select m.member_code,m.full_name,b.manager_track_points mdp,b.manager_network_generation_points mngp,
 round(b.manager_track_points*(rules->>'track_rate')::numeric+b.manager_network_generation_points*(rules->>'network_rate')::numeric,4) amount,
 private.maintenance_active(b.member_id) and private.package_eligible(b.member_id) and exists(select 1 from private.team_manager_qualifications q where q.member_id=b.member_id) eligible
 from private.team_manager_balances b join public.member_profiles m on m.user_id=b.member_id
 where b.manager_track_points>0 or b.manager_network_generation_points>0 order by m.member_code) x),'[]'::jsonb),
 'distributions',coalesce((select jsonb_agg(to_jsonb(x)) from (
 select d.id,d.cycle_id,m.full_name,m.member_code,d.mtp mdp,d.mngp,d.track_rate,d.network_rate,d.amount,d.created_at,d.bonus_transaction_id,
 coalesce(l.wallet_kind,'cash') target_wallet from public.manager_bonus_distributions d
 join public.member_profiles m on m.user_id=d.member_id
 left join public.income_wallet_ledger l on l.idempotency_key='bonus-route:'||d.bonus_transaction_id
 order by d.created_at desc,d.id desc limit 50 offset (p_page-1)*50) x),'[]'::jsonb));
end $$;
revoke all on function public.admin_manager_bonus_wallet(integer) from public,anon;
grant execute on function public.admin_manager_bonus_wallet(integer) to authenticated;

create function public.my_manager_bonus_history(p_page integer default 1)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();rules jsonb:=private.current_team_manager_rules();
begin
 if uid is null then raise exception 'Sign in required';end if;
 if p_page<1 or p_page is null then raise exception 'Invalid page';end if;
 return jsonb_build_object('page',p_page,'page_size',50,
 'lifetime_mdp',(select coalesce(sum(amount),0) from public.manager_point_ledger where manager_id=uid and point_kind='MTP'),
 'lifetime_mngp',(select coalesce(sum(amount),0) from public.manager_point_ledger where manager_id=uid and point_kind='MNGP'),
 'pending_mdp',coalesce((select manager_track_points from private.team_manager_balances where member_id=uid),0),
 'pending_mngp',coalesce((select manager_network_generation_points from private.team_manager_balances where member_id=uid),0),
 'paid_mio',(select coalesce(sum(amount),0) from public.manager_bonus_distributions where member_id=uid),
 'total_count',(select count(*) from public.manager_bonus_distributions where member_id=uid),
 'rows',coalesce((select jsonb_agg(to_jsonb(x)) from(
 select d.id,d.cycle_id,d.mtp mdp,d.mngp,d.track_rate,d.network_rate,d.amount,d.created_at,d.bonus_transaction_id,coalesce(l.wallet_kind,'cash') target_wallet
 from public.manager_bonus_distributions d left join public.income_wallet_ledger l on l.idempotency_key='bonus-route:'||d.bonus_transaction_id
 where d.member_id=uid order by d.created_at desc,d.id desc limit 50 offset (p_page-1)*50)x),'[]'::jsonb));
end $$;
revoke all on function public.my_manager_bonus_history(integer) from public,anon;
grant execute on function public.my_manager_bonus_history(integer) to authenticated;

CREATE OR REPLACE FUNCTION public.my_manager_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=auth.uid();m jsonb;b private.team_manager_balances%rowtype;q private.team_manager_qualifications%rowtype;r record;
begin
  if uid is null then raise exception 'Sign in required';end if;
  m:=private.team_manager_metrics(uid);
  select * into b from private.team_manager_balances where member_id=uid;
  select * into q from private.team_manager_qualifications where member_id=uid;
  select d.* into r from public.leadership_rank_definitions d join public.member_profiles p on p.achieved_rank=d.rank_code where p.user_id=uid;
  return m||jsonb_build_object(
    'bonus_history',public.my_manager_bonus_history(1),'qualified',q.member_id is not null,'qualified_at',q.qualified_at,'tree_available',q.member_id is not null,
    'team_manager_badge_url',m->'rules'->>'badge_url',
    'manager_track_points',coalesce(b.manager_track_points,0),
    'manager_network_generation_points',coalesce(b.manager_network_generation_points,0),
    'leadership_rank',case when r.rank_code is null then null else jsonb_build_object('code',r.rank_code,'name',r.display_name,'theme',r.badge_theme,'badge_url',r.badge_url) end,
    'manager_direct_points',coalesce(b.manager_track_points,0),
    'rank_qualification',jsonb_build_object('metrics',private.rank_metrics(uid),'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'sort_order',d.sort_order,'theme',d.badge_theme,'badge_url',d.badge_url,'left_brp',d.left_brp,'right_brp',d.right_brp,'direct_left',d.direct_left,'direct_right',d.direct_right,'required_dp',d.required_dp,'minimum_package',d.minimum_package,'required_total_earnings',d.required_total_earnings) order by d.sort_order,d.rank_code) from public.leadership_rank_definitions d where d.active),'[]'::jsonb)),
    'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'badge_url',d.badge_url,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb)
  );
end;
$function$
;
