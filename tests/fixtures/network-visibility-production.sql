CREATE OR REPLACE FUNCTION public.my_network_identity(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r jsonb; nodes jsonb;begin
 r:=case when p_kind='manager' then public.my_manager_tree(p_depth) else public.my_network(p_kind,p_root_code,p_depth) end;
 select coalesce(jsonb_agg(x.node||jsonb_build_object('gender',p.gender) order by x.ord),'[]'::jsonb) into nodes
 from jsonb_array_elements(r->'nodes') with ordinality x(node,ord)
 left join public.member_profiles p on p.user_id::text=x.node->>'id';
 return r||jsonb_build_object('nodes',nodes);
end$function$
;

CREATE OR REPLACE FUNCTION private.current_package_code(p_member_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select case when b.package_assigned then coalesce((select a.package_code from public.package_activations a where a.member_id=p_member_id and a.status='approved' and a.id is distinct from b.activation_id and coalesce(a.activated_at,a.requested_at)>b.package_assigned_at order by a.base_value desc,a.activated_at desc limit 1),b.package_code)
 else (select a.package_code from public.package_activations a where a.member_id=p_member_id and a.status='approved' order by a.base_value desc,a.activated_at desc nulls last,a.requested_at desc limit 1) end
 from (select 1) dummy left join private.member_admin_baselines b on b.member_id=p_member_id
$function$
;

CREATE OR REPLACE FUNCTION public.my_network_before_vendor_root(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=auth.uid(); root uuid; is_company boolean; allowed boolean; result jsonb; root_depth integer:=0; view_depth integer; cutoff timestamptz:=private.financial_reset_at();
begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status in('active','inactive') and terms_accepted_at is not null) then raise exception 'Active account required'; end if;
 is_company:=private.has_role('admin'); root:=uid;
 if p_kind not in('generation','binary','pool','single_line','vendor') or p_depth is null or p_depth<0 or (not is_company and ((p_kind='single_line' and p_depth not between 1 and 30) or (p_kind<>'single_line' and p_depth not between 1 and 10))) then raise exception 'Invalid tree view'; end if;
 view_depth:=case when p_depth=0 then (select count(*)::integer from public.member_profiles) else p_depth end;
 if is_company and p_kind in('binary','pool','single_line') then select founder_id into root from private.network_foundation where company_id=uid; end if;
 if nullif(trim(p_root_code),'') is not null then
  select user_id into root from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-','');
 end if;
 if not is_company then
  with recursive team(id,depth,path) as (
   select uid,0,array[uid]
   union all select m.user_id,t.depth+1,t.path||m.user_id from team t join public.member_profiles m on
    (p_kind in('generation','vendor') and m.sponsor_id=t.id) or
    (p_kind not in('generation','vendor') and exists(select 1 from public.binary_placements b where b.member_id=m.user_id and b.parent_id=t.id))
   where t.depth<case when p_kind='single_line' then 30 else 10 end and not m.user_id=any(t.path)
  ) select min(depth) into root_depth from team where id=root;
  if root_depth is null then raise exception 'Selected member is outside your visible network'; end if;
  view_depth:=least(view_depth,(case when p_kind='single_line' then 30 else 10 end)-root_depth);
 end if;
 if root is null then return jsonb_build_object('nodes','[]'::jsonb); end if;
 if p_kind='vendor' then
  return jsonb_build_object('nodes',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'parent_id',root,'full_name',v.business_name,'member_code',m.member_code,'depth',1,'commission_rate',v.commission_rate,'node_type','vendor','status',v.status)) from public.vendors v join public.member_profiles m on m.user_id=v.owner_user_id where v.introduced_by=root),'[]'::jsonb));
 end if;
 with recursive tree(id,parent_id,side,depth,path) as (
  select root,null::uuid,null::text,0,array[root]
  union all select m.user_id,t.id,case when p_kind='generation' then null else b.side end,t.depth+1,t.path||m.user_id from tree t join public.member_profiles m on
   (p_kind='generation' and m.sponsor_id=t.id) or (p_kind<>'generation' and exists(select 1 from public.binary_placements x where x.member_id=m.user_id and x.parent_id=t.id))
   left join public.binary_placements b on b.member_id=m.user_id where t.depth<view_depth and not m.user_id=any(t.path)
 ), bounded as(select * from tree order by depth,id limit 501)
 select jsonb_build_object('root_depth',root_depth,'visible_levels',view_depth,'truncated',count(*)>500,'nodes',coalesce(jsonb_agg(jsonb_build_object('id',t.id,'parent_id',t.parent_id,'side',t.side,'depth',t.depth,'member_code',m.member_code,'full_name',m.full_name,'status',m.status,'package',private.current_package_code(t.id),'rank',m.achieved_rank,'joined_at',m.created_at,'profile_photo_url',m.profile_photo_url,
 'bp',coalesce((select bp from public.package_activations a where a.member_id=t.id and a.status='approved' and coalesce(a.activated_at,a.requested_at)>cutoff order by base_value desc,activated_at desc limit 1),0),
 'left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT' and created_at>cutoff),0)-coalesce((select sum(r.consumed_left) from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where r.member_id=t.id and c.created_at>cutoff),0),
 'right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT' and created_at>cutoff),0)-coalesce((select sum(r.consumed_right) from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where r.member_id=t.id and c.created_at>cutoff),0),
 'total_left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT' and created_at>cutoff),0),
 'total_right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT' and created_at>cutoff),0),'left_team_count',coalesce((private.binary_team_counts(t.id)->>'left')::integer,0),'right_team_count',coalesce((private.binary_team_counts(t.id)->>'right')::integer,0),'left_dp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'left_dp')::numeric,0),'right_dp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'right_dp')::numeric,0),'left_gp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'left_gp')::numeric,0),'right_gp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'right_gp')::numeric,0)) order by t.depth,t.side,t.id) filter(where t.id in(select id from bounded limit 500)),'[]'::jsonb)) into result from bounded t join public.member_profiles m on m.user_id=t.id;
 return result;
end
$function$
;

CREATE OR REPLACE FUNCTION public.my_network_before_manager_badges(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;root uuid;parent jsonb;weighted_nodes jsonb;share_points numeric;
begin
 result:=public.my_network_before_vendor_root(p_kind,p_root_code,p_depth);
 if p_kind='vendor' then
  root:=auth.uid();
  if nullif(trim(p_root_code),'') is not null then
   select user_id into root from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-','');
  end if;
  select jsonb_build_object('id',user_id,'parent_id',null,'full_name',full_name,'member_code',member_code,
   'depth',0,'package',private.current_package_code(user_id),'rank',achieved_rank,'status',status)
  into parent from public.member_profiles where user_id=root;
  result:=jsonb_set(result,'{nodes}',jsonb_build_array(parent)||coalesce(result->'nodes','[]'::jsonb));
 end if;
 share_points:=coalesce((private.current_mlm_rules()->>'binary_share_points_each_side')::numeric,50);
 select coalesce(jsonb_agg(n.node||jsonb_build_object(
  'binary_share_points_each_side',share_points,
  'binary_entitlement',coalesce(s.binary_entitlement,0),
  'binary_entitlement_percent',coalesce(s.binary_entitlement,0)*100,
  'raw_binary_shares',case when share_points>0 then trunc(least(coalesce(s.left_available,0),coalesce(s.right_available,0))/share_points,1) else 0 end,
  'available_binary_shares',coalesce(s.completed_shares,0),
  'left_brp',coalesce(r.left_brp,0),'right_brp',coalesce(r.right_brp,0),
  'total_left_brp',coalesce(r.left_brp,0),'total_right_brp',coalesce(r.right_brp,0),
  'binary_qualified',coalesce((q.status->>'qualified')::boolean,false),
  'binary_qualified_at',q.status->>'qualified_at',
  'left_direct_count',coalesce((q.status->>'left_direct_count')::integer,0),
  'right_direct_count',coalesce((q.status->>'right_direct_count')::integer,0),
  'binary_required_left_directs',1,'binary_required_right_directs',1,
  'binary_required_left_dp',20,'binary_required_right_dp',20
 ) order by n.ordinality),'[]'::jsonb) into weighted_nodes
 from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
 left join private.binary_live_shares(clock_timestamp()) s on s.member_id=nullif(n.node->>'id','')::uuid
 left join (
  select member_id,
   coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='LEFT'),0) left_brp,
   coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='RIGHT'),0) right_brp
  from public.point_ledger where point_type='BRP' and side is not null group by member_id
 ) r on r.member_id=nullif(n.node->>'id','')::uuid
 left join lateral (select private.binary_qualification_status(nullif(n.node->>'id','')::uuid) status) q on true;
 return jsonb_set(result,'{nodes}',weighted_nodes);
end$function$
;

CREATE OR REPLACE FUNCTION public.my_network(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  return private.apply_member_opening_to_tree(jsonb_set(result,'{nodes}',nodes));
end;
$function$
;
CREATE OR REPLACE FUNCTION private.apply_member_opening_to_tree(p_tree jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with adjusted as (
  select n.ordinality,n.node,private.current_package_code(nullif(n.node->>'id','')::uuid) code,
   greatest(0,coalesce((n.node->>'left_bp')::numeric,0)-coalesce(b.consumed_left,0)) l,
   greatest(0,coalesce((n.node->>'right_bp')::numeric,0)-coalesce(b.consumed_right,0)) r
  from jsonb_array_elements(coalesce(p_tree->'nodes','[]')) with ordinality n(node,ordinality)
  left join private.member_admin_baselines b on b.member_id=nullif(n.node->>'id','')::uuid
 ), nodes as (select ordinality,node||case when node ? 'left_bp' then jsonb_build_object('left_bp',l,'right_bp',r,'available_binary_shares',trunc(trunc(least(l,r)/greatest(0.0001,coalesce((private.current_mlm_rules()->>'binary_share_points_each_side')::numeric,50)),1)*coalesce((private.current_mlm_rules()->'plans'->code->>'binary_entitlement')::numeric,0),4)) else '{}'::jsonb end value from adjusted)
 select jsonb_set(p_tree,'{nodes}',coalesce((select jsonb_agg(value order by ordinality) from nodes),'[]'))
$function$
;

CREATE OR REPLACE FUNCTION public.my_manager_tree(p_depth integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;

