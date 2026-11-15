-- Registration display names are canonical uppercase; account identities and finances are unchanged.
begin;
create temporary table registration_name_snapshot on commit drop as
 select 'member'::text kind,user_id::text id,to_jsonb(p)-'full_name' rest from public.member_profiles p
 union all select 'customer',user_id::text,to_jsonb(p)-'full_name' from private.customer_identities p
 union all select 'vendor',user_id::text,to_jsonb(p)-'full_name' from private.vendor_identities p;

alter table public.member_profiles drop constraint member_profiles_gender_check;
alter table public.member_profiles add constraint member_profiles_gender_check check(gender in ('male','female','other'));
-- Extend only the enumerated gender validation in the existing functions, keeping all guards.
do $$
declare target regprocedure;definition text;updated text;
begin
 foreach target in array array[
  'private.validate_signup_gender()'::regprocedure,
  'private.profile_gender_default()'::regprocedure,
  'private.save_my_profile(text,text,text,text,date)'::regprocedure,
  'private.admin_save_member_profile(uuid,text,text,text,text,date,text)'::regprocedure,
  'private.admin_prepare_member(uuid,jsonb,text)'::regprocedure
 ] loop
  select pg_get_functiondef(target) into definition;
  updated:=replace(replace(definition,'''male'',''female''','''male'',''female'',''other'''),'Select Male or Female','Select Male, Female or Other');
  if updated=definition then raise exception 'Expected gender validation missing in %',target;end if;
  execute updated;
 end loop;
end $$;

create or replace function private.uppercase_registration_name() returns trigger
language plpgsql set search_path='' as $$
begin new.full_name:=upper(new.full_name);return new;end $$;
revoke all on function private.uppercase_registration_name() from public,anon,authenticated;
create trigger uppercase_registration_name before insert or update of full_name on public.member_profiles
for each row execute function private.uppercase_registration_name();
create trigger uppercase_registration_name before insert or update of full_name on private.customer_identities
for each row execute function private.uppercase_registration_name();
create trigger uppercase_registration_name before insert or update of full_name on private.vendor_identities
for each row execute function private.uppercase_registration_name();

create or replace function private.uppercase_registration_metadata() returns trigger
language plpgsql set search_path='' as $$
begin
 if jsonb_typeof(new.raw_user_meta_data->'full_name')='string' then
  new.raw_user_meta_data:=jsonb_set(new.raw_user_meta_data,'{full_name}',to_jsonb(upper(new.raw_user_meta_data->>'full_name')));
 end if;
 return new;
end $$;
revoke all on function private.uppercase_registration_metadata() from public,anon,authenticated;
create trigger uppercase_registration_metadata before insert or update of raw_user_meta_data on auth.users
for each row execute function private.uppercase_registration_metadata();

update public.member_profiles set full_name=upper(full_name) where full_name is distinct from upper(full_name);
update private.customer_identities set full_name=upper(full_name) where full_name is distinct from upper(full_name);
update private.vendor_identities set full_name=upper(full_name) where full_name is distinct from upper(full_name);
update auth.users set raw_user_meta_data=jsonb_set(raw_user_meta_data,'{full_name}',to_jsonb(upper(raw_user_meta_data->>'full_name')))
where jsonb_typeof(raw_user_meta_data->'full_name')='string' and raw_user_meta_data->>'full_name' is distinct from upper(raw_user_meta_data->>'full_name');

do $$
begin
 if exists(
  select 1 from registration_name_snapshot s join (
   select 'member'::text kind,user_id::text id,to_jsonb(p)-'full_name' rest from public.member_profiles p
   union all select 'customer',user_id::text,to_jsonb(p)-'full_name' from private.customer_identities p
   union all select 'vendor',user_id::text,to_jsonb(p)-'full_name' from private.vendor_identities p
  ) current_row using(kind,id) where s.rest is distinct from current_row.rest
 ) then raise exception 'Name normalization modified unrelated profile fields';end if;
end $$;
commit;
