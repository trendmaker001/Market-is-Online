-- Profile-only administration. No wallet, authentication, role or placement changes.
alter table public.member_profiles add column if not exists date_of_birth date;
grant select(date_of_birth) on public.member_profiles to authenticated;

create or replace function private.admin_save_member_profile(
 p_member_id uuid,p_name text,p_phone text,p_country text,p_gender text,p_date_of_birth date,p_reason text
) returns void language plpgsql security definer set search_path='' as $$
declare old_profile public.member_profiles%rowtype;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform private.require_recent_totp();
 if length(trim(coalesce(p_name,''))) not between 2 and 150
 or length(trim(coalesce(p_phone,''))) not between 5 and 40
 or length(trim(coalesce(p_reason,''))) not between 10 and 2000
 or not coalesce(private.valid_market_country(upper(p_country)),false)
 or (p_gender is not null and p_gender not in ('male','female'))
 or (p_date_of_birth is not null and (p_date_of_birth<date '1900-01-01' or p_date_of_birth>current_date))
 then raise exception 'Check name, phone, country, gender, date of birth and reason';end if;
 select * into old_profile from public.member_profiles where user_id=p_member_id for update;
 if not found then raise exception 'Member not found';end if;
 update public.member_profiles set full_name=trim(p_name),phone=trim(p_phone),country_code=upper(p_country),
 gender=p_gender,date_of_birth=p_date_of_birth,updated_at=now() where user_id=p_member_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
 values(auth.uid(),'MEMBER_PROFILE_EDITED','member_profile',p_member_id,
 jsonb_build_object('reason',trim(p_reason),'before',jsonb_build_object('full_name',old_profile.full_name,'phone',old_profile.phone,'country_code',old_profile.country_code,'gender',old_profile.gender,'date_of_birth',old_profile.date_of_birth),
 'after',jsonb_build_object('full_name',trim(p_name),'phone',trim(p_phone),'country_code',upper(p_country),'gender',p_gender,'date_of_birth',p_date_of_birth)));
end$$;
revoke all on function private.admin_save_member_profile(uuid,text,text,text,text,date,text) from public,anon;
grant execute on function private.admin_save_member_profile(uuid,text,text,text,text,date,text) to authenticated;
create or replace function public.admin_save_member_profile(
 p_member_id uuid,p_name text,p_phone text,p_country text,p_gender text,p_date_of_birth date,p_reason text
) returns void language sql security invoker set search_path='' as $$
 select private.admin_save_member_profile(p_member_id,p_name,p_phone,p_country,p_gender,p_date_of_birth,p_reason)
$$;
revoke all on function public.admin_save_member_profile(uuid,text,text,text,text,date,text) from public,anon;
grant execute on function public.admin_save_member_profile(uuid,text,text,text,text,date,text) to authenticated;
