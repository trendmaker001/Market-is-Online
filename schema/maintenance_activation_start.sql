-- Start maintenance only on first approved activation; never on registration/login.
alter table public.member_maintenance add column if not exists started_at timestamptz;
alter table public.member_maintenance alter column monthly_due_at drop not null;
alter table public.member_maintenance alter column annual_due_at drop not null;
update public.member_maintenance m set started_at=(select min(coalesce(a.activated_at,a.requested_at)) from public.package_activations a where a.member_id=m.member_id and a.status='approved');
update public.member_maintenance set monthly_due_at=null,annual_due_at=null,monthly_progress_ppv=0,updated_at=now() where started_at is null;
create or replace function private.start_member_maintenance() returns trigger language plpgsql security definer set search_path='' as $$
declare first_at timestamptz;
begin
 if new.status='approved' and (tg_op='INSERT' or old.status is distinct from 'approved') then
  select min(coalesce(activated_at,requested_at)) into first_at from public.package_activations where member_id=new.member_id and status='approved';
  first_at:=coalesce(first_at,new.activated_at,new.requested_at,now());
  insert into public.member_maintenance(member_id,started_at,monthly_due_at,annual_due_at) values(new.member_id,first_at,first_at+interval '180 days',first_at+interval '365 days')
  on conflict(member_id) do update set started_at=excluded.started_at,monthly_due_at=excluded.monthly_due_at,annual_due_at=excluded.annual_due_at,monthly_progress_ppv=0,updated_at=now() where public.member_maintenance.started_at is null;
 end if;
 return new;
end $$;
-- Correct only the requested company's existing timers; no activation or payout is replayed.
update public.member_maintenance m set monthly_due_at=m.started_at+interval '180 days',annual_due_at=m.started_at+interval '365 days',updated_at=now()
where m.started_at is not null and exists(select 1 from private.network_foundation n where n.singleton and n.company_id=m.member_id);
update private.member_welcome_bonus_eligibility w set started_at=m.started_at,ends_at=m.started_at+interval '15 days'
from public.member_maintenance m where m.member_id=w.member_id and w.enabled and m.started_at is not null and exists(select 1 from private.network_foundation n where n.singleton and n.company_id=w.member_id);
-- No eligibility decision exists before a first approved package. Keep an audit copy of any stale decision.
insert into public.audit_logs(actor_id,action,entity_type,before_data,after_data)
select null,'RESET_UNACTIVATED_WELCOME_TIMER','member_welcome_bonus_eligibility',to_jsonb(w),'{}'::jsonb from private.member_welcome_bonus_eligibility w where not exists(select 1 from public.package_activations a where a.member_id=w.member_id and a.status='approved');
delete from private.member_welcome_bonus_eligibility w where not exists(select 1 from public.package_activations a where a.member_id=w.member_id and a.status='approved');
CREATE OR REPLACE FUNCTION public.my_maintenance_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.member_maintenance%rowtype;r jsonb:=private.current_maintenance_rules();code text;
begin
 if auth.uid() is null or not private.registered_member(auth.uid()) then raise exception 'Member account required';end if;
 select * into m from public.member_maintenance where member_id=auth.uid();
 code:=private.current_package_code(auth.uid());
 return jsonb_build_object('package',code,'rules',r,'server_now',now(),
 'started',code is not null,'monthly_due_at',case when code is not null then m.monthly_due_at end,'annual_due_at',case when code is not null then m.annual_due_at end,
 'monthly_progress_ppv',coalesce(m.monthly_progress_ppv,0),
 'monthly_required_ppv',coalesce((r->'monthly_ppv'->>code)::numeric,0),
 'country_code',(select country_code from public.member_profiles where user_id=auth.uid()),'monthly_required',private.monthly_required(auth.uid()),'monthly_active',code is not null and (not private.monthly_required(auth.uid()) or m.monthly_due_at>now()),'annual_active',code is not null and m.annual_due_at>now());
end$function$;
