-- Shared admin settings for qualification and its display; earned snapshots remain permanent.
create or replace function private.current_binary_qualification_rules() returns jsonb
language sql stable security definer set search_path='' as $$
 select coalesce((select config_value || jsonb_build_object('version',version)
 from public.system_config where config_key='BINARY_QUALIFICATION' and effective_to is null
 order by version desc limit 1),jsonb_build_object('version',0,'required_left_directs',1,
 'required_right_directs',1,'required_left_dp',20,'required_right_dp',20));
$$;
revoke all on function private.current_binary_qualification_rules() from public,anon,authenticated;

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
  'required_left_directs',private.current_binary_qualification_rules()->'required_left_directs',
  'required_right_directs',private.current_binary_qualification_rules()->'required_right_directs',
  'required_left_dp',private.current_binary_qualification_rules()->'required_left_dp',
  'required_right_dp',private.current_binary_qualification_rules()->'required_right_dp',
  'rule_version',private.current_binary_qualification_rules()->'version',
  'permanent_once_qualified',true
 );
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
 if coalesce((s->>'left_direct_count')::integer,0)>=(s->>'required_left_directs')::integer
    and coalesce((s->>'right_direct_count')::integer,0)>=(s->>'required_right_directs')::integer
    and coalesce((s->>'left_dp')::numeric,0)>=(s->>'required_left_dp')::numeric
    and coalesce((s->>'right_dp')::numeric,0)>=(s->>'required_right_dp')::numeric then
  insert into private.binary_qualifications(
   member_id,left_directs_at_qualification,right_directs_at_qualification,
   left_dp_at_qualification,right_dp_at_qualification,rule_version
  ) values(
   p_member,(s->>'left_direct_count')::integer,(s->>'right_direct_count')::integer,
   (s->>'left_dp')::numeric,(s->>'right_dp')::numeric,'binary-config-v'||(s->>'rule_version')
  ) on conflict(member_id) do nothing;
 end if;
 return exists(select 1 from private.binary_qualifications where member_id=p_member);
end;
$function$
;
create or replace function private.admin_binary_qualification_summary() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not coalesce(private.has_role('admin'::public.app_role),false) then raise exception 'Admin access required' using errcode='42501';end if;
 return jsonb_build_object('active_members',(select count(*) from private.binary_qualifications q
 join public.member_profiles m on m.user_id=q.member_id where m.status='active'),
 'rules',private.current_binary_qualification_rules(),'checked_at',now());
end $$;
create or replace function public.admin_binary_qualification_summary() returns jsonb
language sql stable security invoker set search_path='' as $$select private.admin_binary_qualification_summary()$$;

create or replace function private.admin_save_binary_qualification_rules(p_rules jsonb,p_expected_version integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare previous jsonb; rules jsonb:='{}'; k text; value numeric; member uuid; version integer;
begin
 if auth.uid() is null or not coalesce(private.has_role('admin'::public.app_role),false) then raise exception 'Admin access required' using errcode='42501';end if;
 perform private.require_recent_totp();
 foreach k in array array['required_left_directs','required_right_directs','required_left_dp','required_right_dp'] loop
  if jsonb_typeof(p_rules->k) is distinct from 'number' then raise exception 'Enter all four qualification requirements';end if;
  value:=(p_rules->>k)::numeric;
  if value<1 or value>1000000 or (k like '%directs' and (value<>trunc(value) or value>1000)) or value<>trunc(value,4) then
   raise exception 'Invalid qualification requirement: %',k;
  end if;
  rules:=rules||jsonb_build_object(k,value);
 end loop;
 perform pg_advisory_xact_lock(hashtextextended('binary-qualification-rules',0));
 previous:=private.current_binary_qualification_rules();version:=(previous->>'version')::integer;
 if p_expected_version is distinct from version then raise exception 'Rules changed. Reload before saving.';end if;
 update public.system_config set effective_to=clock_timestamp() where config_key='BINARY_QUALIFICATION' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,created_by) values('BINARY_QUALIFICATION',version+1,rules,auth.uid());
 -- Recheck unqualified active members when the admin changes thresholds. Existing awards and payouts are untouched.
 for member in select m.user_id from public.member_profiles m where m.status='active'
 and not exists(select 1 from private.binary_qualifications q where q.member_id=m.user_id)
 and exists(select 1 from public.package_activations a where a.member_id=m.user_id and a.status='approved') order by m.user_id loop
  perform private.refresh_binary_qualification(member);
 end loop;
 insert into public.audit_logs(actor_id,action,entity_type,before_data,after_data)
 values(auth.uid(),'BINARY_QUALIFICATION_RULES_SAVED','binary_qualification',previous,rules||jsonb_build_object('version',version+1));
 return private.admin_binary_qualification_summary();
end $$;
create or replace function public.admin_save_binary_qualification_rules(p_rules jsonb,p_expected_version integer) returns jsonb
language sql security invoker set search_path='' as $$select private.admin_save_binary_qualification_rules(p_rules,p_expected_version)$$;
revoke all on function private.admin_binary_qualification_summary(),public.admin_binary_qualification_summary(),
 private.admin_save_binary_qualification_rules(jsonb,integer),public.admin_save_binary_qualification_rules(jsonb,integer) from public,anon,authenticated;
grant execute on function private.admin_binary_qualification_summary(),public.admin_binary_qualification_summary(),
 private.admin_save_binary_qualification_rules(jsonb,integer),public.admin_save_binary_qualification_rules(jsonb,integer) to authenticated;

-- The existing tree response must show the same requirements as the engine and admin card.
do $patch$
declare definition text; updated text;
begin
 definition:=pg_get_functiondef('public.my_network_before_manager_badges(text,text,integer)'::regprocedure);
 updated:=replace(definition,'''binary_required_left_directs'',1,''binary_required_right_directs'',1',
 '''binary_required_left_directs'',q.status->''required_left_directs'',''binary_required_right_directs'',q.status->''required_right_directs''');
 updated:=replace(updated,'''binary_required_left_dp'',20,''binary_required_right_dp'',20',
 '''binary_required_left_dp'',q.status->''required_left_dp'',''binary_required_right_dp'',q.status->''required_right_dp''');
 if updated=definition then raise exception 'Binary tree qualification fields changed; review migration';end if;
 execute updated;
end $patch$;
notify pgrst,'reload schema';
