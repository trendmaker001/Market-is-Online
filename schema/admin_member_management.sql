-- Manual migration snapshots, separate from earned credits and purchase transactions.
create table if not exists private.member_admin_changes(
 id uuid primary key default gen_random_uuid(), actor_id uuid not null references auth.users(id),
 member_id uuid not null references public.member_profiles(user_id), request_key uuid not null unique,
 section text not null, requested jsonb not null, reason text not null,
 before_data jsonb not null, after_data jsonb, created_at timestamptz not null default now());
create table if not exists private.member_restore_context(transaction_id bigint primary key,member_id uuid not null);
create table if not exists private.member_admin_baselines(
 member_id uuid primary key references public.member_profiles(user_id),
 package_assigned boolean not null default false,package_code text,package_assigned_at timestamptz,
 activation_id uuid references public.package_activations(id),
 consumed_left numeric not null default 0,consumed_right numeric not null default 0,
 direct_dp_offset numeric not null default 0,tngp_offset numeric not null default 0,
 left_dp_offset numeric not null default 0,right_dp_offset numeric not null default 0,left_gp_offset numeric not null default 0,right_gp_offset numeric not null default 0);
create table if not exists public.member_opening_earnings(
 member_id uuid not null references public.member_profiles(user_id),
 category text not null check(category in('direct','generation','binary_pool_share','manager','community_share','single_line','ecommerce','other')),
 amount numeric(20,4) not null check(amount>=0 and amount<=1000000000),
 updated_at timestamptz not null default now(),primary key(member_id,category));
alter table private.member_admin_changes enable row level security;
alter table private.member_restore_context enable row level security;
alter table private.member_admin_baselines enable row level security;
alter table public.member_opening_earnings enable row level security;
revoke all on private.member_admin_changes,private.member_restore_context,private.member_admin_baselines,public.member_opening_earnings from public,anon,authenticated;
grant select on public.member_opening_earnings to authenticated;
create policy member_opening_read on public.member_opening_earnings for select to authenticated using(member_id=(select auth.uid()) or private.has_role('admin'));
alter table public.point_ledger add column admin_change_id uuid references private.member_admin_changes(id);
alter table public.point_ledger drop constraint point_ledger_check1;
alter table public.point_ledger add constraint point_ledger_source_check check(num_nonnulls(source_activation_id,source_order_id,admin_change_id)=1);

create or replace function private.member_restore_active(p_member uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from private.member_restore_context where transaction_id=txid_current() and member_id=p_member)
$$;
revoke all on function private.member_restore_active(uuid) from public,anon,authenticated;
-- Suppress business-event side effects only inside the guarded restore transaction.
-- No session flags, JWT overrides, disabled triggers, or member-controlled metadata.
do $patch$
declare fname text;body text;guard text;
begin
 foreach fname in array array['assign_activation_points','on_package_activation_binary_volume','activate_package_member','place_binary_after_activation','release_direct_holds','release_ecommerce_holds','activation_single_line','capture_welcome_bonus_eligibility','start_member_maintenance','super_member_activation_event','cap_total_ppv_credit','enforce_shopping_ppv_mode','refresh_binary_qualification_from_dp','manager_point_event','release_promotion_on_rank','refresh_binary_qualification_from_placement','super_member_profile_event','enforce_package_membership'] loop
  select pg_get_functiondef(p.oid) into body from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname=fname and p.pronargs=0;
  if body is null then raise exception 'Restore prerequisite missing: %',fname;end if;
  guard:=case when fname in('super_member_profile_event','enforce_package_membership') then 'new.user_id' else 'new.member_id' end;
  if strpos(body,'private.member_restore_active')=0 then
   body:=regexp_replace(body,'\mBEGIN\M','BEGIN if private.member_restore_active('||guard||') then return new;end if;','i');execute body;
  end if;
 end loop;
end $patch$;

create or replace function private.current_package_code(p_member_id uuid) returns text language sql stable security definer set search_path='' as $$
 select case when b.package_assigned then coalesce((select a.package_code from public.package_activations a where a.member_id=p_member_id and a.status='approved' and a.id is distinct from b.activation_id and coalesce(a.activated_at,a.requested_at)>b.package_assigned_at order by a.base_value desc,a.activated_at desc limit 1),b.package_code)
 else (select a.package_code from public.package_activations a where a.member_id=p_member_id and a.status='approved' order by a.base_value desc,a.activated_at desc nulls last,a.requested_at desc limit 1) end
 from (select 1) dummy left join private.member_admin_baselines b on b.member_id=p_member_id
$$;
create or replace function private.package_eligible(member uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.member_profiles where user_id=member and status='active') and private.current_package_code(member) is not null
$$;
create or replace function private.direct_dp_summary(p_member uuid) returns table(active_directs integer,total_dp numeric) language sql stable security definer set search_path='' as $$
 select count(distinct mp.user_id)::integer,coalesce(sum(a.dp),0)::numeric+coalesce((select direct_dp_offset from private.member_admin_baselines where member_id=p_member),0)
 from public.member_profiles mp left join public.package_activations a on a.member_id=mp.user_id and a.status='approved'
 where mp.sponsor_id=p_member and mp.status='active'
$$;
do $patch$ declare body text;k text;fragment text;begin
 select pg_get_functiondef('private.binary_side_dp_gp_totals(uuid)'::regprocedure) into body;
 foreach k in array array['left_dp','right_dp','left_gp','right_gp'] loop
  fragment:=case when right(k,2)='dp' then 'coalesce((select dp from direct_dp where root_side=' else 'coalesce((select gp from network_gp where root_side=' end||quote_literal(upper(split_part(k,'_',1)))||'),0)';
  if strpos(body,fragment)=0 then raise exception 'Unexpected side points implementation';end if;
  body:=replace(body,fragment,fragment||'+coalesce((select '||k||'_offset from private.member_admin_baselines where member_id=p_member),0)');
 end loop;execute body;
end $patch$;
-- Carry-forward consumption is an opening figure; real binary cycles remain unchanged.
do $patch$
declare body text;
begin
 select pg_get_functiondef('private.binary_live_shares(timestamptz)'::regprocedure) into body;
 body:=replace(body,'a.status=''approved'' and coalesce(a.activated_at,a.requested_at)<=p_end','a.status=''approved'' and a.package_code=private.current_package_code(a.member_id) and coalesce(a.activated_at,a.requested_at)<=p_end');
 body:=replace(body,'coalesce(v.l,0)-coalesce(c.l,0)','coalesce(v.l,0)-coalesce(c.l,0)-coalesce((select consumed_left from private.member_admin_baselines where member_id=ap.member_id),0)');
 body:=replace(body,'coalesce(v.r,0)-coalesce(c.r,0)','coalesce(v.r,0)-coalesce(c.r,0)-coalesce((select consumed_right from private.member_admin_baselines where member_id=ap.member_id),0)');execute body;
 select pg_get_functiondef('public.my_generation_member_details(text)'::regprocedure) into body;
 body:=replace(body,'''tngp'',(select value from gp_total)','''tngp'',(select value from gp_total)+coalesce((select tngp_offset from private.member_admin_baselines where member_id=target_id),0)');execute body;
end $patch$;

create or replace function private.member_management_state(p_member uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;pts jsonb;g jsonb;code text;tot_l numeric;tot_r numeric;used_l numeric;used_r numeric;
begin
 select member_code into code from public.member_profiles where user_id=p_member;if not found then raise exception 'Member not found';end if;
 select coalesce(jsonb_object_agg(key,total),'{}') into pts from (
 select lower(point_type)||case when side is null then '' else '_'||lower(side) end key,sum(amount) total from public.point_ledger where member_id=p_member and created_at>private.financial_reset_at() group by point_type,side) p;
 tot_l:=coalesce((pts->>'bp_left')::numeric,0);tot_r:=coalesce((pts->>'bp_right')::numeric,0);
 select coalesce(sum(r.consumed_left),0),coalesce(sum(r.consumed_right),0) into used_l,used_r from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where r.member_id=p_member and c.status in('posted','unallocated') and c.created_at>private.financial_reset_at();
 g:=public.my_generation_member_details(code);
 pts:=jsonb_build_object('ppv',0,'bv',0,'gp',0,'dp',0,'bp_left',0,'bp_right',0,'brp_left',0,'brp_right',0)||pts||jsonb_build_object('carry_left',greatest(0,tot_l-used_l-coalesce((select consumed_left from private.member_admin_baselines where member_id=p_member),0)),'carry_right',greatest(0,tot_r-used_r-coalesce((select consumed_right from private.member_admin_baselines where member_id=p_member),0)),'direct_points',coalesce((g->>'direct_points')::numeric,0),'tngp',coalesce((g->>'tngp')::numeric,0));
 select jsonb_build_object(
 'account',jsonb_build_object('package_code',private.current_package_code(p_member),'rank',p.achieved_rank,'status',p.status),
 'wallets',jsonb_build_object('cash',coalesce(w.balance,0),'proceed',coalesce(i.proceed_mio,0),'shopping',coalesce(i.shopping_points,0),'promotion',coalesce(i.promotion_points,0),'exchange',coalesce(e.balance,0)),
 'maintenance',jsonb_build_object('monthly_due_at',m.monthly_due_at,'annual_due_at',m.annual_due_at,'monthly_progress_ppv',coalesce(m.monthly_progress_ppv,0)),
 'earnings',jsonb_build_object('direct',0,'generation',0,'binary_pool_share',0,'manager',0,'community_share',0,'single_line',0,'ecommerce',0,'other',0)||coalesce((select jsonb_object_agg(category,amount) from public.member_opening_earnings where member_id=p_member),'{}'),
 'points',pts||private.binary_side_dp_gp_totals(p_member),
 'placement',jsonb_build_object('sponsor_code',sp.member_code,'placement_code',pl.member_code,'side',bp.side)) into result
 from public.member_profiles p left join public.mio_wallet_accounts w on w.member_id=p.user_id left join public.member_income_wallets i on i.member_id=p.user_id left join private.exchange_wallet_accounts e on e.member_id=p.user_id left join public.member_maintenance m on m.member_id=p.user_id left join public.binary_placements bp on bp.member_id=p.user_id left join public.member_profiles pl on pl.user_id=bp.parent_id left join public.member_profiles sp on sp.user_id=p.sponsor_id where p.user_id=p_member;
 return result;
end $$;
revoke all on function private.member_management_state(uuid) from public,anon,authenticated;
create or replace function private.admin_member_management(p_member uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return jsonb_build_object('state',private.member_management_state(p_member),'server_now',now(),
 'ranks',(select coalesce(jsonb_agg(jsonb_build_object('code',rank_code,'name',display_name) order by sort_order),'[]') from public.leadership_rank_definitions where active),
 'plans',(select jsonb_agg(jsonb_build_object('code',p.package_code,'name',coalesce(private.current_mlm_rules()->'plans'->p.package_code->>'display_name',p.package_code))) from (select distinct package_code from public.package_versions where is_active) p));
end$$;
create or replace function public.admin_member_management(p_member uuid) returns jsonb language sql stable security invoker set search_path='' as $$select private.admin_member_management(p_member)$$;
revoke all on function private.admin_member_management(uuid),public.admin_member_management(uuid) from public,anon;
grant execute on function private.admin_member_management(uuid),public.admin_member_management(uuid) to authenticated;

create or replace function private.admin_save_member_state(p_member uuid,p_section text,p_values jsonb,p_expected jsonb,p_key uuid,p_reason text) returns jsonb language plpgsql security definer set search_path='' as $$
declare old private.member_admin_changes%rowtype;before_state jsonb;after_state jsonb;change_id uuid;v record;amount numeric;delta numeric;plan public.package_versions%rowtype;activation uuid;rank_order integer;sp uuid;parent uuid;cycle_found boolean;current_amount numeric;consumed numeric;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if p_section not in('account','wallets','maintenance','earnings','points','placement') or p_section is null or jsonb_typeof(p_values)<>'object' or p_values is null or p_key is null or length(trim(coalesce(p_reason,''))) not between 10 and 2000 then raise exception 'Invalid section, values, request key or reason';end if;
 perform pg_advisory_xact_lock(hashtextextended('member-admin-request:'||p_key::text,0));
 select * into old from private.member_admin_changes where request_key=p_key;
 if found then
  if old.actor_id<>auth.uid() or old.member_id<>p_member or old.section<>p_section or old.requested<>p_values or old.reason<>trim(p_reason) then raise exception 'Request key already used with different values';end if;return old.after_data;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 perform 1 from public.member_profiles where user_id=p_member for update;if not found then raise exception 'Member not found';end if;
 if p_section='placement' and (exists(select 1 from public.user_roles where user_id=p_member and role='admin') or exists(select 1 from private.network_foundation where founder_id=p_member)) then raise exception 'Company/founder network relationships remain protected. Contact details and membership can be edited separately.';end if;
 insert into public.mio_wallet_accounts(member_id) values(p_member) on conflict do nothing;
 insert into public.member_income_wallets(member_id) values(p_member) on conflict do nothing;
 if p_section='account' and p_values ? 'status' and p_values->>'status'<>'active' and exists(select 1 from public.user_roles where user_id=p_member and role='admin') then raise exception 'An administrator account must remain active';end if;
 perform 1 from public.mio_wallet_accounts where member_id=p_member for update;
 perform 1 from public.member_income_wallets where member_id=p_member for update;
 perform 1 from private.exchange_wallet_accounts where member_id=p_member for update;
 perform 1 from public.member_maintenance where member_id=p_member for update;
 perform pg_advisory_xact_lock(hashtextextended('total-ppv:'||p_member::text,0));
 before_state:=private.member_management_state(p_member)->p_section;
 if p_expected is null or before_state is distinct from p_expected then raise exception 'Member data changed. Refresh and review before saving again.';end if;
 if exists(select 1 from jsonb_object_keys(p_values) k where not before_state ? k and not(p_section='maintenance' and k in('monthly_days','annual_days'))) then raise exception 'Unsupported field';end if;
 insert into private.member_admin_changes(actor_id,member_id,request_key,section,requested,reason,before_data) values(auth.uid(),p_member,p_key,p_section,p_values,trim(p_reason),before_state) returning id into change_id;
 insert into private.member_restore_context values(txid_current(),p_member);
 insert into private.member_admin_baselines(member_id) values(p_member) on conflict do nothing;
 if p_section in('wallets','earnings','points') then
  for v in select * from jsonb_each(p_values) loop
   if jsonb_typeof(v.value)<>'number' then raise exception 'Numeric values required';end if;amount:=(v.value#>>'{}')::numeric;
   if amount<0 or amount>1000000000 or amount<>round(amount,4) then raise exception 'Amounts must be nonnegative, at most 1 billion and have at most four decimals';end if;
  end loop;
 end if;
 if p_section='wallets' then
  for v in select * from jsonb_each(p_values) loop
   amount:=(v.value#>>'{}')::numeric;delta:=amount-(before_state->>v.key)::numeric;if delta=0 then continue;end if;
   if v.key='cash' then
    update public.mio_wallet_accounts set balance=amount,updated_at=now() where member_id=p_member;
    insert into public.mio_ledger(member_id,amount,action,reason,idempotency_key) values(p_member,delta,case when delta>0 then 'admin_mint' else 'admin_burn' end,trim(p_reason),'member-restore:'||change_id||':cash');
   elsif v.key='exchange' then
    if amount>0 and private.current_package_code(p_member) is distinct from 'PREMIUM' then raise exception 'Exchange balance requires Platinum membership';end if;
    insert into private.exchange_wallet_accounts(member_id,balance) values(p_member,amount) on conflict(member_id) do update set balance=excluded.balance,updated_at=now();
   else
    update public.member_income_wallets set proceed_mio=case when v.key='proceed' then amount else proceed_mio end,shopping_points=case when v.key='shopping' then amount else shopping_points end,promotion_points=case when v.key='promotion' then amount else promotion_points end,updated_at=now() where member_id=p_member;
    insert into public.income_wallet_ledger(member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key) values(p_member,v.key,delta,'admin_adjustment',trim(p_reason),jsonb_build_object('admin_change_id',change_id),'member-restore:'||change_id||':'||v.key);
   end if;
  end loop;
 elsif p_section='earnings' then
  for v in select * from jsonb_each(p_values) loop insert into public.member_opening_earnings(member_id,category,amount) values(p_member,v.key,(v.value#>>'{}')::numeric) on conflict(member_id,category) do update set amount=excluded.amount,updated_at=now();end loop;
 elsif p_section='maintenance' then
  if p_values ? 'monthly_due_at' or p_values ? 'annual_due_at' then raise exception 'Enter remaining days rather than timestamps';end if;
  insert into public.member_maintenance(member_id,started_at,monthly_due_at,annual_due_at) values(p_member,now(),now()+interval '180 days',now()+interval '365 days') on conflict do nothing;
  for v in select * from jsonb_each(p_values) loop
   if jsonb_typeof(v.value)<>'number' then raise exception 'Numeric values required';end if;amount:=(v.value#>>'{}')::numeric;
   if amount<0 or amount>36500 or (v.key<>'monthly_progress_ppv' and amount<>trunc(amount)) then raise exception 'Invalid remaining days or maintenance progress';end if;
   update public.member_maintenance set monthly_due_at=case when v.key='monthly_days' then now()+amount*interval '1 day' else monthly_due_at end,annual_due_at=case when v.key='annual_days' then now()+amount*interval '1 day' else annual_due_at end,monthly_progress_ppv=case when v.key='monthly_progress_ppv' then amount else monthly_progress_ppv end,started_at=coalesce(started_at,now()),updated_at=now() where member_id=p_member;
  end loop;
 elsif p_section='account' then
  if p_values ? 'package_code' and (p_values->>'package_code') is distinct from (before_state->>'package_code') then
   if nullif(p_values->>'package_code','') is not null then
    select * into plan from public.package_versions where package_code=p_values->>'package_code' and is_active order by version desc limit 1;if not found then raise exception 'Unknown package';end if;
    select activation_id into activation from private.member_admin_baselines where member_id=p_member;
    if activation is null then
     insert into public.package_activations(member_id,package_code,package_version,source,source_reference,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,approved_by,idempotency_key,binary_reserve_mio)
     values(p_member,plan.package_code,plan.version,'ADMIN','Migration entitlement; no purchase or payout',0,0,0,0,0,0,0,0,0,plan.direct_rate,plan.generation1_rate,plan.binary_entitlement,'approved',now(),auth.uid(),'member-package-import:'||p_member,0) returning id into activation;
    else update public.package_activations set package_code=plan.package_code,package_version=plan.version,direct_rate=plan.direct_rate,generation1_rate=plan.generation1_rate,binary_entitlement=plan.binary_entitlement,status='approved',activated_at=now(),binary_reserve_mio=0 where id=activation;end if;
   else
    select activation_id into activation from private.member_admin_baselines where member_id=p_member;
    update public.package_activations set status='reversed' where id=activation;
   end if;
   if nullif(p_values->>'package_code','') is not null then insert into public.member_maintenance(member_id,started_at,monthly_due_at,annual_due_at) values(p_member,now(),now()+interval '180 days',now()+interval '365 days') on conflict(member_id) do update set started_at=coalesce(public.member_maintenance.started_at,now()),monthly_due_at=coalesce(public.member_maintenance.monthly_due_at,now()+interval '180 days'),annual_due_at=coalesce(public.member_maintenance.annual_due_at,now()+interval '365 days');end if;
   update private.member_admin_baselines set package_assigned=true,package_code=nullif(p_values->>'package_code',''),package_assigned_at=now(),activation_id=activation where member_id=p_member;
  end if;
  if p_values ? 'rank' then
   if nullif(p_values->>'rank','') is not null then
    select sort_order into rank_order from public.leadership_rank_definitions where rank_code=p_values->>'rank' and active;if not found then raise exception 'Unknown rank';end if;
    insert into public.member_rank_history(member_id,rank_code,metrics) select p_member,rank_code,jsonb_build_object('migration',true,'admin_change_id',change_id) from public.leadership_rank_definitions where active and sort_order<=rank_order on conflict do nothing;
   end if;
   update public.member_profiles set achieved_rank=nullif(p_values->>'rank',''),updated_at=now() where user_id=p_member;
  end if;
  if p_values ? 'status' then
   if coalesce(p_values->>'status','') not in('active','inactive','suspended') then raise exception 'Invalid account status';end if;
   update public.member_profiles set status=(p_values->>'status')::public.account_status,updated_at=now() where user_id=p_member;
  end if;
 elsif p_section='points' then
  for v in select * from jsonb_each(p_values) where key not in('carry_left','carry_right','direct_points','tngp','left_dp','right_dp','left_gp','right_gp') loop
   amount:=(v.value#>>'{}')::numeric;delta:=amount-coalesce((before_state->>v.key)::numeric,0);if delta=0 then continue;end if;
   insert into public.point_ledger(member_id,point_type,side,amount,entry_kind,admin_change_id,idempotency_key) values(p_member,upper(split_part(v.key,'_',1)),nullif(upper(split_part(v.key,'_',2)),''),delta,'credit',change_id,'member-points:'||change_id||':'||v.key);
  end loop;
  for v in select * from jsonb_each(p_values) where key in('carry_left','carry_right') loop
   amount:=(v.value#>>'{}')::numeric;
   select coalesce(sum(pl.amount),0) into current_amount from public.point_ledger pl where member_id=p_member and point_type='BP' and side=upper(split_part(v.key,'_',2)) and created_at>private.financial_reset_at();
   if amount>current_amount then raise exception 'Carry-forward cannot exceed lifetime BP';end if;
   select coalesce(sum(case when v.key='carry_left' then r.consumed_left else r.consumed_right end),0) into consumed from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where r.member_id=p_member and c.status in('posted','unallocated') and c.created_at>private.financial_reset_at();
   update private.member_admin_baselines set consumed_left=case when v.key='carry_left' then current_amount-consumed-amount else consumed_left end,consumed_right=case when v.key='carry_right' then current_amount-consumed-amount else consumed_right end where member_id=p_member;
  end loop;
  update private.member_admin_baselines set left_dp_offset=left_dp_offset+coalesce((p_values->>'left_dp')::numeric-(before_state->>'left_dp')::numeric,0),right_dp_offset=right_dp_offset+coalesce((p_values->>'right_dp')::numeric-(before_state->>'right_dp')::numeric,0),left_gp_offset=left_gp_offset+coalesce((p_values->>'left_gp')::numeric-(before_state->>'left_gp')::numeric,0),right_gp_offset=right_gp_offset+coalesce((p_values->>'right_gp')::numeric-(before_state->>'right_gp')::numeric,0),direct_dp_offset=direct_dp_offset+coalesce((p_values->>'direct_points')::numeric-(before_state->>'direct_points')::numeric,0),tngp_offset=tngp_offset+coalesce((p_values->>'tngp')::numeric-(before_state->>'tngp')::numeric,0) where member_id=p_member;
 elsif p_section='placement' then
  select user_id into sp from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(coalesce(p_values->>'sponsor_code',before_state->>'sponsor_code'))),'^MIO-','');
  select user_id into parent from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(coalesce(p_values->>'placement_code',before_state->>'placement_code'))),'^MIO-','');
  if sp is null or parent is null or sp=p_member or parent=p_member or coalesce(p_values->>'side',before_state->>'side','') not in('LEFT','RIGHT') then raise exception 'Valid sponsor, placement and Left/Right are required';end if;
  with recursive up(id,path) as(select sp,array[sp] union all select m.sponsor_id,u.path||m.sponsor_id from up u join public.member_profiles m on m.user_id=u.id where m.sponsor_id is not null and not m.sponsor_id=any(u.path)) select exists(select 1 from up where id=p_member) into cycle_found;
  if cycle_found then raise exception 'Sponsor change would create a cycle';end if;
  with recursive up(id,path) as(select parent,array[parent] union all select b.parent_id,u.path||b.parent_id from up u join public.binary_placements b on b.member_id=u.id where b.parent_id is not null and not b.parent_id=any(u.path)) select exists(select 1 from up where id=p_member) into cycle_found;
  if cycle_found then raise exception 'Placement change would create a cycle';end if;
  if exists(select 1 from public.binary_placements where parent_id=parent and side=coalesce(p_values->>'side',before_state->>'side') and member_id<>p_member) then raise exception 'This placement position is occupied';end if;
  update public.member_profiles set sponsor_id=sp,updated_at=now() where user_id=p_member;
  insert into public.binary_placements(member_id,parent_id,side,placed_by) values(p_member,parent,coalesce(p_values->>'side',before_state->>'side'),auth.uid()) on conflict(member_id) do update set parent_id=excluded.parent_id,side=excluded.side,placed_by=excluded.placed_by,placed_at=now();
 end if;
 if p_section in('account','placement','points') then perform private.refresh_binary_qualification_ancestors(p_member);end if;
 after_state:=private.member_management_state(p_member)->p_section;
 update private.member_admin_changes set after_data=after_state where id=change_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'MEMBER_STATE_RESTORED','member_profile',p_member,jsonb_build_object('section',p_section,'reason',trim(p_reason),'before',before_state,'after',after_state,'change_id',change_id));
 delete from private.member_restore_context where transaction_id=txid_current();return after_state;
end$$;
create or replace function public.admin_save_member_state(p_member uuid,p_section text,p_values jsonb,p_expected jsonb,p_key uuid,p_reason text) returns jsonb language sql security invoker set search_path='' as $$select private.admin_save_member_state(p_member,p_section,p_values,p_expected,p_key,p_reason)$$;
revoke all on function private.admin_save_member_state(uuid,text,jsonb,jsonb,uuid,text),public.admin_save_member_state(uuid,text,jsonb,jsonb,uuid,text) from public,anon;
grant execute on function private.admin_save_member_state(uuid,text,jsonb,jsonb,uuid,text),public.admin_save_member_state(uuid,text,jsonb,jsonb,uuid,text) to authenticated;

create or replace function private.my_account_baseline() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 return jsonb_build_object('package_code',private.current_package_code(auth.uid()),'opening_earnings',coalesce((select jsonb_agg(jsonb_build_object('category',category,'amount',amount,'updated_at',updated_at) order by category) from public.member_opening_earnings where member_id=auth.uid()),'[]'));
end$$;
create or replace function public.my_account_baseline() returns jsonb language sql stable security invoker set search_path='' as $$select private.my_account_baseline()$$;
revoke all on function private.my_account_baseline(),public.my_account_baseline() from public,anon;
grant execute on function private.my_account_baseline(),public.my_account_baseline() to authenticated;

create or replace function private.save_my_profile(p_name text,p_phone text,p_country text,p_gender text,p_dob date) returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required';end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 150 or length(trim(coalesce(p_phone,''))) not between 5 and 40 or not coalesce(private.valid_market_country(upper(p_country)),false) or p_gender not in('male','female') or (p_dob is not null and (p_dob<date '1900-01-01' or p_dob>current_date)) then raise exception 'Check profile details';end if;
 update public.member_profiles set full_name=trim(p_name),phone=trim(p_phone),country_code=upper(p_country),gender=p_gender,date_of_birth=p_dob,updated_at=now() where user_id=auth.uid();
end$$;
create or replace function public.save_my_profile(p_name text,p_phone text,p_country text,p_gender text,p_dob date) returns void language sql security invoker set search_path='' as $$select private.save_my_profile(p_name,p_phone,p_country,p_gender,p_dob)$$;
revoke all on function private.save_my_profile(text,text,text,text,date),public.save_my_profile(text,text,text,text,date) from public,anon;
grant execute on function private.save_my_profile(text,text,text,text,date),public.save_my_profile(text,text,text,text,date) to authenticated;
