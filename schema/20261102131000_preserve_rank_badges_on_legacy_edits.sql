-- Older deployed clients do not submit badge_url; preserve uploaded badges in that case.

create or replace function public.admin_set_team_manager_rules(p_rules jsonb,p_expected_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare cur jsonb:=private.current_team_manager_rules();v integer;n jsonb;badge text;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 if p_expected_version<>(cur->>'version')::integer then raise exception 'Rules changed. Refresh and try again';end if;
 badge:=case when p_rules?'badge_url' then nullif(trim(p_rules->>'badge_url'),'') else nullif(trim(cur->>'badge_url'),'') end;
 if badge is not null and (length(badge)>2048 or badge !~ '^https://') then raise exception 'Invalid Team Manager badge URL';end if;
 n:=jsonb_build_object('enabled',coalesce((p_rules->>'enabled')::boolean,true),'minimum_package',p_rules->>'minimum_package','required_directs',(p_rules->>'required_directs')::integer,'required_direct_dp',(p_rules->>'required_direct_dp')::numeric,'required_tngp',(p_rules->>'required_tngp')::numeric,'required_qualified_lines',(p_rules->>'required_qualified_lines')::integer,'per_line_tngp',(p_rules->>'per_line_tngp')::numeric,'max_generations',(p_rules->>'max_generations')::integer,'track_rate',(p_rules->>'track_rate')::numeric,'network_rate',(p_rules->>'network_rate')::numeric,'badge_url',badge);
 if private.package_weight(n->>'minimum_package')=0 or least((n->>'required_directs')::numeric,(n->>'required_direct_dp')::numeric,(n->>'required_tngp')::numeric,(n->>'required_qualified_lines')::numeric,(n->>'per_line_tngp')::numeric,(n->>'track_rate')::numeric,(n->>'network_rate')::numeric)<0 or (n->>'max_generations')::integer not between 1 and 10 or (n->>'track_rate')::numeric>1 or (n->>'network_rate')::numeric>1 then raise exception 'Invalid Team Manager rules';end if;
 v:=(cur->>'version')::integer+1;update public.system_config set effective_to=now() where config_key='TEAM_MANAGER_RULES' and effective_to is null;insert into public.system_config(config_key,version,config_value,created_by) values('TEAM_MANAGER_RULES',v,n,auth.uid());return private.current_team_manager_rules();
end$$;

create or replace function public.admin_upsert_leadership_rank(p_rank jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare code text:=lower(regexp_replace(trim(p_rank->>'rank_code'),'[^a-z0-9]+','_','g'));badge text;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;perform private.require_recent_totp();
 badge:=case when p_rank?'badge_url' then nullif(trim(p_rank->>'badge_url'),'') else (select badge_url from public.leadership_rank_definitions where rank_code=code) end;
 if badge is not null and (length(badge)>2048 or badge !~ '^https://') then raise exception 'Invalid rank badge URL';end if;
 insert into public.leadership_rank_definitions(rank_code,display_name,sort_order,left_brp,right_brp,direct_left,direct_right,required_dp,badge_theme,badge_url,active)
 values(code,trim(p_rank->>'display_name'),(p_rank->>'sort_order')::integer,(p_rank->>'left_brp')::numeric,(p_rank->>'right_brp')::numeric,(p_rank->>'direct_left')::integer,(p_rank->>'direct_right')::integer,(p_rank->>'required_dp')::numeric,coalesce(p_rank->>'badge_theme','emerald'),badge,coalesce((p_rank->>'active')::boolean,true))
 on conflict(rank_code) do update set display_name=excluded.display_name,sort_order=excluded.sort_order,left_brp=excluded.left_brp,right_brp=excluded.right_brp,direct_left=excluded.direct_left,direct_right=excluded.direct_right,required_dp=excluded.required_dp,badge_theme=excluded.badge_theme,badge_url=excluded.badge_url,active=excluded.active,updated_at=now();
 return (select to_jsonb(r) from public.leadership_rank_definitions r where rank_code=code);
end$$;

revoke all on function public.admin_set_team_manager_rules(jsonb,integer),public.admin_upsert_leadership_rank(jsonb) from public,anon;
grant execute on function public.admin_set_team_manager_rules(jsonb,integer),public.admin_upsert_leadership_rank(jsonb) to authenticated;
