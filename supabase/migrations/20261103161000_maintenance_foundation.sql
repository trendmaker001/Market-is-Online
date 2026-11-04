-- Maintenance rules and audited member deadlines. This migration intentionally
-- adds no payouts until the order and payout paths are installed together.
create table public.member_maintenance (
 member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
 monthly_due_at timestamptz not null,
 annual_due_at timestamptz not null,
 monthly_progress_ppv numeric(18,4) not null default 0 check(monthly_progress_ppv>=0),
 updated_at timestamptz not null default now()
);
alter table public.member_maintenance enable row level security;
revoke all on public.member_maintenance from public,anon,authenticated;
grant select on public.member_maintenance to authenticated;
create policy "member maintenance is private" on public.member_maintenance for select to authenticated
 using(member_id=(select auth.uid()) or private.has_role('admin'));

-- Existing accounts get a full initial grace period on rollout; new accounts
-- start at their first approved activation. No previous bonus is rewritten.
insert into public.member_maintenance(member_id,monthly_due_at,annual_due_at)
select p.user_id,now()+interval '180 days',now()+interval '365 days'
from public.member_profiles p where exists
 (select 1 from public.package_activations a where a.member_id=p.user_id and a.status='approved')
on conflict(member_id) do nothing;

create or replace function private.start_member_maintenance() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='approved' and (tg_op='INSERT' or old.status is distinct from 'approved') then
  insert into public.member_maintenance(member_id,monthly_due_at,annual_due_at)
   values(new.member_id,coalesce(new.activated_at,now())+interval '180 days',coalesce(new.activated_at,now())+interval '365 days')
  on conflict(member_id) do nothing;
 end if;
 return new;
end$$;
create trigger zz_start_member_maintenance after insert or update of status on public.package_activations
 for each row execute function private.start_member_maintenance();

insert into public.system_config(config_key,version,config_value,effective_from,effective_to,created_by)
select 'MAINTENANCE_RULES',1,jsonb_build_object(
 'enabled',true,'monthly_ppv',jsonb_build_object('BASIC_1',5,'BASIC_2',5,'ADVANCED_1',5,'ADVANCED_2',10,'PREMIUM',10),
 'monthly_levels',jsonb_build_object('BASIC_1',2,'BASIC_2',4,'ADVANCED_1',6,'ADVANCED_2',8,'PREMIUM',10),
 'monthly_rates',jsonb_build_array(.10,.10,.10,.10,.10,.10,.10,.10,.10,.10),
 'annual_fee_mio',20,'annual_company_rate',.50,'annual_rates',jsonb_build_array(.35,.10,.05),
 'monthly_initial_days',180,'monthly_extension_days',30,'annual_initial_days',365,'annual_extension_days',365),now(),null,null
where not exists(select 1 from public.system_config where config_key='MAINTENANCE_RULES');

create or replace function private.current_maintenance_rules() returns jsonb language sql stable security definer set search_path='' as $$
 select config_value||jsonb_build_object('version',version) from public.system_config
 where config_key='MAINTENANCE_RULES' and effective_from<=now() and (effective_to is null or effective_to>now())
 order by version desc limit 1
$$;

create or replace function public.my_maintenance_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare m public.member_maintenance%rowtype;r jsonb:=private.current_maintenance_rules();code text;
begin
 if auth.uid() is null or not private.registered_member(auth.uid()) then raise exception 'Member account required';end if;
 select * into m from public.member_maintenance where member_id=auth.uid();
 code:=private.current_package_code(auth.uid());
 return jsonb_build_object('package',code,'rules',r,'server_now',now(),
 'monthly_due_at',m.monthly_due_at,'annual_due_at',m.annual_due_at,
 'monthly_progress_ppv',coalesce(m.monthly_progress_ppv,0),
 'monthly_required_ppv',coalesce((r->'monthly_ppv'->>code)::numeric,0),
 'monthly_active',m.monthly_due_at>now(),'annual_active',m.annual_due_at>now());
end$$;

create or replace function public.admin_maintenance_program() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare r jsonb:=private.current_maintenance_rules();
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return jsonb_build_object('rules',r,'members',
  (select count(*) from public.member_maintenance),
  'monthly_active',(select count(*) from public.member_maintenance where monthly_due_at>now()),
  'annual_active',(select count(*) from public.member_maintenance where annual_due_at>now()));
end$$;

create or replace function public.admin_set_maintenance_rules(p_rules jsonb,p_expected_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_rules jsonb:=private.current_maintenance_rules();code text;rates jsonb;total numeric;v integer;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform private.require_recent_totp();
 if p_expected_version is distinct from (current_rules->>'version')::integer then raise exception 'Settings changed. Refresh and try again';end if;
 if jsonb_typeof(p_rules)<>'object' then raise exception 'Rules object required';end if;
 foreach code in array array['BASIC_1','BASIC_2','ADVANCED_1','ADVANCED_2','PREMIUM'] loop
  if (p_rules->'monthly_ppv'->>code)::numeric<=0 or (p_rules->'monthly_levels'->>code)::integer not between 1 and 10 then raise exception 'Invalid package maintenance rule';end if;
 end loop;
 if (p_rules->>'annual_fee_mio')::numeric<=0 or (p_rules->>'annual_company_rate')::numeric<0 or (p_rules->>'annual_company_rate')::numeric>1 then raise exception 'Invalid annual fee';end if;
 foreach code in array array['monthly_rates','annual_rates'] loop
  rates:=p_rules->code;
  if jsonb_typeof(rates)<>'array' or jsonb_array_length(rates) not between 1 and 10 then raise exception 'Invalid generation rates';end if;
  select sum(value::numeric) into total from jsonb_array_elements_text(rates) value;
  if exists(select 1 from jsonb_array_elements_text(rates) value where value::numeric<0 or value::numeric>1) then raise exception 'Rates must be between 0 and 100 percent';end if;
  if (code='monthly_rates' and total>1.00000001) or (code='annual_rates' and total+(p_rules->>'annual_company_rate')::numeric>1.00000001) then raise exception 'Maintenance allocation exceeds 100 percent';end if;
 end loop;
 perform pg_advisory_xact_lock(hashtextextended('MAINTENANCE_RULES',0));
 select version into v from public.system_config where config_key='MAINTENANCE_RULES' and effective_to is null order by version desc limit 1 for update;
 if v is distinct from p_expected_version then raise exception 'Settings changed. Refresh and try again';end if;
 update public.system_config set effective_to=now() where config_key='MAINTENANCE_RULES' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by)
 values('MAINTENANCE_RULES',v+1,(current_rules-'version')||jsonb_build_object(
  'monthly_ppv',p_rules->'monthly_ppv','monthly_levels',p_rules->'monthly_levels',
  'monthly_rates',p_rules->'monthly_rates','annual_fee_mio',(p_rules->>'annual_fee_mio')::numeric,
  'annual_company_rate',(p_rules->>'annual_company_rate')::numeric,'annual_rates',p_rules->'annual_rates',
  'enabled',coalesce((p_rules->>'enabled')::boolean,true)),now(),auth.uid());
 return private.current_maintenance_rules();
end$$;

revoke all on function private.current_maintenance_rules(),private.start_member_maintenance() from public,anon,authenticated;
revoke all on function public.my_maintenance_status(),public.admin_maintenance_program(),public.admin_set_maintenance_rules(jsonb,integer) from public,anon;
grant execute on function public.my_maintenance_status(),public.admin_maintenance_program(),public.admin_set_maintenance_rules(jsonb,integer) to authenticated;
notify pgrst,'reload schema';
