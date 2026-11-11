begin;
-- Account selection is navigation only. Store ownership and approval remain authoritative.
create or replace function public.my_vendor_access() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); has_member boolean;
begin
 if u is null then raise exception 'Sign in required';end if;
 has_member:=exists(select 1 from public.member_profiles where user_id=u);
 return jsonb_build_object(
  'has_member',has_member,
  'vendor_only',not has_member and exists(select 1 from private.vendor_identities where user_id=u),
  'email_verified',exists(select 1 from auth.users where id=u and email_confirmed_at is not null),
  'has_store',exists(select 1 from public.vendors where owner_user_id=u and status='active'),
  'application_status',(select status::text from public.vendor_applications where applicant_user_id=u order by created_at desc,id desc limit 1),
  'store_status',(select status::text from public.vendors where owner_user_id=u order by created_at desc,id desc limit 1),
  'identity',(select jsonb_build_object('full_name',i.full_name,'phone',i.phone,'country_code',i.country_code,'inviter',m.member_code) from private.vendor_identities i join public.member_profiles m on m.user_id=i.introduced_by where i.user_id=u));
end $$;
revoke all on function public.my_vendor_access() from public,anon;
grant execute on function public.my_vendor_access() to authenticated;

-- An explicit administrator action assigns an existing approved store to a verified identity.
-- This never creates a second auth user, changes a password, or moves historic ledger entries.
create or replace function public.admin_assign_vendor_account(p_vendor uuid,p_email text,p_introducer_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare before_row public.vendors%rowtype; after_row public.vendors%rowtype; owner_id uuid; intro_id uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Workspace access required';end if;
 select * into before_row from public.vendors where id=p_vendor for update;
 if before_row.id is null or before_row.status<>'active' then raise exception 'An approved active store is required';end if;
 select id into owner_id from auth.users where lower(email)=lower(trim(p_email)) and email_confirmed_at is not null;
 if owner_id is null then raise exception 'A verified account with this email is required';end if;
 select user_id into intro_id from public.member_profiles where upper(member_code)=upper(trim(p_introducer_code)) and status not in('suspended','closed');
 if intro_id is null then raise exception 'An active introducing member is required';end if;
 if exists(select 1 from public.member_profiles where user_id=owner_id and status in('suspended','closed')) then raise exception 'This account is not active';end if;
 update public.vendors set owner_user_id=owner_id,introduced_by=intro_id,contact_email=lower(trim(p_email)),is_company_owned=false where id=p_vendor returning * into after_row;
 insert into public.user_roles(user_id,role) values(owner_id,'vendor') on conflict do nothing;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data)
 values(auth.uid(),'VENDOR_ACCOUNT_ASSIGNED','vendor',p_vendor,to_jsonb(before_row),to_jsonb(after_row));
 return jsonb_build_object('vendor_id',p_vendor,'business_name',after_row.business_name,'owner_user_id',owner_id,'introduced_by',intro_id);
end $$;
revoke all on function public.admin_assign_vendor_account(uuid,text,text) from public,anon;
grant execute on function public.admin_assign_vendor_account(uuid,text,text) to authenticated;

-- Include linked existing stores as well as applications; never count an application twice.
create or replace function public.my_vendor_referrals(p_page integer default 1) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); result jsonb;
begin
 if u is null or not exists(select 1 from public.member_profiles where user_id=u and status not in('suspended','closed')) then raise exception 'Member access required';end if;
 with registrations as (
  select v.id,v.business_name,v.status,v.created_at,v.id vendor_id from public.vendors v where v.introduced_by=u
  union all
  select a.id,a.business_name,a.status,a.created_at,null::uuid from public.vendor_applications a where a.introduced_by=u
   and not exists(select 1 from public.vendors v where v.owner_user_id=a.applicant_user_id and v.introduced_by=u and v.business_name=a.business_name)
 ), page_rows as (
  select a.*,coalesce((select sum(r.amount) from public.ecommerce_rewards r join public.order_items oi on oi.id=r.order_item_id
   where oi.vendor_id=a.vendor_id and r.beneficiary_id=u and r.reward_kind='vendor_introducer' and r.status='posted'),0) commission
  from registrations a order by created_at desc,id limit 50 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*50
 ) select jsonb_build_object('total',(select count(*) from registrations),'rows',coalesce((select jsonb_agg(x) from page_rows x),'[]'::jsonb)) into result;
 return result||jsonb_build_object(
 'credited',coalesce((select sum(amount) from public.ecommerce_rewards where beneficiary_id=u and reward_kind='vendor_introducer' and status='posted'),0),
 'pending',coalesce((select sum(amount) from public.ecommerce_rewards where beneficiary_id=u and reward_kind='vendor_introducer' and status in('pending_delivery','held_activation')),0),
 'history',coalesce((select jsonb_agg(x) from(select r.id,r.amount,r.status,r.created_at,v.business_name,o.order_code from public.ecommerce_rewards r join public.order_items oi on oi.id=r.order_item_id join public.vendors v on v.id=oi.vendor_id join public.orders o on o.id=r.order_id where r.beneficiary_id=u and r.reward_kind='vendor_introducer' order by r.created_at desc,r.id limit 50 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*50)x),'[]'::jsonb),
 'history_total',(select count(*) from public.ecommerce_rewards where beneficiary_id=u and reward_kind='vendor_introducer'));
end $$;
revoke all on function public.my_vendor_referrals(integer) from public,anon;
grant execute on function public.my_vendor_referrals(integer) to authenticated;
commit;
