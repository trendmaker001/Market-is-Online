-- Qualification uses the same posted earnings sources as the main dashboard.
-- Existing earned ranks/manager qualifications are permanent and are not revoked.
begin;
alter table public.leadership_rank_definitions
 add column minimum_package text not null default 'PREMIUM' check (minimum_package in ('ADVANCED_2','PREMIUM')),
 add column required_total_earnings numeric(20,4) not null default 10000 check (required_total_earnings >= 0 and required_total_earnings < 'Infinity'::numeric);
update public.leadership_rank_definitions set
 minimum_package=case when rank_code='leader' then 'ADVANCED_2' else 'PREMIUM' end,
 required_total_earnings=case rank_code when 'leader' then 1000 when 'team_leader' then 2000 when 'senior_team_leader' then 3000 when 'executive' then 4000 when 'senior_executive' then 5000 when 'director' then 6000 else 10000 end;
-- Version the manager setting without losing the previous configuration.
do $$ declare r jsonb:=private.current_team_manager_rules(); begin
 update public.system_config set effective_to=now() where config_key='TEAM_MANAGER_RULES' and effective_to is null;
 insert into public.system_config(config_key,version,config_value)
 values('TEAM_MANAGER_RULES',(r->>'version')::integer+1,(r-'version')||jsonb_build_object('required_total_earnings',2000));
end $$;
create or replace function private.member_total_earnings(p_member uuid) returns numeric
language sql stable security definer set search_path='' as $$
 select coalesce((select sum(payable_amount) from public.bonus_transactions where beneficiary_id=p_member and status='posted'),0)
 +coalesce((select sum(amount_mio) from public.maintenance_generation_payouts where beneficiary_id=p_member),0)
 +coalesce((select sum(amount) from public.member_opening_earnings where member_id=p_member),0)
$$;
revoke all on function private.member_total_earnings(uuid) from public,anon,authenticated;
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

  with recursive d(id,root_id,depth,path) as (
    select m.user_id,m.user_id,1,array[p_member,m.user_id]
    from public.member_profiles m where m.sponsor_id=p_member
    union all
    select m.user_id,d.root_id,d.depth+1,d.path||m.user_id
    from d join public.member_profiles m on m.sponsor_id=d.id
    where d.depth<(r->>'max_generations')::integer and not m.user_id=any(d.path)
  ), line_gp as (
    select root_id,coalesce(sum(a.gp),0) gp
    from d left join public.package_activations a on a.member_id=d.id and a.status='approved'
    group by root_id
  )
  select coalesce(sum(gp),0),count(*) filter(where gp>=(r->>'per_line_tngp')::numeric)
  into tngp,lines from line_gp;

  with recursive d(id,root_id,depth,path) as (
    select m.user_id,m.user_id,1,array[p_member,m.user_id]
    from public.member_profiles m where m.sponsor_id=p_member
    union all
    select m.user_id,d.root_id,d.depth+1,d.path||m.user_id
    from d join public.member_profiles m on m.sponsor_id=d.id
    where d.depth<(r->>'max_generations')::integer and not m.user_id=any(d.path)
  ), line_gp as (
    select root_id,coalesce(sum(a.gp),0) gp
    from d left join public.package_activations a on a.member_id=d.id and a.status='approved'
    group by root_id
  ), live_lines as (
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
CREATE OR REPLACE FUNCTION private.rank_metrics(p_member uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with recursive downline(id,root_side,path) as(
  select b.member_id,b.side,array[p_member,b.member_id] from public.binary_placements b where b.parent_id=p_member
  union all select b.member_id,d.root_side,d.path||b.member_id from downline d join public.binary_placements b on b.parent_id=d.id where not b.member_id=any(d.path)
 ),sides as(select d.root_side,count(*) filter(where m.sponsor_id=p_member and m.status='active') directs from downline d join public.member_profiles m on m.user_id=d.id group by d.root_side),brp as(
  select coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='LEFT'),0) l,coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='RIGHT'),0) r from public.point_ledger where member_id=p_member and point_type='BRP'
 ),dp as(select total_dp from private.direct_dp_summary(p_member))
 select jsonb_build_object('package',private.current_package_code(p_member),'total_earnings',private.member_total_earnings(p_member),'left_brp',brp.l,'right_brp',brp.r,'direct_left',coalesce((select directs from sides where root_side='LEFT'),0),'direct_right',coalesce((select directs from sides where root_side='RIGHT'),0),'direct_dp',coalesce(dp.total_dp,0)) from brp,dp
$function$;
CREATE OR REPLACE FUNCTION private.refresh_leadership_rank(p_member uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m jsonb;r record;top_code text;top_order integer:=0;
begin m:=private.rank_metrics(p_member);for r in select * from public.leadership_rank_definitions where active order by sort_order loop
 if (m->>'left_brp')::numeric>=r.left_brp and (m->>'right_brp')::numeric>=r.right_brp and (m->>'direct_left')::integer>=r.direct_left and (m->>'direct_right')::integer>=r.direct_right and (m->>'direct_dp')::numeric>=r.required_dp and private.package_weight(m->>'package')>=private.package_weight(r.minimum_package) and (m->>'total_earnings')::numeric>=r.required_total_earnings then
  insert into public.member_rank_history(member_id,rank_code,metrics) values(p_member,r.rank_code,m) on conflict do nothing;top_code:=r.rank_code;top_order:=r.sort_order;
 end if;end loop;
 if top_code is not null and coalesce((select sort_order from public.leadership_rank_definitions where rank_code=(select achieved_rank from public.member_profiles where user_id=p_member)),0)<=top_order then update public.member_profiles set achieved_rank=top_code,updated_at=now() where user_id=p_member and achieved_rank is distinct from top_code;end if;return top_code;
end$function$;
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
    'qualified',q.member_id is not null,'qualified_at',q.qualified_at,'tree_available',q.member_id is not null,
    'team_manager_badge_url',m->'rules'->>'badge_url',
    'manager_track_points',coalesce(b.manager_track_points,0),
    'manager_network_generation_points',coalesce(b.manager_network_generation_points,0),
    'leadership_rank',case when r.rank_code is null then null else jsonb_build_object('code',r.rank_code,'name',r.display_name,'theme',r.badge_theme,'badge_url',r.badge_url) end,
    'manager_direct_points',coalesce(b.manager_track_points,0),
    'rank_qualification',jsonb_build_object('metrics',private.rank_metrics(uid),'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'sort_order',d.sort_order,'theme',d.badge_theme,'badge_url',d.badge_url,'left_brp',d.left_brp,'right_brp',d.right_brp,'direct_left',d.direct_left,'direct_right',d.direct_right,'required_dp',d.required_dp,'minimum_package',d.minimum_package,'required_total_earnings',d.required_total_earnings) order by d.sort_order,d.rank_code) from public.leadership_rank_definitions d where d.active),'[]'::jsonb)),
    'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'badge_url',d.badge_url,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb)
  );
end;
$function$;
CREATE OR REPLACE FUNCTION private.support_manager_status(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=p_member_id;m jsonb;b private.team_manager_balances%rowtype;q private.team_manager_qualifications%rowtype;r record;
begin
  if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
  if uid is null then raise exception 'Sign in required';end if;
  m:=private.team_manager_metrics(uid);
  select * into b from private.team_manager_balances where member_id=uid;
  select * into q from private.team_manager_qualifications where member_id=uid;
  select d.* into r from public.leadership_rank_definitions d join public.member_profiles p on p.achieved_rank=d.rank_code where p.user_id=uid;
  return m||jsonb_build_object(
    'qualified',q.member_id is not null,'qualified_at',q.qualified_at,'tree_available',q.member_id is not null,
    'team_manager_badge_url',m->'rules'->>'badge_url',
    'manager_track_points',coalesce(b.manager_track_points,0),
    'manager_network_generation_points',coalesce(b.manager_network_generation_points,0),
    'leadership_rank',case when r.rank_code is null then null else jsonb_build_object('code',r.rank_code,'name',r.display_name,'theme',r.badge_theme,'badge_url',r.badge_url) end,
    'manager_direct_points',coalesce(b.manager_track_points,0),
    'rank_qualification',jsonb_build_object('metrics',private.rank_metrics(uid),'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'sort_order',d.sort_order,'theme',d.badge_theme,'badge_url',d.badge_url,'left_brp',d.left_brp,'right_brp',d.right_brp,'direct_left',d.direct_left,'direct_right',d.direct_right,'required_dp',d.required_dp,'minimum_package',d.minimum_package,'required_total_earnings',d.required_total_earnings) order by d.sort_order,d.rank_code) from public.leadership_rank_definitions d where d.active),'[]'::jsonb)),
    'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'badge_url',d.badge_url,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb)
  );
end;
$function$;

revoke all on function private.support_manager_status(uuid) from public,anon,authenticated;

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
 n:=jsonb_build_object('enabled',coalesce((p_rules->>'enabled')::boolean,true),'minimum_package',p_rules->>'minimum_package','required_directs',(p_rules->>'required_directs')::integer,'required_direct_dp',(p_rules->>'required_direct_dp')::numeric,'required_tngp',(p_rules->>'required_tngp')::numeric,'required_qualified_lines',(p_rules->>'required_qualified_lines')::integer,'per_line_tngp',(p_rules->>'per_line_tngp')::numeric,'max_generations',(p_rules->>'max_generations')::integer,'track_rate',(p_rules->>'track_rate')::numeric,'network_rate',(p_rules->>'network_rate')::numeric,'badge_url',badge,'required_total_earnings',coalesce((p_rules->>'required_total_earnings')::numeric,(cur->>'required_total_earnings')::numeric,2000));
 if (n->>'required_total_earnings')::numeric < 0 or (n->>'required_total_earnings')::numeric >= 'Infinity'::numeric then raise exception 'Invalid total earnings requirement';end if;
 if private.package_weight(n->>'minimum_package')=0 or least((n->>'required_directs')::numeric,(n->>'required_direct_dp')::numeric,(n->>'required_tngp')::numeric,(n->>'required_qualified_lines')::numeric,(n->>'per_line_tngp')::numeric,(n->>'track_rate')::numeric,(n->>'network_rate')::numeric)<0 or (n->>'max_generations')::integer not between 1 and 10 or (n->>'track_rate')::numeric>1 or (n->>'network_rate')::numeric>1 then raise exception 'Invalid Team Manager rules';end if;
 v:=(cur->>'version')::integer+1;update public.system_config set effective_to=now() where config_key='TEAM_MANAGER_RULES' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('TEAM_MANAGER_RULES',v,n,auth.uid());return private.current_team_manager_rules();
end$function$;
CREATE OR REPLACE FUNCTION public.admin_upsert_leadership_rank(p_rank jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare code text:=lower(regexp_replace(trim(p_rank->>'rank_code'),'[^a-z0-9]+','_','g'));badge text;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 badge:=case when p_rank?'badge_url' then nullif(trim(p_rank->>'badge_url'),'') else (select badge_url from public.leadership_rank_definitions where rank_code=code) end;
 if badge is not null and (length(badge)>2048 or badge !~ '^https://') then raise exception 'Invalid rank badge URL';end if;
 insert into public.leadership_rank_definitions(rank_code,display_name,sort_order,left_brp,right_brp,direct_left,direct_right,required_dp,badge_theme,badge_url,active,minimum_package,required_total_earnings)
 values(code,trim(p_rank->>'display_name'),(p_rank->>'sort_order')::integer,(p_rank->>'left_brp')::numeric,(p_rank->>'right_brp')::numeric,(p_rank->>'direct_left')::integer,(p_rank->>'direct_right')::integer,(p_rank->>'required_dp')::numeric,coalesce(p_rank->>'badge_theme','emerald'),badge,coalesce((p_rank->>'active')::boolean,true),coalesce(p_rank->>'minimum_package',(select minimum_package from public.leadership_rank_definitions where rank_code=code),'PREMIUM'),coalesce((p_rank->>'required_total_earnings')::numeric,(select required_total_earnings from public.leadership_rank_definitions where rank_code=code),10000))
 on conflict(rank_code) do update set display_name=excluded.display_name,sort_order=excluded.sort_order,left_brp=excluded.left_brp,right_brp=excluded.right_brp,direct_left=excluded.direct_left,direct_right=excluded.direct_right,required_dp=excluded.required_dp,badge_theme=excluded.badge_theme,badge_url=excluded.badge_url,active=excluded.active,minimum_package=excluded.minimum_package,required_total_earnings=excluded.required_total_earnings,updated_at=now();
 return (select to_jsonb(r) from public.leadership_rank_definitions r where rank_code=code);
end$function$;

-- Re-evaluate after committed earning changes, including admin opening earnings.
-- Deferred triggers see the complete transaction, not intermediate ledger values.
create or replace function private.refresh_earning_qualification() returns trigger
language plpgsql security definer set search_path='' as $$
declare old_id uuid;new_id uuid;who uuid;
begin
 if TG_OP<>'INSERT' then old_id:=coalesce((to_jsonb(old)->>'beneficiary_id')::uuid,(to_jsonb(old)->>'member_id')::uuid);end if;
 if TG_OP<>'DELETE' then new_id:=coalesce((to_jsonb(new)->>'beneficiary_id')::uuid,(to_jsonb(new)->>'member_id')::uuid);end if;
 for who in select distinct x from unnest(array[old_id,new_id]) x where x is not null order by x loop
  if exists(select 1 from public.member_profiles where user_id=who) then
   perform pg_advisory_xact_lock(hashtextextended('qualification:'||who::text,0));
   perform private.refresh_team_manager_qualification(who);
   perform private.refresh_leadership_rank(who);
  end if;
 end loop;
 return null;
end $$;
revoke all on function private.refresh_earning_qualification() from public,anon,authenticated;
create constraint trigger qualification_from_bonus after insert or update or delete on public.bonus_transactions
 deferrable initially deferred for each row execute function private.refresh_earning_qualification();
create constraint trigger qualification_from_maintenance after insert or update or delete on public.maintenance_generation_payouts
 deferrable initially deferred for each row execute function private.refresh_earning_qualification();
create constraint trigger qualification_from_opening after insert or update or delete on public.member_opening_earnings
 deferrable initially deferred for each row execute function private.refresh_earning_qualification();
create constraint trigger qualification_from_package after insert or update or delete on public.package_activations
 deferrable initially deferred for each row execute function private.refresh_earning_qualification();
-- Admin edits must take effect without waiting for a new purchase or bonus.
create or replace function private.refresh_qualification_rules() returns trigger
language plpgsql security definer set search_path='' as $$
declare who uuid;
begin
 for who in select user_id from public.member_profiles order by user_id loop
  perform private.refresh_team_manager_qualification(who);
  perform private.refresh_leadership_rank(who);
 end loop;
 return null;
end $$;
revoke all on function private.refresh_qualification_rules() from public,anon,authenticated;
create trigger qualification_rank_rules after insert or update on public.leadership_rank_definitions
 for each statement execute function private.refresh_qualification_rules();
create trigger qualification_manager_rules after insert on public.system_config
 for each row when (new.config_key='TEAM_MANAGER_RULES') execute function private.refresh_qualification_rules();
-- Apply to existing accounts without rewriting any historical earning or award.
do $$ declare who uuid;begin
 for who in select user_id from public.member_profiles order by user_id loop
  perform private.refresh_team_manager_qualification(who);perform private.refresh_leadership_rank(who);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
