-- Mandatory member country identity and a qualified Team Manager breakaway tree.

create or replace function private.team_manager_metrics(p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  r jsonb:=private.current_team_manager_rules();
  directs integer:=0;
  dp numeric:=0;
  tngp numeric:=0;
  lines integer:=0;
  pkg text;
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
  directs_progress:=least(100,round(100*coalesce(directs,0)::numeric/greatest((r->>'required_directs')::numeric,1),2));
  dp_progress:=least(100,round(100*coalesce(dp,0)/greatest((r->>'required_direct_dp')::numeric,1),2));
  tngp_progress:=least(100,round(100*coalesce(tngp,0)/greatest((r->>'required_tngp')::numeric,1),2));
  lines_progress:=least(100,round(100*coalesce(lines,0)::numeric/greatest((r->>'required_qualified_lines')::numeric,1),2));
  progress:=round((package_progress+directs_progress+dp_progress+tngp_progress+lines_progress)/5,2);
  qualified:=coalesce((r->>'enabled')::boolean,true)
    and private.package_weight(pkg)>=private.package_weight(r->>'minimum_package')
    and directs>=(r->>'required_directs')::integer
    and dp>=(r->>'required_direct_dp')::numeric
    and tngp>=(r->>'required_tngp')::numeric
    and lines>=(r->>'required_qualified_lines')::integer;

  return jsonb_build_object(
    'qualified_now',qualified,'package',pkg,'directs',coalesce(directs,0),
    'direct_dp',coalesce(dp,0),'tngp',coalesce(tngp,0),'qualified_lines',coalesce(lines,0),
    'progress_percent',coalesce(progress,0),'rules',r,'line_breakdown',breakdown,
    'criteria_progress',jsonb_build_object('package',package_progress,'directs',directs_progress,
      'direct_dp',dp_progress,'tngp',tngp_progress,'qualified_lines',lines_progress)
  );
end;
$$;

create or replace function public.my_manager_status()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
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
    'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'badge_url',d.badge_url,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb)
  );
end;
$$;

create or replace function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare result jsonb;nodes jsonb;manager_badge text;
begin
  result:=public.my_network_before_manager_badges(p_kind,p_root_code,p_depth);
  manager_badge:=private.current_team_manager_rules()->>'badge_url';
  select coalesce(jsonb_agg(n.node||jsonb_build_object(
    'country_code',p.country_code,'team_manager',q.member_id is not null,'manager_badge_url',manager_badge,
    'rank_name',d.display_name,'rank_theme',d.badge_theme,'rank_badge_url',d.badge_url
  ) order by n.ordinality),'[]'::jsonb) into nodes
  from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
  left join public.member_profiles p on p.user_id=nullif(n.node->>'id','')::uuid
  left join private.team_manager_qualifications q on q.member_id=p.user_id
  left join public.leadership_rank_definitions d on d.rank_code=n.node->>'rank';
  return jsonb_set(result,'{nodes}',nodes);
end;
$$;

create or replace function public.my_manager_tree(p_depth integer default 10)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  rules jsonb:=private.current_team_manager_rules();
  max_depth integer;
  source jsonb;
  nodes jsonb;
begin
  if uid is null then raise exception 'Sign in required';end if;
  if not exists(select 1 from private.team_manager_qualifications where member_id=uid) then
    raise exception 'Team Manager qualification required';
  end if;
  max_depth:=least(greatest(coalesce(p_depth,10),1),coalesce((rules->>'max_generations')::integer,10));
  source:=public.my_network('generation',null,max_depth);
  with recursive raw as (
    select n.node,nullif(n.node->>'id','')::uuid id,nullif(n.node->>'parent_id','')::uuid parent_id,n.ordinality
    from jsonb_array_elements(coalesce(source->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
  ), walk as (
    select r.node,r.id,r.parent_id,r.ordinality,false breakaway
    from raw r where r.id=uid
    union all
    select r.node,r.id,r.parent_id,r.ordinality,
      exists(select 1 from private.team_manager_qualifications q where q.member_id=r.id) breakaway
    from walk w join raw r on r.parent_id=w.id
    where not w.breakaway
  )
  select coalesce(jsonb_agg(node||jsonb_build_object('breakaway',breakaway,'manager_tree',true) order by ordinality),'[]'::jsonb)
  into nodes from walk;
  return jsonb_build_object('kind','manager','qualified',true,'max_generations',max_depth,'breakaway_enabled',true,'nodes',nodes);
end;
$$;

create or replace function public.my_member_dashboard()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare member uuid:=auth.uid();p public.member_profiles%rowtype;g jsonb;v_binary jsonb;code text;cfg jsonb;shares numeric:=0;personal_gp numeric:=0;personal_bp numeric:=0;
begin
 if member is null or not private.registered_member(member) then raise exception 'Member account required';end if;
 select * into p from public.member_profiles where user_id=member;
 code:=private.current_package_code(member);cfg:=private.current_mlm_rules();
 g:=public.my_generation_member_details(p.member_code);
 select node into v_binary from jsonb_array_elements(public.my_network('binary',null,1)->'nodes') node where node->>'id'=member::text limit 1;
 select coalesce(sum(completed_shares),0) into shares from private.binary_live_shares(now()) where member_id=member;
 select coalesce(sum(amount) filter(where point_type='GP'),0),coalesce(sum(amount) filter(where point_type='BP'),0)
  into personal_gp,personal_bp from public.point_ledger where member_id=member and created_at>private.financial_reset_at();
 return jsonb_build_object('full_name',p.full_name,'member_code',p.member_code,'country_code',p.country_code,'profile_photo_url',p.profile_photo_url,
  'enrolled_at',p.created_at,'package_code',code,'package_name',coalesce(cfg->'plans'->code->>'display_name','Free account'),
  'package_active',private.package_eligible(member),'generation',g,'binary',coalesce(v_binary,'{}'::jsonb),
  'personal_gp',personal_gp,'personal_bp',personal_bp,'pending_shares',shares,
  'share_points_each_side',coalesce((cfg->>'binary_share_points_each_side')::numeric,50),
  'activation_offer',private.activation_offer_window(member),'server_now',now());
end;
$$;

revoke all on function private.team_manager_metrics(uuid) from public,anon,authenticated;
revoke all on function public.my_manager_status(),public.my_network(text,text,integer),public.my_manager_tree(integer),public.my_member_dashboard() from public,anon;
grant execute on function public.my_manager_status(),public.my_network(text,text,integer),public.my_manager_tree(integer),public.my_member_dashboard() to authenticated;

notify pgrst,'reload schema';
