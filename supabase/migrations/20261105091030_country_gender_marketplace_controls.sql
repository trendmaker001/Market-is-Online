-- Country-aware marketplace metadata and monthly maintenance controls.
alter table public.member_profiles add column if not exists gender text check(gender in ('male','female'));
alter table public.products add column if not exists country_code text check(country_code ~ '^[A-Z]{2}$');
alter table public.vendor_applications add column if not exists country_code text check(country_code ~ '^[A-Z]{2}$');
alter table public.vendors add column if not exists country_code text check(country_code ~ '^[A-Z]{2}$');

create or replace function private.valid_market_country(code text) returns boolean language sql immutable set search_path='' as $$
 select coalesce(code=any(string_to_array('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW',' ')),false)
$$;
create or replace function private.validate_signup_gender() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.raw_app_meta_data->>'provider'='email' and coalesce(new.raw_user_meta_data->>'gender','') not in ('male','female') then raise exception 'Select Male or Female';end if;
 return new;
end$$;
create trigger require_signup_gender before insert on auth.users for each row execute function private.validate_signup_gender();

create or replace function private.profile_gender_default() returns trigger language plpgsql security definer set search_path='' as $$
declare g text;
begin
 select raw_user_meta_data->>'gender' into g from auth.users where id=new.user_id;
 if new.gender is null and g is not null then
  if g not in ('male','female') then raise exception 'Select Male or Female';end if;
  new.gender:=g;
 end if;
 return new;
end$$;
create trigger member_profile_gender before insert on public.member_profiles for each row execute function private.profile_gender_default();
grant update(gender) on public.member_profiles to authenticated;

create or replace function public.submit_vendor_application_country(p_country text,p_business text,p_email text,p_phone text,p_categories text,p_description text,p_proposed numeric,p_introducer_code text default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;begin
 if not private.valid_market_country(p_country) then raise exception 'Select a country';end if;
 v_id:=public.submit_vendor_application(p_business,p_email,p_phone,p_categories,p_description,p_proposed,p_introducer_code);
 update public.vendor_applications set country_code=p_country where vendor_applications.id=v_id;
 return v_id;
end$$;
create or replace function public.save_product_listing_country(p_country text,p_product_id uuid,p_vendor_id uuid,p_name text,p_sku text,p_description text,p_category text,p_price numeric,p_stock integer,p_images jsonb,p_submit boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;begin
 if not private.valid_market_country(p_country) then raise exception 'Select a product country';end if;
 v_id:=public.save_product_listing(p_product_id,p_vendor_id,p_name,p_sku,p_description,p_category,p_price,p_stock,p_images,p_submit);
 update public.products set country_code=p_country where products.id=v_id;
 return v_id;
end$$;
create or replace function private.vendor_country_default() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.country_code is null then
  select country_code into new.country_code from public.vendor_applications where applicant_user_id=new.owner_user_id and business_name=new.business_name and country_code is not null order by created_at desc limit 1;
 end if;
 return new;
end$$;
create trigger vendor_country_from_application before insert on public.vendors for each row execute function private.vendor_country_default();

create or replace function public.admin_set_product_country(p_product uuid,p_country text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if not private.valid_market_country(p_country) then raise exception 'Select a country';end if;
 update public.products set country_code=p_country,updated_at=now() where id=p_product;
 if not found then raise exception 'Product not found';end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_COUNTRY_UPDATED','product',p_product,jsonb_build_object('country_code',p_country));
end$$;

create table private.monthly_maintenance_countries(country_code text primary key check(country_code ~ '^[A-Z]{2}$'),enabled boolean not null,updated_at timestamptz not null default now(),updated_by uuid references auth.users(id));
alter table private.monthly_maintenance_countries enable row level security;
create or replace function private.monthly_required(p_member uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select c.enabled from public.member_profiles p join private.monthly_maintenance_countries c using(country_code) where p.user_id=p_member),true)
$$;
create or replace function public.admin_monthly_countries() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return coalesce((select jsonb_agg(jsonb_build_object('country_code',country_code,'enabled',enabled,'updated_at',updated_at)) from private.monthly_maintenance_countries),'[]'::jsonb);
end$$;
create or replace function public.admin_set_monthly_country(p_country text,p_enabled boolean) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform private.require_recent_totp();
 if not private.valid_market_country(p_country) or p_enabled is null then raise exception 'Country and status required';end if;
 insert into private.monthly_maintenance_countries(country_code,enabled,updated_by) values(p_country,p_enabled,auth.uid())
 on conflict(country_code) do update set enabled=excluded.enabled,updated_at=now(),updated_by=auth.uid();
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'MONTHLY_COUNTRY_UPDATED','maintenance',jsonb_build_object('country_code',p_country,'enabled',p_enabled));
end$$;
create or replace function private.maintenance_active(p_member uuid,p_at timestamptz default now())
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.member_maintenance m where m.member_id=p_member and (not private.monthly_required(p_member) or m.monthly_due_at>p_at) and m.annual_due_at>p_at)
$$;
do $$declare f text;begin
 select pg_get_functiondef('public.my_maintenance_status()'::regprocedure) into f;
 f:=replace(f,'''monthly_active'',m.monthly_due_at>now()', '''country_code'',(select country_code from public.member_profiles where user_id=auth.uid()),''monthly_required'',private.monthly_required(auth.uid()),''monthly_active'',(not private.monthly_required(auth.uid()) or m.monthly_due_at>now())');
 execute f;
 select pg_get_functiondef('public.admin_maintenance_program()'::regprocedure) into f;
 f:=replace(f,'from public.member_maintenance where monthly_due_at>now()','from public.member_maintenance where not private.monthly_required(member_id) or monthly_due_at>now()');
 execute f;
 select pg_get_functiondef('public.place_maintenance_order(jsonb,text,text,text,text,text,text,text,text)'::regprocedure) into f;
 f:=replace(f,'if member is null or not private.package_eligible(member)', 'if not private.monthly_required(member) then raise exception ''Monthly maintenance is disabled for your country'';end if; if member is null or not private.package_eligible(member)');
 execute f;
end$$;

create or replace function public.my_network_identity(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb; nodes jsonb;begin
 r:=case when p_kind='manager' then public.my_manager_tree(p_depth) else public.my_network(p_kind,p_root_code,p_depth) end;
 select coalesce(jsonb_agg(x.node||jsonb_build_object('gender',p.gender) order by x.ord),'[]'::jsonb) into nodes
 from jsonb_array_elements(r->'nodes') with ordinality x(node,ord)
 left join public.member_profiles p on p.user_id::text=x.node->>'id';
 return r||jsonb_build_object('nodes',nodes);
end$$;
create or replace function public.my_member_dashboard_identity() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 return public.my_member_dashboard()||jsonb_build_object('gender',(select gender from public.member_profiles where user_id=auth.uid()));
end$$;
revoke all on function private.valid_market_country(text),private.validate_signup_gender(),private.profile_gender_default(),private.vendor_country_default(),private.monthly_required(uuid) from public,anon,authenticated;
revoke all on function public.submit_vendor_application_country(text,text,text,text,text,text,numeric,text),public.save_product_listing_country(text,uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean),public.admin_set_product_country(uuid,text),public.admin_monthly_countries(),public.admin_set_monthly_country(text,boolean),public.my_network_identity(text,text,integer),public.my_member_dashboard_identity() from public,anon;
grant execute on function public.submit_vendor_application_country(text,text,text,text,text,text,numeric,text),public.save_product_listing_country(text,uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean),public.admin_set_product_country(uuid,text),public.admin_monthly_countries(),public.admin_set_monthly_country(text,boolean),public.my_network_identity(text,text,integer),public.my_member_dashboard_identity() to authenticated;
-- Only the country-aware wrappers are exposed for new submissions.
revoke execute on function public.submit_vendor_application(text,text,text,text,text,numeric,text),public.save_product_listing(uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean) from public,anon,authenticated;
notify pgrst,'reload schema';
