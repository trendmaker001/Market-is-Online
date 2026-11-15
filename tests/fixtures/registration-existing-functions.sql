CREATE OR REPLACE FUNCTION private.save_my_profile(p_name text, p_phone text, p_country text, p_gender text, p_dob date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 150 or length(trim(coalesce(p_phone,''))) not between 5 and 40 or not coalesce(private.valid_market_country(upper(p_country)),false) or p_gender not in('male','female') or (p_dob is not null and (p_dob<date '1900-01-01' or p_dob>current_date)) then raise exception 'Check profile details';end if;
 update public.member_profiles set full_name=trim(p_name),phone=trim(p_phone),country_code=upper(p_country),gender=p_gender,date_of_birth=p_dob,updated_at=now() where user_id=auth.uid();
end$function$;

CREATE OR REPLACE FUNCTION private.admin_prepare_member(p_key uuid, p_details jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r private.member_provisioning%rowtype;sp uuid;pl uuid;requested_email text:=lower(trim(p_details->>'email'));
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if p_key is null or length(trim(coalesce(p_reason,''))) not between 10 and 2000 or coalesce(requested_email,'')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(requested_email)>254 or length(trim(coalesce(p_details->>'full_name',''))) not between 2 and 150 or length(trim(coalesce(p_details->>'phone',''))) not between 5 and 40 or not coalesce(private.valid_market_country(p_details->>'country'),false) or coalesce(p_details->>'gender','') not in('male','female') or coalesce(p_details->>'side','') not in('LEFT','RIGHT') then raise exception 'Check email, name, phone, country, gender and placement side';end if;
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 select * into r from private.member_provisioning where request_key=p_key for update;
 if found then
  if r.actor_id<>auth.uid() or r.details<>p_details or r.reason<>trim(p_reason) then raise exception 'Request key already used for different details';end if;
  update private.member_provisioning set expires_at=now()+interval '1 hour' where request_key=p_key;
  return jsonb_build_object('token',r.token,'email',r.email,'member_id',r.member_id);
 end if;
 delete from private.member_provisioning where email=requested_email and actor_id=auth.uid() and member_id is null;
 if exists(select 1 from auth.users u where lower(u.email)=requested_email) or exists(select 1 from private.member_provisioning p where p.email=requested_email) then raise exception 'An account or pending creation already uses this email';end if;
 select user_id into sp from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_details->>'sponsor_code')),'^MIO-','');
 select user_id into pl from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_details->>'placement_code')),'^MIO-','');
 if sp is null or pl is null then raise exception 'Sponsor or placement member not found';end if;
 if exists(select 1 from public.user_roles where user_id=pl and role='admin') then raise exception 'Company has no binary placement';end if;
 if exists(select 1 from public.binary_placements where parent_id=pl and side=p_details->>'side') then raise exception 'This placement position is occupied';end if;
 insert into private.member_provisioning(request_key,actor_id,email,details,reason,sponsor_id,placement_id,side) values(p_key,auth.uid(),requested_email,p_details,trim(p_reason),sp,pl,p_details->>'side') returning * into r;
 return jsonb_build_object('token',r.token,'email',r.email,'member_id',r.member_id);
end$function$;

CREATE OR REPLACE FUNCTION private.profile_gender_default()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare g text;
begin
 select raw_user_meta_data->>'gender' into g from auth.users where id=new.user_id;
 if new.gender is null and g is not null then
  if g not in ('male','female') then raise exception 'Select Male or Female';end if;
  new.gender:=g;
 end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.validate_signup_gender()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 -- Shopping identity has its own name, phone and consent validation; gender is not a checkout requirement.
 if new.raw_user_meta_data->>'registration_type'='customer' then return new;end if;
 if new.raw_app_meta_data->>'provider'='email' and coalesce(new.raw_user_meta_data->>'gender','') not in ('male','female') then raise exception 'Select Male or Female';end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.admin_save_member_profile(p_member_id uuid, p_name text, p_phone text, p_country text, p_gender text, p_date_of_birth date, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end$function$;
