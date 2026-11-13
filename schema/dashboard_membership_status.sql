create or replace function private.my_membership_badge_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); p public.member_profiles%rowtype; code text; due timestamptz;
begin
 if u is null then raise exception 'Sign in required'; end if;
 select * into p from public.member_profiles where user_id=u;
 if not found then raise exception 'Member account required'; end if;
 code:=private.current_package_code(u);
 select annual_due_at into due from public.member_maintenance where member_id=u;
 return jsonb_build_object('account_status',p.status,'package_code',code,'package_active',private.package_eligible(u),'annual_due_at',due,'annual_required',coalesce((private.current_maintenance_rules()->>'enabled')::boolean,true),'server_now',now(),'full_name',p.full_name,'member_code',p.member_code,'country_code',p.country_code,'gender',p.gender,'profile_photo_url',p.profile_photo_url,'enrolled_at',p.created_at);
end$$;
revoke all on function private.my_membership_badge_status() from public,anon;
grant execute on function private.my_membership_badge_status() to authenticated;
create or replace function public.my_membership_badge_status() returns jsonb language sql stable security invoker set search_path='' as $$ select private.my_membership_badge_status() $$;
revoke all on function public.my_membership_badge_status() from public,anon;
grant execute on function public.my_membership_badge_status() to authenticated;

CREATE OR REPLACE FUNCTION private.admin_account_holders(p_page integer DEFAULT 1, p_search text DEFAULT ''::text, p_rank text DEFAULT ''::text, p_status text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Workspace access required';end if;
 if coalesce(p_status,'') not in ('','active','inactive','suspended','closed') then raise exception 'Invalid account status';end if;
 with matching as materialized (
  select m.user_id,m.member_code,m.full_name,m.phone,u.email,m.sponsor_id,m.status,m.created_at,m.achieved_rank
  from public.member_profiles m left join auth.users u on u.id=m.user_id
  where (coalesce(p_status,'')='' or m.status::text=p_status)
   and (coalesce(p_rank,'')='' or (p_rank='unranked' and coalesce(m.achieved_rank,'')='') or m.achieved_rank=p_rank)
   and (trim(coalesce(p_search,''))='' or strpos(lower(concat_ws(' ',m.full_name,m.member_code,m.phone,u.email)),lower(trim(p_search)))>0
    or (regexp_replace(p_search,'[^0-9]','','g')<>'' and p_search~'^[+0-9 ()-]+$' and strpos(regexp_replace(coalesce(m.phone,''),'[^0-9]','','g'),regexp_replace(p_search,'[^0-9]','','g'))>0))
 ), counts as (select count(*) total from matching), paging as (
  select total,greatest(1,ceil(total/50.0)::int) pages,least(greatest(1,coalesce(p_page,1)),greatest(1,ceil(total/50.0)::int)) page from counts
 ), selected as (
  select m.* from matching m order by m.created_at,m.user_id limit 50 offset (select (page-1)*50 from paging)
 ), detailed as (
  select m.*,s.full_name sponsor_name,s.member_code sponsor_code,r.display_name rank_name,private.current_package_code(m.user_id) package_code
  from selected m left join public.member_profiles s on s.user_id=m.sponsor_id left join public.leadership_rank_definitions r on r.rank_code=m.achieved_rank
 ) select jsonb_build_object('total',p.total,'page',p.page,'pages',p.pages,'page_size',50,
  'rows',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at,d.user_id) from detailed d),'[]'::jsonb),
  'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',r.rank_code,'name',r.display_name) order by r.sort_order) from public.leadership_rank_definitions r),'[]'::jsonb)) into result from paging p;
 return result;
end$function$
;
CREATE OR REPLACE FUNCTION private.admin_account_holders(p_page integer, p_search text, p_rank text, p_status text, p_country text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Workspace access required';end if;
 if coalesce(p_status,'') not in ('','active','inactive','suspended','closed') then raise exception 'Invalid account status';end if;
 with matching as materialized (
  select m.user_id,m.member_code,m.full_name,m.phone,m.country_code,u.email,m.sponsor_id,m.status,m.created_at,m.achieved_rank
  from public.member_profiles m left join auth.users u on u.id=m.user_id
  where (coalesce(p_country,'')='' or m.country_code=upper(p_country))
   and (coalesce(p_status,'')='' or m.status::text=p_status)
   and (coalesce(p_rank,'')='' or (p_rank='unranked' and coalesce(m.achieved_rank,'')='') or m.achieved_rank=p_rank)
   and (trim(coalesce(p_search,''))='' or strpos(lower(concat_ws(' ',m.full_name,m.member_code,m.phone,u.email)),lower(trim(p_search)))>0
    or (regexp_replace(p_search,'[^0-9]','','g')<>'' and p_search~'^[+0-9 ()-]+$' and strpos(regexp_replace(coalesce(m.phone,''),'[^0-9]','','g'),regexp_replace(p_search,'[^0-9]','','g'))>0))
 ), counts as (select count(*) total from matching), paging as (
  select total,greatest(1,ceil(total/50.0)::int) pages,least(greatest(1,coalesce(p_page,1)),greatest(1,ceil(total/50.0)::int)) page from counts
 ), selected as (
  select m.* from matching m order by m.created_at,m.user_id limit 50 offset (select (page-1)*50 from paging)
 ), detailed as (
  select m.*,bp.parent_id placement_id,pl.full_name placement_name,pl.member_code placement_code,bp.side placement_side,s.full_name sponsor_name,s.member_code sponsor_code,r.display_name rank_name,private.current_package_code(m.user_id) package_code
  from selected m left join public.binary_placements bp on bp.member_id=m.user_id left join public.member_profiles pl on pl.user_id=bp.parent_id left join public.member_profiles s on s.user_id=m.sponsor_id left join public.leadership_rank_definitions r on r.rank_code=m.achieved_rank
 ) select jsonb_build_object('total',p.total,'page',p.page,'pages',p.pages,'page_size',50,
  'rows',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at,d.user_id) from detailed d),'[]'::jsonb),
  'ranks',coalesce((select jsonb_agg(jsonb_build_object('code',r.rank_code,'name',r.display_name) order by r.sort_order) from public.leadership_rank_definitions r),'[]'::jsonb)) into result from paging p;
 return result;
end$function$
;
CREATE OR REPLACE FUNCTION private.admin_save_member_state(p_member uuid, p_section text, p_values jsonb, p_expected jsonb, p_key uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
   if coalesce(p_values->>'status','') not in('active','inactive','suspended','closed') then raise exception 'Invalid account status';end if;
   update public.member_profiles set status=(p_values->>'status')::public.account_status,updated_at=now() where user_id=p_member;
  end if;
 elsif p_section='points' then
  for v in select * from jsonb_each(p_values) where key not in('carry_left','carry_right','direct_points','tngp','left_dp','right_dp','left_gp','right_gp') loop
   amount:=(v.value#>>'{}')::numeric;delta:=amount-coalesce((before_state->>v.key)::numeric,0);if delta=0 then continue;end if;
   insert into public.point_ledger(member_id,point_type,side,amount,entry_kind,admin_change_id,idempotency_key) values(p_member,upper(split_part(v.key,'_',1)),nullif(upper(split_part(v.key,'_',2)),''),delta,'credit',change_id,'member-points:'||change_id||':'||v.key);
  end loop;
  for v in select * from jsonb_each(before_state||p_values) where key in('carry_left','carry_right') and (p_values ? key or p_values ? replace(key,'carry_','bp_')) loop
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
end$function$
;
CREATE OR REPLACE FUNCTION private.support_member_dashboard(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=p_member_id;p public.member_profiles%rowtype;g jsonb;v_binary jsonb;code text;cfg jsonb;shares numeric:=0;personal_gp numeric:=0;personal_bp numeric:=0;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if member is null or not exists(select 1 from public.member_profiles where user_id=member) then raise exception 'Member account required';end if;
 select * into p from public.member_profiles where user_id=member;
 code:=private.current_package_code(member);cfg:=private.current_mlm_rules();
 g:=public.my_generation_member_details(p.member_code);
 select node into v_binary from jsonb_array_elements(public.my_network('binary',p.member_code,1)->'nodes') node where node->>'id'=member::text limit 1;
 select coalesce(sum(completed_shares),0) into shares from private.binary_live_shares(now()) where member_id=member;
 select coalesce(sum(amount) filter(where point_type='GP'),0),coalesce(sum(amount) filter(where point_type='BP'),0)
  into personal_gp,personal_bp from public.point_ledger where member_id=member and created_at>private.financial_reset_at();
 return jsonb_build_object('account_status',p.status,'full_name',p.full_name,'member_code',p.member_code,'country_code',p.country_code,'profile_photo_url',p.profile_photo_url,'gender',p.gender,
  'enrolled_at',p.created_at,'package_code',code,'package_name',coalesce(cfg->'plans'->code->>'display_name','Free account'),
  'package_active',private.package_eligible(member),'generation',g,'binary',coalesce(v_binary,'{}'::jsonb),
  'personal_gp',personal_gp,'personal_bp',personal_bp,'pending_shares',shares,
  'share_points_each_side',coalesce((cfg->>'binary_share_points_each_side')::numeric,50),
  'activation_offer',private.activation_offer_window(member),'server_now',now());
end;
$function$
;
