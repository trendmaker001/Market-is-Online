-- Approved and applied 2026-11-26: preserve qualification and financial rules.
-- Preserve existing qualification and bonus rules; remove repeated read calculations.
CREATE OR REPLACE FUNCTION private.network_generation_line_points(p_member uuid)
 RETURNS TABLE(root_id uuid, gp numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with recursive settings as materialized (select private.network_generation_limit() max_depth, private.financial_reset_at() reset_at), d(id,root_id,depth,path) as (
  select m.user_id,m.user_id,1,array[p_member,m.user_id] from public.member_profiles m where m.sponsor_id=p_member
  union all select m.user_id,d.root_id,d.depth+1,d.path||m.user_id
  from d join public.member_profiles m on m.sponsor_id=d.id
  where d.depth<(select max_depth from settings) and not m.user_id=any(d.path)
 )
 select d.root_id,coalesce(sum(a.gp),0)::numeric
 from d left join public.package_activations a on a.member_id=d.id and a.status='approved'
  and d.depth>=2 and coalesce(a.activated_at,a.requested_at)>(select reset_at from settings)
 group by d.root_id;
$function$;

CREATE OR REPLACE FUNCTION private.team_manager_metrics(p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r jsonb:=private.current_team_manager_rules();
  directs integer:=0;
  dp numeric:=0;
  tngp numeric:=0;
  lines integer:=0;
  pkg text;
  earnings numeric:=private.member_total_earnings(p_member);
  earnings_progress numeric;
  qualified boolean;
  progress numeric;
  package_progress numeric:=0;
  directs_progress numeric:=0;
  dp_progress numeric:=0;
  tngp_progress numeric:=0;
  lines_progress numeric:=0;
  breakdown jsonb:='[]'::jsonb;
begin
  pkg:=private.current_package_code(p_member);
  select active_directs,total_dp into directs,dp from private.direct_dp_summary(p_member);

  with line_gp as materialized (select * from private.network_generation_line_points(p_member)),
  live_lines as (
    select m.user_id,m.member_code,m.full_name,m.created_at,coalesce(g.gp,0) gp,
      row_number() over(order by m.created_at,m.user_id) position
    from public.member_profiles m left join line_gp g on g.root_id=m.user_id
    where m.sponsor_id=p_member
  )
  select
    (select coalesce(sum(gp),0) from line_gp)
      +coalesce((select tngp_offset from private.member_admin_baselines where member_id=p_member),0),
    (select count(*) filter(where gp>=(r->>'per_line_tngp')::numeric) from line_gp),
    (select coalesce(jsonb_agg(jsonb_build_object(
      'position',position,'member_id',user_id,'member_code',member_code,'full_name',full_name,
      'tngp',gp,'required_tngp',(r->>'per_line_tngp')::numeric,
      'progress_percent',least(100,round(100*gp/greatest((r->>'per_line_tngp')::numeric,1),2)),
      'qualified',gp>=(r->>'per_line_tngp')::numeric
    ) order by position),'[]'::jsonb) from live_lines)
  into tngp,lines,breakdown;

  package_progress:=least(100,round(100*private.package_weight(pkg)::numeric/greatest(private.package_weight(r->>'minimum_package'),1),2));
  directs_progress:=case when (r->>'required_directs')::numeric=0 then 100 else least(100,round(100*coalesce(directs,0)::numeric/greatest((r->>'required_directs')::numeric,1),2)) end;
  dp_progress:=case when (r->>'required_direct_dp')::numeric=0 then 100 else least(100,round(100*coalesce(dp,0)/greatest((r->>'required_direct_dp')::numeric,1),2)) end;
  tngp_progress:=case when (r->>'required_tngp')::numeric=0 then 100 else least(100,round(100*coalesce(tngp,0)/greatest((r->>'required_tngp')::numeric,1),2)) end;
  lines_progress:=case when (r->>'required_qualified_lines')::numeric=0 then 100 else least(100,round(100*coalesce(lines,0)::numeric/greatest((r->>'required_qualified_lines')::numeric,1),2)) end;
  earnings_progress:=case when (r->>'required_total_earnings')::numeric=0 then 100 else greatest(0,least(100,round(100*earnings/(r->>'required_total_earnings')::numeric,2))) end;
  progress:=round((package_progress+directs_progress+dp_progress+tngp_progress+lines_progress+earnings_progress)/6,2);
  qualified:=coalesce((r->>'enabled')::boolean,true)
    and private.package_weight(pkg)>=private.package_weight(r->>'minimum_package')
    and directs>=(r->>'required_directs')::integer
    and dp>=(r->>'required_direct_dp')::numeric
    and tngp>=(r->>'required_tngp')::numeric
    and lines>=(r->>'required_qualified_lines')::integer
    and earnings>=(r->>'required_total_earnings')::numeric;

  return jsonb_build_object(
    'total_earnings',earnings,'qualified_now',qualified,'package',pkg,'directs',coalesce(directs,0),
    'direct_dp',coalesce(dp,0),'tngp',coalesce(tngp,0),'qualified_lines',coalesce(lines,0),
    'progress_percent',coalesce(progress,0),'rules',r,'line_breakdown',breakdown,
    'criteria_progress',jsonb_build_object('package',package_progress,'directs',directs_progress,
      'direct_dp',dp_progress,'tngp',tngp_progress,'qualified_lines',lines_progress,'total_earnings',earnings_progress)
  );
end;
$function$;

