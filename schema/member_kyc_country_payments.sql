-- Member identity verification and country payments. Financial writes run only in guarded RPCs.
create table private.member_kyc (
 member_id uuid primary key references public.member_profiles(user_id), revision integer not null default 1,
 document_type text not null check(document_type in ('cnic','passport','licence')),
 document_number text not null, expires_on date not null, country_code text not null,
 identity_snapshot jsonb not null, front_path text not null, back_path text, selfie_path text not null,
 status text not null default 'pending' check(status in ('pending','reviewing','approved','rejected','correction_required')),
 remarks text not null default '', submitted_at timestamptz not null default now(), reviewed_at timestamptz, reviewed_by uuid
);
create unique index member_kyc_document_unique on private.member_kyc(country_code,document_type,document_number) where status in ('pending','reviewing','approved');
create table private.payment_countries (
 country_code text primary key check(country_code ~ '^[A-Z]{2}$'), currency text not null check(currency ~ '^[A-Z]{3,8}$'),
 deposit_rate numeric not null check(deposit_rate>0 and deposit_rate<1000000000), withdrawal_rate numeric not null check(withdrawal_rate>0 and withdrawal_rate<1000000000),
 bank_limit integer not null default 3 check(bank_limit between 1 and 20), mobile_limit integer not null default 2 check(mobile_limit between 1 and 20),
 enabled boolean not null default true, updated_at timestamptz not null default now()
);
create table private.payment_methods (
 id uuid primary key default gen_random_uuid(), country_code text not null references private.payment_countries,
 kind text not null check(kind in ('bank','mobile','crypto')), label text not null check(length(label) between 2 and 80),
 network text not null default '', providers jsonb not null default '[]' check(jsonb_typeof(providers)='array'),
 deposit_enabled boolean not null default false, withdrawal_enabled boolean not null default false,
 deposit_min numeric not null default 1 check(deposit_min>=1), deposit_max numeric not null default 1000000,
 withdrawal_min numeric not null default 1 check(withdrawal_min>=1), withdrawal_max numeric not null default 1000000,
 currency text, deposit_rate numeric, withdrawal_rate numeric, instructions text not null default '',
 updated_at timestamptz not null default now(),
 check(deposit_max>=deposit_min and deposit_max<=1000000000 and withdrawal_max>=withdrawal_min and withdrawal_max<=1000000000),
 check(kind<>'crypto' or (length(network)>0 and currency='USDT')),
 check((deposit_rate is null or (deposit_rate>0 and deposit_rate<1000000000)) and (withdrawal_rate is null or (withdrawal_rate>0 and withdrawal_rate<1000000000))),
 check(kind<>'crypto' or ((not deposit_enabled or coalesce(deposit_rate>0,false)) and (not withdrawal_enabled or coalesce(withdrawal_rate>0,false))))
);
create table private.payment_company_accounts (
 id uuid primary key default gen_random_uuid(), method_id uuid not null references private.payment_methods,
 title text not null, provider text not null default '', account text not null, instructions text not null default '', enabled boolean not null default true,
 updated_at timestamptz not null default now()
);
create table private.member_payout_accounts (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.member_profiles(user_id),
 method_id uuid not null references private.payment_methods, title text not null, provider text not null default '', account text not null,
 enabled boolean not null default true, revision integer not null default 1, updated_at timestamptz not null default now()
);
create index member_payout_owner on private.member_payout_accounts(member_id);
create table private.member_payment_requests (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.member_profiles(user_id),
 direction text not null check(direction in ('deposit','withdrawal')), method_id uuid not null references private.payment_methods,
 country_code text not null, amount numeric not null check(amount>0 and amount=trunc(amount) and amount<=1000000000),
 rate numeric not null check(rate>0), currency text not null, settlement_amount numeric not null check(settlement_amount>0),
 account_snapshot jsonb not null, method_snapshot jsonb not null, sender_details jsonb not null default '{}',
 reference text not null default '', proof_path text, payment_reference text not null default '', receipt_path text,
 status text not null default 'pending' check(status in ('pending','approved','processing','completed','rejected','cancelled')),
 remarks text not null default '', idempotency_key text not null, request_signature jsonb not null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), reviewed_by uuid,
 unique(member_id,idempotency_key)
);
create index member_payment_history on private.member_payment_requests(member_id,created_at desc);
create index member_payment_queue on private.member_payment_requests(country_code,status,created_at desc);
create unique index member_deposit_reference on private.member_payment_requests(method_id,lower(reference)) where direction='deposit' and status not in ('rejected','cancelled');
create table private.member_payment_events (
 id uuid primary key default gen_random_uuid(), actor_id uuid not null, member_id uuid, entity_id uuid,
 action text not null, detail jsonb not null default '{}', created_at timestamptz not null default now()
);
-- Tables are private; no direct table privileges. RPCs enforce ownership and operations role.
do $$ declare t text; begin foreach t in array array['member_kyc','payment_countries','payment_methods','payment_company_accounts','member_payout_accounts','member_payment_requests','member_payment_events'] loop
 execute format('alter table private.%I enable row level security',t);
 execute format('revoke all on private.%I from public,anon,authenticated',t);
end loop; end $$;
insert into private.payment_countries(country_code,currency,deposit_rate,withdrawal_rate) values('PK','PKR',300,290);
insert into private.payment_methods(country_code,kind,label,providers,deposit_enabled,withdrawal_enabled)
 values('PK','bank','Bank Transfer','["HBL","UBL","MCB","Allied Bank","Meezan Bank","Bank Alfalah","Faysal Bank","Askari Bank","National Bank of Pakistan","Bank of Punjab","Standard Chartered"]',true,true),
 ('PK','mobile','Mobile Wallet','["JazzCash","Easypaisa","SadaPay","NayaPay"]',true,true);
insert into private.payment_methods(country_code,kind,label,network,currency) values('PK','crypto','USDT · BNB / BEP20','BEP20','USDT'),('PK','crypto','USDT · TRC20','TRC20','USDT');

create function private.payment_member() returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid();begin if u is null or not private.registered_member(u) then raise exception 'Active member account required';end if;return u;end$$;
create function private.payment_admin() returns void language plpgsql security definer set search_path='' as $$
begin if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;end$$;
create function private.kyc_is_valid(p_member uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.member_kyc k join public.member_profiles p on p.user_id=k.member_id where k.member_id=p_member and k.status='approved' and k.expires_on>=(now() at time zone 'UTC')::date and k.identity_snapshot=jsonb_build_object('full_name',p.full_name,'country_code',p.country_code,'gender',p.gender,'date_of_birth',p.date_of_birth));$$;
create function private.require_member_kyc(p_member uuid) returns void language plpgsql security definer set search_path='' as $$
begin if not private.kyc_is_valid(p_member) then raise exception 'Complete KYC in My Profile and wait for admin approval before proceeding or withdrawing';end if;end$$;
create function private.payment_file_valid(p_path text,p_owner uuid,p_bucket text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(split_part(p_path,'/',1)=p_owner::text and exists(select 1 from storage.objects where bucket_id=p_bucket and name=p_path),false);$$;
create function private.payment_event(p_member uuid,p_entity uuid,p_action text,p_detail jsonb default '{}') returns void language sql security definer set search_path='' as $$
 insert into private.member_payment_events(actor_id,member_id,entity_id,action,detail) values(auth.uid(),p_member,p_entity,p_action,p_detail);$$;
create function private.payment_notice(p_member uuid,p_entity uuid,p_title text,p_message text) returns void language sql security definer set search_path='' as $$
 insert into public.member_notifications(member_id,category,title,message,entity_type,entity_id) values(p_member,'wallet',p_title,left(p_message,500),'member_payment',p_entity);$$;

create function private.kyc_profile_guard() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.full_name is distinct from old.full_name then
  new.full_name:=upper(regexp_replace(trim(new.full_name),' +',' ','g'));
  if new.full_name !~ '^[A-Z]+( [A-Z]+)*$' then raise exception 'Full name must contain A-Z letters and spaces only';end if;
 end if;
 if row(new.full_name,new.country_code,new.gender,new.date_of_birth) is distinct from row(old.full_name,old.country_code,old.gender,old.date_of_birth) then
  if exists(select 1 from private.member_kyc where member_id=old.user_id and status='approved') and not private.has_role('admin') then raise exception 'Verified identity is locked. Contact support for a correction';end if;
  update private.member_kyc set status='correction_required',remarks='Profile identity changed. Resubmit KYC for review.',reviewed_at=null where member_id=old.user_id and status in ('pending','reviewing','approved');
 end if;
 return new;
end$$;
create trigger zz_kyc_profile_guard before update of full_name,country_code,gender,date_of_birth on public.member_profiles for each row execute function private.kyc_profile_guard();

create function private.save_member_kyc(p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.payment_member();p public.member_profiles; k private.member_kyc; typ text:=p_data->>'document_type';num text:=upper(regexp_replace(coalesce(p_data->>'document_number',''),'[ -]','','g')); exp date:=(p_data->>'expires_on')::date; snap jsonb;
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>16384 then raise exception 'Invalid or oversized payment details';end if;
 perform pg_advisory_xact_lock(hashtextextended('member-payment:'||u,0));
 if (select count(*) from private.member_payment_events where actor_id=u and action='kyc_submitted' and created_at>now()-interval '1 hour')>=5 then raise exception 'Too many KYC submissions. Try again later';end if;
 select * into p from public.member_profiles where user_id=u for update;
 select * into k from private.member_kyc where member_id=u for update;
 if k.status='approved' and k.expires_on>=(now() at time zone 'UTC')::date then raise exception 'KYC already approved. Contact support for identity changes';end if;
 if p.full_name !~ '^[A-Z]+( [A-Z]+)*$' or p.date_of_birth is null or p.gender is null or p.country_code is null or coalesce(p.phone,'') !~ '^\+[0-9]{7,15}$' then raise exception 'Complete your profile: capital-letter name, country, phone, gender and date of birth';end if;
 if typ is null or typ not in ('cnic','passport','licence') or exp is null or exp<(now() at time zone 'UTC')::date or num !~ '^[A-Z0-9]{4,40}$' or (typ='cnic' and p.country_code='PK' and num !~ '^[0-9]{13}$') then raise exception 'Check document type, number and expiry date';end if;
 if not private.payment_file_valid(p_data->>'front_path',u,'member-kyc-documents') or not private.payment_file_valid(p_data->>'selfie_path',u,'member-kyc-documents') or (typ<>'passport' and not private.payment_file_valid(p_data->>'back_path',u,'member-kyc-documents')) then raise exception 'Upload all required identity photos';end if;
 snap:=jsonb_build_object('full_name',p.full_name,'country_code',p.country_code,'gender',p.gender,'date_of_birth',p.date_of_birth);
 if k.member_id is not null then perform private.payment_event(u,u,'kyc_previous_submission',to_jsonb(k));end if;
 insert into private.member_kyc(member_id,document_type,document_number,expires_on,country_code,identity_snapshot,front_path,back_path,selfie_path)
 values(u,typ,num,exp,p.country_code,snap,p_data->>'front_path',case when typ='passport' then null else p_data->>'back_path' end,p_data->>'selfie_path')
 on conflict(member_id) do update set revision=private.member_kyc.revision+1,document_type=excluded.document_type,document_number=excluded.document_number,expires_on=excluded.expires_on,country_code=excluded.country_code,identity_snapshot=excluded.identity_snapshot,front_path=excluded.front_path,back_path=excluded.back_path,selfie_path=excluded.selfie_path,status='pending',remarks='',submitted_at=now(),reviewed_at=null,reviewed_by=null;
 perform private.payment_notice(u,u,'KYC submitted','Your identity verification is pending admin review.');
 perform private.payment_event(u,u,'kyc_submitted');return jsonb_build_object('status','pending');
end$$;
create function private.review_member_kyc(p_member uuid,p_revision integer,p_status text,p_remarks text) returns void language plpgsql security definer set search_path='' as $$
declare k private.member_kyc;p public.member_profiles;begin
 perform private.payment_admin();perform private.require_recent_totp();
 perform pg_advisory_xact_lock(hashtextextended('member-payment:'||p_member,0));
 select * into p from public.member_profiles where user_id=p_member for update;
 select * into k from private.member_kyc where member_id=p_member for update;
 if k.member_id is null or k.revision<>p_revision then raise exception 'KYC changed. Refresh before reviewing';end if;
 if p_status is null or p_status not in ('reviewing','approved','rejected','correction_required') then raise exception 'Invalid KYC status';end if;
 if p_status in ('rejected','correction_required') and length(trim(coalesce(p_remarks,'')))<3 then raise exception 'Explain the required correction';end if;
 if p_status='approved' and (k.expires_on<(now() at time zone 'UTC')::date or k.identity_snapshot<>jsonb_build_object('full_name',p.full_name,'country_code',p.country_code,'gender',p.gender,'date_of_birth',p.date_of_birth)) then raise exception 'Identity changed or document expired; request resubmission';end if;
 update private.member_kyc set status=p_status,remarks=left(coalesce(p_remarks,''),1000),reviewed_by=auth.uid(),reviewed_at=now() where member_id=p_member;
 perform private.payment_event(p_member,p_member,'kyc_'||p_status,jsonb_build_object('revision',p_revision,'remarks',p_remarks));
 perform private.payment_notice(p_member,p_member,'KYC '||replace(p_status,'_',' '),coalesce(nullif(p_remarks,''),'Your KYC status has been updated.'));
end$$;

create function private.save_payout_account(p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=private.payment_member();mid uuid:=(p_data->>'method_id')::uuid;aid uuid:=nullif(p_data->>'id','')::uuid;m private.payment_methods;c private.payment_countries;p public.member_profiles;lim integer;old private.member_payout_accounts; acct text:=trim(coalesce(p_data->>'account','')); v_title text:=upper(trim(coalesce(p_data->>'title','')));prov text:=trim(coalesce(p_data->>'provider',''));begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>16384 then raise exception 'Invalid or oversized payment details';end if;
 perform pg_advisory_xact_lock(hashtextextended('member-payment:'||u,0));
 if (select count(*) from private.member_payment_events where actor_id=u and action='payout_account_saved' and created_at>now()-interval '1 hour')>=30 then raise exception 'Too many account changes. Try again later';end if;
 select * into p from public.member_profiles where user_id=u;
 select * into m from private.payment_methods where id=mid;
 select * into c from private.payment_countries where country_code=m.country_code;
 if m.id is null or m.country_code is distinct from p.country_code or not c.enabled or not m.withdrawal_enabled then raise exception 'Withdrawal method unavailable for your country';end if;
 if length(acct) not between 5 and 180 or length(v_title) not between 2 and 150 then raise exception 'Account title and valid account details required';end if;
 if m.kind in ('bank','mobile') and not(m.providers ? prov) then raise exception 'Select a configured bank or wallet provider';end if;
 if m.kind='bank' and p.country_code='PK' and upper(replace(acct,' ','')) !~ '^PK[0-9]{2}[A-Z]{4}[A-Z0-9]{16}$' then raise exception 'Enter a valid 24-character Pakistan IBAN';end if;
 if m.kind='mobile' and acct !~ '^\+?[0-9]{7,15}$' then raise exception 'Enter a valid mobile wallet number';end if;
 if m.kind='crypto' and ((m.network='BEP20' and acct !~ '^0x[0-9a-fA-F]{40}$') or (m.network='TRC20' and acct !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$')) then raise exception 'Address does not match the selected network';end if;
 if aid is not null then select * into old from private.member_payout_accounts where id=aid and member_id=u for update;if old.id is null then raise exception 'Saved account not found';end if;end if;
 lim:=case m.kind when 'bank' then c.bank_limit when 'mobile' then c.mobile_limit else 1 end;
 if coalesce((p_data->>'enabled')::boolean,true) and (select count(*) from private.member_payout_accounts a join private.payment_methods x on x.id=a.method_id where a.member_id=u and a.enabled and x.kind=m.kind and (aid is null or a.id<>aid))>=lim then raise exception 'Saved account limit reached (%)',lim;end if;
 if aid is null then insert into private.member_payout_accounts(member_id,method_id,title,provider,account) values(u,mid,v_title,prov,acct) returning id into aid;
 else update private.member_payout_accounts set method_id=mid,title=v_title,provider=prov,account=acct,enabled=coalesce((p_data->>'enabled')::boolean,true),revision=revision+1,updated_at=now() where id=aid and member_id=u;end if;
 perform private.payment_event(u,aid,'payout_account_saved');return aid;
end$$;

create function private.admin_save_payment_config(p_kind text,p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid:=nullif(p_data->>'id','')::uuid;cc text:=upper(p_data->>'country_code');m private.payment_methods;
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>16384 then raise exception 'Invalid or oversized payment details';end if;
 perform private.payment_admin();perform private.require_recent_totp();
 if p_kind='country' then
  if not coalesce(private.valid_market_country(cc),false) then raise exception 'Select a valid country';end if;
  insert into private.payment_countries(country_code,currency,deposit_rate,withdrawal_rate,bank_limit,mobile_limit,enabled)
  values(cc,upper(p_data->>'currency'),(p_data->>'deposit_rate')::numeric,(p_data->>'withdrawal_rate')::numeric,coalesce((p_data->>'bank_limit')::int,3),coalesce((p_data->>'mobile_limit')::int,2),coalesce((p_data->>'enabled')::boolean,true))
  on conflict(country_code) do update set currency=excluded.currency,deposit_rate=excluded.deposit_rate,withdrawal_rate=excluded.withdrawal_rate,bank_limit=excluded.bank_limit,mobile_limit=excluded.mobile_limit,enabled=excluded.enabled,updated_at=now();
 elsif p_kind='method' then
  if rid is not null then select * into m from private.payment_methods where id=rid for update;if m.id is null then raise exception 'Method not found';end if;
   if m.kind is distinct from p_data->>'kind' or m.country_code is distinct from cc or m.network is distinct from coalesce(p_data->>'network','') then raise exception 'Create a new method to change country, type or network';end if;
  end if;
  insert into private.payment_methods(id,country_code,kind,label,network,providers,deposit_enabled,withdrawal_enabled,deposit_min,deposit_max,withdrawal_min,withdrawal_max,currency,deposit_rate,withdrawal_rate,instructions)
  values(coalesce(rid,gen_random_uuid()),cc,p_data->>'kind',trim(p_data->>'label'),coalesce(p_data->>'network',''),coalesce(p_data->'providers','[]'),coalesce((p_data->>'deposit_enabled')::boolean,false),coalesce((p_data->>'withdrawal_enabled')::boolean,false),coalesce((p_data->>'deposit_min')::numeric,1),coalesce((p_data->>'deposit_max')::numeric,1000000),coalesce((p_data->>'withdrawal_min')::numeric,1),coalesce((p_data->>'withdrawal_max')::numeric,1000000),nullif(p_data->>'currency',''),nullif(p_data->>'deposit_rate','')::numeric,nullif(p_data->>'withdrawal_rate','')::numeric,left(coalesce(p_data->>'instructions',''),2000))
  on conflict(id) do update set label=excluded.label,providers=excluded.providers,deposit_enabled=excluded.deposit_enabled,withdrawal_enabled=excluded.withdrawal_enabled,deposit_min=excluded.deposit_min,deposit_max=excluded.deposit_max,withdrawal_min=excluded.withdrawal_min,withdrawal_max=excluded.withdrawal_max,currency=excluded.currency,deposit_rate=excluded.deposit_rate,withdrawal_rate=excluded.withdrawal_rate,instructions=excluded.instructions,updated_at=now() returning id into rid;
 elsif p_kind='company_account' then
  select * into m from private.payment_methods where id=(p_data->>'method_id')::uuid;
  if m.id is null then raise exception 'Payment method not found';end if;
  if length(trim(coalesce(p_data->>'account',''))) not between 5 and 180 or length(trim(coalesce(p_data->>'title',''))) not between 2 and 150 then raise exception 'Account title and details required';end if;
  if m.kind in ('bank','mobile') and not(m.providers ? coalesce(p_data->>'provider','')) then raise exception 'Select a configured bank or wallet provider';end if;
  if m.kind='bank' and m.country_code='PK' and upper(replace(p_data->>'account',' ','')) !~ '^PK[0-9]{2}[A-Z]{4}[A-Z0-9]{16}$' then raise exception 'Enter a valid 24-character Pakistan IBAN';end if;
  if m.kind='mobile' and p_data->>'account' !~ '^\+?[0-9]{7,15}$' then raise exception 'Enter a valid mobile wallet number';end if;
  if m.kind='crypto' and ((m.network='BEP20' and p_data->>'account' !~ '^0x[0-9a-fA-F]{40}$') or (m.network='TRC20' and p_data->>'account' !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$')) then raise exception 'Address does not match the selected network';end if;
  insert into private.payment_company_accounts(id,method_id,title,provider,account,instructions,enabled)
  values(coalesce(rid,gen_random_uuid()),(p_data->>'method_id')::uuid,trim(p_data->>'title'),coalesce(p_data->>'provider',''),trim(p_data->>'account'),left(coalesce(p_data->>'instructions',''),2000),coalesce((p_data->>'enabled')::boolean,true))
  on conflict(id) do update set method_id=excluded.method_id,title=excluded.title,provider=excluded.provider,account=excluded.account,instructions=excluded.instructions,enabled=excluded.enabled,updated_at=now() returning id into rid;
 else raise exception 'Unknown configuration';end if;
 perform private.payment_event(null,rid,'config_'||p_kind,p_data);return rid;
end$$;

-- Explicit payment actions keep the legacy cash statement correct, without fabricating mint/transfer entries.
do $$ declare r record; d text;begin
 for r in select conname,pg_get_constraintdef(oid) def from pg_constraint where conrelid='public.mio_ledger'::regclass and conname in ('mio_ledger_action_check','mio_ledger_amount_check') loop
 d:=replace(replace(r.def,'''admin_mint''::text','''admin_mint''::text, ''payment_deposit''::text, ''payment_refund''::text'),'''admin_burn''::text','''admin_burn''::text, ''payment_withdrawal''::text');
 execute format('alter table public.mio_ledger drop constraint %I',r.conname);execute format('alter table public.mio_ledger add constraint %I %s',r.conname,d);
 end loop;
end$$;
create function private.payment_cash_entry(p_member uuid,p_request uuid,p_amount numeric,p_action text) returns void language plpgsql security definer set search_path='' as $$
begin
 update public.mio_wallet_accounts set balance=balance+p_amount,updated_at=now() where member_id=p_member and balance+p_amount>=0;
 if not found then raise exception 'Insufficient Cash Wallet balance';end if;
 insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key) values(p_member,p_amount,p_action,replace(p_action,'_',' ')||' · '||p_request,'member-payment:'||p_request||':'||p_action);
 insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key) values(p_member,'cash',p_amount,p_action,replace(p_action,'_',' '),jsonb_build_object('payment_request_id',p_request),'member-payment:'||p_request||':'||p_action);
end$$;
create function private.submit_member_payment(p_data jsonb,p_pin text,p_key text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.payment_member();m private.payment_methods;c private.payment_countries;p public.member_profiles;r private.member_payment_requests;a private.member_payout_accounts;ca private.payment_company_accounts;
 amount numeric;rate numeric;currency text;snap jsonb;dir text:=p_data->>'direction';ref text:=trim(coalesce(p_data->>'reference',''));rid uuid;
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>16384 then raise exception 'Invalid or oversized payment details';end if;
 if dir is null or dir not in ('deposit','withdrawal') or coalesce(p_data->>'amount','') !~ '^[0-9]{1,10}$' then raise exception 'Enter a whole-number MIO amount';end if;
 amount:=(p_data->>'amount')::numeric;if amount<=0 or amount>1000000000 then raise exception 'Invalid amount';end if;
 if length(coalesce(p_key,'')) not between 8 and 120 then raise exception 'Request reference required';end if;
 perform pg_advisory_xact_lock(hashtextextended('member-payment:'||u,0));
 select * into r from private.member_payment_requests where member_id=u and idempotency_key=p_key;
 if r.id is not null then if r.request_signature<>p_data then raise exception 'Request reference already used for different details';end if;return to_jsonb(r);end if;
 if (select count(*) from private.member_payment_requests where member_id=u and created_at>now()-interval '1 hour')>=20 then raise exception 'Too many payment requests. Try again later';end if;
 select * into p from public.member_profiles where user_id=u for update;
 select * into m from private.payment_methods where id=(p_data->>'method_id')::uuid for share;
 select * into c from private.payment_countries where country_code=p.country_code for share;
 if m.id is null or c.country_code is null or not c.enabled or m.country_code is distinct from p.country_code then raise exception 'Payment method unavailable for your profile country';end if;
 if dir='withdrawal' then
  perform private.require_member_kyc(u);perform private.require_transaction_pin(p_pin,u);
  if not m.withdrawal_enabled or amount<m.withdrawal_min or amount>m.withdrawal_max then raise exception 'Check withdrawal method availability and limits';end if;
  select * into a from private.member_payout_accounts where id=(p_data->>'account_id')::uuid and member_id=u and method_id=m.id and enabled for share;
  if a.id is null then raise exception 'Select your saved payout account';end if;
  if (p_data->>'account_revision')::integer is distinct from a.revision then raise exception 'Saved account changed. Review and confirm again';end if;
  rate:=coalesce(m.withdrawal_rate,c.withdrawal_rate);snap:=to_jsonb(a)-'member_id';
 else
  if not m.deposit_enabled or amount<m.deposit_min or amount>m.deposit_max then raise exception 'Check deposit method availability and limits';end if;
  select * into ca from private.payment_company_accounts where id=(p_data->>'account_id')::uuid and method_id=m.id and enabled for share;
  if ca.id is null then raise exception 'Select a company receiving account';end if;
  if p_data->>'account_version' is distinct from ca.updated_at::text then raise exception 'Company account changed. Review the payment details again';end if;
  if length(ref) not between 3 and 180 or not private.payment_file_valid(p_data->>'proof_path',u,'member-payment-proofs') then raise exception 'Payment reference and proof required';end if;
  if length(trim(coalesce(p_data#>>'{sender_details,name}','')))<2 then raise exception 'Sender name required';end if;
  rate:=coalesce(m.deposit_rate,c.deposit_rate);snap:=to_jsonb(ca);
 end if;
 currency:=coalesce(m.currency,c.currency);
 if m.kind='crypto' and (case when dir='withdrawal' then m.withdrawal_rate else m.deposit_rate end) is null then raise exception 'Crypto conversion rate is not configured';end if;
 if (p_data->>'quoted_rate')::numeric is distinct from rate then raise exception 'Rate changed. Review the new amount before submitting';end if;
 insert into private.member_payment_requests(member_id,direction,method_id,country_code,amount,rate,currency,settlement_amount,account_snapshot,method_snapshot,sender_details,reference,proof_path,idempotency_key,request_signature)
 values(u,dir,m.id,p.country_code,amount,rate,currency,round(amount*rate,case when m.kind='crypto' then 6 else 2 end),snap,to_jsonb(m),coalesce(p_data->'sender_details','{}'),ref,case when dir='deposit' then p_data->>'proof_path' end,p_key,p_data) returning id into rid;
 if dir='withdrawal' then perform private.payment_cash_entry(u,rid,-amount,'payment_withdrawal');end if;
 perform private.payment_event(u,rid,dir||'_submitted',jsonb_build_object('amount',amount,'rate',rate,'currency',currency));
 perform private.payment_notice(u,rid,initcap(dir)||' request submitted',amount||' MIO · Pending review.');
 return(select to_jsonb(x) from private.member_payment_requests x where id=rid);
end$$;
create function private.review_member_payment(p_id uuid,p_status text,p_remarks text,p_reference text,p_receipt text) returns void language plpgsql security definer set search_path='' as $$
declare r private.member_payment_requests;u uuid:=auth.uid();admin boolean:=coalesce(private.has_role('admin'),false);
begin
 if u is null then raise exception 'Sign in required';end if;
 if admin then perform private.require_recent_totp();end if;
 select * into r from private.member_payment_requests where id=p_id for update;
 if r.id is null or (not admin and r.member_id<>u) then raise exception 'Request not found';end if;
 if p_status is null or p_status not in ('approved','processing','completed','rejected','cancelled') then raise exception 'Invalid status';end if;
 if not admin and (p_status<>'cancelled' or r.status<>'pending') then raise exception 'Only a pending request can be cancelled';end if;
 if r.status=p_status then return;end if;
 if r.status in ('completed','rejected','cancelled') then raise exception 'This request is already final';end if;
 if p_status='cancelled' and r.status<>'pending' then raise exception 'Only pending requests can be cancelled';end if;
 if p_status='approved' and r.status<>'pending' then raise exception 'Invalid status transition';end if;
 if p_status='processing' and r.direction<>'withdrawal' then raise exception 'Deposits must be verified then completed';end if;
 if p_status='approved' and r.direction='deposit' then raise exception 'Use Completed after actual deposit verification';end if;
 if p_status='rejected' and length(trim(coalesce(p_remarks,'')))<3 then raise exception 'Rejection reason required';end if;
 if p_status='completed' and r.direction='withdrawal' then
  if length(trim(coalesce(p_reference,'')))<3 or not private.payment_file_valid(p_receipt,u,'member-payment-proofs') then raise exception 'Payment reference and company receipt required after sending payment';end if;
  perform private.require_member_kyc(r.member_id);
 end if;
 if p_status in ('cancelled','rejected') and r.direction='withdrawal' then perform private.payment_cash_entry(r.member_id,r.id,r.amount,'payment_refund');end if;
 if p_status='completed' and r.direction='deposit' then perform private.payment_cash_entry(r.member_id,r.id,r.amount,'payment_deposit');end if;
 update private.member_payment_requests set status=p_status,remarks=left(coalesce(p_remarks,''),1000),payment_reference=coalesce(p_reference,''),receipt_path=case when p_status='completed' and direction='withdrawal' then p_receipt else receipt_path end,reviewed_by=u,updated_at=now() where id=r.id;
 perform private.payment_event(r.member_id,r.id,r.direction||'_'||p_status,jsonb_build_object('remarks',p_remarks,'reference',p_reference));
 perform private.payment_notice(r.member_id,r.id,initcap(r.direction)||' '||p_status,r.amount||' MIO · '||r.settlement_amount||' '||r.currency||'. '||coalesce(p_remarks,''));
end$$;

create function private.my_payment_workspace(p_offset integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.payment_member();cc text;begin
 select country_code into cc from public.member_profiles where user_id=u;
 return jsonb_build_object('profile',(select jsonb_build_object('full_name',full_name,'country_code',country_code,'phone',phone,'gender',gender,'date_of_birth',date_of_birth) from public.member_profiles where user_id=u),
 'kyc',(select to_jsonb(k) from private.member_kyc k where member_id=u),'kyc_valid',private.kyc_is_valid(u),
 'country',(select to_jsonb(c) from private.payment_countries c where country_code=cc),'cash_balance',(select balance from public.mio_wallet_accounts where member_id=u),
 'pending_balance',(select coalesce(sum(amount),0) from private.member_payment_requests where member_id=u and direction='withdrawal' and status in ('pending','approved','processing')),
 'methods',coalesce((select jsonb_agg(m order by label) from private.payment_methods m where country_code=cc),'[]'),
 'company_accounts',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('version',a.updated_at::text)) from private.payment_company_accounts a join private.payment_methods m on m.id=a.method_id where m.country_code=cc and m.deposit_enabled and a.enabled),'[]'),
 'payout_accounts',coalesce((select jsonb_agg(a order by updated_at desc) from private.member_payout_accounts a where member_id=u),'[]'),
 'history',coalesce((select jsonb_agg(x order by created_at desc) from(select r.* from private.member_payment_requests r where member_id=u order by created_at desc limit 25 offset greatest(p_offset,0))x),'[]'),
 'total',(select count(*) from private.member_payment_requests where member_id=u));
end$$;
create function private.admin_payment_workspace(p_country text default 'PK',p_offset integer default 0,p_status text default '') returns jsonb language plpgsql security definer set search_path='' as $$
begin perform private.payment_admin();return jsonb_build_object(
 'country',(select to_jsonb(c) from private.payment_countries c where country_code=p_country),
 'methods',coalesce((select jsonb_agg(m order by kind,label) from private.payment_methods m where country_code=p_country),'[]'),
 'company_accounts',coalesce((select jsonb_agg(a) from private.payment_company_accounts a join private.payment_methods m on m.id=a.method_id where m.country_code=p_country),'[]'),
 'requests',coalesce((select jsonb_agg(x order by created_at desc) from(select r.*,p.full_name,p.member_code from private.member_payment_requests r join public.member_profiles p on p.user_id=r.member_id where r.country_code=p_country and (p_status='' or r.status=p_status) order by r.created_at desc limit 25 offset greatest(p_offset,0))x),'[]'),
 'total',(select count(*) from private.member_payment_requests where country_code=p_country and (p_status='' or status=p_status)),
 'kyc',coalesce((select jsonb_agg(x order by submitted_at desc) from(select k.*,p.full_name,p.member_code from private.member_kyc k join public.member_profiles p on p.user_id=k.member_id where k.country_code=p_country and (p_status='' or k.status=p_status) order by k.submitted_at desc limit 25 offset greatest(p_offset,0))x),'[]'),
 'kyc_total',(select count(*) from private.member_kyc where country_code=p_country and (p_status='' or status=p_status)),
 'events',coalesce((select jsonb_agg(x order by created_at desc) from(select id,actor_id,member_id,entity_id,action,created_at from private.member_payment_events order by created_at desc limit 25 offset greatest(p_offset,0))x),'[]'));
end$$;

create function private.guard_proceed_kyc() returns trigger language plpgsql security definer set search_path='' as $$begin perform private.require_member_kyc(new.member_id);return new;end$$;
create trigger member_kyc_before_proceed before insert on public.proceed_wallet_conversions for each row execute function private.guard_proceed_kyc();

-- Private immutable uploads. No member overwrite/delete policies: reviewed evidence cannot change in place.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('member-kyc-documents','member-kyc-documents',false,5242880,array['image/jpeg','image/png','image/webp']),
 ('member-payment-proofs','member-payment-proofs',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf']);
create function private.member_payment_file_access(p_bucket text,p_name text,p_write boolean) returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then return false;end if;
 if p_write then return split_part(p_name,'/',1)=auth.uid()::text and (private.registered_member(auth.uid()) or private.has_role('admin'));end if;
 if private.has_role('admin') or split_part(p_name,'/',1)=auth.uid()::text then return true;end if;
 return p_bucket='member-payment-proofs' and exists(select 1 from private.member_payment_requests where member_id=auth.uid() and receipt_path=p_name);
end$$;
create policy member_private_upload on storage.objects for insert to authenticated with check(bucket_id in ('member-kyc-documents','member-payment-proofs') and private.member_payment_file_access(bucket_id,name,true));
create policy member_private_read on storage.objects for select to authenticated using(bucket_id in ('member-kyc-documents','member-payment-proofs') and private.member_payment_file_access(bucket_id,name,false));

-- Public invoker facades. Only the guarded commands below are callable by authenticated users.
create function public.my_payment_workspace(p_offset integer default 0) returns jsonb language sql set search_path='' as $$select private.my_payment_workspace(p_offset)$$;
create function public.admin_payment_workspace(p_country text default 'PK',p_offset integer default 0,p_status text default '') returns jsonb language sql set search_path='' as $$select private.admin_payment_workspace(p_country,p_offset,p_status)$$;
create function public.save_member_kyc(p_data jsonb) returns jsonb language sql set search_path='' as $$select private.save_member_kyc(p_data)$$;
create function public.review_member_kyc(p_member uuid,p_revision integer,p_status text,p_remarks text) returns void language sql set search_path='' as $$select private.review_member_kyc(p_member,p_revision,p_status,p_remarks)$$;
create function public.save_payout_account(p_data jsonb) returns uuid language sql set search_path='' as $$select private.save_payout_account(p_data)$$;
create function public.admin_save_payment_config(p_kind text,p_data jsonb) returns uuid language sql set search_path='' as $$select private.admin_save_payment_config(p_kind,p_data)$$;
create function public.submit_member_payment(p_data jsonb,p_pin text,p_key text) returns jsonb language sql set search_path='' as $$select private.submit_member_payment(p_data,p_pin,p_key)$$;
create function public.review_member_payment(p_id uuid,p_status text,p_remarks text,p_reference text,p_receipt text) returns void language sql set search_path='' as $$select private.review_member_payment(p_id,p_status,p_remarks,p_reference,p_receipt)$$;
do $$ declare r record;begin
 for r in select n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.proname in ('payment_member','payment_admin','kyc_is_valid','require_member_kyc','payment_file_valid','payment_event','payment_notice','kyc_profile_guard','guard_proceed_kyc','payment_cash_entry','member_payment_file_access','my_payment_workspace','admin_payment_workspace','save_member_kyc','review_member_kyc','save_payout_account','admin_save_payment_config','submit_member_payment','review_member_payment') loop
 execute format('revoke all on function %I.%I(%s) from public,anon,authenticated',r.nspname,r.proname,r.args);
 if r.proname in ('member_payment_file_access','my_payment_workspace','admin_payment_workspace','save_member_kyc','review_member_kyc','save_payout_account','admin_save_payment_config','submit_member_payment','review_member_payment') then execute format('grant execute on function %I.%I(%s) to authenticated',r.nspname,r.proname,r.args);end if;
 end loop;
end$$;
-- Cover payment queues, pending totals, receipt ownership checks and configuration joins.
create index payment_methods_country on private.payment_methods(country_code);
create index payment_company_method on private.payment_company_accounts(method_id);
create index member_payout_method on private.member_payout_accounts(method_id);
create index member_payment_method on private.member_payment_requests(method_id);
create index member_payment_receipt on private.member_payment_requests(member_id,receipt_path) where receipt_path is not null;
create index member_payment_pending on private.member_payment_requests(member_id) include(amount) where direction='withdrawal' and status in ('pending','approved','processing');
create index member_payment_country_date on private.member_payment_requests(country_code,created_at desc);
create index member_kyc_queue on private.member_kyc(country_code,status,submitted_at desc);
create index member_kyc_country_date on private.member_kyc(country_code,submitted_at desc);
create index member_payment_event_date on private.member_payment_events(created_at desc);
create index member_payment_event_actor on private.member_payment_events(actor_id,action,created_at desc);
