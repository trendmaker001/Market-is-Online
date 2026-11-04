-- Dynamic Super Member qualification and audited PPV-to-MIO shopping benefit.

do $config$
declare actor uuid;
begin
  if not exists(
    select 1 from public.system_config
    where config_key='SUPER_MEMBER_RULES' and effective_to is null
  ) then
    select user_id into actor from public.user_roles where role='admin' order by created_at limit 1;
    insert into public.system_config(config_key,version,config_value,created_by)
    values(
      'SUPER_MEMBER_RULES',1,
      jsonb_build_object(
        'enabled',true,
        'minimum_package','ADVANCED_2',
        'required_directs',5,
        'required_direct_dp',500,
        'reward_rate',1,
        'ppv_to_mio',1,
        'self_shopping',true,
        'affiliate_shopping',true
      ),actor
    );
  end if;
end
$config$;

create table private.super_member_qualifications(
  member_id uuid primary key references public.member_profiles(user_id) on delete cascade,
  qualified_at timestamptz not null default now(),
  rule_version integer not null,
  qualification_snapshot jsonb not null,
  active boolean not null default true,
  suspension_note text,
  suspended_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table public.super_member_rewards(
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.member_profiles(user_id) on delete cascade,
  order_id uuid not null references public.orders(id),
  reward_kind text not null check(reward_kind in('self_shopping','affiliate_shopping')),
  eligible_ppv numeric(20,4) not null check(eligible_ppv>0),
  reward_rate numeric(12,8) not null check(reward_rate>0),
  ppv_to_mio numeric(12,8) not null check(ppv_to_mio>0),
  amount_mio numeric(20,8) not null check(amount_mio>0),
  status text not null default 'posted' check(status in('posted','reversed')),
  rule_version integer not null,
  rules_snapshot jsonb not null,
  posted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique(order_id,member_id,reward_kind)
);
create index super_member_rewards_member_created_idx
  on public.super_member_rewards(member_id,created_at desc);
create index super_member_rewards_order_idx on public.super_member_rewards(order_id);

alter table public.super_member_rewards enable row level security;
create policy "members read own super member rewards"
on public.super_member_rewards for select to authenticated
using(member_id=(select auth.uid()) or private.has_role('admin'));
revoke all on public.super_member_rewards from public,anon;
grant select on public.super_member_rewards to authenticated;

create or replace function private.current_super_member_rules()
returns jsonb language sql stable security definer set search_path=''
as $function$
  select jsonb_build_object('version',version)||config_value
  from public.system_config
  where config_key='SUPER_MEMBER_RULES'
    and effective_from<=now() and (effective_to is null or effective_to>now())
  order by version desc limit 1
$function$;

create or replace function private.super_member_metrics(p_member uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
declare
  rules jsonb:=private.current_super_member_rules();
  pkg text:=private.current_package_code(p_member);
  directs integer:=0;
  direct_dp numeric:=0;
  package_ratio numeric:=0;
  direct_ratio numeric:=0;
  dp_ratio numeric:=0;
  progress numeric:=0;
  current_qualified boolean:=false;
  earned private.super_member_qualifications%rowtype;
begin
  select active_directs,total_dp into directs,direct_dp from private.direct_dp_summary(p_member);
  package_ratio:=least(1,private.package_weight(pkg)::numeric/
    greatest(private.package_weight(rules->>'minimum_package'),1));
  direct_ratio:=least(1,coalesce(directs,0)::numeric/
    greatest((rules->>'required_directs')::numeric,1));
  dp_ratio:=least(1,coalesce(direct_dp,0)/
    greatest((rules->>'required_direct_dp')::numeric,1));
  progress:=least(100,round(100*(package_ratio+direct_ratio+dp_ratio)/3,2));
  current_qualified:=coalesce((rules->>'enabled')::boolean,true)
    and package_ratio>=1 and direct_ratio>=1 and dp_ratio>=1;
  select * into earned from private.super_member_qualifications where member_id=p_member;
  return jsonb_build_object(
    'qualified_now',current_qualified,
    'qualified',earned.member_id is not null,
    'active',coalesce(earned.active,false),
    'qualified_at',earned.qualified_at,
    'package',pkg,
    'directs',coalesce(directs,0),
    'direct_dp',coalesce(direct_dp,0),
    'progress_percent',case when earned.member_id is not null then 100 else coalesce(progress,0) end,
    'criteria_progress',jsonb_build_object(
      'package',round(package_ratio*100,2),
      'directs',round(direct_ratio*100,2),
      'direct_dp',round(dp_ratio*100,2)
    ),
    'rules',rules
  );
end
$function$;

create or replace function private.refresh_super_member_qualification(p_member uuid)
returns boolean language plpgsql security definer set search_path=''
as $function$
declare metrics jsonb;inserted boolean:=false;
begin
  if p_member is null then return false;end if;
  metrics:=private.super_member_metrics(p_member);
  if coalesce((metrics->>'qualified_now')::boolean,false) then
    insert into private.super_member_qualifications(
      member_id,rule_version,qualification_snapshot
    ) values(
      p_member,(metrics->'rules'->>'version')::integer,metrics
    ) on conflict(member_id) do nothing;
    inserted:=found;
  end if;
  return inserted;
end
$function$;

create or replace function private.super_member_profile_event()
returns trigger language plpgsql security definer set search_path=''
as $function$
begin
  perform private.refresh_super_member_qualification(new.user_id);
  perform private.refresh_super_member_qualification(new.sponsor_id);
  if tg_op='UPDATE' and old.sponsor_id is distinct from new.sponsor_id then
    perform private.refresh_super_member_qualification(old.sponsor_id);
  end if;
  return new;
end
$function$;

drop trigger if exists zz_super_member_profile_insert on public.member_profiles;
create trigger zz_super_member_profile_insert
after insert on public.member_profiles for each row
execute function private.super_member_profile_event();
drop trigger if exists zz_super_member_profile_update on public.member_profiles;
create trigger zz_super_member_profile_update
after update of sponsor_id,status on public.member_profiles for each row
execute function private.super_member_profile_event();

create or replace function private.super_member_activation_event()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare sponsor uuid;
begin
  perform private.refresh_super_member_qualification(new.member_id);
  select sponsor_id into sponsor from public.member_profiles where user_id=new.member_id;
  perform private.refresh_super_member_qualification(sponsor);
  return new;
end
$function$;

drop trigger if exists zz_super_member_activation_insert on public.package_activations;
create trigger zz_super_member_activation_insert
after insert on public.package_activations for each row
when(new.status='approved')
execute function private.super_member_activation_event();
drop trigger if exists zz_super_member_activation_update on public.package_activations;
create trigger zz_super_member_activation_update
after update of status on public.package_activations for each row
when(new.status='approved')
execute function private.super_member_activation_event();

create or replace function private.post_super_member_order_reward()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare
  rules jsonb:=private.current_super_member_rules();
  beneficiary uuid;
  kind text;
  ppv numeric:=0;
  amount numeric:=0;
  reward_id uuid;
begin
  if new.status in('cancelled','returned') then return new;end if;
  if new.status<>'delivered' or new.payment_status<>'confirmed' then return new;end if;
  if exists(select 1 from public.maintenance_orders where order_id=new.id) then return new;end if;
  if not coalesce((rules->>'enabled')::boolean,true) then return new;end if;

  if new.selling_affiliate_id is not null then
    if not coalesce((rules->>'affiliate_shopping')::boolean,true) then return new;end if;
    beneficiary:=new.selling_affiliate_id;kind:='affiliate_shopping';
  elsif new.buyer_id is not null then
    if not coalesce((rules->>'self_shopping')::boolean,true) then return new;end if;
    beneficiary:=new.buyer_id;kind:='self_shopping';
  else return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('super-member-order:'||new.id::text,0));
  perform private.refresh_super_member_qualification(beneficiary);
  if not exists(
    select 1 from private.super_member_qualifications
    where member_id=beneficiary and active
  ) then return new;end if;

  select coalesce(sum(trunc(coalesce(
    ppv_per_unit_snapshot,
    unit_price_pkr/nullif(new.usd_to_pkr_rate,0)
  )*quantity,4)),0)
  into ppv from public.order_items where order_id=new.id;
  if ppv<=0 then return new;end if;
  amount:=round(ppv*(rules->>'reward_rate')::numeric*(rules->>'ppv_to_mio')::numeric,8);
  if amount<=0 then return new;end if;

  insert into public.super_member_rewards(
    member_id,order_id,reward_kind,eligible_ppv,reward_rate,ppv_to_mio,
    amount_mio,rule_version,rules_snapshot
  ) values(
    beneficiary,new.id,kind,ppv,(rules->>'reward_rate')::numeric,
    (rules->>'ppv_to_mio')::numeric,amount,(rules->>'version')::integer,rules
  ) on conflict(order_id,member_id,reward_kind) do nothing
  returning id into reward_id;
  if reward_id is null then return new;end if;

  insert into public.mio_ledger(
    member_id,amount,action,source_order_id,reason,idempotency_key
  ) values(
    beneficiary,amount,'bonus_credit',new.id,
    'Super Member 100% PPV benefit · '||replace(kind,'_',' '),
    'super-member:'||reward_id::text
  ) on conflict(idempotency_key) do nothing;
  if found then
    insert into public.mio_wallet_accounts(member_id,balance)
    values(beneficiary,amount)
    on conflict(member_id) do update set
      balance=public.mio_wallet_accounts.balance+excluded.balance,updated_at=now();
  end if;
  return new;
end
$function$;

drop trigger if exists zzz_super_member_order_reward on public.orders;
create trigger zzz_super_member_order_reward
after update of status,payment_status on public.orders for each row
execute function private.post_super_member_order_reward();

create or replace function public.my_super_member_status()
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare uid uuid:=auth.uid();metrics jsonb;
begin
  if uid is null then raise exception 'Sign in required';end if;
  perform private.refresh_super_member_qualification(uid);
  metrics:=private.super_member_metrics(uid);
  return metrics||jsonb_build_object(
    'total_reward_mio',coalesce((select sum(amount_mio) from public.super_member_rewards where member_id=uid and status='posted'),0),
    'self_reward_mio',coalesce((select sum(amount_mio) from public.super_member_rewards where member_id=uid and status='posted' and reward_kind='self_shopping'),0),
    'affiliate_reward_mio',coalesce((select sum(amount_mio) from public.super_member_rewards where member_id=uid and status='posted' and reward_kind='affiliate_shopping'),0),
    'history',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select r.id,r.order_id,o.order_code,r.reward_kind,r.eligible_ppv,r.reward_rate,
          r.ppv_to_mio,r.amount_mio,r.status,r.posted_at,r.created_at
        from public.super_member_rewards r join public.orders o on o.id=r.order_id
        where r.member_id=uid order by r.created_at desc limit 50
      )x
    ),'[]'::jsonb)
  );
end
$function$;

create or replace function public.admin_super_member_program()
returns jsonb language plpgsql stable security definer set search_path=''
as $function$
begin
  if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
  return jsonb_build_object(
    'rules',private.current_super_member_rules(),
    'summary',jsonb_build_object(
      'qualified_members',(select count(*) from private.super_member_qualifications),
      'active_members',(select count(*) from private.super_member_qualifications where active),
      'total_reward_mio',coalesce((select sum(amount_mio) from public.super_member_rewards where status='posted'),0),
      'self_reward_mio',coalesce((select sum(amount_mio) from public.super_member_rewards where status='posted' and reward_kind='self_shopping'),0),
      'affiliate_reward_mio',coalesce((select sum(amount_mio) from public.super_member_rewards where status='posted' and reward_kind='affiliate_shopping'),0)
    ),
    'members',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.qualified_at desc)
      from (
        select q.member_id,m.member_code,m.full_name,q.qualified_at,q.active,q.suspension_note,
          coalesce(sum(r.amount_mio) filter(where r.status='posted'),0) total_reward_mio
        from private.super_member_qualifications q
        join public.member_profiles m on m.user_id=q.member_id
        left join public.super_member_rewards r on r.member_id=q.member_id
        group by q.member_id,m.member_code,m.full_name,q.qualified_at,q.active,q.suspension_note
        order by q.qualified_at desc limit 100
      )x
    ),'[]'::jsonb),
    'recent_rewards',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select r.id,r.member_id,m.member_code,m.full_name,o.order_code,r.reward_kind,
          r.eligible_ppv,r.amount_mio,r.status,r.created_at
        from public.super_member_rewards r
        join public.member_profiles m on m.user_id=r.member_id
        join public.orders o on o.id=r.order_id
        order by r.created_at desc limit 100
      )x
    ),'[]'::jsonb)
  );
end
$function$;

create or replace function public.admin_set_super_member_rules(
  p_rules jsonb,p_expected_version integer
) returns jsonb language plpgsql security definer set search_path=''
as $function$
declare current_rules jsonb:=private.current_super_member_rules();next_rules jsonb;next_version integer;
begin
  if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
  perform private.require_recent_totp();
  if p_expected_version<>(current_rules->>'version')::integer then raise exception 'Rules changed. Refresh and try again';end if;
  next_rules:=jsonb_build_object(
    'enabled',coalesce((p_rules->>'enabled')::boolean,true),
    'minimum_package',p_rules->>'minimum_package',
    'required_directs',(p_rules->>'required_directs')::integer,
    'required_direct_dp',(p_rules->>'required_direct_dp')::numeric,
    'reward_rate',(p_rules->>'reward_rate')::numeric,
    'ppv_to_mio',(p_rules->>'ppv_to_mio')::numeric,
    'self_shopping',coalesce((p_rules->>'self_shopping')::boolean,true),
    'affiliate_shopping',coalesce((p_rules->>'affiliate_shopping')::boolean,true)
  );
  if private.package_weight(next_rules->>'minimum_package')=0
    or (next_rules->>'required_directs')::integer<0
    or (next_rules->>'required_direct_dp')::numeric<0
    or (next_rules->>'reward_rate')::numeric<=0 or (next_rules->>'reward_rate')::numeric>10
    or (next_rules->>'ppv_to_mio')::numeric<=0 or (next_rules->>'ppv_to_mio')::numeric>100
  then raise exception 'Invalid Super Member rules';end if;
  next_version:=(current_rules->>'version')::integer+1;
  update public.system_config set effective_to=clock_timestamp()
  where config_key='SUPER_MEMBER_RULES' and effective_to is null;
  insert into public.system_config(config_key,version,config_value,effective_from,created_by)
  values('SUPER_MEMBER_RULES',next_version,next_rules,clock_timestamp(),auth.uid());
  return jsonb_build_object('version',next_version)||next_rules;
end
$function$;

create or replace function public.admin_set_super_member_status(
  p_member_id uuid,p_active boolean,p_note text default null
) returns void language plpgsql security definer set search_path=''
as $function$
begin
  if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
  perform private.require_recent_totp();
  update private.super_member_qualifications set
    active=p_active,
    suspension_note=case when p_active then null else nullif(trim(p_note),'') end,
    suspended_by=case when p_active then null else auth.uid() end,
    updated_at=now()
  where member_id=p_member_id;
  if not found then raise exception 'Super Member qualification not found';end if;
end
$function$;

revoke all on function private.current_super_member_rules(),private.super_member_metrics(uuid),
  private.refresh_super_member_qualification(uuid),private.super_member_profile_event(),
  private.super_member_activation_event(),private.post_super_member_order_reward()
from public,anon,authenticated;
revoke all on function public.my_super_member_status(),public.admin_super_member_program(),
  public.admin_set_super_member_rules(jsonb,integer),public.admin_set_super_member_status(uuid,boolean,text)
from public,anon;
grant execute on function public.my_super_member_status(),public.admin_super_member_program(),
  public.admin_set_super_member_rules(jsonb,integer),public.admin_set_super_member_status(uuid,boolean,text)
to authenticated;

-- Evaluate current members without retroactively paying historical orders.
do $refresh$
declare member record;
begin
  for member in select user_id from public.member_profiles loop
    perform private.refresh_super_member_qualification(member.user_id);
  end loop;
end
$refresh$;

notify pgrst,'reload schema';
