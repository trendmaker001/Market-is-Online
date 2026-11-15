-- Display-only root label from the saved placement, after existing network authorization.
-- No parent/side, placement, referral, reward, balance or permissions changes.
CREATE OR REPLACE FUNCTION public.my_network(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;nodes jsonb;manager_badge text;
begin
  result:=public.my_network_before_manager_badges(case when p_kind='free_generation' then 'generation' else p_kind end,p_root_code,p_depth);
  manager_badge:=private.current_team_manager_rules()->>'badge_url';
  select coalesce(jsonb_agg(n.node||jsonb_build_object(
    'country_code',coalesce(p.country_code,n.node->>'country_code'),'team_manager',q.member_id is not null,'manager_badge_url',manager_badge,
    'rank_name',d.display_name,'rank_theme',d.badge_theme,'rank_badge_url',d.badge_url
  )||case when p_kind in ('binary','single_line') and n.node->>'depth'='0'
    then jsonb_build_object('actual_placement_side',b.side) else '{}'::jsonb end order by n.ordinality),'[]'::jsonb) into nodes
  from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
  left join public.member_profiles p on p.user_id=nullif(n.node->>'id','')::uuid
  left join public.binary_placements b on b.member_id=p.user_id and b.parent_id is not null
    and p_kind in ('binary','single_line') and n.node->>'depth'='0'
  left join private.team_manager_qualifications q on q.member_id=p.user_id
  left join public.leadership_rank_definitions d on d.rank_code=n.node->>'rank';
  result:=private.apply_member_opening_to_tree(jsonb_set(result,'{nodes}',nodes));
  if p_kind='free_generation' then return private.free_generation_tree_view(result); end if;
  return private.paid_binary_tree_view(result,p_kind);
end;
$function$;

