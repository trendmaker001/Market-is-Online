-- Read-only team counts match the paid-only Binary / Binary Placement tree.
-- Traverse hidden Free positions to retain real paths; count only paid Members.
-- No placement, reward, wallet, qualification or ledger writes.
create or replace function private.binary_team_counts(p_member uuid) returns jsonb
language sql stable security definer set search_path='' as $$
 with recursive downline(id,root_side,path) as (
  select b.member_id,b.side,array[p_member,b.member_id]
  from public.binary_placements b where b.parent_id=p_member
  union all
  select b.member_id,d.root_side,d.path||b.member_id
  from downline d join public.binary_placements b on b.parent_id=d.id
  where not b.member_id=any(d.path)
 )
 select jsonb_build_object(
  'left',count(*) filter(where root_side='LEFT'),
  'right',count(*) filter(where root_side='RIGHT')
 ) from downline where private.current_package_code(id) is not null
$$;
CREATE OR REPLACE FUNCTION public.member_binary_placement_details(p_member_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=auth.uid(); target uuid; is_company boolean; allowed boolean:=false;
 package_code text; package_name text; allowed_levels integer:=0; totals jsonb; levels jsonb;
begin
 if uid is null then raise exception 'Sign in required'; end if;
 select user_id into target from public.member_profiles
 where member_code='MIO-'||regexp_replace(upper(trim(coalesce(p_member_code,''))),'^MIO-','');
 if target is null then raise exception 'Member not found'; end if;
 is_company:=private.has_role('admin');
 if is_company or target=uid then allowed:=true; else
  with recursive team(id,depth,path) as (
   select uid,0,array[uid]
   union all
   select b.member_id,t.depth+1,t.path||b.member_id
   from team t join public.binary_placements b on b.parent_id=t.id
   where t.depth<30 and not b.member_id=any(t.path)
  ) select exists(select 1 from team where id=target) into allowed;
 end if;
 if not allowed then raise exception 'Member is outside your placement network'; end if;
 package_code:=private.current_package_code(target);
 select coalesce(j->'plans'->package_code->>'display_name','Free account'),
  coalesce((j->'plans'->package_code->>'single_line_levels')::integer,0)
 into package_name,allowed_levels from (select private.current_mlm_rules() j) q;
 totals:=private.binary_team_counts(target);
 with recursive descendants(id,depth,path) as (
  select b.member_id,1,array[target,b.member_id]
  from public.binary_placements b where b.parent_id=target
  union all
  select b.member_id,d.depth+1,d.path||b.member_id
  from descendants d join public.binary_placements b on b.parent_id=d.id
  where d.depth<30 and not b.member_id=any(d.path)
 ), counts as (
  select depth,count(*)::integer member_count from descendants
  where private.current_package_code(id) is not null group by depth
 )
 select jsonb_agg(jsonb_build_object(
  'level',g,'member_count',coalesce(c.member_count,0),
  'earning_active',g<=allowed_levels,'locked',g>allowed_levels
 ) order by g) into levels
 from generate_series(1,30) g left join counts c on c.depth=g;
 return jsonb_build_object(
  'member_id',target,'member_code',p_member_code,'package_code',package_code,
  'package_name',package_name,'allowed_levels',allowed_levels,'visible_levels',30,
  'total_team',coalesce((totals->>'left')::integer,0)+coalesce((totals->>'right')::integer,0),
  'left_team',coalesce((totals->>'left')::integer,0),
  'right_team',coalesce((totals->>'right')::integer,0),'levels',coalesce(levels,'[]'::jsonb)
 );
end;
$function$
;
notify pgrst,'reload schema';
