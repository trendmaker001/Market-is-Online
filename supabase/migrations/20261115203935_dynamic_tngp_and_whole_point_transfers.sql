-- Generation 1 is DP-only. TNGP uses the full GP of generations 2..network limit.
-- Capture the previous derived values before replacing functions. No financial ledger is rewritten.
create temporary table mio_tngp_before on commit drop as
with recursive d(owner,id,depth,path) as (
 select m.sponsor_id,m.user_id,1,array[m.sponsor_id,m.user_id] from public.member_profiles m where m.sponsor_id is not null
 union all select d.owner,m.user_id,d.depth+1,d.path||m.user_id
 from d join public.member_profiles m on m.sponsor_id=d.id
 where d.depth<10 and not m.user_id=any(d.path)
), old_gp as (
 select d.owner,sum(a.gp) gp from d join public.package_activations a on a.member_id=d.id and a.status='approved'
 where coalesce(a.activated_at,a.requested_at)>private.financial_reset_at() group by d.owner
)
select m.user_id,coalesce(g.gp,0)+coalesce(b.tngp_offset,0) dashboard_tngp,
 (private.team_manager_metrics(m.user_id)->>'tngp')::numeric manager_tngp,
 (select total_dp from private.direct_dp_summary(m.user_id)) direct_dp
from public.member_profiles m left join old_gp g on g.owner=m.user_id
left join private.member_admin_baselines b on b.member_id=m.user_id;

create or replace function private.network_generation_limit(p_config jsonb default null)
returns integer language sql stable security definer set search_path='' as $$
 select greatest(1,least(30,coalesce(max((value->>'max_generations')::integer),1)))
 from jsonb_each(coalesce(p_config,private.current_mlm_rules())->'plans');
$$;
revoke all on function private.network_generation_limit(jsonb) from public,anon,authenticated;

create or replace function private.network_generation_line_points(p_member uuid)
returns table(root_id uuid,gp numeric) language sql stable security definer set search_path='' as $$
 with recursive d(id,root_id,depth,path) as (
  select m.user_id,m.user_id,1,array[p_member,m.user_id] from public.member_profiles m where m.sponsor_id=p_member
  union all select m.user_id,d.root_id,d.depth+1,d.path||m.user_id
  from d join public.member_profiles m on m.sponsor_id=d.id
  where d.depth<private.network_generation_limit() and not m.user_id=any(d.path)
 )
 select d.root_id,coalesce(sum(a.gp),0)::numeric
 from d left join public.package_activations a on a.member_id=d.id and a.status='approved'
  and d.depth>=2 and coalesce(a.activated_at,a.requested_at)>private.financial_reset_at()
 group by d.root_id;
$$;
revoke all on function private.network_generation_line_points(uuid) from public,anon,authenticated;

create or replace function private.member_tngp(p_member uuid)
returns numeric language sql stable security definer set search_path='' as $$
 select coalesce((select sum(gp) from private.network_generation_line_points(p_member)),0)
  +coalesce((select tngp_offset from private.member_admin_baselines where member_id=p_member),0);
$$;
revoke all on function private.member_tngp(uuid) from public,anon,authenticated;

alter table public.package_versions drop constraint package_versions_max_generations_check;
alter table public.package_versions add constraint package_versions_max_generations_check check(max_generations between 1 and 30);
CREATE OR REPLACE FUNCTION private.current_team_manager_rules()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select jsonb_build_object('version',version)||config_value||jsonb_build_object('max_generations',private.network_generation_limit()) from public.system_config where config_key='TEAM_MANAGER_RULES' and effective_from<=now() and (effective_to is null or effective_to>now()) order by version desc limit 1
$function$;
CREATE OR REPLACE FUNCTION public.my_generation_member_details(p_member_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 viewer_id uuid:=auth.uid();
 target_id uuid;
 cfg jsonb;
 target_code text;
 package_code text;
 package_name text;
 allowed_levels integer:=0;
 unlocked_levels integer:=0;
 v_active_directs integer:=0;
 v_working_dp numeric:=0;
 result jsonb;
begin
 if viewer_id is null or not private.registered_member(viewer_id) then
  raise exception 'Member account required';
 end if;

 target_code:='MIO-'||regexp_replace(upper(trim(coalesce(p_member_code,''))),'^MIO-','');
 select user_id into target_id from public.member_profiles where member_code=target_code;
 if target_id is null then raise exception 'Member not found'; end if;

 if not private.has_role('admin') and target_id<>viewer_id then
  if not exists(
   with recursive permitted(id,depth,path) as (
    select viewer_id,0,array[viewer_id]
    union all
    select m.user_id,p.depth+1,p.path||m.user_id
    from permitted p join public.member_profiles m on m.sponsor_id=p.id
    where p.depth<private.network_generation_limit() and not m.user_id=any(p.path)
   ) select 1 from permitted where id=target_id
  ) then raise exception 'Member is outside your permitted network'; end if;
 end if;

 cfg:=private.current_mlm_rules();
 package_code:=private.current_package_code(target_id);
 if package_code is not null then
  package_name:=coalesce(cfg->'plans'->package_code->>'display_name',package_code);
  allowed_levels:=coalesce((cfg->'plans'->package_code->>'max_generations')::integer,0);
  unlocked_levels:=private.generation_levels_by_dp(target_id,cfg);
 else
  package_name:='Free account';
 end if;
 select d.active_directs,d.total_dp into v_active_directs,v_working_dp from private.direct_dp_summary(target_id) d;

 with recursive descendants(id,parent_id,depth,path) as (
  select m.user_id,m.sponsor_id,1,array[target_id,m.user_id]
  from public.member_profiles m where m.sponsor_id=target_id
  union all
  select m.user_id,m.sponsor_id,d.depth+1,d.path||m.user_id
  from descendants d join public.member_profiles m on m.sponsor_id=d.id
  where d.depth<private.network_generation_limit(cfg) and not m.user_id=any(d.path)
 ), member_rows as (
  select d.depth,m.user_id,m.full_name,m.member_code,m.status,m.created_at,m.profile_photo_url,
   private.current_package_code(m.user_id) member_package
  from descendants d join public.member_profiles m on m.user_id=d.id
 ), generations as (
  select level,
   coalesce((select count(*) from member_rows r where r.depth=level),0)::integer member_count,
   coalesce((select jsonb_agg(jsonb_build_object(
    'id',r.user_id,'full_name',r.full_name,'member_code',r.member_code,'status',r.status,
    'joined_at',r.created_at,'profile_photo_url',r.profile_photo_url,'package',r.member_package
   ) order by r.created_at,r.member_code) from member_rows r where r.depth=level),'[]'::jsonb) members
  from generate_series(1,private.network_generation_limit(cfg)) level
 )
 select jsonb_build_object(
  'package_code',package_code,'package_name',package_name,
  'allowed_generations',allowed_levels,'active_generations',unlocked_levels,
  'direct_count',(select count(*) from member_rows where depth=1),
  'active_direct_count',coalesce(v_active_directs,0),'direct_points',coalesce(v_working_dp,0),
  'network_generation_limit',private.network_generation_limit(cfg),'tngp',private.member_tngp(target_id),'total_generation_network',(select count(*) from member_rows),
  'directs',coalesce((select members from generations where level=1),'[]'::jsonb),
  'generations',(select jsonb_agg(jsonb_build_object(
   'level',level,'member_count',member_count,'unlocked',level<=unlocked_levels,
   'allowed',level<=allowed_levels,'members',members
  ) order by level) from generations)
 ) into result;
 return result;
end;
$function$;
CREATE OR REPLACE FUNCTION private.team_manager_metrics(p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r jsonb:=private.current_team_manager_rules();
  directs integer:=0;
  dp numeric:=0;
  tngp numeric:=0;
  lines integer:=0;
  pkg text;
  earnings numeric:=private.member_total_earnings(p_member);
  earnings_progress numeric;
  qualified boolean;
  progress numeric;
  package_progress numeric:=0;
  directs_progress numeric:=0;
  dp_progress numeric:=0;
  tngp_progress numeric:=0;
  lines_progress numeric:=0;
  breakdown jsonb:='[]'::jsonb;
begin
  pkg:=private.current_package_code(p_member);
  select active_directs,total_dp into directs,dp from private.direct_dp_summary(p_member);

  with line_gp as (select * from private.network_generation_line_points(p_member))
  select coalesce(sum(gp),0),count(*) filter(where gp>=(r->>'per_line_tngp')::numeric)
  into tngp,lines from line_gp;

  tngp:=private.member_tngp(p_member);

  with line_gp as (select * from private.network_generation_line_points(p_member)),  live_lines as (
    select m.user_id,m.member_code,m.full_name,m.created_at,coalesce(g.gp,0) gp,
      row_number() over(order by m.created_at,m.user_id) position
    from public.member_profiles m left join line_gp g on g.root_id=m.user_id
    where m.sponsor_id=p_member
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'position',position,'member_id',user_id,'member_code',member_code,'full_name',full_name,
    'tngp',gp,'required_tngp',(r->>'per_line_tngp')::numeric,
    'progress_percent',least(100,round(100*gp/greatest((r->>'per_line_tngp')::numeric,1),2)),
    'qualified',gp>=(r->>'per_line_tngp')::numeric
  ) order by position),'[]'::jsonb) into breakdown from live_lines;

  package_progress:=least(100,round(100*private.package_weight(pkg)::numeric/greatest(private.package_weight(r->>'minimum_package'),1),2));
  directs_progress:=case when (r->>'required_directs')::numeric=0 then 100 else least(100,round(100*coalesce(directs,0)::numeric/greatest((r->>'required_directs')::numeric,1),2)) end;
  dp_progress:=case when (r->>'required_direct_dp')::numeric=0 then 100 else least(100,round(100*coalesce(dp,0)/greatest((r->>'required_direct_dp')::numeric,1),2)) end;
  tngp_progress:=case when (r->>'required_tngp')::numeric=0 then 100 else least(100,round(100*coalesce(tngp,0)/greatest((r->>'required_tngp')::numeric,1),2)) end;
  lines_progress:=case when (r->>'required_qualified_lines')::numeric=0 then 100 else least(100,round(100*coalesce(lines,0)::numeric/greatest((r->>'required_qualified_lines')::numeric,1),2)) end;
  earnings_progress:=case when (r->>'required_total_earnings')::numeric=0 then 100 else greatest(0,least(100,round(100*earnings/(r->>'required_total_earnings')::numeric,2))) end;
  progress:=round((package_progress+directs_progress+dp_progress+tngp_progress+lines_progress+earnings_progress)/6,2);
  qualified:=coalesce((r->>'enabled')::boolean,true)
    and private.package_weight(pkg)>=private.package_weight(r->>'minimum_package')
    and directs>=(r->>'required_directs')::integer
    and dp>=(r->>'required_direct_dp')::numeric
    and tngp>=(r->>'required_tngp')::numeric
    and lines>=(r->>'required_qualified_lines')::integer
    and earnings>=(r->>'required_total_earnings')::numeric;

  return jsonb_build_object(
    'total_earnings',earnings,'qualified_now',qualified,'package',pkg,'directs',coalesce(directs,0),
    'direct_dp',coalesce(dp,0),'tngp',coalesce(tngp,0),'qualified_lines',coalesce(lines,0),
    'progress_percent',coalesce(progress,0),'rules',r,'line_breakdown',breakdown,
    'criteria_progress',jsonb_build_object('package',package_progress,'directs',directs_progress,
      'direct_dp',dp_progress,'tngp',tngp_progress,'qualified_lines',lines_progress,'total_earnings',earnings_progress)
  );
end;
$function$;
CREATE OR REPLACE FUNCTION public.admin_set_team_manager_rules(p_rules jsonb, p_expected_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare cur jsonb:=private.current_team_manager_rules();v integer;n jsonb;badge text;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if p_expected_version<>(cur->>'version')::integer then raise exception 'Rules changed. Refresh and try again';end if;
 badge:=case when p_rules?'badge_url' then nullif(trim(p_rules->>'badge_url'),'') else nullif(trim(cur->>'badge_url'),'') end;
 if badge is not null and (length(badge)>2048 or badge !~ '^https://') then raise exception 'Invalid Team Manager badge URL';end if;
 n:=jsonb_build_object('enabled',coalesce((p_rules->>'enabled')::boolean,true),'minimum_package',p_rules->>'minimum_package','required_directs',(p_rules->>'required_directs')::integer,'required_direct_dp',(p_rules->>'required_direct_dp')::numeric,'required_tngp',(p_rules->>'required_tngp')::numeric,'required_qualified_lines',(p_rules->>'required_qualified_lines')::integer,'per_line_tngp',(p_rules->>'per_line_tngp')::numeric,'max_generations',private.network_generation_limit(),'track_rate',(p_rules->>'track_rate')::numeric,'network_rate',(p_rules->>'network_rate')::numeric,'badge_url',badge,'required_total_earnings',coalesce((p_rules->>'required_total_earnings')::numeric,(cur->>'required_total_earnings')::numeric,2000));
 if (n->>'required_total_earnings')::numeric < 0 or (n->>'required_total_earnings')::numeric >= 'Infinity'::numeric then raise exception 'Invalid total earnings requirement';end if;
 if private.package_weight(n->>'minimum_package')=0 or least((n->>'required_directs')::numeric,(n->>'required_direct_dp')::numeric,(n->>'required_tngp')::numeric,(n->>'required_qualified_lines')::numeric,(n->>'per_line_tngp')::numeric,(n->>'track_rate')::numeric,(n->>'network_rate')::numeric)<0 or (n->>'max_generations')::integer not between 1 and 30 or (n->>'track_rate')::numeric>1 or (n->>'network_rate')::numeric>1 then raise exception 'Invalid Team Manager rules';end if;
 v:=(cur->>'version')::integer+1;update public.system_config set effective_to=now() where config_key='TEAM_MANAGER_RULES' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('TEAM_MANAGER_RULES',v,n,auth.uid());return private.current_team_manager_rules();
end$function$;
CREATE OR REPLACE FUNCTION public.admin_save_plan(p_code text, p_plan jsonb, p_expected_version integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 cfg jsonb;v integer;old public.package_versions%rowtype;levels integer;sllevels integer;
 required_directs integer;required_dp numeric;rate numeric;tot numeric;key text;
 gplan numeric;bplan numeric;genbonus numeric;genmanager numeric;genglobal numeric;
 placement numeric;pool numeric;bmanager numeric;bglobal numeric;
 base numeric;fee_rate numeric;fee numeric;gross_ppv numeric;
begin
 if not private.has_role('admin') then raise exception 'Master account required';end if;
 perform private.require_recent_totp();
 perform pg_advisory_xact_lock(hashtextextended('edit-mlm-plans',0));
 cfg:=private.current_mlm_rules();v:=(cfg->>'version')::integer;
 if v<>p_expected_version then raise exception 'Plans changed. Reload before saving';end if;
 if p_code not in('BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM') or p_plan is null then raise exception 'Choose a valid plan';end if;

 foreach key in array array['generation_plan_rate','binary_plan_rate','generation_bonus_rate','generation_manager_rate','generation_global_rate','single_line_cap','binary_pool_rate','binary_manager_rate','binary_global_rate'] loop
  if jsonb_typeof(p_plan->key)<>'number' then raise exception 'Missing numeric budget: %',key;end if;
 end loop;
 gplan:=(p_plan->>'generation_plan_rate')::numeric;bplan:=(p_plan->>'binary_plan_rate')::numeric;
 genbonus:=(p_plan->>'generation_bonus_rate')::numeric;genmanager:=(p_plan->>'generation_manager_rate')::numeric;genglobal:=(p_plan->>'generation_global_rate')::numeric;
 placement:=(p_plan->>'single_line_cap')::numeric;pool:=(p_plan->>'binary_pool_rate')::numeric;bmanager:=(p_plan->>'binary_manager_rate')::numeric;bglobal:=(p_plan->>'binary_global_rate')::numeric;
 if least(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)<0 or greatest(gplan,bplan,genbonus,genmanager,genglobal,placement,pool,bmanager,bglobal)>1 then raise exception 'All percentages must be between 0 and 100';end if;
 if abs(gplan+bplan-1)>.000000001 then raise exception 'Generation Plan and Binary Plan must total exactly 100 percent';end if;
 if genbonus+genmanager+genglobal>1.000000001 then raise exception 'Generation breakdown exceeds 100 percent of GP';end if;
 if placement+pool+bmanager+bglobal>1.000000001 then raise exception 'Binary breakdown exceeds 100 percent of BP';end if;

 select * into old from public.package_versions where package_code=p_code and is_active order by version desc limit 1 for update;
 foreach key in array array['base_value','bv','dp','gp','bp','brp','direct_rate','binary_entitlement','max_generations','generation_required_directs','generation_required_dp','single_line_levels'] loop
  if jsonb_typeof(p_plan->key)<>'number' or not(p_plan ? key) then raise exception 'Missing numeric plan field: %',key;end if;
  rate:=(p_plan->>key)::numeric;if rate<0 or rate>1000000 then raise exception 'Invalid plan value: %',key;end if;
 end loop;
 base:=(p_plan->>'base_value')::numeric;
 fee_rate:=coalesce((p_plan->>'company_fee_rate')::numeric,(p_plan->>'company_fee')::numeric/nullif(base,0));
 if base<=0 or fee_rate<0 or fee_rate>1 then raise exception 'Base value and admin fee percentage are invalid';end if;
 fee:=round(base*fee_rate,4);gross_ppv:=round(base+fee,4);
 if (p_plan->>'bv')::numeric>base or (p_plan->>'bv')::numeric>gross_ppv or (p_plan->>'direct_rate')::numeric>1 or (p_plan->>'binary_entitlement')::numeric>1 then raise exception 'Plan points/rates exceed allowed funding';end if;
 if abs((p_plan->>'gp')::numeric-(p_plan->>'dp')::numeric*gplan)>.0001 or abs((p_plan->>'bp')::numeric-(p_plan->>'dp')::numeric*bplan)>.0001 then raise exception 'GP and BP must follow the configured DP plan split';end if;

 levels:=(p_plan->>'max_generations')::integer;sllevels:=(p_plan->>'single_line_levels')::integer;
 required_directs:=(p_plan->>'generation_required_directs')::integer;required_dp:=(p_plan->>'generation_required_dp')::numeric;
 if levels not between 1 and 30 or sllevels not between 1 and 30 or (p_plan->>'max_generations')::numeric<>levels or (p_plan->>'single_line_levels')::numeric<>sllevels then raise exception 'Generation limit 1–30; binary placement limit 1–30';end if;
 if required_directs not between 0 and 100 or (p_plan->>'generation_required_directs')::numeric<>required_directs or required_dp<0 then raise exception 'Generation qualification requires a whole direct-member count and non-negative DP';end if;
 if jsonb_typeof(p_plan->'generation_rates')<>'object' or jsonb_typeof(p_plan->'single_line_rates')<>'array' or jsonb_array_length(p_plan->'single_line_rates')<>sllevels then raise exception 'Enter all level rates';end if;
 tot:=0;for i in 2..levels loop if jsonb_typeof(p_plan->'generation_rates'->i::text)<>'number' then raise exception 'Missing generation rate';end if;rate:=(p_plan->'generation_rates'->>i::text)::numeric;if rate<0 or rate>1 then raise exception 'Generation rate must be 0–100 percent';end if;tot:=tot+rate;end loop;
 if tot>genbonus+.000000001 then raise exception 'Generation levels exceed the Generation bonus budget';end if;
 tot:=0;for r in 0..sllevels-1 loop rate:=(p_plan->'single_line_rates'->>r)::numeric;if rate is null or rate<0 or rate>1 then raise exception 'Invalid binary placement rate';end if;tot:=tot+rate;end loop;
 if tot>placement+.000000001 then raise exception 'Binary placement levels exceed their budget';end if;

 cfg:=cfg||jsonb_build_object('generation_plan_rate',gplan,'binary_plan_rate',bplan,'generation_bonus_rate',genbonus,'generation_manager_rate',genmanager,'generation_global_rate',genglobal,'single_line_cap',placement,'binary_pool_rate',pool,'binary_manager_rate',bmanager,'binary_global_rate',bglobal);
 update public.package_versions set is_active=false,effective_to=clock_timestamp() where package_code=p_code and is_active;
 insert into public.package_versions(package_code,version,display_name,base_value,company_fee,ppv,bv,dp,gp,bp,brp,max_generations,direct_rate,generation1_rate,binary_entitlement)
 values(p_code,old.version+1,old.display_name,base,fee,gross_ppv,(p_plan->>'bv')::numeric,(p_plan->>'dp')::numeric,(p_plan->>'gp')::numeric,(p_plan->>'bp')::numeric,(p_plan->>'brp')::numeric,levels,(p_plan->>'direct_rate')::numeric,(p_plan->>'direct_rate')::numeric,(p_plan->>'binary_entitlement')::numeric);
 select to_jsonb(p)||jsonb_build_object('company_fee_rate',fee_rate,'generation_rates',p_plan->'generation_rates','single_line_rates',p_plan->'single_line_rates','single_line_levels',sllevels,'generation_required_directs',required_directs,'generation_required_dp',required_dp)
 into p_plan from public.package_versions p where package_code=p_code and version=old.version+1;
 cfg:=jsonb_set(jsonb_set(cfg,array['plans',p_code],p_plan),'{version}',to_jsonb(v+1));
 update public.system_config set effective_to=clock_timestamp() where config_key='MLM_PLANS' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,created_by) values('MLM_PLANS',v+1,cfg,auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data)
 values(auth.uid(),'MLM_PLAN_VERSION_SAVED','package',jsonb_build_object('code',p_code,'version',v+1,'plan',p_plan,'gross_ppv_rule',true,'generation_plan',jsonb_build_object('split',gplan,'generation',genbonus,'manager',genmanager,'global',genglobal),'binary_plan',jsonb_build_object('split',bplan,'pool',pool,'placement',placement,'manager',bmanager,'global',bglobal)));
 return cfg;
end
$function$;
-- Derive graduated generation access from the same editable package qualification rules.
create or replace function private.generation_levels_by_dp(p_member uuid,p_cfg jsonb)
returns integer language sql stable security definer set search_path='' as $$
 with own_plan as (
  select coalesce((p_cfg->'plans'->coalesce(private.current_package_code(p_member),'BASIC_1')->>'max_generations')::integer,0) levels
 ), d as (select * from private.direct_dp_summary(p_member)), eligible as (
  select coalesce(max((p.value->>'max_generations')::integer),0) levels
  from jsonb_each(p_cfg->'plans') p cross join d
  where d.active_directs>=coalesce((p.value->>'generation_required_directs')::integer,ceil((p.value->>'max_generations')::numeric/2)::integer)
   and d.total_dp>=coalesce((p.value->>'generation_required_dp')::numeric,(p.value->>'max_generations')::numeric*10)
 ) select least(own_plan.levels,eligible.levels) from own_plan cross join eligible;
$$;
revoke all on function private.generation_levels_by_dp(uuid,jsonb) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.mlm_point_candidates(member uuid, dp_base numeric, gp_base numeric, cfg jsonb)
 RETURNS TABLE(beneficiary uuid, method bonus_method, depth integer, qualifying_base numeric, nominal numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with recursive up(id,sponsor,depth,path) as(
  select m.user_id,m.sponsor_id,0,array[m.user_id] from public.member_profiles m where m.user_id=member
  union all select m.user_id,m.sponsor_id,u.depth+1,u.path||m.user_id from up u join public.member_profiles m on m.user_id=u.sponsor
  where u.depth<private.network_generation_limit(cfg) and not m.user_id=any(u.path)
 ),resolved as(
  select u.*,cfg->'plans'->coalesce(private.current_package_code(u.id),'BASIC_1') plan,
   private.package_eligible(u.id) eligible,private.generation_levels_by_dp(u.id,cfg) open_levels
  from up u where depth>0 and private.registered_member(u.id)
 )
 select id,case when depth=1 then 'direct'::public.bonus_method else 'generation'::public.bonus_method end,depth,
  case when depth=1 then dp_base else gp_base end,
  case when depth=1 then dp_base*coalesce((plan->>'direct_rate')::numeric,0)
   else gp_base*coalesce((plan->'generation_rates'->>depth::text)::numeric,0) end
 from resolved where depth=1 or (eligible and private.maintenance_active(id) and depth<=open_levels);
$function$;
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
  if sponsor is not null and exists(select 1 from private.team_manager_qualifications where member_id=sponsor) and private.maintenance_active(sponsor) and not exists(select 1 from private.team_manager_qualifications where member_id=source_member) then
   insert into public.manager_point_ledger(manager_id,source_member_id,point_kind,amount,source_point_id,generation) values(sponsor,source_member,'MTP',new.amount,new.id,1) on conflict do nothing;
   if found then insert into private.team_manager_balances(member_id,manager_track_points) values(sponsor,new.amount) on conflict(member_id) do update set manager_track_points=private.team_manager_balances.manager_track_points+excluded.manager_track_points,updated_at=now();end if;
  end if;
 end if;
 if new.point_type='GP' and not exists(select 1 from private.team_manager_qualifications where member_id=source_member) then
  select sponsor_id into ancestor from public.member_profiles where user_id=source_member;
  while ancestor is not null and depth<10 loop depth:=depth+1;
   if exists(select 1 from private.team_manager_qualifications where member_id=ancestor) and private.maintenance_active(ancestor) then
    insert into public.manager_point_ledger(manager_id,source_member_id,point_kind,amount,source_point_id,generation) values(ancestor,source_member,'MNGP',new.amount,new.id,depth) on conflict do nothing;
    if found then insert into private.team_manager_balances(member_id,manager_network_generation_points) values(ancestor,new.amount) on conflict(member_id) do update set manager_network_generation_points=private.team_manager_balances.manager_network_generation_points+excluded.manager_network_generation_points,updated_at=now();end if;exit;
   end if;select sponsor_id into ancestor from public.member_profiles where user_id=ancestor;end loop;
 end if;
 perform private.refresh_leadership_rank(new.member_id);
 ancestor:=source_member;depth:=0;while ancestor is not null and depth<=private.network_generation_limit() loop perform private.refresh_team_manager_qualification(ancestor);select sponsor_id into ancestor from public.member_profiles where user_id=ancestor;depth:=depth+1;end loop;
 return new;
end$function$;
CREATE OR REPLACE FUNCTION private.exchange_move(p_kind text, p_recipient uuid, p_amount numeric, p_key text, p_note text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare sender uuid:=auth.uid(); dest uuid:=p_recipient; sp boolean; rp boolean; sw text; dw text; old private.exchange_transfers%rowtype; tx uuid:=gen_random_uuid(); cash numeric; bal numeric; locked uuid;
begin
 if sender is null then raise exception 'Authentication required';end if;
 if p_kind not in ('fund','cash_send','exchange_send') or p_kind is null then raise exception 'Invalid transfer type';end if;
 if p_amount is null or p_amount<1 or p_amount>1000000000 or p_amount<>trunc(p_amount) then raise exception 'Invalid MIO amount: enter whole points only';end if;
 if length(coalesce(p_key,''))<12 or length(p_key)>100 then raise exception 'Invalid idempotency key';end if;
 if length(coalesce(p_note,''))>300 then raise exception 'Note must be 300 characters or fewer';end if;
 if p_kind='fund' then dest:=sender;elsif dest is null or dest=sender then raise exception 'Choose another member';end if;
 perform pg_advisory_xact_lock(hashtextextended('mio-request:'||sender::text||':'||p_key,0));
 -- Lock identity rows in the same order for every route.
 for locked in select user_id from public.member_profiles where user_id in(sender,dest) order by user_id for share loop null;end loop;
 if not exists(select 1 from public.member_profiles where user_id=sender and status in ('active','inactive') and terms_accepted_at is not null)
 or not exists(select 1 from public.member_profiles where user_id=dest and status in ('active','inactive') and terms_accepted_at is not null) then raise exception 'Registered, unblocked accounts required';end if;
 sp:=coalesce(private.current_package_code(sender)='PREMIUM',false);
 rp:=coalesce(private.current_package_code(dest)='PREMIUM',false);
 if p_kind='fund' then
  if not sp then raise exception 'Exchange Wallet is available only to Platinum members';end if;sw:='cash';dw:='exchange';
 elsif p_kind='cash_send' then
  if sp then raise exception 'Platinum members must fund their Exchange Wallet first, then send from Exchange Wallet';end if;
  if not rp then raise exception 'Cash Wallet transfers are allowed only to a Platinum Exchange Wallet';end if;sw:='cash';dw:='exchange';
 else
  if not sp then raise exception 'Exchange Wallet is available only to Platinum members';end if;sw:='exchange';dw:=case when rp then 'exchange' else 'cash' end;
 end if;
 select * into old from private.exchange_transfers where actor_id=sender and idempotency_key=p_key;
 if found then
  if old.kind<>p_kind or old.recipient_id<>dest or old.amount<>p_amount or old.note<>coalesce(p_note,'') then raise exception 'This request key was already used for a different transfer';end if;
  return old.id;
 end if;
 -- Prevent old cash-transfer requests from being replayed after rollout.
 if exists(select 1 from public.mio_ledger where idempotency_key=sender::text||':'||p_key||':out') then raise exception 'This transfer request was already processed';end if;
 -- Cash rows first, then exchange rows, both in member order: atomic balance checks.
 for locked in select member_id from public.mio_wallet_accounts where member_id in(sender,dest) order by member_id for update loop null;end loop;
 if not exists(select 1 from public.mio_wallet_accounts where member_id=sender) or not exists(select 1 from public.mio_wallet_accounts where member_id=dest) then raise exception 'Cash Wallet is not initialized';end if;
 insert into private.exchange_wallet_accounts(member_id) select v from (values(sender),(dest)) x(v) where (v=sender and sp) or (v=dest and rp) group by v order by v on conflict do nothing;
 for locked in select member_id from private.exchange_wallet_accounts where member_id in(sender,dest) order by member_id for update loop null;end loop;
 if sw='cash' then
  select balance into cash from public.mio_wallet_accounts where member_id=sender;
  if cash<p_amount then raise exception 'Insufficient Cash Wallet balance';end if;
  update public.mio_wallet_accounts set balance=balance-p_amount,updated_at=now() where member_id=sender;
 else
  select balance into bal from private.exchange_wallet_accounts where member_id=sender;
  if bal is null or bal<p_amount then raise exception 'Insufficient Exchange Wallet balance';end if;
  update private.exchange_wallet_accounts set balance=balance-p_amount,updated_at=now() where member_id=sender;
 end if;
 if dw='cash' then update public.mio_wallet_accounts set balance=balance+p_amount,updated_at=now() where member_id=dest;
 else update private.exchange_wallet_accounts set balance=balance+p_amount,updated_at=now() where member_id=dest;end if;
 insert into private.exchange_transfers(id,actor_id,recipient_id,source_wallet,destination_wallet,kind,amount,note,idempotency_key) values(tx,sender,dest,sw,dw,p_kind,p_amount,coalesce(p_note,''),p_key);
 if sw='cash' then insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,reason,idempotency_key) values(sender,-p_amount,'transfer_out',dest,tx,case when p_kind='fund' then 'Cash to own Exchange Wallet' else 'Cash to Platinum Exchange Wallet' end,sender::text||':'||p_key||':out');end if;
 if dw='cash' then insert into public.mio_ledger(member_id,amount,action,counterparty_id,transfer_id,reason,idempotency_key) values(dest,p_amount,'transfer_in',sender,tx,'Received from Platinum Exchange Wallet',sender::text||':'||p_key||':in');end if;
 return tx;
end $function$;

-- Record changed projections for review while retaining original DP, balances and paid bonuses.
insert into public.audit_logs(action,entity_type,entity_id,before_data,after_data)
select 'TNGP_GENERATION_RANGE_CORRECTED','member',b.user_id,
 jsonb_build_object('dashboard_tngp',b.dashboard_tngp,'manager_tngp',b.manager_tngp,'direct_dp',b.direct_dp),
 jsonb_build_object('dashboard_tngp',private.member_tngp(b.user_id),'manager_tngp',private.team_manager_metrics(b.user_id)->'tngp',
 'direct_dp',(select total_dp from private.direct_dp_summary(b.user_id)),'generation_from',2,'generation_to',private.network_generation_limit(),
 'reason','Direct generation GP excluded; full eligible GP retained; paid bonuses unchanged')
from mio_tngp_before b
where b.dashboard_tngp is distinct from private.member_tngp(b.user_id)
 or b.manager_tngp is distinct from (private.team_manager_metrics(b.user_id)->>'tngp')::numeric;
do $$begin
 if exists(select 1 from mio_tngp_before b where b.direct_dp is distinct from (select total_dp from private.direct_dp_summary(b.user_id))) then
 raise exception 'TNGP correction must not change DP';end if;
end$$;
