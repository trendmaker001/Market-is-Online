-- Read-only projection: never move placements or recalculate financial values.
create or replace function private.paid_binary_tree_view(p_tree jsonb,p_kind text)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare visible_nodes jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_kind not in ('binary','pool','single_line') then return p_tree; end if;
 with recursive raw as (
  select node,ord,node->>'id' id,node->>'parent_id' parent_id
  from jsonb_array_elements(coalesce(p_tree->'nodes','[]'::jsonb)) with ordinality x(node,ord)
 ), paths as (
  select r.*, ''::text placement_path,array[r.id] visited
  from raw r where r.parent_id is null or not exists(select 1 from raw p where p.id=r.parent_id)
  union all
  select r.*,p.placement_path||case when r.node->>'side'='LEFT' then 'L' else 'R' end,p.visited||r.id
  from paths p join raw r on r.parent_id=p.id where not r.id=any(p.visited)
 )
 select coalesce(jsonb_agg(node||jsonb_build_object('placement_path',placement_path) order by ord),'[]'::jsonb)
 into visible_nodes from paths
 where nullif(node->>'package','') is not null and upper(node->>'package') not in ('FREE','NONE');
 return jsonb_set(p_tree,'{nodes}',visible_nodes)||jsonb_build_object('paid_members_only',true);
end;
$$;
revoke all on function private.paid_binary_tree_view(jsonb,text) from public,anon,authenticated;

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
  return private.paid_binary_tree_view(private.apply_member_opening_to_tree(jsonb_set(result,'{nodes}',nodes)),p_kind);
end;
$function$
;
