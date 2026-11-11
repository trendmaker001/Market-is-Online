alter table public.orders add column customer_advance_pkr numeric(14,2) not null default 0 check(customer_advance_pkr>=0);
-- Shopping identities are independent of network membership. All writes use checked RPCs.
create table private.customer_identities (
 user_id uuid primary key references auth.users(id),full_name text not null,phone text,
 country_code text not null default 'PK',sponsor_id uuid references public.member_profiles(user_id),
 terms_accepted_at timestamptz,created_at timestamptz not null default now()
);
create table private.customer_payment_accounts (
 id uuid primary key default gen_random_uuid(),bank_name text not null,account_title text not null,
 account_number text not null,instructions text not null default '',active boolean not null default true,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table private.customer_order_funding (
 order_id uuid primary key references public.orders(id),customer_id uuid not null references private.customer_identities(user_id),
 method text not null check(method in('ADVANCE','SPONSOR')),required_pkr numeric(14,2) not null check(required_pkr>0),
 hold_mio numeric(20,4) not null check(hold_mio>0),rate_snapshot numeric not null check(rate_snapshot>0),
 status text not null check(status in('awaiting_payment','pending','submitted','approved','rejected','cancelled','refund_due','refunded')),
 paid_pkr numeric(14,2) not null default 0 check(paid_pkr>=0),payment_account_id uuid references private.customer_payment_accounts(id),
 account_snapshot jsonb,transaction_id text,transaction_key text,submitted_at timestamptz,reviewed_at timestamptz,
 reviewer_id uuid references auth.users(id),review_note text,created_at timestamptz not null default now()
);
create index customer_order_funding_owner on private.customer_order_funding(customer_id,created_at desc);
-- An unverified rejected reference can be corrected; a submitted/verified transfer cannot pay twice.
create unique index customer_payment_reference_unique on private.customer_order_funding(payment_account_id,transaction_key)
 where transaction_key is not null and status in('submitted','approved','refund_due','refunded');
alter table private.customer_identities enable row level security;
alter table private.customer_payment_accounts enable row level security;
alter table private.customer_order_funding enable row level security;
revoke all on private.customer_identities,private.customer_payment_accounts,private.customer_order_funding from public,anon,authenticated;

create function private.customer_order_requirement(p_total numeric,p_rate numeric)
returns jsonb language plpgsql immutable set search_path='' as $$
begin
 if p_total is null or p_total<=0 or p_rate is null or p_rate<=0 then raise exception 'Invalid order total or reference rate';end if;
 return jsonb_build_object('required_pkr',least(p_total,case when p_total<=6000 then 600 else round(p_total*.10,2) end),
 'hold_mio',case when p_total<=6000 then 2 else ceil(round(p_total*.10,2)/p_rate*10000)/10000 end,'rate_snapshot',p_rate);
end $$;
revoke all on function private.customer_order_requirement(numeric,numeric) from public,anon,authenticated;

create function public.my_shopping_account() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c private.customer_identities%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select * into c from private.customer_identities where user_id=auth.uid();
 return jsonb_build_object('has_customer',c.user_id is not null,'customer_only',c.user_id is not null and not exists(select 1 from public.member_profiles where user_id=auth.uid()),
 'full_name',c.full_name,'phone',c.phone,'terms_accepted',c.terms_accepted_at is not null,'has_sponsor',c.sponsor_id is not null,
 'sponsor_code',(select member_code from public.member_profiles where user_id=c.sponsor_id));
end $$;
create function public.complete_shopping_profile(p_name text,p_phone text,p_consent boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or length(trim(coalesce(p_name,''))) not between 2 and 120 or length(trim(coalesce(p_phone,''))) not between 7 and 20 or p_consent is distinct from true then raise exception 'Name, phone and consent are required';end if;
 update private.customer_identities set full_name=trim(p_name),phone=trim(p_phone),terms_accepted_at=coalesce(terms_accepted_at,now()) where user_id=auth.uid();
 if not found then raise exception 'Shopping account not found';end if;
end $$;

create function public.join_network_from_shopping(p_referral_code text,p_consent boolean) returns void language plpgsql security definer set search_path='' as $$
declare c private.customer_identities%rowtype;sponsor uuid;ref text:=regexp_replace(upper(trim(p_referral_code)),'-[LR]$','');code text;
begin
 if auth.uid() is null or p_consent is distinct from true then raise exception 'Sign in and accept membership terms';end if;
 select * into c from private.customer_identities where user_id=auth.uid() for update;
 if c.user_id is null or c.terms_accepted_at is null then raise exception 'Complete your shopping profile first';end if;
 if exists(select 1 from public.member_profiles where user_id=auth.uid()) then return;end if;
 if not exists(select 1 from auth.users where id=auth.uid() and email_confirmed_at is not null) then raise exception 'Verify your email first';end if;
 select user_id into sponsor from public.member_profiles where (upper(referral_code)=ref or upper(member_code)=ref) and status in('active','inactive') and terms_accepted_at is not null;
 if sponsor is null or sponsor=auth.uid() then raise exception 'Valid member referral code required';end if;
 code:=upper(substr(replace(auth.uid()::text,'-',''),1,10));
 insert into public.member_profiles(user_id,member_code,referral_code,full_name,phone,country_code,sponsor_id,status,terms_accepted_at,terms_version)
 values(auth.uid(),'MIO-'||code,code,c.full_name,c.phone,c.country_code,sponsor,'active',now(),'phase1-terms-v1');
 insert into public.user_roles(user_id,role) values(auth.uid(),'member');
 if right(upper(trim(p_referral_code)),2) in('-L','-R') then perform private.place_outermost(auth.uid(),sponsor,case right(upper(trim(p_referral_code)),1) when 'L' then 'LEFT' else 'RIGHT' end);end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'SHOPPER_JOINED_NETWORK','member',auth.uid());
 -- Customer identity, order ownership and payment records are deliberately retained.
end $$;

create function public.shopping_payment_accounts() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return coalesce((select jsonb_agg(to_jsonb(a)-'created_at'-'updated_at' order by a.created_at) from private.customer_payment_accounts a where active),'[]');
end $$;
create function public.admin_save_shopping_payment_account(p_id uuid,p_bank text,p_title text,p_number text,p_instructions text,p_active boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid:=coalesce(p_id,gen_random_uuid());
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if length(trim(coalesce(p_bank,''))) not between 2 and 120 or length(trim(coalesce(p_title,''))) not between 2 and 160 or length(trim(coalesce(p_number,''))) not between 4 and 120 or length(coalesce(p_instructions,''))>1000 or p_active is null then raise exception 'Complete valid bank, account title and account number';end if;
 insert into private.customer_payment_accounts(id,bank_name,account_title,account_number,instructions,active)
 values(result,trim(p_bank),trim(p_title),trim(p_number),trim(coalesce(p_instructions,'')),p_active)
 on conflict(id) do update set bank_name=excluded.bank_name,account_title=excluded.account_title,account_number=excluded.account_number,instructions=excluded.instructions,active=excluded.active,updated_at=now();
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'CUSTOMER_PAYMENT_ACCOUNT_SAVED','payment_account',result);
 return result;
end $$;

create function public.submit_shopping_advance(p_order_id uuid,p_account_id uuid,p_transaction_id text) returns void language plpgsql security definer set search_path='' as $$
declare f private.customer_order_funding%rowtype;a private.customer_payment_accounts%rowtype;o public.orders%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select * into o from public.orders where id=p_order_id for update;
 select * into f from private.customer_order_funding where order_id=p_order_id for update;
 if f.customer_id is distinct from auth.uid() then raise exception 'Order not found';end if;
 if f.method<>'ADVANCE' or o.status<>'placed' then raise exception 'Order is not awaiting an advance';end if;
 if f.status='approved' then raise exception 'Payment already approved';end if;
 if f.status='submitted' then
  if f.payment_account_id=p_account_id and f.transaction_key=lower(regexp_replace(trim(p_transaction_id),'\s','','g')) then return;end if;
  raise exception 'Payment is already under review';
 end if;
 if f.status not in('awaiting_payment','rejected') then raise exception 'Payment submission is not available';end if;
 if length(trim(coalesce(p_transaction_id,''))) not between 4 and 120 then raise exception 'Enter a valid transaction ID';end if;
 select * into a from private.customer_payment_accounts where id=p_account_id and active;
 if a.id is null then raise exception 'Select an active payment account';end if;
 update private.customer_order_funding set status='submitted',payment_account_id=a.id,account_snapshot=to_jsonb(a)-'created_at'-'updated_at',
 transaction_id=trim(p_transaction_id),transaction_key=lower(regexp_replace(trim(p_transaction_id),'\s','','g')),submitted_at=now(),review_note=null where order_id=p_order_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'CUSTOMER_ADVANCE_SUBMITTED','order',p_order_id,jsonb_build_object('required_pkr',f.required_pkr,'transaction_id',trim(p_transaction_id)));
end $$;

create function public.admin_review_shopping_advance(p_order_id uuid,p_approve boolean,p_verified_pkr numeric,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare f private.customer_order_funding%rowtype;o public.orders%rowtype;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select * into o from public.orders where id=p_order_id for update;
 select * into f from private.customer_order_funding where order_id=p_order_id for update;
 if f.order_id is null or f.method<>'ADVANCE' then raise exception 'Advance payment not found';end if;
 if f.status='approved' and p_approve then return;end if;
 if f.status<>'submitted' or o.status<>'placed' then raise exception 'Payment is not awaiting review';end if;
 if p_approve is null or length(trim(coalesce(p_note,'')))<10 then raise exception 'Verification or rejection note required';end if;
 if p_approve and (p_verified_pkr is null or p_verified_pkr<>f.required_pkr) then raise exception 'Verify the exact required advance amount: PKR %',f.required_pkr;end if;
 update private.customer_order_funding set status=case when p_approve then 'approved' else 'rejected' end,paid_pkr=case when p_approve then f.required_pkr else 0 end,
 reviewed_at=now(),reviewer_id=auth.uid(),review_note=trim(p_note) where order_id=p_order_id;
 if p_approve then update public.orders set customer_advance_pkr=f.required_pkr,cod_due_pkr=total_pkr-f.required_pkr,status='confirmed',updated_at=now() where id=p_order_id;end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),case when p_approve then 'CUSTOMER_ADVANCE_APPROVED' else 'CUSTOMER_ADVANCE_REJECTED' end,'order',p_order_id,jsonb_build_object('amount',p_verified_pkr,'note',trim(p_note),'transaction_id',f.transaction_id));
end $$;

create function public.my_shopping_orders() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return coalesce((select jsonb_agg(x.data order by x.created_at desc) from (
 select o.created_at,jsonb_build_object('id',o.id,'order_code',o.order_code,'status',o.status,'payment_status',o.payment_status,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'created_at',o.created_at,
 'shipping_name',o.shipping_name,'shipping_city',o.shipping_city,'shipping_address',o.shipping_address,
 'funding',to_jsonb(f)-'customer_id'-'transaction_key'-'reviewer_id',
 'sponsor_status',a.status,'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.product_name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_pkr)),'[]') from public.order_items i where i.order_id=o.id)) as data
 from private.customer_order_funding f join public.orders o on o.id=f.order_id left join public.affiliate_guest_order_approvals a on a.order_id=o.id
 where f.customer_id=auth.uid() order by o.created_at desc limit 100) x),'[]');
end $$;

create function public.admin_shopping_payments() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from private.customer_payment_accounts a),'[]'),
 'payments',coalesce((select jsonb_agg(x.data order by x.created_at desc) from (select f.created_at,to_jsonb(f)||jsonb_build_object('order_code',o.order_code,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'customer_name',o.shipping_name,'order_status',o.status) as data from private.customer_order_funding f join public.orders o on o.id=f.order_id where f.method='ADVANCE' order by case f.status when 'submitted' then 0 when 'refund_due' then 1 else 2 end,f.created_at desc limit 100) x),'[]'));
end $$;

create function public.admin_record_shopping_refund(p_order_id uuid,p_reference text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if length(trim(coalesce(p_reference,'')))<8 then raise exception 'Enter the completed refund transaction reference';end if;
 perform 1 from public.orders where id=p_order_id for update;
 update private.customer_order_funding set status='refunded',review_note='Refund transaction: '||trim(p_reference),reviewed_at=now(),reviewer_id=auth.uid() where order_id=p_order_id and status='refund_due';
 if not found then raise exception 'No refund is due';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'CUSTOMER_ADVANCE_REFUNDED','order',p_order_id,jsonb_build_object('reference',trim(p_reference)));
end $$;

create function private.guard_customer_order_progress() returns trigger language plpgsql security definer set search_path='' as $$
declare f private.customer_order_funding%rowtype;
begin
 select * into f from private.customer_order_funding where order_id=old.id;
 if f.order_id is null then return new;end if;
 if new.status in('cancelled','returned') then return new;end if;
 if (new.status<>old.status and new.status in('confirmed','processing','shipped','delivered')) or (new.payment_status='confirmed' and old.payment_status<>'confirmed') then
  if f.method='ADVANCE' and f.status<>'approved' then raise exception 'Advance payment must be verified before processing this order';end if;
  if f.method='SPONSOR' and not exists(select 1 from public.affiliate_guest_order_approvals where order_id=old.id and status in('approved','released')) then raise exception 'Sponsor hold must be approved before processing this order';end if;
 end if;
 return new;
end $$;
create trigger ab_guard_customer_order_progress before update on public.orders for each row execute function private.guard_customer_order_progress();
create function private.close_customer_order_funding() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status in('cancelled','returned') and old.status is distinct from new.status then
  update private.customer_order_funding set status=case when paid_pkr>0 then 'refund_due' else 'cancelled' end where order_id=new.id and status not in('refund_due','refunded','cancelled');
 end if;
 return new;
end $$;
create trigger zz_close_customer_order_funding after update on public.orders for each row execute function private.close_customer_order_funding();
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

  -- Public shoppers do not enter the member network. The explicit upgrade RPC
  -- creates membership later; mutable auth metadata never authorizes access.
  if lower(new.email)<>'m.shujaat1993@gmail.com' and not exists(
    select 1 from private.founder_invites fi where fi.email=lower(new.email)
    and fi.token_hash=encode(sha256(convert_to(upper(trim(coalesce(new.raw_user_meta_data->>'referral_code',''))),'UTF8')),'hex')
    and fi.expires_at>now() and fi.redeemed_at is null
  ) then
   nm:=nullif(trim(new.raw_user_meta_data->>'full_name'),'');ph:=nullif(trim(new.raw_user_meta_data->>'phone'),'');
   ref:=regexp_replace(upper(trim(coalesce(new.raw_user_meta_data->>'affiliate_code',new.raw_user_meta_data->>'referral_code',''))),'-[LR]$','');
   if ref<>'' then
    select user_id into sponsor from public.member_profiles where (upper(referral_code)=ref or upper(member_code)=ref or upper(replace(member_code,'MIO-',''))=ref)
      and status in('active','inactive') and terms_accepted_at is not null;
    if sponsor is null then raise exception 'Referral link is no longer valid';end if;
   end if;
   if coalesce(new.raw_app_meta_data->>'provider','email')='email' and (length(coalesce(nm,''))<2 or length(coalesce(ph,''))<7 or new.raw_user_meta_data->>'terms_accepted' is distinct from 'true') then raise exception 'Name, phone and shopping terms consent are required';end if;
   insert into private.customer_identities(user_id,full_name,phone,country_code,sponsor_id,terms_accepted_at)
   values(new.id,coalesce(nm,'Customer'),ph,case when new.raw_user_meta_data->>'country_code' ~ '^[A-Z]{2}$' then new.raw_user_meta_data->>'country_code' else 'PK' end,sponsor,
    case when new.raw_user_meta_data->>'terms_accepted'='true' then now() end);
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
$function$;
CREATE OR REPLACE FUNCTION private.place_shopping_order_core(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_guest_email text, p_idempotency_key text, p_access_token text, p_affiliate_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  oid uuid:=gen_random_uuid();
  existing public.orders%rowtype;
  prod public.products%rowtype;
  item record;
  fee numeric;
  gross numeric(14,2):=0;
  disc numeric(14,2):=0;
  email_normalized text:=lower(trim(coalesce(p_guest_email,'')));
  phone_normalized text:=regexp_replace(coalesce(p_shipping_phone,''),'[^0-9+]','','g');
  token_hash text;
begin
  if auth.uid() is null then raise exception 'Sign in first';end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Basket is empty';end if;
  if jsonb_array_length(p_items)>30 then raise exception 'Too many basket lines';end if;
  if exists(select 1 from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) where product_id is null or quantity is null or quantity<1 or quantity>99) then raise exception 'Invalid basket line';end if;
  if email_normalized!~'^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Enter a valid email address';end if;
  if length(trim(coalesce(p_shipping_name,'')))<2 or length(trim(coalesce(p_shipping_name,'')))>120 then raise exception 'Enter a valid delivery name';end if;
  if length(phone_normalized)<7 or length(phone_normalized)>20 then raise exception 'Enter a valid delivery phone';end if;
  if length(trim(coalesce(p_shipping_address,'')))<8 or length(trim(coalesce(p_shipping_address,'')))>500 then raise exception 'Enter a complete delivery address';end if;
  if length(trim(coalesce(p_shipping_city,'')))<2 or length(trim(coalesce(p_shipping_city,'')))>100 then raise exception 'Enter a valid city';end if;
  if length(coalesce(p_idempotency_key,''))<12 or length(coalesce(p_access_token,''))<32 then raise exception 'Invalid guest order request';end if;
  token_hash:=md5(p_access_token);
  perform pg_advisory_xact_lock(hashtextextended('guest-order:'||email_normalized||':'||p_idempotency_key,0));
  select * into existing from public.orders where idempotency_key='guest:'||email_normalized||':'||p_idempotency_key;
  if existing.id is not null then
    if existing.guest_access_token_hash<>token_hash then raise exception 'Guest order token mismatch';end if;
    return jsonb_build_object('order_id',existing.id,'order_code',existing.order_code,'status',existing.status);
  end if;
  if (select count(*) from public.orders where buyer_id is null and lower(guest_email)=email_normalized and regexp_replace(shipping_phone,'[^0-9+]','','g')=phone_normalized and created_at>now()-interval '1 hour' and status not in('cancelled','returned'))>=5 then
    raise exception 'Too many recent guest orders. Please try again later';
  end if;
  select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
  if fee is null then raise exception 'Delivery charges are awaiting company configuration';end if;
  perform set_config('mio.affiliate_code',coalesce(trim(p_affiliate_code),''),true);
  insert into public.orders(id,order_code,buyer_id,subtotal_pkr,delivery_fee_pkr,total_pkr,payment_method,payment_status,status,shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key,usd_to_pkr_rate,guest_email,guest_access_token_hash)
  values(oid,'USR-'||upper(substr(replace(oid::text,'-',''),1,10)),null,0,fee,fee,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),trim(p_shipping_address),trim(p_shipping_city),'guest:'||email_normalized||':'||p_idempotency_key,private.current_mio_reference_price(),email_normalized,token_hash);
  for item in select product_id,sum(quantity)::integer quantity from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) group by product_id order by product_id loop
    select * into prod from public.products where id=item.product_id for update;
    if prod.id is null or prod.status<>'approved' or prod.stock_quantity<item.quantity then raise exception 'A selected product is unavailable or out of stock';end if;
    if not exists(select 1 from public.vendors v where v.id=prod.vendor_id and v.status='active') then raise exception 'Seller is not active';end if;
    update public.products set stock_quantity=stock_quantity-item.quantity,updated_at=now() where id=prod.id;
    insert into public.order_items(order_id,product_id,vendor_id,product_name_snapshot,unit_price_pkr,quantity) values(oid,prod.id,prod.vendor_id,prod.name,prod.price_pkr,item.quantity);
    gross:=gross+prod.price_pkr*item.quantity;
  end loop;
  if gross<=0 then raise exception 'Basket total must be positive';end if;
  select coalesce(sum(buyer_discount_pkr),0) into disc from public.order_items where order_id=oid;
  update public.orders set discount_pkr=disc,subtotal_pkr=gross-disc,total_pkr=gross-disc+fee where id=oid;
  perform set_config('mio.affiliate_code','',true);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'CUSTOMER_MARKETPLACE_ORDER_PLACED','order',oid,jsonb_build_object('order_code',(select order_code from public.orders where id=oid),'guest',true,'affiliate_attributed',exists(select 1 from public.orders where id=oid and selling_affiliate_id is not null)));
  return (select jsonb_build_object('order_id',id,'order_code',order_code,'status',status) from public.orders where id=oid);
end $function$;

alter table public.affiliate_guest_order_approvals drop constraint affiliate_guest_order_approvals_hold_mio_check;
alter table public.affiliate_guest_order_approvals add constraint affiliate_guest_order_approvals_hold_mio_check check(hold_mio>0);
alter table public.affiliate_guest_order_approvals add column required_pkr numeric(14,2),add column rate_snapshot numeric;
-- Recalculate only unapproved requests. Existing funded holds retain their exact ledger amount.
update public.affiliate_guest_order_approvals a set
 hold_mio=(private.customer_order_requirement(o.total_pkr,o.usd_to_pkr_rate)->>'hold_mio')::numeric,
 hold_amount=(private.customer_order_requirement(o.total_pkr,o.usd_to_pkr_rate)->>'hold_mio')::numeric,
 required_pkr=(private.customer_order_requirement(o.total_pkr,o.usd_to_pkr_rate)->>'required_pkr')::numeric,rate_snapshot=o.usd_to_pkr_rate
from public.orders o where o.id=a.order_id and a.status in('pending','guarantee_requested') and o.total_pkr>0 and o.usd_to_pkr_rate>0;

create function public.place_shopping_order(p_items jsonb,p_shipping_name text,p_shipping_phone text,p_shipping_address text,p_shipping_city text,p_idempotency_key text,p_funding_method text default 'ADVANCE',p_affiliate_code text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c private.customer_identities%rowtype;email text;code text:=nullif(trim(p_affiliate_code),'');placed jsonb;o public.orders%rowtype;requirement jsonb;key text;
begin
 if auth.uid() is null then raise exception 'Create or sign in to your User account before placing an order';end if;
 insert into private.customer_identities(user_id,full_name,phone,country_code,sponsor_id,terms_accepted_at)
 select user_id,full_name,phone,coalesce(country_code,'PK'),sponsor_id,terms_accepted_at from public.member_profiles where user_id=auth.uid() and terms_accepted_at is not null
 on conflict(user_id) do nothing;
 select * into c from private.customer_identities where user_id=auth.uid();
 if c.user_id is null then raise exception 'Shopping User account required';end if;
 if c.terms_accepted_at is null then raise exception 'Complete your shopping profile and consent first';end if;
 select lower(u.email) into email from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null;
 if email is null then raise exception 'Verify your email before placing an order';end if;
 if p_funding_method is null or p_funding_method not in('ADVANCE','SPONSOR') then raise exception 'Choose advance payment or sponsor hold';end if;
 if length(coalesce(p_idempotency_key,'')) not between 12 and 150 then raise exception 'Valid order request reference required';end if;
 key:='customer:'||auth.uid()||':'||p_idempotency_key;
 perform pg_advisory_xact_lock(hashtextextended(key,0));
 select x.* into o from public.orders x join private.customer_order_funding f on f.order_id=x.id and f.customer_id=auth.uid()
 where x.idempotency_key='guest:'||email||':'||key;
 if found then return jsonb_build_object('order_id',o.id,'order_code',o.order_code,'status',o.status,'duplicate',true);end if;
 if code is null and c.sponsor_id is not null then select member_code into code from public.member_profiles where user_id=c.sponsor_id;end if;
 if p_funding_method='SPONSOR' and code is null then raise exception 'A linked sponsor is required';end if;
 placed:=private.place_shopping_order_core(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,email,key,gen_random_uuid()::text,code);
 select * into o from public.orders where id=(placed->>'order_id')::uuid for update;
 requirement:=private.customer_order_requirement(o.total_pkr,o.usd_to_pkr_rate);
 insert into private.customer_order_funding(order_id,customer_id,method,required_pkr,hold_mio,rate_snapshot,status)
 values(o.id,auth.uid(),p_funding_method,(requirement->>'required_pkr')::numeric,(requirement->>'hold_mio')::numeric,o.usd_to_pkr_rate,case p_funding_method when 'ADVANCE' then 'awaiting_payment' else 'pending' end);
 update public.affiliate_guest_order_approvals set hold_mio=(requirement->>'hold_mio')::numeric,hold_amount=(requirement->>'hold_mio')::numeric,
 required_pkr=(requirement->>'required_pkr')::numeric,rate_snapshot=o.usd_to_pkr_rate where order_id=o.id;
 update public.orders set cod_due_pkr=total_pkr where id=o.id;
 return placed||requirement||jsonb_build_object('funding_method',p_funding_method);
end $$;
CREATE OR REPLACE FUNCTION public.place_guest_affiliate_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_guest_email text, p_idempotency_key text, p_access_token text, p_affiliate_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$begin raise exception 'Create or sign in to your User account, then use shopping checkout';end $function$;
CREATE OR REPLACE FUNCTION public.place_configured_bundle_order(p_type uuid, p_vendor uuid, p_bundle_items jsonb, p_quote_key text, p_request jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_requester text;
  v_request_key text := p_request->>'p_idempotency_key';
  member uuid := auth.uid();
  access_token text := p_request->>'p_access_token';
  regular_items jsonb := coalesce(p_request->'p_items','[]');
  guest_email text := lower(trim(p_request->>'p_guest_email'));
  bundle_product_id uuid := gen_random_uuid();
  quote jsonb;
  placed jsonb;
  items jsonb;
  country text;
begin
  if member is null then raise exception 'Create or sign in to your User account before placing an order';end if;
  if length(coalesce(v_request_key,'')) not between 12 and 120 then raise exception 'Invalid checkout request key'; end if;
  if member is null then
    if length(coalesce(access_token,''))<32 or guest_email is null then raise exception 'Guest checkout details required'; end if;
    v_requester:='guest:'||guest_email||':'||md5(access_token);
  else v_requester:=member::text;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('bundle-checkout:'||v_requester||':'||v_request_key,0));
  select result into placed from private.configured_bundle_checkouts c
    where c.requester=v_requester and c.request_key=v_request_key;
  if found then return placed||jsonb_build_object('duplicate',true); end if;
  if jsonb_typeof(regular_items)<>'array' or jsonb_array_length(regular_items)>29 then raise exception 'Invalid basket'; end if;
  if jsonb_typeof(p_bundle_items) is distinct from 'array' or jsonb_array_length(p_bundle_items)>99 then raise exception 'Invalid bundle selection'; end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('mio-reference-price-pkr',0));
  perform 1 from private.marketplace_bundle_types where private.marketplace_bundle_types.id=p_type for share;
  perform 1 from public.vendors where public.vendors.id=p_vendor for share;
  perform p.id from public.products p
    where p.id in (select (x->>'product_id')::uuid from jsonb_array_elements(p_bundle_items||regular_items) x)
    order by p.id for update;
  quote:=private.configured_bundle_quote(p_type,p_vendor,p_bundle_items);
  if not (quote->>'complete')::boolean then raise exception 'Complete the required bundle units'; end if;
  if p_quote_key is distinct from quote->>'quote_key' then
    return jsonb_build_object('quote_changed',true,'quote',quote);
  end if;
  if not (quote->>'meets_minimum')::boolean then
    raise exception 'Final bundle product total must be at least PKR % before delivery',quote->>'minimum_pkr';
  end if;
  select coalesce(to_jsonb(v)->>'country_code','PK') into country from public.vendors v where v.id=p_vendor;
  perform set_config('mio.configured_bundle_id',bundle_product_id::text,true);
  insert into public.products(id,vendor_id,name,description,category,image_urls,price_pkr,compare_at_price_pkr,stock_quantity,status,bundle_definition,country_code)
  values(bundle_product_id,p_vendor,quote->>'name','Customer-selected bundle','Bundles','[]',(quote->>'price_pkr')::numeric,
    (quote->>'original_total')::numeric,1,'approved',quote,country);
  items:=regular_items||jsonb_build_array(jsonb_build_object('product_id',bundle_product_id,'quantity',1));
  if member is null then
    placed:=public.place_guest_affiliate_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',
      p_request->>'p_shipping_address',p_request->>'p_shipping_city',guest_email,'bundle:'||v_request_key,
      access_token,p_request->>'p_affiliate_code');
  elsif (exists(select 1 from private.customer_identities where user_id=member) and not exists(select 1 from public.member_profiles where user_id=member)) or nullif(trim(p_request->>'p_affiliate_code'),'') is not null then
    placed:=public.place_shopping_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',p_request->>'p_shipping_address',p_request->>'p_shipping_city','bundle:'||v_request_key,coalesce(p_request->>'p_funding_method','ADVANCE'),p_request->>'p_affiliate_code');
  elsif coalesce((p_request->>'maintenance')::boolean,false) then
    placed:=public.place_maintenance_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',
      p_request->>'p_shipping_address',p_request->>'p_shipping_city','bundle:'||v_request_key,p_request->>'p_checkout_mode',
      p_request->>'p_balance_payment_method',p_request->>'p_transaction_pin');
  else
    placed:=public.place_checkout_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',
      p_request->>'p_shipping_address',p_request->>'p_shipping_city','bundle:'||v_request_key,p_request->>'p_checkout_mode',
      p_request->>'p_balance_payment_method',p_request->>'p_transaction_pin');
  end if;
  if not exists(select 1 from public.order_items where order_id=(placed->>'order_id')::uuid and product_id=bundle_product_id)
    then raise exception 'Order request key is already in use'; end if;
  update public.products p set status='archived' where p.id=bundle_product_id;
  perform set_config('mio.configured_bundle_id','',true);
  insert into private.configured_bundle_checkouts values(v_requester,v_request_key,placed);
  return placed;
end $function$;
CREATE OR REPLACE FUNCTION private.enforce_affiliate_guest_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare approval text;
begin
 if exists(select 1 from private.customer_order_funding where order_id=old.id and method='ADVANCE') then return new;end if;
 if old.buyer_id is not null or old.selling_affiliate_id is null then return new;end if;
 select status into approval from public.affiliate_guest_order_approvals where order_id=old.id;
 if coalesce(approval,'pending') not in('approved','released') and(
  (new.payment_status='confirmed' and old.payment_status<>'confirmed')or
  (new.status in('confirmed','processing','shipped','delivered')and new.status<>old.status)
 )then raise exception 'Selling member approval is required before processing this guest order';end if;
 return new;
end$function$;
CREATE OR REPLACE FUNCTION public.review_affiliate_guest_order(p_order_id uuid, p_approve boolean, p_transaction_pin text, p_idempotency_key text, p_hold_method text DEFAULT 'MIO'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();a public.affiliate_guest_order_approvals%rowtype;o public.orders%rowtype;
 item record;paid boolean;ppv_balance numeric;direct_sponsor uuid;method text:=upper(coalesce(p_hold_method,'MIO'));
begin
 if member is null then raise exception 'Sign in first';end if;
 if length(trim(coalesce(p_idempotency_key,'')))<8 then raise exception 'Valid request reference required';end if;
 perform pg_advisory_xact_lock(hashtextextended('affiliate-approval:'||p_order_id::text,0));
 if p_approve is null then raise exception 'Choose approve or reject';end if;
 perform 1 from public.orders where id=p_order_id for update;
 if exists(select 1 from private.customer_order_funding f where f.order_id=p_order_id and f.method<>'SPONSOR') then raise exception 'Customer selected advance payment, not sponsor hold';end if;
 if exists(select 1 from public.orders where id=p_order_id and status in('cancelled','returned')) then raise exception 'This order is already closed';end if;

 select * into a from public.affiliate_guest_order_approvals where order_id=p_order_id for update;
 if a.order_id is null or a.sponsor_id<>member then raise exception 'Affiliate order approval not found';end if;
 select * into o from public.orders where id=p_order_id for update;
 if a.status not in('pending','guarantee_requested') then return jsonb_build_object('order_id',a.order_id,'status',a.status,'hold_type',a.hold_type);end if;
 if o.status in('cancelled','returned') then raise exception 'This order is already closed';end if;
 if not p_approve then
  for item in select product_id,sum(quantity)::integer qty from public.order_items where order_id=o.id group by product_id order by product_id loop
   update public.products set stock_quantity=stock_quantity+item.qty,updated_at=now() where id=item.product_id;
  end loop;
  update public.orders set status='cancelled',updated_at=now() where id=o.id;
  update public.affiliate_guest_order_approvals set status='rejected',rejected_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
  return jsonb_build_object('order_id',o.id,'status','rejected');
 end if;
 select exists(select 1 from public.package_activations p where p.member_id=member and p.status='approved') into paid;
 if paid and method<>'MIO' then raise exception 'Paid members must use the Cash Wallet guarantee';end if;
 if method='SPONSOR' then
  if paid then raise exception 'Sponsor guarantee is available to free accounts only';end if;
  select sponsor_id into direct_sponsor from public.member_profiles where user_id=member;
  if direct_sponsor is null then raise exception 'No direct sponsor is available for this request';end if;
  update public.affiliate_guest_order_approvals set status='guarantee_requested',hold_type='SPONSOR_MIO',hold_member_id=direct_sponsor,
   guarantee_requested_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
  return jsonb_build_object('order_id',o.id,'status','guarantee_requested');
 end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 if method='PPV' then
  if paid then raise exception 'PPV guarantee is available to free accounts only';end if;
  select coalesce(sum(amount),0) into ppv_balance from public.point_ledger where member_id=member and point_type='PPV';
  if ppv_balance<a.hold_mio then raise exception 'Insufficient PPV for the required order guarantee';end if;
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
   values(member,'PPV',-a.hold_mio,o.id,'debit','affiliate-ppv-hold:'||o.id) on conflict(idempotency_key)do nothing;
 else
  update public.mio_wallet_accounts set balance=balance-a.hold_mio,updated_at=now() where member_id=member and balance>=a.hold_mio;
  if not found then raise exception 'Cash Wallet balance is below the required order guarantee';end if;
  insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key)
   values(member,-a.hold_mio,'affiliate_order_hold',o.id,'Refundable guest-order security guarantee','affiliate-hold:'||o.id)on conflict(idempotency_key)do nothing;
  method:='MIO';
 end if;
 update public.affiliate_guest_order_approvals set status='approved',hold_amount=a.hold_mio,hold_type=method,hold_member_id=member,approved_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
 return jsonb_build_object('order_id',o.id,'status','approved','hold_type',method,'hold_amount',a.hold_mio);
end
$function$;
CREATE OR REPLACE FUNCTION public.review_sponsor_guest_guarantee(p_order_id uuid, p_approve boolean, p_transaction_pin text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();a public.affiliate_guest_order_approvals%rowtype;
begin
 if member is null then raise exception 'Sign in first';end if;
 perform pg_advisory_xact_lock(hashtextextended('affiliate-approval:'||p_order_id::text,0));
 if p_approve is null then raise exception 'Choose approve or reject';end if;
 perform 1 from public.orders where id=p_order_id for update;
 if exists(select 1 from private.customer_order_funding f where f.order_id=p_order_id and f.method<>'SPONSOR') then raise exception 'Customer selected advance payment, not sponsor hold';end if;
 if exists(select 1 from public.orders where id=p_order_id and status in('cancelled','returned')) then raise exception 'This order is already closed';end if;

 select * into a from public.affiliate_guest_order_approvals where order_id=p_order_id for update;
 if a.order_id is null or a.status<>'guarantee_requested' or a.hold_member_id is distinct from member then raise exception 'Sponsor guarantee request not found';end if;
 if not p_approve then
  update public.affiliate_guest_order_approvals set status='pending',hold_type=null,hold_member_id=null,updated_at=now() where order_id=p_order_id;
  return jsonb_build_object('order_id',p_order_id,'status','pending');
 end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 update public.mio_wallet_accounts set balance=balance-a.hold_mio,updated_at=now() where member_id=member and balance>=a.hold_mio;
 if not found then raise exception 'Sponsor Cash Wallet balance is below the required order guarantee';end if;
 insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key)
 values(member,-a.hold_mio,'affiliate_order_hold',p_order_id,'Refundable sponsor guest-order guarantee','affiliate-hold:'||p_order_id)on conflict(idempotency_key)do nothing;
 update public.affiliate_guest_order_approvals set status='approved',hold_amount=a.hold_mio,hold_type='SPONSOR_MIO',approved_at=now(),guarantee_confirmed_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=p_order_id;
 return jsonb_build_object('order_id',p_order_id,'status','approved','hold_type','SPONSOR_MIO','hold_amount',a.hold_mio);
end
$function$;
CREATE OR REPLACE FUNCTION public.my_affiliate_guest_order_approvals()
 RETURNS TABLE(order_id uuid, order_code text, status text, hold_mio numeric, hold_type text, hold_amount numeric, role text, is_paid boolean, available_mio numeric, available_ppv numeric, created_at timestamp with time zone, approved_at timestamp with time zone, released_at timestamp with time zone, guest_name text, guest_city text, total_pkr numeric, payment_status payment_status, fulfillment_status order_status, item_count bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select a.order_id,o.order_code,a.status,a.hold_mio,a.hold_type,a.hold_amount,
  case when a.sponsor_id=auth.uid() then 'SELLER' else 'GUARANTOR' end,
  exists(select 1 from public.package_activations p where p.member_id=a.sponsor_id and p.status='approved'),
  coalesce((select w.balance from public.mio_wallet_accounts w where w.member_id=auth.uid()),0),
  coalesce((select sum(l.amount) from public.point_ledger l where l.member_id=auth.uid() and l.point_type='PPV'),0),
  a.created_at,a.approved_at,a.released_at,o.shipping_name,o.shipping_city,o.total_pkr,o.payment_status,o.status,count(i.id)
 from public.affiliate_guest_order_approvals a join public.orders o on o.id=a.order_id
 left join public.order_items i on i.order_id=o.id
 where (a.sponsor_id=auth.uid() or(a.status='guarantee_requested' and a.hold_member_id=auth.uid())) and not exists(select 1 from private.customer_order_funding f where f.order_id=a.order_id and f.method='ADVANCE')
 group by a.order_id,o.id order by a.created_at desc
$function$;
CREATE OR REPLACE FUNCTION public.cancel_unpaid_order(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype; item record; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null or (o.buyer_id is distinct from auth.uid() and not private.has_role('admin') and not exists(select 1 from private.customer_order_funding f where f.order_id=o.id and f.customer_id=auth.uid())) then raise exception 'Order not found'; end if;
 if exists(select 1 from private.customer_order_funding where order_id=o.id and (status='submitted' or (not private.has_role('admin') and status in('approved','refund_due')))) then raise exception 'Payment is under review or paid; contact support to cancel';end if;
 if o.status='cancelled' then return; end if;
 if o.payment_status<>'unconfirmed' or o.status not in('placed','confirmed','processing') or (not private.has_role('admin') and o.status<>'placed') then raise exception 'This order cannot be cancelled here; contact the company'; end if;
 for item in select product_id,sum(quantity)::integer qty from public.order_items where order_id=o.id group by product_id order by product_id loop
  update public.products set stock_quantity=stock_quantity+item.qty,updated_at=now() where id=item.product_id;
 end loop;
 update public.orders set status='cancelled',updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'UNPAID_ORDER_CANCELLED','order',o.id,jsonb_build_object('status',o.status),jsonb_build_object('status','cancelled','inventory_restored',true));
end $function$;
revoke all on function private.place_shopping_order_core(jsonb,text,text,text,text,text,text,text,text) from public,anon,authenticated;
revoke all on function private.guard_customer_order_progress() from public,anon,authenticated;
revoke all on function private.close_customer_order_funding() from public,anon,authenticated;
revoke all on function public.my_shopping_account() from public,anon,authenticated;
grant execute on function public.my_shopping_account() to authenticated;
revoke all on function public.complete_shopping_profile(text,text,boolean) from public,anon,authenticated;
grant execute on function public.complete_shopping_profile(text,text,boolean) to authenticated;
revoke all on function public.join_network_from_shopping(text,boolean) from public,anon,authenticated;
grant execute on function public.join_network_from_shopping(text,boolean) to authenticated;
revoke all on function public.shopping_payment_accounts() from public,anon,authenticated;
grant execute on function public.shopping_payment_accounts() to authenticated;
revoke all on function public.admin_save_shopping_payment_account(uuid,text,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.admin_save_shopping_payment_account(uuid,text,text,text,text,boolean) to authenticated;
revoke all on function public.submit_shopping_advance(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.submit_shopping_advance(uuid,uuid,text) to authenticated;
revoke all on function public.admin_review_shopping_advance(uuid,boolean,numeric,text) from public,anon,authenticated;
grant execute on function public.admin_review_shopping_advance(uuid,boolean,numeric,text) to authenticated;
revoke all on function public.my_shopping_orders() from public,anon,authenticated;
grant execute on function public.my_shopping_orders() to authenticated;
revoke all on function public.admin_shopping_payments() from public,anon,authenticated;
grant execute on function public.admin_shopping_payments() to authenticated;
revoke all on function public.admin_record_shopping_refund(uuid,text) from public,anon,authenticated;
grant execute on function public.admin_record_shopping_refund(uuid,text) to authenticated;
revoke all on function public.place_shopping_order(jsonb,text,text,text,text,text,text,text) from public,anon,authenticated;
grant execute on function public.place_shopping_order(jsonb,text,text,text,text,text,text,text) to authenticated;
notify pgrst,'reload schema';
