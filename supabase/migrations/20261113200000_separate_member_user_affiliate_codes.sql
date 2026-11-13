-- Distinct persisted namespaces for existing and future accounts.
-- MIO member IDs remain stable so financial/history references are preserved.
alter table public.member_profiles add column affiliate_code text not null
 default ('AFF-'||upper(replace(gen_random_uuid()::text,'-','')))
 unique check (affiliate_code ~ '^AFF-[0-9A-F]{32}$');
alter table private.customer_identities add column customer_code text not null
 default ('USR-'||upper(replace(gen_random_uuid()::text,'-','')))
 unique check (customer_code ~ '^USR-[0-9A-F]{32}$');
grant select(affiliate_code) on public.member_profiles to authenticated;

create function private.protect_referral_identity_codes() returns trigger language plpgsql set search_path='' as $$
begin
 if tg_table_name='member_profiles' then
  if new.affiliate_code is distinct from old.affiliate_code then raise exception 'Affiliate code cannot be changed';end if;
 else
  if new.customer_code is distinct from old.customer_code then raise exception 'User code cannot be changed';end if;
 end if;
 return new;
end $$;
revoke all on function private.protect_referral_identity_codes() from public,anon,authenticated;
create trigger protect_affiliate_code before update on public.member_profiles
 for each row execute function private.protect_referral_identity_codes();
create trigger protect_customer_code before update on private.customer_identities
 for each row execute function private.protect_referral_identity_codes();

create or replace function private.resolve_shopping_referral(p_code text) returns uuid
language sql stable security definer set search_path='' as $$
 select m.user_id from public.member_profiles m
 where m.status in('active','inactive') and m.terms_accepted_at is not null
 and (m.affiliate_code=upper(trim(p_code))
 -- Compatibility for already shared shopping links; never accepts MEM/REF or side codes.
 or (upper(trim(p_code)) !~ '^(MEM|REF|AFF)-' and upper(trim(p_code)) !~ '-[LR]$'
 and not exists(select 1 from private.customer_identities c where c.customer_code=upper(trim(p_code)))
 and (upper(m.member_code)=regexp_replace(upper(trim(p_code)),'^USR-','MIO-')
 or upper(m.referral_code)=upper(trim(p_code))))) limit 1
$$;
create or replace function public.shopping_referral(p_code text) returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('code',m.affiliate_code,'name',m.full_name)
 from public.member_profiles m where m.user_id=private.resolve_shopping_referral(p_code)
$$;

create or replace function private.normalize_side_referral() returns trigger
language plpgsql security definer set search_path='' as $$
declare ref text:=regexp_replace(upper(trim(coalesce(new.raw_user_meta_data->>'referral_code',''))),'^(MEM|REF)-','');
begin
 if new.raw_user_meta_data->>'registration_type'='member' and ref ~ '^(AFF|USR)-' then
  raise exception 'Use a Member invitation code for Member signup';
 end if;
 if ref<>'' then
  new.raw_user_meta_data:=new.raw_user_meta_data||jsonb_build_object('referral_code',ref);
 end if;
 if ref ~ '-[LR]$' then
  new.raw_user_meta_data:=new.raw_user_meta_data||jsonb_build_object('referral_code',left(ref,length(ref)-2),'referral_side',case right(ref,1) when 'L' then 'LEFT' else 'RIGHT' end);
 end if;
 return new;
end $$;

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

  -- Public shoppers stay outside the network. Explicit Member signup proceeds
  -- through the validated sponsor, consent and package guards below.
  if new.raw_user_meta_data->>'registration_type' is distinct from 'member'
  and lower(new.email)<>'m.shujaat1993@gmail.com' and not exists(
    select 1 from private.founder_invites fi where fi.email=lower(new.email)
    and fi.token_hash=encode(sha256(convert_to(upper(trim(coalesce(new.raw_user_meta_data->>'referral_code',''))),'UTF8')),'hex')
    and fi.expires_at>now() and fi.redeemed_at is null
  ) then
   nm:=nullif(trim(new.raw_user_meta_data->>'full_name'),'');ph:=nullif(trim(new.raw_user_meta_data->>'phone'),'');
   ref:=upper(trim(coalesce(new.raw_user_meta_data->>'affiliate_code',new.raw_user_meta_data->>'referral_code','')));
   if ref<>'' then
    sponsor:=private.resolve_shopping_referral(ref);
    if sponsor is null then raise exception 'Referral link is no longer valid';end if;
   end if;
   if coalesce(new.raw_app_meta_data->>'provider','email')='email' and (length(coalesce(nm,''))<2 or length(coalesce(ph,''))<7 or new.raw_user_meta_data->>'terms_accepted' is distinct from 'true') then raise exception 'Name, phone and shopping terms consent are required';end if;
   insert into private.customer_identities(user_id,full_name,phone,country_code,sponsor_id,terms_accepted_at)
   values(new.id,coalesce(nm,'Customer'),ph,case when new.raw_user_meta_data->>'country_code' ~ '^[A-Z]{2}$' then new.raw_user_meta_data->>'country_code' else 'PK' end,sponsor,
    case when new.raw_user_meta_data->>'terms_accepted'='true' then now() end);
   return new;
  end if;
  if new.raw_user_meta_data->>'registration_type'='member' then
   if coalesce(new.raw_user_meta_data->>'country_code','')!~'^[A-Z]{2}$' then raise exception 'Country is required';end if;
   if coalesce(new.raw_user_meta_data->>'referral_code','') ~ '^(AFF|USR)-'
      or nullif(new.raw_user_meta_data->>'affiliate_code','') is not null then raise exception 'Use a Member invitation code for Member signup';end if;
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
       sponsor_id,status,terms_accepted_at,terms_version,country_code)
  VALUES(new.id,'MIO-'||ref,ref,coalesce(nm,'Member'),ph,sponsor,
       CASE WHEN pending OR founder_candidate THEN 'pending'::public.account_status
            ELSE 'active'::public.account_status END,
       CASE WHEN pending AND NOT founder_candidate THEN NULL ELSE now() END,
       CASE WHEN pending AND NOT founder_candidate THEN NULL ELSE 'phase1-terms-v1' END,
       coalesce(nullif(new.raw_user_meta_data->>'country_code',''),'PK'));

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
-- Preserve the current secure account response while adding the shopper's own ID
-- and returning the sponsor's actual affiliate code.
do $migration$
declare body text;
begin
 body:=pg_get_functiondef('public.my_shopping_account()'::regprocedure);
 if strpos(body,'''full_name'',c.full_name')=0 or strpos(body,'regexp_replace(member_code,''^MIO-'',''USR-'')')=0 then
  raise exception 'Shopping identity source changed; review migration';
 end if;
 body:=replace(body,'''full_name'',c.full_name','''customer_code'',c.customer_code,''full_name'',c.full_name');
 body:=replace(body,'regexp_replace(member_code,''^MIO-'',''USR-'')','affiliate_code');
 execute body;
 -- Public Member preview accepts MEM and old REF invitation aliases.
 body:=pg_get_functiondef('public.lookup_side_referral(text)'::regprocedure);
 body:=replace(body,'upper(trim(p_code))','regexp_replace(upper(trim(p_code)),''^(MEM|REF)-'','''')');
 execute body;
end $migration$;
-- Signed-in legacy order entry points also understand the new AFF namespace.
do $migration$
declare body text;needle text:=$old$select user_id into seller from public.member_profiles
    where (upper(member_code)=code or upper(replace(member_code,'MIO-',''))=code
      or upper(referral_code)=regexp_replace(code,'-[LR]$',''))
      and status in('active','inactive') and terms_accepted_at is not null;$old$;
begin
 body:=pg_get_functiondef('private.snapshot_order_reward_mode()'::regprocedure);
 if strpos(body,needle)=0 then raise exception 'Order attribution source changed; review migration';end if;
 execute replace(body,needle,'seller:=private.resolve_shopping_referral(code);');
end $migration$;
notify pgrst,'reload schema';

