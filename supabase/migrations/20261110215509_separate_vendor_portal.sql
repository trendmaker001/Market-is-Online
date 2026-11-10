-- A vendor application identity is independent of network membership.
create table private.vendor_identities(
 user_id uuid primary key references auth.users(id) on delete cascade,
 introduced_by uuid not null references public.member_profiles(user_id),
 full_name text not null,phone text not null,country_code text not null,
 created_at timestamptz not null default now()
);
alter table private.vendor_identities enable row level security;
revoke all on private.vendor_identities from public,anon,authenticated;
CREATE OR REPLACE FUNCTION private.create_member_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  sponsor uuid; ref text; nm text; ph text; pending boolean; reserved boolean;
  founder_candidate boolean := false;
BEGIN if new.raw_app_meta_data ? 'admin_provisioning' then return private.create_provisioned_profile(new);end if;
  -- Signup intent only creates a pending identity. It never grants seller privileges.
  if new.raw_user_meta_data->>'registration_type'='vendor' then
   if coalesce((select config_value from public.system_config where config_key='VENDOR_REGISTRATION' and effective_to is null order by version desc limit 1),'true'::jsonb)<>'true'::jsonb then raise exception 'Vendor registration is closed';end if;
   nm:=nullif(trim(new.raw_user_meta_data->>'full_name'),'');ph:=nullif(trim(new.raw_user_meta_data->>'phone'),'');
   if nm is null or ph is null or new.raw_user_meta_data->>'terms_accepted' is distinct from 'true' then raise exception 'Name, phone and terms consent are required';end if;
   ref:=upper(trim(coalesce(new.raw_user_meta_data->>'vendor_invitation','')));
   select user_id into sponsor from public.member_profiles where status in('active','inactive') and terms_accepted_at is not null and (upper(member_code)=ref or upper(referral_code)=ref);
   if sponsor is null or sponsor=new.id then raise exception 'Valid vendor invitation required';end if;
   if coalesce(new.raw_user_meta_data->>'country_code','')!~'^[A-Z]{2}$' then raise exception 'Country is required';end if;
   insert into private.vendor_identities(user_id,introduced_by,full_name,phone,country_code) values(new.id,sponsor,nm,ph,new.raw_user_meta_data->>'country_code');
   return new;
  end if;

  reserved:=lower(new.email)='m.shujaat1993@gmail.com';
  pending:=coalesce(to_jsonb(new)->'raw_app_meta_data'->>'provider','')='google' or reserved;
  nm:=nullif(trim(new.raw_user_meta_data->>'full_name'),'');
  ph:=nullif(trim(new.raw_user_meta_data->>'phone'),'');
  ref:=nullif(upper(trim(new.raw_user_meta_data->>'referral_code')),'');

  IF NOT pending THEN
    IF nm IS NULL THEN RAISE EXCEPTION 'Full name is required'; END IF;
    IF ph IS NULL THEN RAISE EXCEPTION 'Phone is required'; END IF;
    IF coalesce(new.raw_user_meta_data->>'terms_accepted','false')<>'true' THEN
      RAISE EXCEPTION 'Terms consent is required';
    END IF;
    IF ref IS NULL THEN RAISE EXCEPTION 'Referral code is required'; END IF;

    SELECT true INTO founder_candidate FROM private.founder_invites fi
    JOIN private.network_foundation nf ON nf.singleton=true
    WHERE lower(new.email)=fi.email
      AND fi.token_hash=encode(sha256(convert_to(ref,'UTF8')),'hex')
      AND fi.expires_at>now() AND fi.pending_user_id IS NULL
      AND fi.redeemed_at IS NULL AND nf.founder_id IS NULL
    FOR UPDATE OF fi;
    founder_candidate:=coalesce(founder_candidate,false);

    IF NOT founder_candidate THEN
      SELECT user_id INTO sponsor FROM public.member_profiles
      WHERE (upper(referral_code)=ref OR upper(member_code)=ref)
        AND status IN('active','inactive') AND terms_accepted_at IS NOT NULL;
      IF sponsor IS NULL OR sponsor=new.id THEN RAISE EXCEPTION 'Referral code not found'; END IF;
    END IF;
  END IF;

  -- The founder candidate is pending and cannot enter the company network until verified.
  ref:=upper(substr(replace(new.id::text,'-',''),1,10));
  INSERT INTO public.member_profiles(user_id,member_code,referral_code,full_name,phone,
       sponsor_id,status,terms_accepted_at,terms_version)
  VALUES(new.id,'MIO-'||ref,ref,coalesce(nm,'Member'),ph,sponsor,
       CASE WHEN pending OR founder_candidate THEN 'pending'::public.account_status
            ELSE 'active'::public.account_status END,
       CASE WHEN pending AND NOT founder_candidate THEN NULL ELSE now() END,
       CASE WHEN pending AND NOT founder_candidate THEN NULL ELSE 'phase1-terms-v1' END);

  INSERT INTO public.user_roles(user_id,role) VALUES(new.id,'member');

  IF founder_candidate THEN
    UPDATE private.founder_invites
      SET pending_user_id=new.id
      WHERE singleton=true AND pending_user_id IS NULL
        AND redeemed_at IS NULL AND expires_at>now();
    IF NOT FOUND THEN RAISE EXCEPTION 'Founder invitation was already claimed'; END IF;
    -- Supabase may create a confirmed user immediately when email confirmation is disabled.
    IF new.email_confirmed_at IS NOT NULL THEN
      PERFORM private.finalize_founder_invite(new.id);
    END IF;
  END IF;
  IF reserved THEN
    UPDATE private.operator_setup SET user_id=new.id
    WHERE email=lower(new.email) AND user_id IS NULL;
  END IF;
  RETURN new;
END
$function$
;
CREATE OR REPLACE FUNCTION public.submit_vendor_application(p_business text, p_email text, p_phone text, p_categories text, p_description text, p_proposed numeric, p_introducer_code text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare vid uuid; intro uuid; m public.member_profiles%rowtype; consumer boolean; begin
 if coalesce((select config_value from public.system_config where config_key='VENDOR_REGISTRATION' and effective_to is null order by version desc limit 1),'true'::jsonb) <> 'true'::jsonb then raise exception 'Seller registration is currently closed'; end if;
 if auth.uid() is null then raise exception 'Sign in or register with a referral code before applying'; end if;
 select introduced_by into intro from private.vendor_identities where user_id=auth.uid();
 if intro is null then raise exception 'Use a separate vendor account through a member vendor invitation';end if;
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email before applying';end if;
 if length(trim(coalesce(p_business,''))) not between 2 and 150 or p_email not like '%@%' or length(trim(coalesce(p_phone,'')))<5 or length(trim(coalesce(p_categories,'')))<2 then raise exception 'Complete business details'; end if;
 if p_proposed is null or p_proposed<.05 or p_proposed>1 then raise exception 'Proposed agreement percentage is required (5 to 100 percent)';end if;
 insert into public.vendor_applications(applicant_user_id,business_name,contact_email,contact_phone,categories,description,proposed_commission,introduced_by) values(auth.uid(),trim(p_business),trim(p_email),trim(p_phone),trim(p_categories),p_description,p_proposed,intro) returning id into vid;
 return vid;
end $function$
;
CREATE OR REPLACE FUNCTION public.admin_review_vendor_application(p_application_id uuid, p_approve boolean, p_commission_rate numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.vendor_applications%rowtype; vid uuid; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 select * into a from public.vendor_applications where id=p_application_id for update;
 if a.id is null or a.status<>'pending' then raise exception 'Pending application not found'; end if;
 if p_approve then
  if exists(select 1 from private.vendor_identities where user_id=a.applicant_user_id) and not exists(select 1 from auth.users where id=a.applicant_user_id and email_confirmed_at is not null) then raise exception 'Vendor email must be verified';end if;
  if p_commission_rate is null or p_commission_rate<0.05 or p_commission_rate>1 or p_commission_rate<>round(p_commission_rate,6) then raise exception 'Set this vendor commission at approval'; end if;
  if (a.agreement_accepted_at is null or a.agreed_commission is null or a.agreed_commission is distinct from p_commission_rate) then raise exception 'Vendor must accept these commission terms first'; end if;
  select id into vid from public.vendors where owner_user_id=a.applicant_user_id and not is_company_owned for update;
  if vid is null then
   insert into public.vendors(owner_user_id,business_name,contact_email,contact_phone,description,status,commission_rate,introduced_by,reviewed_by,reviewed_at) values(a.applicant_user_id,a.business_name,a.contact_email,a.contact_phone,a.description,'active',p_commission_rate,a.introduced_by,auth.uid(),now()) returning id into vid;
  else update public.vendors set business_name=a.business_name,contact_email=a.contact_email,contact_phone=a.contact_phone,description=a.description,status='active',commission_rate=p_commission_rate,introduced_by=a.introduced_by where id=vid; end if;
  insert into public.user_roles(user_id,role) values(a.applicant_user_id,'vendor') on conflict do nothing;
 end if;
 update public.vendor_applications set status=case when p_approve then 'active'::public.vendor_status else 'rejected'::public.vendor_status end,reviewed_by=auth.uid(),reviewed_at=now(),agreed_commission=case when p_approve then p_commission_rate else agreed_commission end where id=a.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_APPLICATION_REVIEWED','vendor_application',a.id,jsonb_build_object('approved',p_approve,'commission',p_commission_rate,'vendor',vid));
 return vid;
end $function$
;

create or replace function public.my_vendor_access() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 return jsonb_build_object('vendor_only',exists(select 1 from private.vendor_identities where user_id=auth.uid()),
 'email_verified',exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null),
 'has_store',exists(select 1 from public.vendors where owner_user_id=auth.uid() and status='active'),
 'identity',(select jsonb_build_object('full_name',i.full_name,'phone',i.phone,'country_code',i.country_code,'inviter',m.member_code) from private.vendor_identities i join public.member_profiles m on m.user_id=i.introduced_by where i.user_id=auth.uid()));
end $$;

create or replace function public.my_vendor_referrals(p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid();begin
 if u is null or not exists(select 1 from public.member_profiles where user_id=u and status not in('suspended','closed')) then raise exception 'Member access required';end if;
 return jsonb_build_object('total',(select count(*) from public.vendor_applications where introduced_by=u),
 'credited',coalesce((select sum(amount) from public.ecommerce_rewards where beneficiary_id=u and reward_kind='vendor_introducer' and status='posted'),0),
 'pending',coalesce((select sum(amount) from public.ecommerce_rewards where beneficiary_id=u and reward_kind='vendor_introducer' and status in('pending_delivery','held_activation')),0),
 'rows',coalesce((select jsonb_agg(x) from(select a.business_name,a.status,a.created_at,
  coalesce((select sum(r.amount) from public.ecommerce_rewards r join public.order_items oi on oi.id=r.order_item_id join public.vendors v on v.id=oi.vendor_id where v.owner_user_id=a.applicant_user_id and r.beneficiary_id=u and r.reward_kind='vendor_introducer' and r.status='posted'),0) as commission
 from public.vendor_applications a where a.introduced_by=u order by a.created_at desc,a.id limit 50 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*50)x),'[]'::jsonb),
 'history',coalesce((select jsonb_agg(x) from(select r.id,r.amount,r.status,r.created_at,v.business_name,o.order_code from public.ecommerce_rewards r join public.order_items oi on oi.id=r.order_item_id join public.vendors v on v.id=oi.vendor_id join public.orders o on o.id=r.order_id where r.beneficiary_id=u and r.reward_kind='vendor_introducer' order by r.created_at desc,r.id limit 50 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*50)x),'[]'::jsonb),
 'history_total',(select count(*) from public.ecommerce_rewards where beneficiary_id=u and reward_kind='vendor_introducer'));
end $$;

create or replace function public.seller_portal_orders(p_vendor uuid,p_page integer default 1) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.vendors where id=p_vendor and status='active' and (owner_user_id=auth.uid() or private.has_role('admin'))) then raise exception 'Seller access required';end if;
 return jsonb_build_object('total',(select count(distinct order_id) from public.order_items where vendor_id=p_vendor),
 'rows',coalesce((select jsonb_agg(x) from(select o.id,o.order_code,o.created_at,o.status,o.payment_status,
 (select sum(i.line_total_pkr) from public.order_items i where i.order_id=o.id and i.vendor_id=p_vendor) as amount,
 (select jsonb_agg(jsonb_build_object('name',i.product_name_snapshot,'quantity',i.quantity,'amount',i.line_total_pkr)) from public.order_items i where i.order_id=o.id and i.vendor_id=p_vendor) as items
 from public.orders o where exists(select 1 from public.order_items i where i.order_id=o.id and i.vendor_id=p_vendor) order by o.created_at desc,o.id limit 50 offset (greatest(1,least(coalesce(p_page,1),100000))-1)*50)x),'[]'::jsonb));
end $$;
revoke all on function public.my_vendor_access(),public.my_vendor_referrals(integer),public.seller_portal_orders(uuid,integer) from public,anon;
grant execute on function public.my_vendor_access(),public.my_vendor_referrals(integer),public.seller_portal_orders(uuid,integer) to authenticated;
