do $patch$ declare body text;fname text;begin
 foreach fname in array array['support_member_dashboard','support_income_wallets','support_maintenance_status'] loop
  select pg_get_functiondef(p.oid) into body from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname=fname;
  body:=replace(body,'not private.registered_member(member)','not exists(select 1 from public.member_profiles where user_id=member)');
  body:=replace(body,'not private.registered_member(p_member_id)','not exists(select 1 from public.member_profiles where user_id=p_member_id)');execute body;
 end loop;
 select pg_get_functiondef('private.admin_member_dashboard(uuid)'::regprocedure) into body;
 body:=replace(body,'''earned'',earned+maintenance_earned','''earned'',earned+maintenance_earned+coalesce((select sum(amount) from public.member_opening_earnings where member_id=p_member_id),0)');execute body;
end $patch$;
create or replace function private.apply_member_opening_to_tree(p_tree jsonb) returns jsonb language sql stable security definer set search_path='' as $$
 with adjusted as (
  select n.ordinality,n.node,private.current_package_code(nullif(n.node->>'id','')::uuid) code,
   greatest(0,coalesce((n.node->>'left_bp')::numeric,0)-coalesce(b.consumed_left,0)) l,
   greatest(0,coalesce((n.node->>'right_bp')::numeric,0)-coalesce(b.consumed_right,0)) r
  from jsonb_array_elements(coalesce(p_tree->'nodes','[]')) with ordinality n(node,ordinality)
  left join private.member_admin_baselines b on b.member_id=nullif(n.node->>'id','')::uuid
 ), nodes as (select ordinality,node||case when node ? 'left_bp' then jsonb_build_object('left_bp',l,'right_bp',r,'available_binary_shares',trunc(trunc(least(l,r)/greatest(0.0001,coalesce((private.current_mlm_rules()->>'binary_share_points_each_side')::numeric,50)),1)*coalesce((private.current_mlm_rules()->'plans'->code->>'binary_entitlement')::numeric,0),4)) else '{}'::jsonb end value from adjusted)
 select jsonb_set(p_tree,'{nodes}',coalesce((select jsonb_agg(value order by ordinality) from nodes),'[]'))
$$;
revoke all on function private.apply_member_opening_to_tree(jsonb) from public,anon,authenticated;
do $patch$ declare body text;begin
 select pg_get_functiondef('public.my_network(text,text,integer)'::regprocedure) into body;
 if strpos(body,'return jsonb_set(result,''{nodes}'',nodes)')=0 then raise exception 'Unexpected network wrapper; review before applying';end if;
 body:=replace(body,'return jsonb_set(result,''{nodes}'',nodes)','return private.apply_member_opening_to_tree(jsonb_set(result,''{nodes}'',nodes))');execute body;
end $patch$;
