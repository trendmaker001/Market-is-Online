-- Cumulative Team Manager progress plus manual 12-cycle Global Community Share.

-- Community Share is funded from its own reserved contribution ledger, so it
-- has no activation/order source (the same source model as Team Manager).
alter table public.bonus_transactions drop constraint if exists bonus_source_check;
alter table public.bonus_transactions add constraint bonus_source_check check(
 (method='binary_pool_share' and cycle_id is not null and num_nonnulls(source_activation_id,source_order_id)=0) or
 (method in('team_manager','community_share') and cycle_id is null and num_nonnulls(source_activation_id,source_order_id)=0) or
 (method not in('binary_pool_share','team_manager','community_share') and cycle_id is null and num_nonnulls(source_activation_id,source_order_id)=1)
);

-- Community funds are explicitly reserved in their own audited contribution ledger.
do $$declare f text;begin
 f:=pg_get_functiondef('private.guard_bonus_funding()'::regprocedure);
 f:=replace(f,$replace$if new.method='team_manager' then return new;end if;$replace$,$replace$if new.method in('team_manager','community_share') then return new;end if;$replace$);
 execute f;
end$$;

create table public.community_share_grants(
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references public.member_profiles(user_id) on delete cascade,
 share_kind text not null check(share_kind in('actual','gift')),
 quantity integer not null check(quantity>0),
 actual_share_milestone integer not null check(actual_share_milestone>0),
 start_cycle integer not null check(start_cycle>0),
 end_cycle integer not null check(end_cycle>=start_cycle),
 rule_version integer not null,
 created_at timestamptz not null default now(),
 unique(member_id,share_kind,actual_share_milestone)
);
create index community_share_grants_member_cycle_idx on public.community_share_grants(member_id,start_cycle,end_cycle);
create index community_share_grants_active_cycle_idx on public.community_share_grants(start_cycle,end_cycle);

create table public.community_fund_contributions(
 id uuid primary key default gen_random_uuid(),
 amount_mio numeric(20,8) not null check(amount_mio>0),
 installment_count integer not null check(installment_count between 1 and 120),
 installment_mio numeric(20,8) not null check(installment_mio>=0),
 final_remainder_mio numeric(20,8) not null default 0 check(final_remainder_mio>=0),
 start_cycle integer not null check(start_cycle>0),
 end_cycle integer not null check(end_cycle>=start_cycle),
 note text not null check(length(trim(note)) between 3 and 500),
 idempotency_key text not null unique,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
create index community_fund_contributions_cycle_idx on public.community_fund_contributions(start_cycle,end_cycle);

create table public.community_share_cycles(
 id uuid primary key default gen_random_uuid(),
 cycle_number integer not null unique check(cycle_number>0),
 idempotency_key text not null unique,
 fund_pool_mio numeric(20,8) not null check(fund_pool_mio>0),
 active_actual_shares integer not null check(active_actual_shares>=0),
 active_gift_shares integer not null check(active_gift_shares>=0),
 total_active_shares integer not null check(total_active_shares>0),
 per_share_mio numeric(24,12) not null check(per_share_mio>=0),
 distributed_mio numeric(20,8) not null check(distributed_mio>=0),
 member_count integer not null check(member_count>=0),
 distributed_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);

create table public.community_share_distributions(
 id uuid primary key default gen_random_uuid(),
 cycle_id uuid not null references public.community_share_cycles(id) on delete cascade,
 member_id uuid not null references public.member_profiles(user_id),
 actual_shares integer not null check(actual_shares>=0),
 gift_shares integer not null check(gift_shares>=0),
 amount_mio numeric(20,8) not null check(amount_mio>=0),
 bonus_transaction_id uuid references public.bonus_transactions(id),
 created_at timestamptz not null default now(),
 unique(cycle_id,member_id)
);
create index community_share_distributions_member_idx on public.community_share_distributions(member_id,created_at desc);

-- Keep every wallet credit tied to its immutable Community Share distribution.
alter table public.mio_ledger add column if not exists community_distribution_id uuid references public.community_share_distributions(id);
alter table public.mio_ledger drop constraint if exists mio_ledger_activation_source_check;
alter table public.mio_ledger add constraint mio_ledger_activation_source_check check(
 (action='package_activation' and activation_id is not null and num_nonnulls(cycle_id,source_order_id,manager_distribution_id,community_distribution_id)=0) or
 (action='bonus_credit' and num_nonnulls(activation_id,cycle_id,source_order_id,manager_distribution_id,community_distribution_id)=1) or
 (action in('affiliate_order_hold','affiliate_order_refund') and source_order_id is not null and activation_id is null and cycle_id is null and manager_distribution_id is null and community_distribution_id is null) or
 (action not in('package_activation','bonus_credit','affiliate_order_hold','affiliate_order_refund') and num_nonnulls(activation_id,cycle_id,source_order_id,manager_distribution_id,community_distribution_id)=0)
);

alter table public.community_share_grants enable row level security;
alter table public.community_fund_contributions enable row level security;
alter table public.community_share_cycles enable row level security;
alter table public.community_share_distributions enable row level security;

create policy "members read own community grants" on public.community_share_grants for select to authenticated
 using(member_id=(select auth.uid()) or private.has_role('admin'));
create policy "admins read community funds" on public.community_fund_contributions for select to authenticated
 using(private.has_role('admin'));
create policy "admins read community cycles" on public.community_share_cycles for select to authenticated
 using(private.has_role('admin'));
create policy "members read own community distributions" on public.community_share_distributions for select to authenticated
 using(member_id=(select auth.uid()) or private.has_role('admin'));

revoke all on public.community_share_grants,public.community_fund_contributions,public.community_share_cycles,public.community_share_distributions from public,anon,authenticated;
grant select on public.community_share_grants,public.community_share_distributions to authenticated;
grant select on public.community_fund_contributions,public.community_share_cycles to authenticated;

insert into public.system_config(config_key,version,config_value,effective_from,effective_to,created_by)
select 'COMMUNITY_SHARE_RULES',1,jsonb_build_object(
 'enabled',true,'minimum_package','ADVANCED_2','directs_per_share',5,'dp_per_share',500,
 'gift_every_actual_shares',2,'gift_share_quantity',1,'validity_cycles',12,'fund_installments',12
),now(),null,null
where not exists(select 1 from public.system_config where config_key='COMMUNITY_SHARE_RULES');

create or replace function private.current_community_share_rules() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('version',version)||config_value
 from public.system_config
 where config_key='COMMUNITY_SHARE_RULES' and effective_from<=now() and (effective_to is null or effective_to>now())
 order by version desc limit 1
$$;

create or replace function private.current_community_cycle() returns integer language sql stable security definer set search_path='' as $$
 select coalesce(max(cycle_number),0) from public.community_share_cycles
$$;

create or replace function private.team_manager_metrics(p_member uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
 r jsonb:=private.current_team_manager_rules();directs integer:=0;dp numeric:=0;tngp numeric:=0;lines integer:=0;
 pkg text;qualified boolean;progress numeric;line_breakdown jsonb:='[]'::jsonb;criteria jsonb;
 package_ratio numeric:=0;direct_ratio numeric:=0;dp_ratio numeric:=0;tngp_ratio numeric:=0;line_ratio numeric:=0;
begin
 pkg:=private.current_package_code(p_member);
 select active_directs,total_dp into directs,dp from private.direct_dp_summary(p_member);
 with recursive roots as(
  select m.user_id,m.member_code,m.full_name,row_number() over(order by m.member_code,m.user_id)::integer position
  from public.member_profiles m where m.sponsor_id=p_member and m.status='active'
 ),d(id,root_id,depth,path) as(
  select r0.user_id,r0.user_id,1,array[p_member,r0.user_id] from roots r0
  union all
  select m.user_id,d.root_id,d.depth+1,d.path||m.user_id
  from d join public.member_profiles m on m.sponsor_id=d.id
  where d.depth<(r->>'max_generations')::integer and not m.user_id=any(d.path)
 ),line_gp as(
  select roots.position,roots.user_id,roots.member_code,roots.full_name,coalesce(sum(a.gp),0)::numeric gp
  from roots join d on d.root_id=roots.user_id
  left join public.package_activations a on a.member_id=d.id and a.status='approved'
  group by roots.position,roots.user_id,roots.member_code,roots.full_name
 ),slots as(
  select generate_series(1,greatest((r->>'required_qualified_lines')::integer,coalesce((select max(position) from line_gp),0))) position
 ),detail as(
  select s.position,l.user_id,l.member_code,l.full_name,coalesce(l.gp,0) gp
  from slots s left join line_gp l using(position)
 )
 select coalesce(sum(gp),0),count(*) filter(where user_id is not null and gp>=(r->>'per_line_tngp')::numeric),
  coalesce(jsonb_agg(jsonb_build_object(
   'position',position,'member_id',user_id,'member_code',member_code,'full_name',full_name,'tngp',gp,
   'required_tngp',(r->>'per_line_tngp')::numeric,
   'progress_percent',least(100,round(100*gp/greatest((r->>'per_line_tngp')::numeric,1),2)),
   'qualified',user_id is not null and gp>=(r->>'per_line_tngp')::numeric
  ) order by position),'[]'::jsonb)
 into tngp,lines,line_breakdown from detail;

 package_ratio:=least(1,private.package_weight(pkg)::numeric/greatest(private.package_weight(r->>'minimum_package'),1));
 direct_ratio:=least(1,coalesce(directs,0)::numeric/greatest((r->>'required_directs')::numeric,1));
 dp_ratio:=least(1,coalesce(dp,0)/greatest((r->>'required_direct_dp')::numeric,1));
 tngp_ratio:=least(1,coalesce(tngp,0)/greatest((r->>'required_tngp')::numeric,1));
 line_ratio:=least(1,coalesce(lines,0)::numeric/greatest((r->>'required_qualified_lines')::numeric,1));
 progress:=least(100,round(100*(package_ratio+direct_ratio+dp_ratio+tngp_ratio+line_ratio)/5,2));
 criteria:=jsonb_build_object(
  'package',round(package_ratio*100,2),'directs',round(direct_ratio*100,2),'direct_dp',round(dp_ratio*100,2),
  'tngp',round(tngp_ratio*100,2),'qualified_lines',round(line_ratio*100,2)
 );
 qualified:=coalesce((r->>'enabled')::boolean,true)
  and package_ratio>=1 and direct_ratio>=1 and dp_ratio>=1 and tngp_ratio>=1 and line_ratio>=1;
 return jsonb_build_object(
  'qualified_now',qualified,'package',pkg,'directs',coalesce(directs,0),'direct_dp',coalesce(dp,0),
  'tngp',coalesce(tngp,0),'qualified_lines',coalesce(lines,0),'progress_percent',coalesce(progress,0),
  'criteria_progress',criteria,'line_breakdown',line_breakdown,'rules',r
 );
end$$;

create or replace function private.community_share_metrics(p_member uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
 r jsonb:=private.current_community_share_rules();pkg text;directs integer:=0;dp numeric:=0;eligible boolean:=false;
 actual_target integer:=0;gift_target integer:=0;actual_granted integer:=0;gift_granted integer:=0;
 active_actual integer:=0;active_gift integer:=0;cycle_no integer:=private.current_community_cycle();next_actual integer;
begin
 pkg:=private.current_package_code(p_member);
 select active_directs,total_dp into directs,dp from private.direct_dp_summary(p_member);
 eligible:=coalesce((r->>'enabled')::boolean,true) and private.package_weight(pkg)>=private.package_weight(r->>'minimum_package');
 if eligible then
  actual_target:=least(floor(coalesce(directs,0)::numeric/greatest((r->>'directs_per_share')::numeric,1)),floor(coalesce(dp,0)/greatest((r->>'dp_per_share')::numeric,1)))::integer;
  gift_target:=floor(actual_target::numeric/greatest((r->>'gift_every_actual_shares')::numeric,1))::integer*(r->>'gift_share_quantity')::integer;
 end if;
 select coalesce(sum(quantity) filter(where share_kind='actual'),0),coalesce(sum(quantity) filter(where share_kind='gift'),0),
  coalesce(sum(quantity) filter(where share_kind='actual' and start_cycle<=cycle_no+1 and end_cycle>=cycle_no+1),0),
  coalesce(sum(quantity) filter(where share_kind='gift' and start_cycle<=cycle_no+1 and end_cycle>=cycle_no+1),0)
 into actual_granted,gift_granted,active_actual,active_gift from public.community_share_grants where member_id=p_member;
 next_actual:=greatest(actual_granted+1,1);
 return jsonb_build_object(
  'enabled',coalesce((r->>'enabled')::boolean,true),'eligible_package',eligible,'package',pkg,'directs',coalesce(directs,0),'direct_dp',coalesce(dp,0),
  'qualified_actual_shares',actual_target,'qualified_gift_shares',gift_target,'lifetime_actual_shares',actual_granted,'lifetime_gift_shares',gift_granted,
  'active_actual_shares',active_actual,'active_gift_shares',active_gift,'active_total_shares',active_actual+active_gift,
  'current_cycle',cycle_no,'next_cycle',cycle_no+1,'next_actual_share',next_actual,
  'next_required_directs',next_actual*(r->>'directs_per_share')::integer,'next_required_dp',next_actual*(r->>'dp_per_share')::numeric,
  'rules',r
 );
end$$;

create or replace function private.refresh_community_share_grants(p_member uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare m jsonb;r jsonb;current_cycle integer:=private.current_community_cycle();actual_target integer;gift_target integer;actual_granted integer;gift_granted integer;validity integer;
begin
 m:=private.community_share_metrics(p_member);r:=m->'rules';validity:=(r->>'validity_cycles')::integer;
 if not coalesce((m->>'eligible_package')::boolean,false) then return m;end if;
 actual_target:=(m->>'qualified_actual_shares')::integer;gift_target:=(m->>'qualified_gift_shares')::integer;
 actual_granted:=(m->>'lifetime_actual_shares')::integer;gift_granted:=(m->>'lifetime_gift_shares')::integer;
 if actual_target>actual_granted then
  insert into public.community_share_grants(member_id,share_kind,quantity,actual_share_milestone,start_cycle,end_cycle,rule_version)
  values(p_member,'actual',actual_target-actual_granted,actual_target,current_cycle+1,current_cycle+validity,(r->>'version')::integer)
  on conflict(member_id,share_kind,actual_share_milestone) do nothing;
 end if;
 if gift_target>gift_granted then
  insert into public.community_share_grants(member_id,share_kind,quantity,actual_share_milestone,start_cycle,end_cycle,rule_version)
  values(p_member,'gift',gift_target-gift_granted,actual_target,current_cycle+1,current_cycle+validity,(r->>'version')::integer)
  on conflict(member_id,share_kind,actual_share_milestone) do nothing;
 end if;
 return private.community_share_metrics(p_member);
end$$;

create or replace function public.my_community_share_status() returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();m jsonb;
begin
 if uid is null then raise exception 'Sign in required';end if;
 m:=private.refresh_community_share_grants(uid);
 return m||jsonb_build_object(
  'grants',coalesce((select jsonb_agg(jsonb_build_object('kind',share_kind,'quantity',quantity,'start_cycle',start_cycle,'end_cycle',end_cycle,'created_at',created_at) order by created_at) from public.community_share_grants where member_id=uid),'[]'::jsonb),
  'distributions',coalesce((select jsonb_agg(jsonb_build_object('cycle_number',c.cycle_number,'actual_shares',d.actual_shares,'gift_shares',d.gift_shares,'amount_mio',d.amount_mio,'created_at',d.created_at) order by c.cycle_number desc) from public.community_share_distributions d join public.community_share_cycles c on c.id=d.cycle_id where d.member_id=uid),'[]'::jsonb)
 );
end$$;

create or replace function public.admin_community_share_program() returns jsonb language plpgsql security definer set search_path='' as $$
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
end$$;

create or replace function public.admin_set_community_share_rules(p_rules jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cur jsonb:=private.current_community_share_rules();n jsonb;v integer;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if p_expected_version<>(cur->>'version')::integer then raise exception 'Rules changed. Refresh and try again';end if;
 n:=jsonb_build_object(
  'enabled',coalesce((p_rules->>'enabled')::boolean,true),'minimum_package',p_rules->>'minimum_package',
  'directs_per_share',(p_rules->>'directs_per_share')::integer,'dp_per_share',(p_rules->>'dp_per_share')::numeric,
  'gift_every_actual_shares',(p_rules->>'gift_every_actual_shares')::integer,'gift_share_quantity',(p_rules->>'gift_share_quantity')::integer,
  'validity_cycles',(p_rules->>'validity_cycles')::integer,'fund_installments',(p_rules->>'fund_installments')::integer
 );
 if private.package_weight(n->>'minimum_package')<private.package_weight('ADVANCED_2')
  or least((n->>'directs_per_share')::numeric,(n->>'dp_per_share')::numeric,(n->>'gift_every_actual_shares')::numeric,(n->>'gift_share_quantity')::numeric,(n->>'validity_cycles')::numeric,(n->>'fund_installments')::numeric)<=0
  or (n->>'validity_cycles')::integer>120 or (n->>'fund_installments')::integer>120 then raise exception 'Invalid Community Share rules';end if;
 v:=(cur->>'version')::integer+1;
 update public.system_config set effective_to=now() where config_key='COMMUNITY_SHARE_RULES' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('COMMUNITY_SHARE_RULES',v,n,now(),auth.uid());
 return jsonb_build_object('version',v)||n;
end$$;

create or replace function public.admin_add_community_fund(p_amount_mio numeric,p_note text,p_idempotency_key text) returns jsonb language plpgsql security definer set search_path='' as $$
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
end$$;

create or replace function public.admin_distribute_community_share(p_idempotency_key text) returns jsonb language plpgsql security definer set search_path='' as $$
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
 select coalesce(sum(quantity) filter(where share_kind='actual'),0),coalesce(sum(quantity) filter(where share_kind='gift'),0) into actual_total,gift_total from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle;
 shares_total:=actual_total+gift_total;if pool<=0 then raise exception 'No Community Share installment is due for cycle %',next_cycle;end if;if shares_total<=0 then raise exception 'No active Community Shares for cycle %',next_cycle;end if;
 per_share:=pool/shares_total;
 select count(*) into members from (select member_id from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle group by member_id) x;
 insert into public.community_share_cycles(cycle_number,idempotency_key,fund_pool_mio,active_actual_shares,active_gift_shares,total_active_shares,per_share_mio,distributed_mio,member_count,distributed_by)
 values(next_cycle,trim(p_idempotency_key),pool,actual_total,gift_total,shares_total,per_share,0,members,auth.uid()) returning id into cycle_id;
 for r in
  select member_id,coalesce(sum(quantity) filter(where share_kind='actual'),0)::integer actual_shares,coalesce(sum(quantity) filter(where share_kind='gift'),0)::integer gift_shares
  from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle group by member_id order by member_id
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
end$$;

revoke all on function private.current_community_share_rules(),private.current_community_cycle(),private.community_share_metrics(uuid),private.refresh_community_share_grants(uuid) from public,anon,authenticated;
revoke all on function public.my_community_share_status(),public.admin_community_share_program(),public.admin_set_community_share_rules(jsonb,integer),public.admin_add_community_fund(numeric,text,text),public.admin_distribute_community_share(text) from public,anon,authenticated;
grant execute on function public.my_community_share_status() to authenticated;
grant execute on function public.admin_community_share_program(),public.admin_set_community_share_rules(jsonb,integer),public.admin_add_community_fund(numeric,text,text),public.admin_distribute_community_share(text) to authenticated;
