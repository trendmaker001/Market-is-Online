-- Simple deposit setup and country-specific identity policy. Existing policies remain ON.
alter table private.payment_countries add column kyc_required boolean not null default true;
alter table private.payment_countries add column usdt_deposit_rate numeric check(usdt_deposit_rate>0 and usdt_deposit_rate<1000000000);
alter table private.payment_methods add column simple_deposit boolean not null default false;

create or replace function private.require_member_kyc(p_member uuid) returns void language plpgsql security definer set search_path='' as $$
declare required boolean:=true;cc text;
begin
 select country_code into cc from public.member_profiles where user_id=p_member;
 if cc is null then raise exception 'Member profile country required';end if;
 select kyc_required into required from private.payment_countries where country_code=cc for share;
 if coalesce(required,true) and not private.kyc_is_valid(p_member) then raise exception 'Complete KYC in My Profile and wait for admin approval before proceeding or withdrawing';end if;
end$$;

create function private.set_country_kyc(p_country text,p_required boolean,p_version text) returns void language plpgsql security definer set search_path='' as $$
declare c private.payment_countries;
begin
 perform private.payment_admin();perform private.require_recent_totp();
 select * into c from private.payment_countries where country_code=p_country for update;
 if c.country_code is null then raise exception 'Configure this country first';end if;
 if p_required is null then raise exception 'Choose ON or OFF';end if;
 if p_version::timestamptz is distinct from c.updated_at then raise exception 'Country settings changed. Refresh and try again';end if;
 update private.payment_countries set kyc_required=p_required,updated_at=clock_timestamp() where country_code=p_country;
 perform private.payment_event(null,null,'country_kyc_policy',jsonb_build_object('country',p_country,'before',c.kyc_required,'required',p_required));
end$$;
create function public.admin_set_country_kyc(p_country text,p_required boolean,p_version text) returns void language sql set search_path='' as $$select private.set_country_kyc(p_country,p_required,p_version)$$;
create or replace function private.admin_save_payment_config(p_kind text,p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid:=nullif(p_data->>'id','')::uuid;cc text:=upper(p_data->>'country_code');m private.payment_methods;
begin
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>16384 then raise exception 'Invalid or oversized payment details';end if;
 perform private.payment_admin();perform private.require_recent_totp();
 if p_kind='country' then
  if not coalesce(private.valid_market_country(cc),false) then raise exception 'Select a valid country';end if;
  insert into private.payment_countries(country_code,currency,deposit_rate,withdrawal_rate,bank_limit,mobile_limit,enabled)
  values(cc,upper(p_data->>'currency'),(p_data->>'deposit_rate')::numeric,(p_data->>'withdrawal_rate')::numeric,coalesce((p_data->>'bank_limit')::int,3),coalesce((p_data->>'mobile_limit')::int,2),coalesce((p_data->>'enabled')::boolean,true))
  on conflict(country_code) do update set currency=excluded.currency,deposit_rate=excluded.deposit_rate,withdrawal_rate=excluded.withdrawal_rate,bank_limit=excluded.bank_limit,mobile_limit=excluded.mobile_limit,enabled=excluded.enabled,updated_at=now();
 if p_data ? 'usdt_deposit_rate' then
   update private.payment_countries set usdt_deposit_rate=nullif(p_data->>'usdt_deposit_rate','')::numeric where country_code=cc;
   if exists(select 1 from private.payment_methods where country_code=cc and simple_deposit and kind='crypto' and deposit_enabled) and nullif(p_data->>'usdt_deposit_rate','') is null then raise exception 'A USDT deposit rate is required while USDT deposits are enabled';end if;
   update private.payment_methods set deposit_rate=nullif(p_data->>'usdt_deposit_rate','')::numeric,updated_at=clock_timestamp() where country_code=cc and simple_deposit and kind='crypto';
  end if;
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

-- This endpoint saves the receiving account and its deposit-only method together.
create function private.save_deposit_option(p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare cc text:=upper(p_data->>'country_code');kind text:=p_data->>'kind';network text:=coalesce(p_data->>'network','');
 aid uuid:=nullif(p_data->>'id','')::uuid;mid uuid;old_a private.payment_company_accounts;old_m private.payment_methods;c private.payment_countries;
 provider text:=trim(coalesce(p_data->>'provider',''));title text:=trim(coalesce(p_data->>'title',''));account text:=trim(coalesce(p_data->>'account',''));enabled boolean:=coalesce((p_data->>'enabled')::boolean,true);
begin
 perform private.payment_admin();perform private.require_recent_totp();
 if p_data is null or jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>4096 then raise exception 'Invalid deposit option';end if;
 select * into c from private.payment_countries where country_code=cc for share;
 if c.country_code is null then raise exception 'Configure country rates first';end if;
 if kind is null or kind not in ('bank','mobile','crypto') then raise exception 'Select Bank Transfer, Mobile Wallet or Crypto';end if;
 if aid is not null then
  select * into old_a from private.payment_company_accounts where id=aid for update;
  select * into old_m from private.payment_methods where id=old_a.method_id;
  if old_a.id is null or old_m.country_code is distinct from cc then raise exception 'Deposit option not found in this country';end if;
  if (p_data->>'version')::timestamptz is distinct from old_a.updated_at then raise exception 'Account changed. Refresh and try again';end if;
 end if;
 if kind='crypto' then
  if coalesce(p_data->>'coin','USDT')<>'USDT' or network not in ('TRC20','ERC20','BEP20') then raise exception 'Choose USDT with TRC20, ERC20 or BEP20';end if;
  if (network='TRC20' and account !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$') or (network in ('ERC20','BEP20') and account !~ '^0x[0-9a-fA-F]{40}$') then raise exception 'Address format does not match the selected network';end if;
  provider:='USDT';title:='USDT · '||network;
  -- Missing exchange rates never turn into guessed 1:1 or PKR rates.
  enabled:=enabled and c.usdt_deposit_rate is not null;
 else
  network:='';
  if length(provider) not between 2 and 100 or length(title) not between 2 and 150 then raise exception 'Name and account title are required';end if;
  if kind='bank' and (length(account) not between 5 and 40 or account !~ '^[A-Za-z0-9 -]+$') then raise exception 'Enter a bank account number or IBAN';end if;
  if kind='mobile' and account !~ '^\+?[0-9]{7,15}$' then raise exception 'Enter a valid mobile wallet number';end if;
 end if;
 if old_m.simple_deposit and old_m.kind=kind and old_m.network=network then mid:=old_m.id;else mid:=gen_random_uuid();end if;
 insert into private.payment_methods(id,country_code,kind,label,network,providers,deposit_enabled,withdrawal_enabled,currency,deposit_rate,simple_deposit)
 values(mid,cc,kind,case when kind='crypto' then title else left(provider,80) end,network,case when kind='crypto' then '[]'::jsonb else jsonb_build_array(provider) end,enabled,false,case when kind='crypto' then 'USDT' end,case when kind='crypto' then c.usdt_deposit_rate end,true)
 on conflict(id) do update set label=excluded.label,providers=excluded.providers,deposit_enabled=excluded.deposit_enabled,deposit_rate=excluded.deposit_rate,updated_at=clock_timestamp();
 insert into private.payment_company_accounts(id,method_id,title,provider,account,enabled)
 values(coalesce(aid,gen_random_uuid()),mid,title,provider,account,coalesce((p_data->>'enabled')::boolean,true))
 on conflict(id) do update set method_id=excluded.method_id,title=excluded.title,provider=excluded.provider,account=excluded.account,enabled=excluded.enabled,updated_at=clock_timestamp() returning id into aid;
 if old_m.simple_deposit and old_m.id<>mid then update private.payment_methods set deposit_enabled=false where id=old_m.id;end if;
 perform private.payment_event(null,aid,'deposit_option_saved',jsonb_build_object('country',cc,'kind',kind,'network',network,'enabled',enabled));
 return aid;
end$$;
create function public.admin_save_deposit_option(p_data jsonb) returns uuid language sql set search_path='' as $$select private.save_deposit_option(p_data)$$;
revoke all on function private.set_country_kyc(text,boolean,text),public.admin_set_country_kyc(text,boolean,text),private.save_deposit_option(jsonb),public.admin_save_deposit_option(jsonb) from public,anon,authenticated;
grant execute on function private.set_country_kyc(text,boolean,text),public.admin_set_country_kyc(text,boolean,text),private.save_deposit_option(jsonb),public.admin_save_deposit_option(jsonb) to authenticated;
notify pgrst,'reload schema';
