create table if not exists private.binary_qualifications(member_id uuid primary key references public.member_profiles(user_id),qualified_at timestamptz not null default now(),left_directs_at_qualification integer not null,right_directs_at_qualification integer not null,left_dp_at_qualification numeric not null,right_dp_at_qualification numeric not null,rule_version text not null default 'binary-once-v1');
CREATE OR REPLACE FUNCTION private.binary_side_dp_gp_totals(p_member uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with recursive downline(id,root_side,path) as (
  select b.member_id,b.side,array[p_member,b.member_id]
  from public.binary_placements b
  where b.parent_id=p_member and b.side in('LEFT','RIGHT')
  union all
  select b.member_id,d.root_side,d.path||b.member_id
  from downline d
  join public.binary_placements b on b.parent_id=d.id
  where not b.member_id=any(d.path)
 ),
 direct_dp as (
  select
   d.root_side,
   coalesce(sum(a.dp),0)::numeric as dp
  from downline d
  join public.member_profiles m
   on m.user_id=d.id
  and m.sponsor_id=p_member
  and m.status='active'
  join public.package_activations a
   on a.member_id=m.user_id
  and a.status='approved'
  group by d.root_side
 ),
 network_gp as (
  select
   d.root_side,
   coalesce(sum(pl.amount) filter(where pl.point_type='GP'),0)::numeric as gp
  from downline d
  left join public.point_ledger pl
   on pl.member_id=d.id
  and pl.created_at>private.financial_reset_at()
  group by d.root_side
 )
 select jsonb_build_object(
  'left_dp',coalesce((select dp from direct_dp where root_side='LEFT'),0),
  'right_dp',coalesce((select dp from direct_dp where root_side='RIGHT'),0),
  'left_gp',coalesce((select gp from network_gp where root_side='LEFT'),0),
  'right_gp',coalesce((select gp from network_gp where root_side='RIGHT'),0)
 );
$function$
;
CREATE OR REPLACE FUNCTION private.binary_qualification_status(p_member uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with recursive downline(id,root_side,path) as (
  select b.member_id,b.side,array[p_member,b.member_id]
  from public.binary_placements b
  where b.parent_id=p_member and b.side in('LEFT','RIGHT')
  union all
  select b.member_id,d.root_side,d.path||b.member_id
  from downline d
  join public.binary_placements b on b.parent_id=d.id
  where not b.member_id=any(d.path)
 ), side_totals as (
  select private.binary_side_dp_gp_totals(p_member) j
 ), direct_counts as (
  select
   count(*) filter(where d.root_side='LEFT')::integer left_directs,
   count(*) filter(where d.root_side='RIGHT')::integer right_directs
  from downline d
  join public.member_profiles m on m.user_id=d.id and m.sponsor_id=p_member and m.status='active'
  where exists(
   select 1 from public.package_activations a
   where a.member_id=d.id and a.status='approved'
  )
 ), snapshot as (
  select q.* from private.binary_qualifications q where q.member_id=p_member
 )
 select jsonb_build_object(
  'qualified',exists(select 1 from snapshot),
  'qualified_at',(select qualified_at from snapshot),
  'left_direct_count',coalesce((select left_directs from direct_counts),0),
  'right_direct_count',coalesce((select right_directs from direct_counts),0),
  'left_dp',coalesce(((select j from side_totals)->>'left_dp')::numeric,0),
  'right_dp',coalesce(((select j from side_totals)->>'right_dp')::numeric,0),
  'required_left_directs',1,
  'required_right_directs',1,
  'required_left_dp',20,
  'required_right_dp',20,
  'permanent_once_qualified',true
 );
$function$
;
CREATE OR REPLACE FUNCTION private.refresh_binary_qualification_ancestors(p_member uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_member uuid:=p_member; parent_member uuid; depth integer:=0;
begin
 loop
  select parent_id into parent_member from public.binary_placements where member_id=current_member;
  exit when parent_member is null;
  perform private.refresh_binary_qualification(parent_member);
  current_member:=parent_member;
  depth:=depth+1;
  if depth>=100 then raise exception 'Binary placement depth limit reached'; end if;
 end loop;
end;
$function$
;
CREATE OR REPLACE FUNCTION private.refresh_binary_qualification(p_member uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare s jsonb;
begin
 if p_member is null then return false; end if;
 if exists(select 1 from private.binary_qualifications where member_id=p_member) then return true; end if;
 if not exists(
  select 1 from public.package_activations
  where member_id=p_member and status='approved'
 ) then return false; end if;
 s:=private.binary_qualification_status(p_member);
 if coalesce((s->>'left_direct_count')::integer,0)>=1
    and coalesce((s->>'right_direct_count')::integer,0)>=1
    and coalesce((s->>'left_dp')::numeric,0)>=20
    and coalesce((s->>'right_dp')::numeric,0)>=20 then
  insert into private.binary_qualifications(
   member_id,left_directs_at_qualification,right_directs_at_qualification,
   left_dp_at_qualification,right_dp_at_qualification
  ) values(
   p_member,(s->>'left_direct_count')::integer,(s->>'right_direct_count')::integer,
   (s->>'left_dp')::numeric,(s->>'right_dp')::numeric
  ) on conflict(member_id) do nothing;
 end if;
 return exists(select 1 from private.binary_qualifications where member_id=p_member);
end;
$function$
;
CREATE OR REPLACE FUNCTION private.binary_live_shares(p_end timestamp with time zone DEFAULT clock_timestamp())
 RETURNS TABLE(member_id uuid, package_code text, package_version integer, binary_entitlement numeric, left_available numeric, right_available numeric, completed_shares numeric, consumed_each numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with cfg as (
 select private.current_mlm_rules() j,private.financial_reset_at() cutoff
), ap as (
 select distinct on(a.member_id) a.member_id,a.package_code,a.package_version,
  coalesce((cfg.j->'plans'->a.package_code->>'binary_entitlement')::numeric,a.binary_entitlement) entitlement
 from public.package_activations a
 cross join cfg
 join public.member_profiles mp on mp.user_id=a.member_id and mp.status='active' and private.maintenance_active(a.member_id,p_end)
 join private.binary_qualifications q on q.member_id=a.member_id
 where a.status='approved' and coalesce(a.activated_at,a.requested_at)<=p_end
 order by a.member_id,a.base_value desc,a.activated_at desc,a.requested_at desc
), v as (
 select pl.member_id,
  coalesce(sum(pl.amount) filter(where pl.side='LEFT'),0) l,
  coalesce(sum(pl.amount) filter(where pl.side='RIGHT'),0) r
 from public.point_ledger pl cross join cfg
 where pl.point_type='BP' and pl.created_at>cfg.cutoff and pl.created_at<=p_end
 group by pl.member_id
), c as (
 select r.member_id,coalesce(sum(r.consumed_left),0) l,coalesce(sum(r.consumed_right),0) r
 from public.binary_member_results r
 join public.binary_cycles bc on bc.id=r.cycle_id cross join cfg
 where bc.status in('posted','unallocated') and bc.created_at>cfg.cutoff
 group by r.member_id
), x as (
 select ap.*,greatest(coalesce(v.l,0)-coalesce(c.l,0),0) la,
  greatest(coalesce(v.r,0)-coalesce(c.r,0),0) ra,
  coalesce((cfg.j->>'binary_share_points_each_side')::numeric,50) sp
 from ap cross join cfg left join v on v.member_id=ap.member_id left join c on c.member_id=ap.member_id
)
select member_id,package_code,package_version,entitlement,la,ra,
 trunc(trunc(least(la,ra)/sp,1)*entitlement,4),
 trunc(least(la,ra)/sp,1)*sp
from x where sp>0;
$function$
;
