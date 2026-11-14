-- Read-only projection of the existing authorized sponsor network.
-- No placement, activation, sponsorship or financial writes.
CREATE OR REPLACE FUNCTION private.free_generation_tree_view(p_tree jsonb)
RETURNS jsonb LANGUAGE sql STABLE SET search_path TO ''
AS $function$
 with recursive nodes as (
  select n.node,n.ord,
   nullif(n.node->>'id','') id,
   nullif(n.node->>'parent_id','') parent_id,
   coalesce(upper(nullif(n.node->>'package','')),'FREE') in ('FREE','NONE') is_free
  from jsonb_array_elements(coalesce(p_tree->'nodes','[]'::jsonb)) with ordinality n(node,ord)
 ), kept(id) as (
  select id from nodes where is_free
  union
  select n.parent_id from nodes n join kept k on k.id=n.id where n.parent_id is not null
 ), visible as (
  select n.* from nodes n join kept k on k.id=n.id
 )
 select coalesce(p_tree,'{}'::jsonb)||jsonb_build_object(
  'nodes',coalesce((select jsonb_agg(node||jsonb_build_object('free_account',is_free,'context_only',not is_free) order by ord) from visible),'[]'::jsonb),
  'free_member_count',(select count(*) from visible where is_free),
  'sponsor_connection_count',(select count(*) from visible where not is_free),
  'tree_kind','free_generation'
 );
$function$;
REVOKE ALL ON FUNCTION private.free_generation_tree_view(jsonb) FROM PUBLIC,anon,authenticated;

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
  ) order by n.ordinality),'[]'::jsonb) into nodes
  from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
  left join public.member_profiles p on p.user_id=nullif(n.node->>'id','')::uuid
  left join private.team_manager_qualifications q on q.member_id=p.user_id
  left join public.leadership_rank_definitions d on d.rank_code=n.node->>'rank';
  result:=private.apply_member_opening_to_tree(jsonb_set(result,'{nodes}',nodes));
  if p_kind='free_generation' then return private.free_generation_tree_view(result); end if;
  return private.paid_binary_tree_view(result,p_kind);
end;
$function$;

