-- Only enrollment/placement eligibility and tree presentation change.
-- Reward functions, config, ledgers, sponsor relationships and paid ordering are retained.
select pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
create table private.member_placement_intents(
 member_id uuid primary key references public.member_profiles(user_id),
 sponsor_id uuid not null references public.member_profiles(user_id),
 side text not null check(side in ('LEFT','RIGHT')),
 placement_anchor uuid references public.member_profiles(user_id),
 recorded_at timestamptz not null default now()
);
alter table private.member_placement_intents enable row level security;
revoke all on private.member_placement_intents from public,anon,authenticated;

-- Record the chosen side once, server-side, independently of mutable auth metadata.
create function private.remember_member_placement(p_member uuid,p_sponsor uuid,p_side text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if p_side not in ('LEFT','RIGHT') or p_side is null then raise exception 'Choose LEFT or RIGHT';end if;
 if not exists(select 1 from public.member_profiles where user_id=p_member and sponsor_id=p_sponsor)
 then raise exception 'Placement sponsor does not match registration';end if;
 insert into private.member_placement_intents(member_id,sponsor_id,side)
 values(p_member,p_sponsor,p_side) on conflict(member_id) do nothing;
 if not exists(select 1 from private.member_placement_intents where member_id=p_member and sponsor_id=p_sponsor and side=p_side)
 then raise exception 'Registration side is already saved';end if;
end $$;
revoke all on function private.remember_member_placement(uuid,uuid,text) from public,anon,authenticated;

-- Existing confirmed choices: actual placement first, then approved membership request,
-- then signup metadata. This backfill does not create a binary position.
insert into private.member_placement_intents(member_id,sponsor_id,side)
select m.user_id,m.sponsor_id,coalesce(b.side,r.placement_side,upper(u.raw_user_meta_data->>'referral_side'))
from public.member_profiles m join auth.users u on u.id=m.user_id
left join public.binary_placements b on b.member_id=m.user_id
left join lateral(select placement_side from private.shopping_membership_requests
 where customer_id=m.user_id and status='completed' order by reviewed_at desc limit 1)r on true
where m.sponsor_id is not null
and coalesce(b.side,r.placement_side,upper(u.raw_user_meta_data->>'referral_side')) in ('LEFT','RIGHT');

-- Repair only unambiguous old free nodes (leaf or one child on the same side).
-- Audit the original placement. Never guess how to merge a two-sided branch.
do $$ declare b record;c record;n integer;begin
 for b in select p.*,m.sponsor_id from public.binary_placements p join public.member_profiles m on m.user_id=p.member_id
 where private.current_package_code(p.member_id) is null for update of p loop
  if b.parent_id is null then raise exception 'Unactivated root requires explicit reconciliation';end if;
  select count(*) into n from public.binary_placements where parent_id=b.member_id;
  if n>1 then raise exception 'Free placement with two child branches requires explicit reconciliation';end if;
  select * into c from public.binary_placements where parent_id=b.member_id;
  if n=1 and c.side<>b.side then raise exception 'Free placement has a cross-side child; explicit reconciliation required';end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
  values(null,'FREE_PLACEMENT_RECONCILED','binary_placement',b.member_id,
   jsonb_build_object('previous',to_jsonb(b),'child',case when n=1 then to_jsonb(c) else null end,'reason','Package activation required before placement'));
  delete from public.binary_placements where member_id=b.member_id;
  if n=1 then update public.binary_placements set parent_id=b.parent_id,side=b.side where member_id=c.member_id;end if;
 end loop;
end $$;

-- A database guard also covers direct inserts/admin placement routes.
create function private.require_activated_binary_member()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if private.current_package_code(new.member_id) is null then
  raise exception 'Activate a package before binary placement';end if;
 if new.parent_id is not null and private.current_package_code(new.parent_id) is null then
  raise exception 'Binary parent must have an activated package';end if;
 return new;
end $$;
revoke all on function private.require_activated_binary_member() from public,anon,authenticated;
create trigger activated_binary_member before insert or update of member_id,parent_id,side on public.binary_placements
for each row execute function private.require_activated_binary_member();

CREATE OR REPLACE FUNCTION private.place_outermost(p_member uuid, p_sponsor uuid, p_side text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare parent uuid:=p_sponsor; child uuid; hops integer:=0; begin
 if p_side is null or p_side not in('LEFT','RIGHT') then raise exception 'Choose LEFT or RIGHT'; end if;
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 if exists(select 1 from public.user_roles where user_id=p_sponsor and role='admin') then raise exception 'Company has no left/right links. Use founder referral'; end if;
 if exists(select 1 from public.binary_placements where member_id=p_member) then return; end if;
 if private.current_package_code(p_member) is null then
  perform private.remember_member_placement(p_member,p_sponsor,p_side);
  return;
 end if;
 if not exists(select 1 from public.binary_placements where member_id=parent) then raise exception 'Sponsor binary position must be set first'; end if;
 loop
  select member_id into child from public.binary_placements where parent_id=parent and side=p_side;
  exit when child is null;
  parent:=child; hops:=hops+1;
  if parent=p_member or hops>10000 then raise exception 'Invalid or excessively deep binary path'; end if;
 end loop;
 insert into public.binary_placements(member_id,parent_id,side,placed_by) values(p_member,parent,p_side,p_sponsor);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(p_sponsor,'REFERRAL_BINARY_PLACED','binary_placement',p_member,jsonb_build_object('sponsor',p_sponsor,'parent',parent,'side',p_side));
end $function$;

create or replace function private.place_signup_binary()
returns trigger language plpgsql security definer set search_path='' as $$
declare side text;begin
 select upper(raw_user_meta_data->>'referral_side') into side from auth.users where id=new.user_id;
 if new.sponsor_id is not null and side in ('LEFT','RIGHT') then
  perform private.remember_member_placement(new.user_id,new.sponsor_id,side);
  if private.package_eligible(new.user_id) then perform private.place_outermost(new.user_id,new.sponsor_id,side);end if;
 end if;
 return new;
end $$;

CREATE OR REPLACE FUNCTION private.place_binary_after_activation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare sponsor uuid; side text; company uuid;
BEGIN if private.member_restore_active(new.member_id) then return new;end if;
  if new.status <> 'approved' or not private.package_eligible(new.member_id)
     or exists (select 1 from public.binary_placements where member_id = new.member_id) then
    return new;
  end if;
  if exists(select 1 from public.user_roles where user_id=new.member_id and role='admin') then
    return new;
  end if;
  select company_id into company
  from private.network_foundation
  where singleton and founder_id=new.member_id;
  if company is not null then
    insert into public.binary_placements(member_id,parent_id,side,placed_by)
    values(new.member_id,null,null,company)
    on conflict(member_id) do nothing;
    return new;
  end if;
  select coalesce(i.placement_anchor,i.sponsor_id),i.side into sponsor,side
  from private.member_placement_intents i where i.member_id=new.member_id;
  if sponsor is not null and side is not null then
    perform private.place_outermost(new.member_id,sponsor,upper(side));
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION private.complete_referral_join(p_full_name text, p_phone text, p_referral_code text, p_consent boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=auth.uid(); sponsor uuid; state public.account_status;
begin
 if uid is null then raise exception 'Sign in first'; end if;
 select status into state from public.member_profiles where user_id=uid for update;
 if state is distinct from 'pending' then raise exception 'Pending onboarding required'; end if;
 if length(trim(coalesce(p_full_name,'')))<2 or length(trim(coalesce(p_phone,'')))<5 or p_consent is distinct from true then raise exception 'Complete your name, phone and consent'; end if;
 select user_id into sponsor from public.member_profiles where (upper(referral_code)=upper(trim(p_referral_code)) or upper(member_code)=upper(trim(p_referral_code))) and status in('active','inactive') and terms_accepted_at is not null;
 if sponsor is not null and not private.package_eligible(sponsor) then raise exception 'Sponsor must activate a package before inviting members';end if;
 if sponsor is null or sponsor=uid then raise exception 'Valid referral code is required'; end if;
 update public.member_profiles set full_name=trim(p_full_name),phone=trim(p_phone),sponsor_id=sponsor,status='active',terms_accepted_at=now(),terms_version='phase1-terms-v1',updated_at=now() where user_id=uid;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(uid,'REFERRAL_JOIN_COMPLETED','member',uid,jsonb_build_object('sponsor_id',sponsor));
end $function$;

CREATE OR REPLACE FUNCTION public.complete_referral_join(p_full_name text, p_phone text, p_referral_code text, p_consent boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare ref text:=regexp_replace(upper(trim(p_referral_code)),'^(MEM|REF)-',''); side text; sponsor uuid; begin
 if ref ~ '-[LR]$' then side:=case right(ref,1) when 'L' then 'LEFT' else 'RIGHT' end;ref:=left(ref,length(ref)-2); end if;
 perform private.complete_referral_join(p_full_name,p_phone,ref,p_consent);
 select sponsor_id into sponsor from public.member_profiles where user_id=auth.uid();
 if side is not null then perform private.place_outermost(auth.uid(),sponsor,side); end if;
end $function$;

CREATE OR REPLACE FUNCTION private.create_provisioned_profile(new_user auth.users)
 RETURNS auth.users
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r private.member_provisioning%rowtype;code text;
begin
 perform pg_advisory_xact_lock(hashtextextended('member-network-placement',0));
 select * into r from private.member_provisioning where token=(new_user.raw_app_meta_data->>'admin_provisioning')::uuid and email=lower(new_user.email) and member_id is null and expires_at>now() for update;
 if not found then raise exception 'Valid administrator creation reservation required';end if;
 if not exists(select 1 from public.user_roles where user_id=r.actor_id and role='admin') then raise exception 'Creating administrator no longer authorized';end if;
 if exists(select 1 from public.binary_placements where parent_id=r.placement_id and side=r.side) then raise exception 'This placement position is occupied';end if;
 code:=upper(substr(replace(new_user.id::text,'-',''),1,10));
 insert into private.member_restore_context values(txid_current(),new_user.id);
 insert into public.member_profiles(user_id,member_code,referral_code,full_name,phone,country_code,gender,sponsor_id,status,terms_accepted_at)
 values(new_user.id,'MIO-'||code,code,trim(r.details->>'full_name'),trim(r.details->>'phone'),r.details->>'country',r.details->>'gender',r.sponsor_id,'pending',null);
 insert into public.user_roles(user_id,role) values(new_user.id,'member');
 insert into private.member_placement_intents(member_id,sponsor_id,side,placement_anchor)
 values(new_user.id,r.sponsor_id,r.side,r.placement_id);
 update private.member_provisioning set member_id=new_user.id where request_key=r.request_key;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(r.actor_id,'FREE_MEMBER_CREATED','member_profile',new_user.id,jsonb_build_object('email',r.email,'reason',r.reason,'sponsor_id',r.sponsor_id,'placement_id',r.placement_id,'side',r.side));
 delete from private.member_restore_context where transaction_id=txid_current();return new_user;
end$function$;

CREATE OR REPLACE FUNCTION private.review_shopping_membership(p_request uuid, p_approve boolean, p_side text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r private.shopping_membership_requests%rowtype;c private.customer_identities%rowtype;s public.member_profiles%rowtype;code text;
begin
 if auth.uid() is null or p_approve is null then raise exception 'Sign in and choose a decision';end if;
 if length(coalesce(p_note,''))>500 then raise exception 'Keep the review note within 500 characters';end if;
 select * into r from private.shopping_membership_requests where id=p_request for update;
 if r.id is null then raise exception 'Request not found';end if;
 -- Check ownership before exposing any terminal state or accepting retries.
 if r.status='pending_admin' then
  if not private.has_role('admin') then raise exception 'Admin access required';end if;
 elsif r.sponsor_id is distinct from auth.uid() then
  if r.source='direct' and r.admin_reviewed_by=auth.uid() and private.has_role('admin') then return jsonb_build_object('status',r.status,'already_reviewed',true);end if;
  raise exception 'Only the assigned sponsor can review this request';
 end if;
 if r.status in ('completed','declined') then return jsonb_build_object('status',r.status,'already_reviewed',true);end if;
 select * into c from private.customer_identities where user_id=r.customer_id for update;
 if not p_approve then
  if length(trim(coalesce(p_note,'')))<3 then raise exception 'Add a short reason for declining';end if;
  update private.shopping_membership_requests set status='declined',admin_reviewed_by=case when r.status='pending_admin' then auth.uid() else admin_reviewed_by end,admin_reviewed_at=case when r.status='pending_admin' then now() else admin_reviewed_at end,reviewed_by=auth.uid(),reviewed_at=now(),review_note=trim(p_note),updated_at=now() where id=r.id;
  perform private.notify_shopper(c.user_id,'membership','Membership request declined',trim(p_note),'account/earn',r.id);
 elsif r.status='pending_admin' then
  select m.* into s from private.network_foundation nf join public.member_profiles m on m.user_id=nf.founder_id where nf.singleton and nf.founder_id<>nf.company_id and m.status in ('active','inactive') and m.terms_accepted_at is not null;
  if s.user_id is null or exists(select 1 from public.user_roles where user_id=s.user_id and role='admin') or not exists(select 1 from public.binary_placements where member_id=s.user_id) then raise exception 'Founder account is not ready for placement';end if;
  update private.shopping_membership_requests set sponsor_id=s.user_id,sponsor_member_code=s.member_code,status='awaiting_founder',admin_reviewed_by=auth.uid(),admin_reviewed_at=now(),review_note=trim(coalesce(p_note,'')),updated_at=now() where id=r.id;
  update private.customer_identities set sponsor_id=s.user_id where user_id=c.user_id;
  perform private.notify_shopper(c.user_id,'membership','Admin approved your request','Your request has been sent to the Founder for Left or Right placement. Membership starts after placement.','account/earn',r.id);
  perform private.notify_member(s.user_id,'shopping','User ready for Founder placement',c.full_name||' has admin approval. Review and choose Left or Right in My Network.','shopping_membership',r.id,jsonb_build_object('route','network'));
 else
  if p_side is null or p_side not in ('LEFT','RIGHT') then raise exception 'Choose Left or Right before confirming membership';end if;
  select * into s from public.member_profiles where user_id=r.sponsor_id and status in ('active','inactive') and terms_accepted_at is not null;
  if s.user_id is null or exists(select 1 from public.user_roles where user_id=s.user_id and role='admin') then raise exception 'Sponsor is not eligible for placement';end if;
  if not exists(select 1 from auth.users where id=c.user_id and email_confirmed_at is not null) then raise exception 'Customer must verify their email first';end if;
  if exists(select 1 from public.member_profiles where user_id=c.user_id) then raise exception 'Customer already has a membership; review their existing placement';end if;
  code:=upper(substr(replace(c.user_id::text,'-',''),1,10));
  insert into public.member_profiles(user_id,member_code,referral_code,full_name,phone,country_code,sponsor_id,status,terms_accepted_at,terms_version)
  values(c.user_id,'MIO-'||code,code,c.full_name,c.phone,c.country_code,s.user_id,'inactive',r.consent_at,'phase1-terms-v1');
  insert into public.user_roles(user_id,role) values(c.user_id,'member') on conflict do nothing;
  perform private.place_outermost(c.user_id,s.user_id,p_side);
  update private.customer_identities set sponsor_id=s.user_id where user_id=c.user_id;
  update private.shopping_membership_requests set status='completed',placement_side=p_side,reviewed_by=auth.uid(),reviewed_at=now(),review_note=trim(coalesce(p_note,'')),updated_at=now() where id=r.id;
  perform private.notify_shopper(c.user_id,'membership','Your membership is ready','Your sponsor has saved the '||lower(p_side)||' side. Binary placement starts when your package activates. Open your Member Dashboard; your shopping history is preserved.','dashboard',r.id);
  perform private.notify_member(c.user_id,'shopping','Welcome to your member network','Your membership is ready. Package activation and earning qualifications are separate.','shopping_membership',r.id,jsonb_build_object('route','network'));
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'SHOPPING_MEMBERSHIP_REVIEWED','shopping_membership',r.id,jsonb_build_object('approved',p_approve,'side',p_side,'previous_status',r.status));
 return (select jsonb_build_object('status',status,'placement_side',placement_side) from private.shopping_membership_requests where id=r.id);
end $function$;

CREATE OR REPLACE FUNCTION public.my_network_before_vendor_root(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid:=auth.uid(); root uuid; is_company boolean; allowed boolean; result jsonb; root_depth integer:=0; view_depth integer; cutoff timestamptz:=private.financial_reset_at();
begin
 if uid is null or not exists(select 1 from public.member_profiles where user_id=uid and status in('active','inactive') and terms_accepted_at is not null) then raise exception 'Active account required'; end if;
 is_company:=private.has_role('admin'); root:=uid;
 if p_kind not in('generation','binary','pool','single_line','vendor') or p_depth is null or p_depth<0 or (not is_company and ((p_kind='single_line' and p_depth not between 1 and 30) or (p_kind<>'single_line' and p_depth not between 1 and 10))) then raise exception 'Invalid tree view'; end if;
 view_depth:=case when p_depth=0 then (select count(*)::integer from public.member_profiles) else p_depth end;
 if is_company and p_kind in('binary','pool','single_line') then select founder_id into root from private.network_foundation where company_id=uid; end if;
 if nullif(trim(p_root_code),'') is not null then
  select user_id into root from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-','');
 end if;
 if not is_company then
  with recursive team(id,depth,path) as (
   select uid,0,array[uid]
   union all select m.user_id,t.depth+1,t.path||m.user_id from team t join public.member_profiles m on
    (p_kind in('generation','vendor') and m.sponsor_id=t.id) or
    (p_kind not in('generation','vendor') and exists(select 1 from public.binary_placements b where b.member_id=m.user_id and b.parent_id=t.id))
   where t.depth<case when p_kind='single_line' then 30 else 10 end and not m.user_id=any(t.path)
  ) select min(depth) into root_depth from team where id=root;
  if root_depth is null then raise exception 'Selected member is outside your visible network'; end if;
  view_depth:=least(view_depth,(case when p_kind='single_line' then 30 else 10 end)-root_depth);
 end if;
 if root is null then return jsonb_build_object('nodes','[]'::jsonb); end if;
 if p_kind='vendor' then
  return jsonb_build_object('nodes',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'parent_id',root,'full_name',v.business_name,'member_code',m.member_code,'depth',1,'commission_rate',v.commission_rate,'node_type','vendor','status',v.status,'business_name',v.business_name,'country_code',coalesce(v.country_code,m.country_code),'profile_photo_url',v.logo_url,'joined_at',v.created_at)) from public.vendors v left join public.member_profiles m on m.user_id=v.owner_user_id where v.introduced_by=root),'[]'::jsonb));
 end if;
 with recursive tree(id,parent_id,side,depth,path) as (
  select root,null::uuid,null::text,0,array[root]
  union all select m.user_id,t.id,case when p_kind='generation' then null else b.side end,t.depth+1,t.path||m.user_id from tree t join public.member_profiles m on
   (p_kind='generation' and m.sponsor_id=t.id) or (p_kind<>'generation' and exists(select 1 from public.binary_placements x where x.member_id=m.user_id and x.parent_id=t.id))
   left join public.binary_placements b on b.member_id=m.user_id where t.depth<view_depth and not m.user_id=any(t.path)
 ), bounded as(select * from tree order by depth,id limit 501)
 select jsonb_build_object('root_depth',root_depth,'visible_levels',view_depth,'truncated',count(*)>500,'nodes',coalesce(jsonb_agg(jsonb_build_object('id',t.id,'parent_id',t.parent_id,'side',t.side,'depth',t.depth,'member_code',m.member_code,'full_name',m.full_name,'status',m.status,'package',private.current_package_code(t.id),'rank',m.achieved_rank,'joined_at',m.created_at,'profile_photo_url',m.profile_photo_url,
 'bp',coalesce((select bp from public.package_activations a where a.member_id=t.id and a.status='approved' and coalesce(a.activated_at,a.requested_at)>cutoff order by base_value desc,activated_at desc limit 1),0),
 'left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT' and created_at>cutoff),0)-coalesce((select sum(r.consumed_left) from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where r.member_id=t.id and c.created_at>cutoff),0),
 'right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT' and created_at>cutoff),0)-coalesce((select sum(r.consumed_right) from public.binary_member_results r join public.binary_cycles c on c.id=r.cycle_id where r.member_id=t.id and c.created_at>cutoff),0),
 'total_left_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='LEFT' and created_at>cutoff),0),
 'total_right_bp',coalesce((select sum(amount) from public.point_ledger where member_id=t.id and point_type='BP' and side='RIGHT' and created_at>cutoff),0),'left_team_count',coalesce((private.binary_team_counts(t.id)->>'left')::integer,0),'right_team_count',coalesce((private.binary_team_counts(t.id)->>'right')::integer,0),'left_dp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'left_dp')::numeric,0),'right_dp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'right_dp')::numeric,0),'left_gp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'left_gp')::numeric,0),'right_gp',coalesce((private.binary_side_dp_gp_totals(t.id)->>'right_gp')::numeric,0)) order by t.depth,t.side,t.id) filter(where t.id in(select id from bounded limit 500)),'[]'::jsonb)) into result from bounded t join public.member_profiles m on m.user_id=t.id;
 return result;
end
$function$;

CREATE OR REPLACE FUNCTION public.my_network_before_manager_badges(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;root uuid;parent jsonb;weighted_nodes jsonb;share_points numeric;
begin
 result:=public.my_network_before_vendor_root(p_kind,p_root_code,p_depth);
 if p_kind='vendor' then
  root:=auth.uid();
  if nullif(trim(p_root_code),'') is not null then
   select user_id into root from public.member_profiles where member_code='MIO-'||regexp_replace(upper(trim(p_root_code)),'^MIO-','');
  end if;
  select jsonb_build_object('id',user_id,'parent_id',null,'full_name',full_name,'member_code',member_code,
   'depth',0,'package',private.current_package_code(user_id),'rank',achieved_rank,'status',status,'profile_photo_url',profile_photo_url,'joined_at',created_at,'country_code',country_code)
  into parent from public.member_profiles where user_id=root;
  result:=jsonb_set(result,'{nodes}',jsonb_build_array(parent)||coalesce(result->'nodes','[]'::jsonb));
 end if;
 share_points:=coalesce((private.current_mlm_rules()->>'binary_share_points_each_side')::numeric,50);
 select coalesce(jsonb_agg(n.node||jsonb_build_object(
  'binary_share_points_each_side',share_points,
  'binary_entitlement',coalesce(s.binary_entitlement,0),
  'binary_entitlement_percent',coalesce(s.binary_entitlement,0)*100,
  'raw_binary_shares',case when share_points>0 then trunc(least(coalesce(s.left_available,0),coalesce(s.right_available,0))/share_points,1) else 0 end,
  'available_binary_shares',coalesce(s.completed_shares,0),
  'left_brp',coalesce(r.left_brp,0),'right_brp',coalesce(r.right_brp,0),
  'total_left_brp',coalesce(r.left_brp,0),'total_right_brp',coalesce(r.right_brp,0),
  'binary_qualified',coalesce((q.status->>'qualified')::boolean,false),
  'binary_qualified_at',q.status->>'qualified_at',
  'left_direct_count',coalesce((q.status->>'left_direct_count')::integer,0),
  'right_direct_count',coalesce((q.status->>'right_direct_count')::integer,0),
  'binary_required_left_directs',1,'binary_required_right_directs',1,
  'binary_required_left_dp',20,'binary_required_right_dp',20
 ) order by n.ordinality),'[]'::jsonb) into weighted_nodes
 from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
 left join private.binary_live_shares(clock_timestamp()) s on s.member_id=nullif(n.node->>'id','')::uuid
 left join (
  select member_id,
   coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='LEFT'),0) left_brp,
   coalesce(sum(case when entry_kind='credit' then amount else -amount end) filter(where side='RIGHT'),0) right_brp
  from public.point_ledger where point_type='BRP' and side is not null group by member_id
 ) r on r.member_id=nullif(n.node->>'id','')::uuid
 left join lateral (select private.binary_qualification_status(nullif(n.node->>'id','')::uuid) status) q on true;
 return jsonb_set(result,'{nodes}',weighted_nodes);
end$function$;

CREATE OR REPLACE FUNCTION public.my_network(p_kind text DEFAULT 'generation'::text, p_root_code text DEFAULT NULL::text, p_depth integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb;nodes jsonb;manager_badge text;
begin
  result:=public.my_network_before_manager_badges(p_kind,p_root_code,p_depth);
  manager_badge:=private.current_team_manager_rules()->>'badge_url';
  select coalesce(jsonb_agg(n.node||jsonb_build_object(
    'country_code',coalesce(p.country_code,n.node->>'country_code'),'team_manager',q.member_id is not null,'manager_badge_url',manager_badge,
    'rank_name',d.display_name,'rank_theme',d.badge_theme,'rank_badge_url',d.badge_url
  ) order by n.ordinality),'[]'::jsonb) into nodes
  from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
  left join public.member_profiles p on p.user_id=nullif(n.node->>'id','')::uuid
  left join private.team_manager_qualifications q on q.member_id=p.user_id
  left join public.leadership_rank_definitions d on d.rank_code=n.node->>'rank';
  return private.paid_binary_tree_view(private.apply_member_opening_to_tree(jsonb_set(result,'{nodes}',nodes)),p_kind);
end;
$function$;

CREATE OR REPLACE FUNCTION private.paid_binary_tree_view(p_tree jsonb, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare visible_nodes jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_kind='generation' then
  with recursive raw as (
   select node,ord,node->>'id' id,node->>'parent_id' parent_id,
    (nullif(node->>'package','') is not null and upper(node->>'package') not in ('FREE','NONE')) paid
   from jsonb_array_elements(coalesce(p_tree->'nodes','[]'::jsonb)) with ordinality x(node,ord)
  ), paths as (
   select r.*,null::text visible_parent,array[r.id] visited from raw r
   where r.parent_id is null or not exists(select 1 from raw p where p.id=r.parent_id)
   union all select r.*,case when p.paid then p.id else p.visible_parent end,p.visited||r.id
   from paths p join raw r on r.parent_id=p.id where not r.id=any(p.visited)
  ) select coalesce(jsonb_agg(node||jsonb_build_object('parent_id',visible_parent,'sponsor_id',parent_id) order by ord),'[]'::jsonb)
  into visible_nodes from paths where paid;
  return jsonb_set(p_tree,'{nodes}',visible_nodes)||jsonb_build_object('paid_members_only',true);
 end if;
 if p_kind not in ('binary','pool','single_line') then return p_tree; end if;
 with recursive raw as (
  select node,ord,node->>'id' id,node->>'parent_id' parent_id
  from jsonb_array_elements(coalesce(p_tree->'nodes','[]'::jsonb)) with ordinality x(node,ord)
 ), paths as (
  select r.*, ''::text placement_path,array[r.id] visited
  from raw r where r.parent_id is null or not exists(select 1 from raw p where p.id=r.parent_id)
  union all
  select r.*,p.placement_path||case when r.node->>'side'='LEFT' then 'L' else 'R' end,p.visited||r.id
  from paths p join raw r on r.parent_id=p.id where not r.id=any(p.visited)
 )
 select coalesce(jsonb_agg(node||jsonb_build_object('placement_path',placement_path) order by ord),'[]'::jsonb)
 into visible_nodes from paths
 where nullif(node->>'package','') is not null and upper(node->>'package') not in ('FREE','NONE');
 return jsonb_set(p_tree,'{nodes}',visible_nodes)||jsonb_build_object('paid_members_only',true);
end;
$function$;
