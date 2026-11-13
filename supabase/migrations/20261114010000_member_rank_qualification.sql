-- Read-only rank targets and own metrics; keep legacy manager balance key compatible.
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
    'rank_qualification',jsonb_build_object('metrics',private.rank_metrics(uid),'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'sort_order',d.sort_order,'theme',d.badge_theme,'badge_url',d.badge_url,'left_brp',d.left_brp,'right_brp',d.right_brp,'direct_left',d.direct_left,'direct_right',d.direct_right,'required_dp',d.required_dp) order by d.sort_order,d.rank_code) from public.leadership_rank_definitions d where d.active),'[]'::jsonb)),
    'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'badge_url',d.badge_url,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb)
  );
end;
$function$;

notify pgrst,'reload schema';
