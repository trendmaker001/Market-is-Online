begin;
-- Enforce the admin UI step-up requirement at the database boundary as well.
create or replace function public.admin_assign_vendor_account(p_vendor uuid,p_email text,p_introducer_code text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare before_row public.vendors%rowtype; after_row public.vendors%rowtype; owner_id uuid; intro_id uuid;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Workspace access required';end if;
 perform private.require_recent_totp();
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

commit;
