-- Uploaded rank badges and an auditable Team Manager financial snapshot.

alter table public.leadership_rank_definitions
  add column if not exists badge_url text;

alter table public.leadership_rank_definitions
  drop constraint if exists leadership_rank_definitions_badge_url_check;
alter table public.leadership_rank_definitions
  add constraint leadership_rank_definitions_badge_url_check
  check (badge_url is null or (length(badge_url) <= 2048 and badge_url ~ '^https://'));

do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
    values('rank-badges','rank-badges',true,2097152,array['image/jpeg','image/png','image/webp'])
    on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
    execute 'drop policy if exists rank_badges_public_read on storage.objects';
    execute 'create policy rank_badges_public_read on storage.objects for select using(bucket_id=''rank-badges'')';
    execute 'drop policy if exists rank_badges_admin_insert on storage.objects';
    execute 'create policy rank_badges_admin_insert on storage.objects for insert to authenticated with check(bucket_id=''rank-badges'' and private.has_role(''admin''))';
    execute 'drop policy if exists rank_badges_admin_update on storage.objects';
    execute 'create policy rank_badges_admin_update on storage.objects for update to authenticated using(bucket_id=''rank-badges'' and private.has_role(''admin'')) with check(bucket_id=''rank-badges'' and private.has_role(''admin''))';
  end if;
end$$;

create or replace function public.my_manager_status() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid();m jsonb;b private.team_manager_balances%rowtype;q private.team_manager_qualifications%rowtype;r record;
begin
 if uid is null then raise exception 'Sign in required';end if;
 m:=private.team_manager_metrics(uid);select * into b from private.team_manager_balances where member_id=uid;select * into q from private.team_manager_qualifications where member_id=uid;select d.* into r from public.leadership_rank_definitions d join public.member_profiles p on p.achieved_rank=d.rank_code where p.user_id=uid;
 return m||jsonb_build_object(
  'qualified',q.member_id is not null,'qualified_at',q.qualified_at,
  'team_manager_badge_url',m->'rules'->>'badge_url',
  'manager_track_points',coalesce(b.manager_track_points,0),'manager_network_generation_points',coalesce(b.manager_network_generation_points,0),
  'leadership_rank',case when r.rank_code is null then null else jsonb_build_object('code',r.rank_code,'name',r.display_name,'theme',r.badge_theme,'badge_url',r.badge_url) end,
  'rank_history',coalesce((select jsonb_agg(jsonb_build_object('code',d.rank_code,'name',d.display_name,'theme',d.badge_theme,'badge_url',d.badge_url,'achieved_at',h.achieved_at) order by d.sort_order) from public.member_rank_history h join public.leadership_rank_definitions d on d.rank_code=h.rank_code where h.member_id=uid),'[]'::jsonb)
 );
end$$;

create or replace function public.my_network(p_kind text default 'generation',p_root_code text default null,p_depth integer default 4) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;nodes jsonb;manager_badge text;
begin
 result:=public.my_network_before_manager_badges(p_kind,p_root_code,p_depth);
 manager_badge:=private.current_team_manager_rules()->>'badge_url';
 select coalesce(jsonb_agg(n.node||jsonb_build_object('team_manager',q.member_id is not null,'manager_badge_url',manager_badge,'rank_name',d.display_name,'rank_theme',d.badge_theme,'rank_badge_url',d.badge_url) order by n.ordinality),'[]'::jsonb) into nodes
 from jsonb_array_elements(coalesce(result->'nodes','[]'::jsonb)) with ordinality n(node,ordinality)
 left join private.team_manager_qualifications q on q.member_id=nullif(n.node->>'id','')::uuid
 left join public.leadership_rank_definitions d on d.rank_code=n.node->>'rank';
 return jsonb_set(result,'{nodes}',nodes);
end$$;

create or replace function public.admin_manager_program() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare rules jsonb:=private.current_team_manager_rules();pending_mio numeric;distributed_mio numeric;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select coalesce(sum(b.manager_track_points*(rules->>'track_rate')::numeric+b.manager_network_generation_points*(rules->>'network_rate')::numeric),0) into pending_mio from private.team_manager_balances b;
 select coalesce(sum(amount),0) into distributed_mio from public.manager_bonus_distributions;
 return jsonb_build_object(
  'rules',rules,
  'ranks',coalesce((select jsonb_agg(to_jsonb(r) order by sort_order) from public.leadership_rank_definitions r),'[]'::jsonb),
  'pending',coalesce((select jsonb_agg(jsonb_build_object('member_id',b.member_id,'member_code',m.member_code,'full_name',m.full_name,'mtp',b.manager_track_points,'mngp',b.manager_network_generation_points) order by m.member_code) from private.team_manager_balances b join public.member_profiles m on m.user_id=b.member_id where b.manager_track_points>0 or b.manager_network_generation_points>0),'[]'::jsonb),
  'summary',jsonb_build_object(
    'total_generated_mio',distributed_mio+pending_mio,
    'wallet_distributed_mio',distributed_mio,
    'management_pending_mio',pending_mio,
    'pending_manager_count',(select count(*) from private.team_manager_balances where manager_track_points>0 or manager_network_generation_points>0),
    'distributed_manager_count',(select count(distinct member_id) from public.manager_bonus_distributions),
    'total_mtp',(select coalesce(sum(manager_track_points),0) from private.team_manager_balances),
    'total_mngp',(select coalesce(sum(manager_network_generation_points),0) from private.team_manager_balances),
    'last_distributed_at',(select max(created_at) from public.manager_bonus_cycles)
  )
 );
end$$;

create or replace function public.admin_set_team_manager_rules(p_rules jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cur jsonb:=private.current_team_manager_rules();v integer;n jsonb;badge text:=nullif(trim(p_rules->>'badge_url'),'');
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if p_expected_version<>(cur->>'version')::integer then raise exception 'Rules changed. Refresh and try again';end if;
 if badge is not null and (length(badge)>2048 or badge !~ '^https://') then raise exception 'Invalid Team Manager badge URL';end if;
 n:=jsonb_build_object('enabled',coalesce((p_rules->>'enabled')::boolean,true),'minimum_package',p_rules->>'minimum_package','required_directs',(p_rules->>'required_directs')::integer,'required_direct_dp',(p_rules->>'required_direct_dp')::numeric,'required_tngp',(p_rules->>'required_tngp')::numeric,'required_qualified_lines',(p_rules->>'required_qualified_lines')::integer,'per_line_tngp',(p_rules->>'per_line_tngp')::numeric,'max_generations',(p_rules->>'max_generations')::integer,'track_rate',(p_rules->>'track_rate')::numeric,'network_rate',(p_rules->>'network_rate')::numeric,'badge_url',badge);
 if private.package_weight(n->>'minimum_package')=0 or least((n->>'required_directs')::numeric,(n->>'required_direct_dp')::numeric,(n->>'required_tngp')::numeric,(n->>'required_qualified_lines')::numeric,(n->>'per_line_tngp')::numeric,(n->>'track_rate')::numeric,(n->>'network_rate')::numeric)<0 or (n->>'max_generations')::integer not between 1 and 10 or (n->>'track_rate')::numeric>1 or (n->>'network_rate')::numeric>1 then raise exception 'Invalid Team Manager rules';end if;
 v:=(cur->>'version')::integer+1;update public.system_config set effective_to=now() where config_key='TEAM_MANAGER_RULES' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('TEAM_MANAGER_RULES',v,n,auth.uid());return private.current_team_manager_rules();
end$$;

create or replace function public.admin_upsert_leadership_rank(p_rank jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare code text:=lower(regexp_replace(trim(p_rank->>'rank_code'),'[^a-z0-9]+','_','g'));badge text:=nullif(trim(p_rank->>'badge_url'),'');
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if badge is not null and (length(badge)>2048 or badge !~ '^https://') then raise exception 'Invalid rank badge URL';end if;
 insert into public.leadership_rank_definitions(rank_code,display_name,sort_order,left_brp,right_brp,direct_left,direct_right,required_dp,badge_theme,badge_url,active)
 values(code,trim(p_rank->>'display_name'),(p_rank->>'sort_order')::integer,(p_rank->>'left_brp')::numeric,(p_rank->>'right_brp')::numeric,(p_rank->>'direct_left')::integer,(p_rank->>'direct_right')::integer,(p_rank->>'required_dp')::numeric,coalesce(p_rank->>'badge_theme','emerald'),badge,coalesce((p_rank->>'active')::boolean,true))
 on conflict(rank_code) do update set display_name=excluded.display_name,sort_order=excluded.sort_order,left_brp=excluded.left_brp,right_brp=excluded.right_brp,direct_left=excluded.direct_left,direct_right=excluded.direct_right,required_dp=excluded.required_dp,badge_theme=excluded.badge_theme,badge_url=excluded.badge_url,active=excluded.active,updated_at=now();
 return (select to_jsonb(r) from public.leadership_rank_definitions r where rank_code=code);
end$$;

revoke all on function public.my_manager_status(),public.my_network(text,text,integer),public.admin_manager_program(),public.admin_set_team_manager_rules(jsonb,integer),public.admin_upsert_leadership_rank(jsonb) from public,anon;
grant execute on function public.my_manager_status(),public.my_network(text,text,integer) to authenticated;
grant execute on function public.admin_manager_program(),public.admin_set_team_manager_rules(jsonb,integer),public.admin_upsert_leadership_rank(jsonb) to authenticated;
