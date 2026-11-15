-- Presentation only: no changes to package versions, purchases, wallets or reward formulas.
begin;
create table public.subscription_plan_display (
 package_code text primary key,
 category text not null check (category in ('regular','platinum','promotional')),
 display_order integer not null check (display_order between 1 and 9999),
 version integer not null default 1 check (version > 0),
 updated_at timestamptz not null default now()
);
alter table public.subscription_plan_display enable row level security;
revoke all on public.subscription_plan_display from public,anon,authenticated;
grant select on public.subscription_plan_display to anon,authenticated;
create policy subscription_display_read on public.subscription_plan_display for select to anon,authenticated using (true);
insert into public.subscription_plan_display(package_code,category,display_order) values
 ('ADVANCED_2','regular',1),('ADVANCED_1','regular',2),('BASIC_2','regular',3),
 ('PREMIUM','platinum',1),('BASIC_1','promotional',1);

create function public.get_subscription_plan_display() returns setof public.subscription_plan_display
language sql stable security invoker set search_path='' as $$
 select * from public.subscription_plan_display order by category,display_order,package_code
$$;
revoke all on function public.get_subscription_plan_display() from public;
grant execute on function public.get_subscription_plan_display() to anon,authenticated;

create function private.admin_set_subscription_plan_display(p_code text,p_category text,p_display_order integer,p_expected_version integer)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.subscription_plan_display%rowtype; saved public.subscription_plan_display%rowtype;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform private.require_recent_totp();
 if p_category is null or p_category not in ('regular','platinum','promotional') then raise exception 'Select a valid subscription category';end if;
 if p_display_order is null or p_display_order not between 1 and 9999 then raise exception 'Display order must be from 1 to 9999';end if;
 if not exists(select 1 from public.package_versions where package_code=p_code and is_active) then raise exception 'Subscription plan is unavailable';end if;
 -- Serializes presentation edits only, independent of the financial plan editor.
 perform pg_advisory_xact_lock(hashtextextended('subscription-display:'||p_code,0));
 select * into prior from public.subscription_plan_display where package_code=p_code for update;
 if p_expected_version is null or p_expected_version<>coalesce(prior.version,0) then raise exception 'Category settings changed. Reload before saving.';end if;
 insert into public.subscription_plan_display(package_code,category,display_order,version)
 values(p_code,p_category,p_display_order,1)
 on conflict(package_code) do update set category=excluded.category,display_order=excluded.display_order,
 version=public.subscription_plan_display.version+1,updated_at=now()
 returning * into saved;
 insert into public.audit_logs(actor_id,action,entity_type,before_data,after_data)
 values(auth.uid(),'SUBSCRIPTION_DISPLAY_UPDATED','subscription_plan',to_jsonb(prior),to_jsonb(saved));
 return to_jsonb(saved);
end $$;
revoke all on function private.admin_set_subscription_plan_display(text,text,integer,integer) from public,anon,authenticated;
grant execute on function private.admin_set_subscription_plan_display(text,text,integer,integer) to authenticated;
create function public.admin_set_subscription_plan_display(p_code text,p_category text,p_display_order integer,p_expected_version integer)
returns jsonb language sql security invoker set search_path='' as $$
 select private.admin_set_subscription_plan_display(p_code,p_category,p_display_order,p_expected_version)
$$;
revoke all on function public.admin_set_subscription_plan_display(text,text,integer,integer) from public,anon;
grant execute on function public.admin_set_subscription_plan_display(text,text,integer,integer) to authenticated;
commit;
