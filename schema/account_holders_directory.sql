-- Admin-only directory. Filters and counts are computed before the fixed 50-row page.
-- Email is read from Auth only inside the guarded private function.
create or replace function private.admin_account_holders(p_page integer default 1,p_search text default '',p_rank text default '',p_status text default '')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Workspace access required';end if;
 if coalesce(p_status,'') not in ('','active','inactive','suspended') then raise exception 'Invalid account status';end if;
 with matching as materialized (
  select m.user_id,m.member_code,m.full_name,m.phone,u.email,m.sponsor_id,m.status,m.created_at,m.achieved_rank
  from public.member_profiles m left join auth.users u on u.id=m.user_id
  where (coalesce(p_status,'')='' or m.status::text=p_status)
   and (coalesce(p_rank,'')='' or (p_rank='unranked' and coalesce(m.achieved_rank,'')='') or m.achieved_rank=p_rank)
   and (trim(coalesce(p_search,''))='' or strpos(lower(concat_ws(' ',m.full_name,m.member_code,m.phone,u.email)),lower(trim(p_search)))>0
    or (regexp_replace(p_search,'[^0-9]','','g')<>'' and p_search~'^[+0-9 ()-]+$' and strpos(regexp_replace(coalesce(m.phone,''),'[^0-9]','','g'),regexp_replace(p_search,'[^0-9]','','g'))>0))
 ), counts as (select count(*) total from matching), paging as (
  select total,greatest(1,ceil(total/50.0)::int) pages,least(greatest(1,coalesce(p_page,1)),greatest(1,ceil(total/50.0)::int)) page from counts
 ), selected as (
  select m.* from matching m order by m.created_at,m.user_id limit 50 offset (select (page-1)*50 from paging)
 ), detailed as (
  select m.*,s.full_name sponsor_name,s.member_code sponsor_code,r.display_name rank_name,private.current_package_code(m.user_id) package_code
  from selected m left join public.member_profiles s on s.user_id=m.sponsor_id left join public.leadership_rank_definitions r on r.rank_code=m.achieved_rank
 ) select jsonb_build_object('total',p.total,'page',p.page,'pages',p.pages,'page_size',50,
  'rows',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at,d.user_id) from detailed d),'[]'::jsonb),
  'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',r.rank_code,'name',r.display_name) order by r.sort_order) from public.leadership_rank_definitions r),'[]'::jsonb)) into result from paging p;
 return result;
end$$;
revoke all on function private.admin_account_holders(integer,text,text,text) from public,anon;
grant execute on function private.admin_account_holders(integer,text,text,text) to authenticated;
create or replace function public.admin_account_holders(p_page integer default 1,p_search text default '',p_rank text default '',p_status text default '')
returns jsonb language sql stable security invoker set search_path='' as $$select private.admin_account_holders(p_page,p_search,p_rank,p_status)$$;
revoke all on function public.admin_account_holders(integer,text,text,text) from public,anon;
grant execute on function public.admin_account_holders(integer,text,text,text) to authenticated;

-- Contact edits also work for inactive accounts, without activating packages or changing eligibility.
create or replace function public.manage_member_account(p_member_id uuid,p_name text,p_phone text,p_status text,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare old_status text;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Workspace access required';end if;
 perform private.require_recent_totp();
 if p_status not in('active','inactive','suspended') or length(trim(coalesce(p_name,'')))<2 or length(trim(coalesce(p_phone,'')))<5 or length(trim(coalesce(p_reason,'')))<10 then raise exception 'Complete member details, status and reason';end if;
 if exists(select 1 from public.user_roles where user_id=p_member_id and role='admin') or exists(select 1 from private.network_foundation where founder_id=p_member_id) then raise exception 'Company and founder accounts are protected';end if;
 select status::text into old_status from public.member_profiles where user_id=p_member_id for update;
 if old_status is null or old_status not in('active','inactive','suspended') then raise exception 'Member not found';end if;
 if (old_status='inactive')<>(p_status='inactive') then raise exception 'Inactive accounts must activate through the package process';end if;
 update public.member_profiles set full_name=trim(p_name),phone=trim(p_phone),status=p_status::public.account_status,updated_at=now() where user_id=p_member_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'MEMBER_ACCOUNT_MANAGED','member_profile',p_member_id,jsonb_build_object('name',p_name,'status',p_status,'reason',p_reason));
end$$;
revoke all on function public.manage_member_account(uuid,text,text,text,text) from public,anon;
grant execute on function public.manage_member_account(uuid,text,text,text,text) to authenticated;
