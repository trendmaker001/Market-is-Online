-- Read-only admin snapshot; never changes the signed-in identity or refreshes grants.
CREATE OR REPLACE FUNCTION private.support_member_dashboard(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=p_member_id;p public.member_profiles%rowtype;g jsonb;v_binary jsonb;code text;cfg jsonb;shares numeric:=0;personal_gp numeric:=0;personal_bp numeric:=0;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if member is null or not private.registered_member(member) then raise exception 'Member account required';end if;
 select * into p from public.member_profiles where user_id=member;
 code:=private.current_package_code(member);cfg:=private.current_mlm_rules();
 g:=public.my_generation_member_details(p.member_code);
 select node into v_binary from jsonb_array_elements(public.my_network('binary',p.member_code,1)->'nodes') node where node->>'id'=member::text limit 1;
 select coalesce(sum(completed_shares),0) into shares from private.binary_live_shares(now()) where member_id=member;
 select coalesce(sum(amount) filter(where point_type='GP'),0),coalesce(sum(amount) filter(where point_type='BP'),0)
  into personal_gp,personal_bp from public.point_ledger where member_id=member and created_at>private.financial_reset_at();
 return jsonb_build_object('full_name',p.full_name,'member_code',p.member_code,'country_code',p.country_code,'profile_photo_url',p.profile_photo_url,'gender',p.gender,
  'enrolled_at',p.created_at,'package_code',code,'package_name',coalesce(cfg->'plans'->code->>'display_name','Free account'),
  'package_active',private.package_eligible(member),'generation',g,'binary',coalesce(v_binary,'{}'::jsonb),
  'personal_gp',personal_gp,'personal_bp',personal_bp,'pending_shares',shares,
  'share_points_each_side',coalesce((cfg->>'binary_share_points_each_side')::numeric,50),
  'activation_offer',private.activation_offer_window(member),'server_now',now());
end;
$function$
; 
revoke all on function private.support_member_dashboard(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.support_income_wallets(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=p_member_id;cfg jsonb;result jsonb;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if member is null or not private.registered_member(member)then raise exception 'Member account required';end if;
 cfg:=private.current_proceed_wallet_config();
 select jsonb_build_object('cash_mio',coalesce(m.balance,0),'proceed_mio',coalesce(w.proceed_mio,0),'shopping_points',coalesce(w.shopping_points,0),'promotion_points',coalesce(w.promotion_points,0),'shopping_locked',false,'promotion_locked',false,'config',cfg,
  'ledger',coalesce((select jsonb_agg(x order by x.created_at desc)from(select id,wallet_kind,amount,entry_kind,note,metadata,created_at from public.income_wallet_ledger where member_id=member order by created_at desc limit 200)x),'[]'::jsonb),
  'promotion_releases',coalesce((select jsonb_agg(x order by x.created_at desc)from(select r.id,r.rank_code,d.display_name,r.amount,r.created_at from public.promotion_rank_releases r join public.leadership_rank_definitions d on d.rank_code=r.rank_code where r.member_id=member order by r.created_at desc limit 100)x),'[]'::jsonb)) into result
 from public.member_profiles p left join public.mio_wallet_accounts m on m.member_id=p.user_id left join public.member_income_wallets w on w.member_id=p.user_id where p.user_id=member;
 return coalesce(result,'{}');end$function$
; 
revoke all on function private.support_income_wallets(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.support_maintenance_status(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.member_maintenance%rowtype;r jsonb:=private.current_maintenance_rules();code text;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_member_id is null or not private.registered_member(p_member_id) then raise exception 'Member account required';end if;
 select * into m from public.member_maintenance where member_id=p_member_id;
 code:=private.current_package_code(p_member_id);
 return jsonb_build_object('package',code,'rules',r,'server_now',now(),
 'started',code is not null,'monthly_due_at',case when code is not null then m.monthly_due_at end,'annual_due_at',case when code is not null then m.annual_due_at end,
 'monthly_progress_ppv',coalesce(m.monthly_progress_ppv,0),
 'monthly_required_ppv',coalesce((r->'monthly_ppv'->>code)::numeric,0),
 'country_code',(select country_code from public.member_profiles where user_id=p_member_id),'monthly_required',private.monthly_required(p_member_id),'monthly_active',code is not null and (not private.monthly_required(p_member_id) or m.monthly_due_at>now()),'annual_active',code is not null and m.annual_due_at>now());
end$function$
; 
revoke all on function private.support_maintenance_status(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.support_manager_status(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=p_member_id;m jsonb;b private.team_manager_balances%rowtype;q private.team_manager_qualifications%rowtype;r record;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
  if uid is null then raise exception 'Sign in required';end if;
  m:=private.team_manager_metrics(uid);
  select * into b from private.team_manager_balances where member_id=uid;
  select * into q from private.team_manager_qualifications where member_id=uid;
  select d.* into r from public.leadership_rank_definitions d join public.member_profiles p on p.achieved_rank=d.rank_code where p.user_id=uid;
  return m||jsonb_build_object(
    'qualified',q.member_id is not null,'qualified_at',q.qualified_at,'tree_available',q.member_id is not null,
    'team_manager_badge_url',m->'rules'->>'badge_url',
    'manager_track_points',coalesce(b.manager_track_points,0),
    'manager_network_generation_points',coalesce(b.manager_network_generation_points,0),
    'leadership_rank',case when r.rank_code is null then null else jsonb_build_object('code',r.rank_code,'name',r.display_name,'theme',r.badge_theme,'badge_url',r.badge_url) end,
    'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'badge_url',d.badge_url,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb)
  );
end;
$function$
; 
revoke all on function private.support_manager_status(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.support_community_share_status(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=p_member_id;m jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if uid is null then raise exception 'Sign in required';end if;
 m:=private.community_share_metrics(uid);
 return m||jsonb_build_object(
  'grants',coalesce((select jsonb_agg(jsonb_build_object('kind',share_kind,'quantity',quantity,'start_cycle',start_cycle,'end_cycle',end_cycle,'created_at',created_at) order by created_at) from public.community_share_grants where member_id=uid),'[]'::jsonb),
  'distributions',coalesce((select jsonb_agg(jsonb_build_object('cycle_number',c.cycle_number,'actual_shares',d.actual_shares,'gift_shares',d.gift_shares,'amount_mio',d.amount_mio,'created_at',d.created_at) order by c.cycle_number desc) from public.community_share_distributions d join public.community_share_cycles c on c.id=d.cycle_id where d.member_id=uid),'[]'::jsonb)
 );
end$function$
; 
revoke all on function private.support_community_share_status(uuid) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.support_super_member_status(p_member_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=p_member_id;metrics jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
  if uid is null then raise exception 'Sign in required';end if;
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
$function$
; 
revoke all on function private.support_super_member_status(uuid) from public,anon,authenticated;

create or replace function private.admin_member_dashboard(p_member_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s jsonb; w jsonb; m jsonb; balance numeric; net_ppv numeric; cap_ppv numeric; earned numeric; held numeric; maintenance_earned numeric; mode text;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_member_id is null or not exists(select 1 from public.member_profiles where user_id=p_member_id) then raise exception 'Member not found';end if;
 s:=private.support_member_dashboard(p_member_id);
 w:=private.support_income_wallets(p_member_id);
 m:=private.support_maintenance_status(p_member_id);
 select shopping_reward_mode into mode from public.member_profiles where user_id=p_member_id;
 select coalesce(sum(amount),0),coalesce(sum(-amount) filter(where amount<0 and idempotency_key like 'unified-total-ppv-cap:%'),0)
 into net_ppv,cap_ppv from public.point_ledger where member_id=p_member_id and point_type='PPV' and created_at>private.financial_reset_at();
 select coalesce(sum(payable_amount) filter(where status='posted'),0),coalesce(sum(payable_amount) filter(where status='pending'),0)
 into earned,held from public.bonus_transactions where beneficiary_id=p_member_id and created_at>private.financial_reset_at();
 select coalesce(sum(amount_mio),0) into maintenance_earned from public.maintenance_generation_payouts where beneficiary_id=p_member_id;
 return jsonb_build_object('member_id',p_member_id,'summary',s||jsonb_build_object('maintenance',m,'manager_program',private.support_manager_status(p_member_id),'community_share',private.support_community_share_status(p_member_id),'super_member',private.support_super_member_status(p_member_id)),
 'financial',jsonb_build_object('balance',coalesce((w->>'cash_mio')::numeric,0),'ppv',least(110,greatest(0,net_ppv)),'ppvTotal',greatest(0,net_ppv+cap_ppv),'ppvExcess',greatest(0,net_ppv+cap_ppv-110),'earned',earned+maintenance_earned,'held',held),
 'incomeWallets',w,'maintenanceStatus',m,'rewardPreference',jsonb_build_object('eligible',s->'package_active','mode',mode,'ppvUsed',greatest(0,net_ppv+cap_ppv),'ppvCap',110,'locked',net_ppv+cap_ppv>=110));
end$$;
revoke all on function private.admin_member_dashboard(uuid) from public,anon;
grant execute on function private.admin_member_dashboard(uuid) to authenticated;
create or replace function public.admin_member_dashboard(p_member_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
 select private.admin_member_dashboard(p_member_id)
$$;
revoke all on function public.admin_member_dashboard(uuid) from public,anon;
grant execute on function public.admin_member_dashboard(uuid) to authenticated;

