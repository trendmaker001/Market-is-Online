-- Dynamic Team Manager programme, breakaway points and leadership ranks.

alter table public.member_profiles drop constraint if exists member_profiles_achieved_rank_check;

create table public.leadership_rank_definitions(
 rank_code text primary key check(rank_code~'^[a-z][a-z0-9_]{1,39}$'),
 display_name text not null check(length(trim(display_name)) between 2 and 60),
 sort_order integer not null unique check(sort_order between 1 and 1000),
 left_brp numeric(18,4) not null check(left_brp>=0),
 right_brp numeric(18,4) not null check(right_brp>=0),
 direct_left integer not null check(direct_left>=0),
 direct_right integer not null check(direct_right>=0),
 required_dp numeric(18,4) not null check(required_dp>=0),
 badge_theme text not null default 'emerald' check(badge_theme in('emerald','blue','violet','amber','ruby','diamond')),
 active boolean not null default true,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
insert into public.leadership_rank_definitions(rank_code,display_name,sort_order,left_brp,right_brp,direct_left,direct_right,required_dp,badge_theme) values
 ('leader','Leader',10,5000,5000,5,5,500,'emerald'),
 ('team_leader','Team Leader',20,10000,10000,10,10,1000,'blue'),
 ('senior_team_leader','Senior Team Leader',30,25000,25000,10,10,2000,'violet'),
 ('executive','Executive',40,50000,50000,10,10,5000,'amber'),
 ('senior_executive','Senior Executive',50,100000,100000,10,10,10000,'ruby'),
 ('director','Director',60,250000,250000,10,10,20000,'diamond')
on conflict(rank_code) do nothing;

create table public.member_rank_history(
 id uuid primary key default gen_random_uuid(),member_id uuid not null references public.member_profiles(user_id) on delete cascade,
 rank_code text not null references public.leadership_rank_definitions(rank_code),achieved_at timestamptz not null default now(),
 metrics jsonb not null default '{}'::jsonb,unique(member_id,rank_code)
);
create index member_rank_history_member_idx on public.member_rank_history(member_id,achieved_at desc);

create table private.team_manager_qualifications(
 member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
 qualified_at timestamptz not null default now(),rule_version integer not null,qualification_snapshot jsonb not null
);
create table private.team_manager_balances(
 member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
 manager_track_points numeric(20,4) not null default 0 check(manager_track_points>=0),
 manager_network_generation_points numeric(20,4) not null default 0 check(manager_network_generation_points>=0),
 updated_at timestamptz not null default now()
);
create table public.manager_point_ledger(
 id uuid primary key default gen_random_uuid(),manager_id uuid not null references public.member_profiles(user_id) on delete cascade,
 source_member_id uuid not null references public.member_profiles(user_id),point_kind text not null check(point_kind in('MTP','MNGP')),
 amount numeric(20,4) not null check(amount>0),source_point_id uuid not null references public.point_ledger(id),
 generation smallint check(generation between 1 and 10),created_at timestamptz not null default now(),
 unique(manager_id,point_kind,source_point_id)
);
create index manager_point_ledger_manager_idx on public.manager_point_ledger(manager_id,created_at desc);
create table public.manager_bonus_cycles(
 id uuid primary key default gen_random_uuid(),idempotency_key text not null unique,distributed_by uuid not null references auth.users(id),
 manager_count integer not null default 0,total_mtp numeric(20,4) not null default 0,total_mngp numeric(20,4) not null default 0,
 total_mio numeric(20,8) not null default 0,created_at timestamptz not null default now()
);
create table public.manager_bonus_distributions(
 id uuid primary key default gen_random_uuid(),cycle_id uuid not null references public.manager_bonus_cycles(id) on delete cascade,
 member_id uuid not null references public.member_profiles(user_id),mtp numeric(20,4) not null,mngp numeric(20,4) not null,
 track_rate numeric(10,8) not null,network_rate numeric(10,8) not null,amount numeric(20,8) not null check(amount>=0),
 bonus_transaction_id uuid references public.bonus_transactions(id),created_at timestamptz not null default now(),unique(cycle_id,member_id)
);

alter table public.leadership_rank_definitions enable row level security;
alter table public.member_rank_history enable row level security;
alter table public.manager_point_ledger enable row level security;
alter table public.manager_bonus_cycles enable row level security;
alter table public.manager_bonus_distributions enable row level security;
create policy "members read leadership definitions" on public.leadership_rank_definitions for select to authenticated using(true);
create policy "members read own rank history" on public.member_rank_history for select to authenticated using(member_id=(select auth.uid()) or private.has_role('admin'));
create policy "members read own manager points" on public.manager_point_ledger for select to authenticated using(manager_id=(select auth.uid()) or private.has_role('admin'));
create policy "admins read manager cycles" on public.manager_bonus_cycles for select to authenticated using(private.has_role('admin'));
create policy "members read manager distributions" on public.manager_bonus_distributions for select to authenticated using(member_id=(select auth.uid()) or private.has_role('admin'));
revoke all on public.leadership_rank_definitions,public.member_rank_history,public.manager_point_ledger,public.manager_bonus_cycles,public.manager_bonus_distributions from public,anon,authenticated;
grant select on public.leadership_rank_definitions,public.member_rank_history,public.manager_point_ledger,public.manager_bonus_distributions to authenticated;
grant select on public.manager_bonus_cycles to authenticated;

insert into public.system_config(config_key,version,config_value,effective_from,effective_to,created_by)
select 'TEAM_MANAGER_RULES',1,jsonb_build_object('enabled',true,'minimum_package','ADVANCED_2','required_directs',10,
 'required_direct_dp',1000,'required_tngp',10000,'required_qualified_lines',10,'per_line_tngp',1000,
 'max_generations',10,'track_rate',.05,'network_rate',.10),now(),null,null
where not exists(select 1 from public.system_config where config_key='TEAM_MANAGER_RULES');

create or replace function private.current_team_manager_rules() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('version',version)||config_value from public.system_config where config_key='TEAM_MANAGER_RULES' and effective_from<=now() and (effective_to is null or effective_to>now()) order by version desc limit 1
$$;

create or replace function private.package_weight(p_code text) returns integer language sql immutable set search_path='' as $$
 select case p_code when 'BASIC_1' then 1 when 'BASIC_2' then 2 when 'ADVANCED_1' then 3 when 'ADVANCED_2' then 4 when 'PREMIUM' then 5 else 0 end
$$;

create or replace function private.team_manager_metrics(p_member uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb:=private.current_team_manager_rules();directs integer:=0;dp numeric:=0;tngp numeric:=0;lines integer:=0;pkg text;qualified boolean;progress numeric;
begin
 pkg:=private.current_package_code(p_member);select active_directs,total_dp into directs,dp from private.direct_dp_summary(p_member);
 with recursive d(id,root_id,depth,path) as(
  select m.user_id,m.user_id,1,array[p_member,m.user_id] from public.member_profiles m where m.sponsor_id=p_member
  union all select m.user_id,d.root_id,d.depth+1,d.path||m.user_id from d join public.member_profiles m on m.sponsor_id=d.id where d.depth<(r->>'max_generations')::integer and not m.user_id=any(d.path)
 ),line_gp as(select root_id,coalesce(sum(a.gp),0) gp from d left join public.package_activations a on a.member_id=d.id and a.status='approved' group by root_id)
 select coalesce(sum(gp),0),count(*) filter(where gp>=(r->>'per_line_tngp')::numeric) into tngp,lines from line_gp;
 qualified:=coalesce((r->>'enabled')::boolean,true) and private.package_weight(pkg)>=private.package_weight(r->>'minimum_package') and directs>=(r->>'required_directs')::integer and dp>=(r->>'required_direct_dp')::numeric and tngp>=(r->>'required_tngp')::numeric and lines>=(r->>'required_qualified_lines')::integer;
 progress:=least(100,round(100*least(private.package_weight(pkg)::numeric/greatest(private.package_weight(r->>'minimum_package'),1),directs::numeric/greatest((r->>'required_directs')::numeric,1),dp/greatest((r->>'required_direct_dp')::numeric,1),tngp/greatest((r->>'required_tngp')::numeric,1),lines::numeric/greatest((r->>'required_qualified_lines')::numeric,1)),2));
 return jsonb_build_object('qualified_now',qualified,'package',pkg,'directs',coalesce(directs,0),'direct_dp',coalesce(dp,0),'tngp',coalesce(tngp,0),'qualified_lines',coalesce(lines,0),'progress_percent',coalesce(progress,0),'rules',r);
end$$;

create or replace function private.refresh_team_manager_qualification(p_member uuid) returns boolean language plpgsql security definer set search_path='' as $$
declare m jsonb;inserted boolean:=false;
begin m:=private.team_manager_metrics(p_member);if coalesce((m->>'qualified_now')::boolean,false) then
 insert into private.team_manager_qualifications(member_id,rule_version,qualification_snapshot) values(p_member,(m->'rules'->>'version')::integer,m) on conflict(member_id) do nothing;inserted:=found;
 insert into private.team_manager_balances(member_id) values(p_member) on conflict do nothing;end if;return inserted;end$$;

create or replace function private.rank_metrics(p_member uuid) returns jsonb language sql stable security definer set search_path='' as $$
 with recursive downline(id,root_side,path) as(
  select b.member_id,b.side,array[p_member,b.member_id] from public.binary_placements b where b.parent_id=p_member
  union all select b.member_id,d.root_side,d.path||b.member_id from downline d join public.binary_placements b on b.parent_id=d.id where not b.member_id=any(d.path)
 ),sides as(select d.root_side,count(*) filter(where m.sponsor_id=p_member and m.status='active') directs from downline d join public.member_profiles m on m.user_id=d.id group by d.root_side),brp as(
  select coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='LEFT'),0) l,coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='RIGHT'),0) r from public.point_ledger where member_id=p_member and point_type='BRP'
 ),dp as(select total_dp from private.direct_dp_summary(p_member))
 select jsonb_build_object('left_brp',brp.l,'right_brp',brp.r,'direct_left',coalesce((select directs from sides where root_side='LEFT'),0),'direct_right',coalesce((select directs from sides where root_side='RIGHT'),0),'direct_dp',coalesce(dp.total_dp,0)) from brp,dp
$$;

create or replace function private.refresh_leadership_rank(p_member uuid) returns text language plpgsql security definer set search_path='' as $$
declare m jsonb;r record;top_code text;top_order integer:=0;
begin m:=private.rank_metrics(p_member);for r in select * from public.leadership_rank_definitions where active order by sort_order loop
 if (m->>'left_brp')::numeric>=r.left_brp and (m->>'right_brp')::numeric>=r.right_brp and (m->>'direct_left')::integer>=r.direct_left and (m->>'direct_right')::integer>=r.direct_right and (m->>'direct_dp')::numeric>=r.required_dp then
  insert into public.member_rank_history(member_id,rank_code,metrics) values(p_member,r.rank_code,m) on conflict do nothing;top_code:=r.rank_code;top_order:=r.sort_order;
 end if;end loop;
 if top_code is not null and coalesce((select sort_order from public.leadership_rank_definitions where rank_code=(select achieved_rank from public.member_profiles where user_id=p_member)),0)<=top_order then update public.member_profiles set achieved_rank=top_code,updated_at=now() where user_id=p_member;end if;return top_code;
end$$;

create or replace function private.manager_point_event() returns trigger language plpgsql security definer set search_path='' as $$
declare source_member uuid;sponsor uuid;ancestor uuid;depth integer:=0;
begin
 if new.entry_kind<>'credit' or new.amount<=0 or new.point_type not in('DP','GP','BRP') then return new;end if;source_member:=new.member_id;
 if new.point_type='DP' then
  select sponsor_id into sponsor from public.member_profiles where user_id=source_member;
  if sponsor is not null and exists(select 1 from private.team_manager_qualifications where member_id=sponsor) and not exists(select 1 from private.team_manager_qualifications where member_id=source_member) then
   insert into public.manager_point_ledger(manager_id,source_member_id,point_kind,amount,source_point_id,generation) values(sponsor,source_member,'MTP',new.amount,new.id,1) on conflict do nothing;
   if found then insert into private.team_manager_balances(member_id,manager_track_points) values(sponsor,new.amount) on conflict(member_id) do update set manager_track_points=private.team_manager_balances.manager_track_points+excluded.manager_track_points,updated_at=now();end if;
  end if;
 end if;
 if new.point_type='GP' and not exists(select 1 from private.team_manager_qualifications where member_id=source_member) then
  select sponsor_id into ancestor from public.member_profiles where user_id=source_member;
  while ancestor is not null and depth<10 loop depth:=depth+1;
   if exists(select 1 from private.team_manager_qualifications where member_id=ancestor) then
    insert into public.manager_point_ledger(manager_id,source_member_id,point_kind,amount,source_point_id,generation) values(ancestor,source_member,'MNGP',new.amount,new.id,depth) on conflict do nothing;
    if found then insert into private.team_manager_balances(member_id,manager_network_generation_points) values(ancestor,new.amount) on conflict(member_id) do update set manager_network_generation_points=private.team_manager_balances.manager_network_generation_points+excluded.manager_network_generation_points,updated_at=now();end if;exit;
   end if;select sponsor_id into ancestor from public.member_profiles where user_id=ancestor;end loop;
 end if;
 perform private.refresh_leadership_rank(new.member_id);
 ancestor:=source_member;depth:=0;while ancestor is not null and depth<10 loop perform private.refresh_team_manager_qualification(ancestor);select sponsor_id into ancestor from public.member_profiles where user_id=ancestor;depth:=depth+1;end loop;
 return new;
end$$;
create trigger zz_manager_point_event after insert on public.point_ledger for each row execute function private.manager_point_event();

create or replace function public.my_manager_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid();m jsonb;b private.team_manager_balances%rowtype;q private.team_manager_qualifications%rowtype;r record;
begin if uid is null then raise exception 'Sign in required';end if;m:=private.team_manager_metrics(uid);select * into b from private.team_manager_balances where member_id=uid;select * into q from private.team_manager_qualifications where member_id=uid;select d.* into r from public.leadership_rank_definitions d join public.member_profiles p on p.achieved_rank=d.rank_code where p.user_id=uid;
 return m||jsonb_build_object('qualified',q.member_id is not null,'qualified_at',q.qualified_at,'manager_track_points',coalesce(b.manager_track_points,0),'manager_network_generation_points',coalesce(b.manager_network_generation_points,0),'leadership_rank',case when r.rank_code is null then null else jsonb_build_object('code',r.rank_code,'name',r.display_name,'theme',r.badge_theme) end,'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb));end$$;

alter function public.my_network(text,text,integer) rename to my_network_before_manager_badges;
revoke all on function public.my_network_before_manager_badges(text,text,integer) from public,anon,authenticated;
create or replace function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;nodes jsonb;
begin result:=public.my_network_before_manager_badges(p_kind,p_root_code,p_depth);
 select coalesce(jsonb_agg(n.node||jsonb_build_object('team_manager',q.member_id is not null,'rank_name',d.display_name,'rank_theme',d.badge_theme) order by n.ordinality),'[]'::jsonb) into nodes
 from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
 left join private.team_manager_qualifications q on q.member_id=nullif(n.node->>'id','')::uuid
 left join public.leadership_rank_definitions d on d.rank_code=n.node->>'rank';
 return jsonb_set(result,'{nodes}',nodes);end$$;
revoke all on function public.my_network(text,text,integer) from public,anon;
grant execute on function public.my_network(text,text,integer) to authenticated;

create or replace function public.admin_manager_program() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;return jsonb_build_object('rules',private.current_team_manager_rules(),'ranks',coalesce((select jsonb_agg(to_jsonb(r) order by sort_order) from public.leadership_rank_definitions r),'[]'::jsonb),'pending',coalesce((select jsonb_agg(jsonb_build_object('member_id',b.member_id,'member_code',m.member_code,'full_name',m.full_name,'mtp',b.manager_track_points,'mngp',b.manager_network_generation_points) order by m.member_code) from private.team_manager_balances b join public.member_profiles m on m.user_id=b.member_id where b.manager_track_points>0 or b.manager_network_generation_points>0),'[]'::jsonb));end$$;

create or replace function public.admin_set_team_manager_rules(p_rules jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cur jsonb:=private.current_team_manager_rules();v integer;n jsonb;
begin if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();if p_expected_version<>(cur->>'version')::integer then raise exception 'Rules changed. Refresh and try again';end if;
 n:=jsonb_build_object('enabled',coalesce((p_rules->>'enabled')::boolean,true),'minimum_package',p_rules->>'minimum_package','required_directs',(p_rules->>'required_directs')::integer,'required_direct_dp',(p_rules->>'required_direct_dp')::numeric,'required_tngp',(p_rules->>'required_tngp')::numeric,'required_qualified_lines',(p_rules->>'required_qualified_lines')::integer,'per_line_tngp',(p_rules->>'per_line_tngp')::numeric,'max_generations',(p_rules->>'max_generations')::integer,'track_rate',(p_rules->>'track_rate')::numeric,'network_rate',(p_rules->>'network_rate')::numeric);
 if private.package_weight(n->>'minimum_package')=0 or least((n->>'required_directs')::numeric,(n->>'required_direct_dp')::numeric,(n->>'required_tngp')::numeric,(n->>'required_qualified_lines')::numeric,(n->>'per_line_tngp')::numeric,(n->>'track_rate')::numeric,(n->>'network_rate')::numeric)<0 or (n->>'max_generations')::integer not between 1 and 10 or (n->>'track_rate')::numeric>1 or (n->>'network_rate')::numeric>1 then raise exception 'Invalid Team Manager rules';end if;
 v:=(cur->>'version')::integer+1;update public.system_config set effective_to=now() where config_key='TEAM_MANAGER_RULES' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('TEAM_MANAGER_RULES',v,n,auth.uid());return private.current_team_manager_rules();end$$;

create or replace function public.admin_upsert_leadership_rank(p_rank jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare code text:=lower(regexp_replace(trim(p_rank->>'rank_code'),'[^a-z0-9]+','_','g'));
begin if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 insert into public.leadership_rank_definitions(rank_code,display_name,sort_order,left_brp,right_brp,direct_left,direct_right,required_dp,badge_theme,active) values(code,trim(p_rank->>'display_name'),(p_rank->>'sort_order')::integer,(p_rank->>'left_brp')::numeric,(p_rank->>'right_brp')::numeric,(p_rank->>'direct_left')::integer,(p_rank->>'direct_right')::integer,(p_rank->>'required_dp')::numeric,coalesce(p_rank->>'badge_theme','emerald'),coalesce((p_rank->>'active')::boolean,true)) on conflict(rank_code) do update set display_name=excluded.display_name,sort_order=excluded.sort_order,left_brp=excluded.left_brp,right_brp=excluded.right_brp,direct_left=excluded.direct_left,direct_right=excluded.direct_right,required_dp=excluded.required_dp,badge_theme=excluded.badge_theme,active=excluded.active,updated_at=now();return (select to_jsonb(r) from public.leadership_rank_definitions r where rank_code=code);end$$;

-- Manager bonuses are funded by their accumulated audited point ledger, not a sale event.
alter table public.bonus_transactions drop constraint if exists bonus_source_check;
alter table public.bonus_transactions add constraint bonus_source_check check((method='binary_pool_share' and cycle_id is not null and num_nonnulls(source_activation_id,source_order_id)=0) or (method='team_manager' and cycle_id is null and num_nonnulls(source_activation_id,source_order_id)=0) or (method not in('binary_pool_share','team_manager') and cycle_id is null and num_nonnulls(source_activation_id,source_order_id)=1));
do $$declare f text;begin f:=pg_get_functiondef('private.guard_bonus_funding()'::regprocedure);f:=replace(f,'if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;if new.payable_amount<0 then raise exception ''Negative bonus is invalid'';end if;','if exists(select 1 from public.bonus_transactions where idempotency_key=new.idempotency_key) then return new;end if;if new.payable_amount<0 then raise exception ''Negative bonus is invalid'';end if;if new.method=''team_manager'' then return new;end if;');execute f;end$$;

alter table public.mio_ledger add column if not exists manager_distribution_id uuid references public.manager_bonus_distributions(id);
alter table public.mio_ledger drop constraint if exists mio_ledger_activation_source_check;
alter table public.mio_ledger add constraint mio_ledger_activation_source_check check(
 (action='package_activation' and activation_id is not null and num_nonnulls(cycle_id,source_order_id,manager_distribution_id)=0) or
 (action='bonus_credit' and num_nonnulls(activation_id,cycle_id,source_order_id,manager_distribution_id)=1) or
 (action in('affiliate_order_hold','affiliate_order_refund') and source_order_id is not null and activation_id is null and cycle_id is null and manager_distribution_id is null) or
 (action not in('package_activation','bonus_credit','affiliate_order_hold','affiliate_order_refund') and num_nonnulls(activation_id,cycle_id,source_order_id,manager_distribution_id)=0));

create or replace function public.admin_distribute_manager_bonus(p_idempotency_key text) returns jsonb language plpgsql security definer set search_path='' as $$
declare r record;rules jsonb:=private.current_team_manager_rules();cycle uuid;tx uuid;dist uuid;amount numeric;cnt integer:=0;tm numeric:=0;ng numeric:=0;total numeric:=0;
begin if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();if nullif(trim(p_idempotency_key),'') is null then raise exception 'Distribution key required';end if;perform pg_advisory_xact_lock(hashtextextended('manager-bonus-distribution',0));select id into cycle from public.manager_bonus_cycles where idempotency_key=p_idempotency_key;if cycle is not null then return jsonb_build_object('cycle_id',cycle,'duplicate',true);end if;
 insert into public.manager_bonus_cycles(idempotency_key,distributed_by) values(trim(p_idempotency_key),auth.uid()) returning id into cycle;
 for r in select b.*,m.member_code from private.team_manager_balances b join public.member_profiles m on m.user_id=b.member_id where b.manager_track_points>0 or b.manager_network_generation_points>0 for update of b loop
  amount:=round(r.manager_track_points*(rules->>'track_rate')::numeric+r.manager_network_generation_points*(rules->>'network_rate')::numeric,8);if amount<=0 then continue;end if;
  insert into public.manager_bonus_distributions(cycle_id,member_id,mtp,mngp,track_rate,network_rate,amount) values(cycle,r.member_id,r.manager_track_points,r.manager_network_generation_points,(rules->>'track_rate')::numeric,(rules->>'network_rate')::numeric,amount) returning id into dist;
  insert into public.mio_wallet_accounts(member_id,balance) values(r.member_id,amount) on conflict(member_id) do update set balance=public.mio_wallet_accounts.balance+excluded.balance,updated_at=now();
  insert into public.bonus_transactions(beneficiary_id,method,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,status,idempotency_key) values(r.member_id,'team_manager',r.manager_track_points+r.manager_network_generation_points,null,amount,amount,'MIO','team-manager-v1',jsonb_build_object('bonus_component','team_manager','manager_track_points',r.manager_track_points,'manager_network_generation_points',r.manager_network_generation_points,'track_rate',rules->>'track_rate','network_rate',rules->>'network_rate','cycle_id',cycle),'posted','manager-bonus:'||cycle||':'||r.member_id) returning id into tx;
  update public.manager_bonus_distributions set bonus_transaction_id=tx where id=dist;
  insert into public.mio_ledger(member_id,amount,action,bonus_transaction_id,manager_distribution_id,reason,idempotency_key) values(r.member_id,amount,'bonus_credit',tx,dist,'Team Manager bonus distribution','manager-mio:'||dist);
  update private.team_manager_balances set manager_track_points=0,manager_network_generation_points=0,updated_at=now() where member_id=r.member_id;cnt:=cnt+1;tm:=tm+r.manager_track_points;ng:=ng+r.manager_network_generation_points;total:=total+amount;
 end loop;update public.manager_bonus_cycles set manager_count=cnt,total_mtp=tm,total_mngp=ng,total_mio=total where id=cycle;return jsonb_build_object('cycle_id',cycle,'duplicate',false,'manager_count',cnt,'total_mtp',tm,'total_mngp',ng,'total_mio',total);end$$;

create or replace function private.default_bonus_wallet_routes() returns jsonb language sql immutable set search_path='' as $$select jsonb_build_object('direct_sponsor','cash','welcome_bonus','cash','generation','proceed','binary_placement','proceed','binary_pool_share','proceed','team_manager','proceed','ecommerce_cashback','cash','ecommerce_affiliate_level1','cash','ecommerce_level2','proceed','vendor_introducer','proceed')$$;

revoke all on function private.current_team_manager_rules(),private.package_weight(text),private.team_manager_metrics(uuid),private.refresh_team_manager_qualification(uuid),private.rank_metrics(uuid),private.refresh_leadership_rank(uuid),private.manager_point_event() from public,anon,authenticated;
revoke all on function public.my_manager_status(),public.admin_manager_program(),public.admin_set_team_manager_rules(jsonb,integer),public.admin_upsert_leadership_rank(jsonb),public.admin_distribute_manager_bonus(text) from public,anon;
grant execute on function public.my_manager_status(),public.admin_manager_program(),public.admin_set_team_manager_rules(jsonb,integer),public.admin_upsert_leadership_rank(jsonb),public.admin_distribute_manager_bonus(text) to authenticated;
-- Manual rank assignment is retired; achievements are produced only by verified metrics.
revoke all on function public.admin_set_member_rank(text,text) from public,anon,authenticated;

-- Re-evaluate existing members without back-paying historical manager points.
do $$declare m record;begin for m in select user_id from public.member_profiles loop perform private.refresh_team_manager_qualification(m.user_id);perform private.refresh_leadership_rank(m.user_id);end loop;end$$;
notify pgrst,'reload schema';
