-- Privileged account creation is performed by the Edge Function, never by browser Auth admin calls.
create table private.member_provisioning(
 request_key uuid primary key,token uuid not null unique default gen_random_uuid(),actor_id uuid not null references auth.users(id),
 email text not null unique,details jsonb not null,reason text not null,sponsor_id uuid not null references public.member_profiles(user_id),
 placement_id uuid not null references public.member_profiles(user_id),side text not null check(side in('LEFT','RIGHT')),
 member_id uuid unique references public.member_profiles(user_id),created_at timestamptz not null default now(),expires_at timestamptz not null default now()+interval '1 hour');
alter table private.member_provisioning enable row level security;revoke all on private.member_provisioning from public,anon,authenticated;
create or replace function private.admin_prepare_member(p_key uuid,p_details jsonb,p_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
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
end$$;
create or replace function public.admin_prepare_member(p_key uuid,p_details jsonb,p_reason text) returns jsonb language sql security invoker set search_path='' as $$select private.admin_prepare_member(p_key,p_details,p_reason)$$;
revoke all on function private.admin_prepare_member(uuid,jsonb,text),public.admin_prepare_member(uuid,jsonb,text) from public,anon;
grant execute on function private.admin_prepare_member(uuid,jsonb,text),public.admin_prepare_member(uuid,jsonb,text) to authenticated;

create or replace function private.create_provisioned_profile(new_user auth.users) returns auth.users language plpgsql security definer set search_path='' as $$
declare r private.member_provisioning%rowtype;code text;
begin
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 select * into r from private.member_provisioning where token=(new_user.raw_app_meta_data->>'admin_provisioning')::uuid and email=lower(new_user.email) and member_id is null and expires_at>now() for update;
 if not found then raise exception 'Valid administrator creation reservation required';end if;
 if not exists(select 1 from public.user_roles where user_id=r.actor_id and role='admin') then raise exception 'Creating administrator no longer authorized';end if;
 if exists(select 1 from public.binary_placements where parent_id=r.placement_id and side=r.side) then raise exception 'This placement position is occupied';end if;
 code:=upper(substr(replace(new_user.id::text,'-',''),1,10));
 insert into private.member_restore_context values(txid_current(),new_user.id);
 insert into public.member_profiles(user_id,member_code,referral_code,full_name,phone,country_code,gender,sponsor_id,status,terms_accepted_at)
 values(new_user.id,'MIO-'||code,code,trim(r.details->>'full_name'),trim(r.details->>'phone'),r.details->>'country',r.details->>'gender',r.sponsor_id,'pending',null);
 insert into public.user_roles(user_id,role) values(new_user.id,'member');
 insert into public.binary_placements(member_id,parent_id,side,placed_by) values(new_user.id,r.placement_id,r.side,r.actor_id);
 update private.member_provisioning set member_id=new_user.id where request_key=r.request_key;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(r.actor_id,'FREE_MEMBER_CREATED','member_profile',new_user.id,jsonb_build_object('email',r.email,'reason',r.reason,'sponsor_id',r.sponsor_id,'placement_id',r.placement_id,'side',r.side));
 delete from private.member_restore_context where transaction_id=txid_current();return new_user;
end$$;
revoke all on function private.create_provisioned_profile(auth.users) from public,anon,authenticated;
do $patch$ declare body text;begin
 select pg_get_functiondef('private.create_member_profile()'::regprocedure) into body;
 body:=regexp_replace(body,'\mBEGIN\M','BEGIN if new.raw_app_meta_data ? ''admin_provisioning'' then return private.create_provisioned_profile(new);end if;','i');execute body;
end $patch$;

create or replace function private.complete_admin_member_join(p_consent boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or p_consent is distinct from true then raise exception 'Sign in and accept the terms';end if;
 if not exists(select 1 from private.member_provisioning where member_id=auth.uid()) then raise exception 'No administrator-created account found';end if;
 if not exists(select 1 from auth.users u where u.id=auth.uid() and to_jsonb(u)->>'email_confirmed_at' is not null) then raise exception 'Verify your email first';end if;
 update public.member_profiles set terms_accepted_at=coalesce(terms_accepted_at,now()),terms_version=coalesce(terms_version,'phase1-terms-v1'),status=case when status='pending' then case when private.current_package_code(auth.uid()) is null then 'inactive'::public.account_status else 'active'::public.account_status end else status end,updated_at=now() where user_id=auth.uid();
end$$;
create or replace function public.complete_admin_member_join(p_consent boolean) returns void language sql security invoker set search_path='' as $$select private.complete_admin_member_join(p_consent)$$;
revoke all on function private.complete_admin_member_join(boolean),public.complete_admin_member_join(boolean) from public,anon;
grant execute on function private.complete_admin_member_join(boolean),public.complete_admin_member_join(boolean) to authenticated;
-- The member can identify the onboarding flow without exposing a creation token.
create or replace function private.my_account_baseline() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 return jsonb_build_object('package_code',private.current_package_code(auth.uid()),'admin_provisioned',exists(select 1 from private.member_provisioning where member_id=auth.uid()),'opening_earnings',coalesce((select jsonb_agg(jsonb_build_object('category',category,'amount',amount,'updated_at',updated_at) order by category) from public.member_opening_earnings where member_id=auth.uid()),'[]'));
end$$;
