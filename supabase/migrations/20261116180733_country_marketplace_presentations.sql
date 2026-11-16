-- Keep existing Pakistani campaigns; never reuse them in another country.
set lock_timeout='3s';
set statement_timeout='30s';
create table private.marketplace_country_presentations (
 country_code text primary key check(private.valid_market_country(country_code)),
 settings jsonb not null, updated_at timestamptz not null default clock_timestamp(),
 updated_by uuid references auth.users(id)
);
alter table private.marketplace_country_presentations enable row level security;
revoke all on private.marketplace_country_presentations from public,anon,authenticated;
create index marketplace_country_presentations_editor_idx on private.marketplace_country_presentations(updated_by);
insert into private.marketplace_country_presentations(country_code,settings)
select 'PK',settings || jsonb_build_object('main',coalesce(settings->'main',(select config_value from public.system_config where config_key='MARKETPLACE_HERO' and effective_to is null order by version desc limit 1),'[]'::jsonb),'video',coalesce(settings->'video','[]'::jsonb),'main_interval',coalesce(settings->'main_interval','3'::jsonb)) from private.marketplace_presentation where id;
-- Recover missing legacy country metadata only from the existing owner's profile.
update public.vendors v set country_code=p.country_code from public.member_profiles p
where v.owner_user_id=p.user_id and v.country_code is null and private.valid_market_country(p.country_code);
update public.products p set country_code=v.country_code from public.vendors v
where p.vendor_id=v.id and p.country_code is null and private.valid_market_country(v.country_code);
create index if not exists marketplace_vendor_country_active on public.vendors(country_code,id) where status='active';
create index if not exists marketplace_product_country_available on public.products(country_code,id) where status='approved' and stock_quantity>0;

create function private.country_presentation_read(p_country text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb; stamp timestamptz; k text;begin
 if not private.valid_market_country(p_country) then raise exception 'Choose a valid shopping country';end if;
 select settings,updated_at into r,stamp from private.marketplace_country_presentations where country_code=p_country;
 r:=coalesce(r,'{"enabled":false,"interval":5,"main_interval":3,"main":[],"video":[],"slides":[],"promos":[],"categories":[]}'::jsonb);
 if auth.uid() is null or not private.has_role('admin') then
  foreach k in array array['main','video','slides','promos','categories'] loop
   r:=jsonb_set(r,array[k],coalesce((select jsonb_agg(value) from jsonb_array_elements(coalesce(r->k,'[]'::jsonb)) where value->>'enabled'='true'),'[]'::jsonb));
  end loop;
 end if;
 return r||jsonb_build_object('_revision',stamp,'country_code',p_country);
end $$;
create function public.marketplace_country_presentation(p_country text) returns jsonb language sql stable security invoker set search_path='' as $$select private.country_presentation_read(p_country)$$;

create function private.country_presentation_save(p_country text,p_settings jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare k text;item jsonb;val text;field text;stamp timestamptz;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform private.require_recent_totp();
 if not private.valid_market_country(p_country) then raise exception 'Choose a country';end if;
 if octet_length(p_settings::text)>200000 then raise exception 'Presentation is too large';end if;
 perform pg_advisory_xact_lock(hashtextextended('country_presentation:'||p_country,0));
 select updated_at into stamp from private.marketplace_country_presentations where country_code=p_country for update;
 if (p_settings->>'_revision')::timestamptz is distinct from stamp then raise exception 'Promotions changed. Reload this country before saving';end if;
 if p_settings is null or jsonb_typeof(p_settings)<>'object' or jsonb_typeof(p_settings->'interval') is distinct from 'number' or (p_settings->>'interval')::numeric not between 3 and 15 or jsonb_typeof(p_settings->'enabled') is distinct from 'boolean' then raise exception 'Choose an enabled state and interval from 3 to 15 seconds'; end if;
 if p_settings ? 'main_interval' and (jsonb_typeof(p_settings->'main_interval') is distinct from 'number' or (p_settings->>'main_interval')::numeric not between 3 and 15) then raise exception 'Main rotation must be 3 to 15 seconds'; end if;
 foreach k in array array['main','video','slides','promos','categories'] loop
  if k in ('main','video') and not p_settings ? k then continue; end if;
  if jsonb_typeof(p_settings->k) is distinct from 'array' then raise exception 'Invalid presentation items'; end if;
  if jsonb_array_length(p_settings->k)>(case k when 'main' then 8 when 'video' then 1 when 'slides' then 8 when 'promos' then 2 else 60 end) then raise exception 'Too many presentation items'; end if;
  for item in select value from jsonb_array_elements(p_settings->k) loop
   if jsonb_typeof(item)<>'object' or length(coalesce(item->>'title',''))>120 or jsonb_typeof(item->'enabled') is distinct from 'boolean' then raise exception 'Invalid image details'; end if;
   foreach field in array array['image_url','mobile_url','video_url','mobile_video_url','link'] loop
    val:=coalesce(item->>field,'');
    if length(val)>2000 or (val<>'' and not (val ~ '^https://[^[:space:]]+$' or val ~ '^/[A-Za-z0-9][^[:space:]]*$' or (field='link' and val ~ '^#[^[:space:]]+$'))) then raise exception 'Use an HTTPS URL, site path or internal link'; end if;
   end loop;
   if coalesce(item->>'image_url','')='' then raise exception 'Each item needs an image'; end if;
   if k='video' and coalesce(item->>'video_url','')='' then raise exception 'Add a video URL or upload a video'; end if;
   if k<>'categories' and (item->>'enabled')::boolean and coalesce(item->>'link','')='' then raise exception 'Add a destination link for each active promotion'; end if;
   if k='categories' and length(coalesce(item->>'name','')) not between 1 and 60 then raise exception 'Choose a category name'; end if;
  end loop;
 end loop;

 p_settings:=p_settings-'_revision'-'country_code';
 insert into private.marketplace_country_presentations(country_code,settings,updated_by) values(p_country,p_settings,auth.uid())
 on conflict(country_code) do update set settings=excluded.settings,updated_at=clock_timestamp(),updated_by=auth.uid();
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'COUNTRY_PROMOTIONS_SAVED','marketplace',jsonb_build_object('country_code',p_country,'settings',p_settings));
 return private.country_presentation_read(p_country);
end $$;
create function public.admin_save_country_presentation(p_country text,p_settings jsonb) returns jsonb language sql security invoker set search_path='' as $$select private.country_presentation_save(p_country,p_settings)$$;

create function private.vendor_market_country_save(p_vendor uuid,p_country text) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform private.require_recent_totp();
 if not private.valid_market_country(p_country) then raise exception 'Choose a country';end if;
 update public.vendors set country_code=p_country where id=p_vendor;
 if not found then raise exception 'Store not found';end if;
 update public.products set country_code=p_country,updated_at=now() where vendor_id=p_vendor;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'VENDOR_MARKET_COUNTRY_SAVED','vendor',p_vendor,jsonb_build_object('country_code',p_country));
end $$;
create function public.admin_set_vendor_market_country(p_vendor uuid,p_country text) returns void language sql security invoker set search_path='' as $$select private.vendor_market_country_save(p_vendor,p_country)$$;

-- New listings inherit their store country; reject conflicting classification.
create function private.product_market_country_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare c text;begin
 select country_code into c from public.vendors where id=new.vendor_id;
 if c is not null then
  if new.country_code is null then new.country_code:=c;
  elsif new.country_code<>c then raise exception 'Product country must match the store marketplace country';end if;
 end if;
 return new;
end $$;
create trigger product_market_country_guard before insert or update of country_code,vendor_id on public.products for each row execute function private.product_market_country_guard();
revoke all on function private.product_market_country_guard() from public,anon,authenticated;
revoke all on function private.country_presentation_read(text),public.marketplace_country_presentation(text),private.country_presentation_save(text,jsonb),public.admin_save_country_presentation(text,jsonb),private.vendor_market_country_save(uuid,text),public.admin_set_vendor_market_country(uuid,text) from public,anon,authenticated;
grant usage on schema private to anon,authenticated;
grant execute on function private.country_presentation_read(text),public.marketplace_country_presentation(text) to anon,authenticated;
grant execute on function private.country_presentation_save(text,jsonb),public.admin_save_country_presentation(text,jsonb),private.vendor_market_country_save(uuid,text),public.admin_set_vendor_market_country(uuid,text) to authenticated;
notify pgrst,'reload schema';
