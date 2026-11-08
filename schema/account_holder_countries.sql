-- Admin-only directory. Filters and counts are computed before the fixed 50-row page.
-- Email is read from Auth only inside the guarded private function.
create or replace function private.admin_account_holders(p_page integer,p_search text,p_rank text,p_status text,p_country text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Workspace access required';end if;
 if coalesce(p_status,'') not in ('','active','inactive','suspended') then raise exception 'Invalid account status';end if;
 with matching as materialized (
  select m.user_id,m.member_code,m.full_name,m.phone,m.country_code,u.email,m.sponsor_id,m.status,m.created_at,m.achieved_rank
  from public.member_profiles m left join auth.users u on u.id=m.user_id
  where (coalesce(p_country,'')='' or m.country_code=upper(p_country))
   and (coalesce(p_status,'')='' or m.status::text=p_status)
   and (coalesce(p_rank,'')='' or (p_rank='unranked' and coalesce(m.achieved_rank,'')='') or m.achieved_rank=p_rank)
   and (trim(coalesce(p_search,''))='' or strpos(lower(concat_ws(' ',m.full_name,m.member_code,m.phone,u.email)),lower(trim(p_search)))>0
    or (regexp_replace(p_search,'[^0-9]','','g')<>'' and p_search~'^[+0-9 ()-]+$' and strpos(regexp_replace(coalesce(m.phone,''),'[^0-9]','','g'),regexp_replace(p_search,'[^0-9]','','g'))>0))
 ), counts as (select count(*) total from matching), paging as (
  select total,greatest(1,ceil(total/50.0)::int) pages,least(greatest(1,coalesce(p_page,1)),greatest(1,ceil(total/50.0)::int)) page from counts
 ), selected as (
  select m.* from matching m order by m.created_at,m.user_id limit 50 offset (select (page-1)*50 from paging)
 ), detailed as (
  select m.*,bp.parent_id placement_id,pl.full_name placement_name,pl.member_code placement_code,bp.side placement_side,s.full_name sponsor_name,s.member_code sponsor_code,r.display_name rank_name,private.current_package_code(m.user_id) package_code
  from selected m left join public.binary_placements bp on bp.member_id=m.user_id left join public.member_profiles pl on pl.user_id=bp.parent_id left join public.member_profiles s on s.user_id=m.sponsor_id left join public.leadership_rank_definitions r on r.rank_code=m.achieved_rank
 ) select jsonb_build_object('total',p.total,'page',p.page,'pages',p.pages,'page_size',50,
  'rows',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at,d.user_id) from detailed d),'[]'::jsonb),
  'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',r.rank_code,'name',r.display_name) order by r.sort_order) from public.leadership_rank_definitions r),'[]'::jsonb)) into result from paging p;
 return result;
end$$;
revoke all on function private.admin_account_holders(integer,text,text,text,text) from public,anon;
grant execute on function private.admin_account_holders(integer,text,text,text,text) to authenticated;
create or replace function public.admin_account_holders(p_page integer,p_search text,p_rank text,p_status text,p_country text)
returns jsonb language sql stable security invoker set search_path='' as $$select private.admin_account_holders(p_page,p_search,p_rank,p_status,p_country)$$;
revoke all on function public.admin_account_holders(integer,text,text,text,text) from public,anon;
grant execute on function public.admin_account_holders(integer,text,text,text,text) to authenticated;


