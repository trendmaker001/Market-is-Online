-- All restricted network payouts require both deadlines to be current.
-- Direct referral and placement remain under their original package rules.
create or replace function private.maintenance_active(p_member uuid,p_at timestamptz default now())
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.member_maintenance m where m.member_id=p_member
  and m.monthly_due_at>p_at and m.annual_due_at>p_at)
$$;

do $$declare f text;needle text:='where depth=1 or (eligible and depth<=open_levels)';begin
 f:=pg_get_functiondef('private.mlm_point_candidates(uuid,numeric,numeric,jsonb)'::regprocedure);
 if strpos(f,needle)=0 then raise exception 'Generation candidate function changed';end if;
 f:=replace(f,needle,'where depth=1 or (eligible and private.maintenance_active(id) and depth<=open_levels)');
 execute f;
end$$;

do $$declare f text;needle text:='mp.status=''active''';begin
 f:=pg_get_functiondef('private.binary_live_shares(timestamptz)'::regprocedure);
 if strpos(f,needle)=0 then raise exception 'Binary share function changed';end if;
 f:=replace(f,needle,needle||' and private.maintenance_active(a.member_id,p_end)');
 execute f;
end$$;

-- Only currently maintained Community Shares enter the denominator. An
-- expired member misses that cycle; existing grant expiry is not extended.
do $$declare f text;needle text:='from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle';begin
 f:=pg_get_functiondef('public.admin_distribute_community_share(text)'::regprocedure);
 if strpos(f,needle)=0 then raise exception 'Community distribution function changed';end if;
 f:=replace(f,needle,'from public.community_share_grants where start_cycle<=next_cycle and end_cycle>=next_cycle and private.maintenance_active(member_id)');
 execute f;
end$$;

-- Manager points do not accrue during an expired period. Already accrued
-- points remain auditable and can be distributed once the member is current.
do $$declare f text;needle text:='exists(select 1 from private.team_manager_qualifications where member_id=sponsor)';begin
 f:=pg_get_functiondef('private.manager_point_event()'::regprocedure);
 if strpos(f,needle)=0 then raise exception 'Manager point function changed';end if;
 f:=replace(f,needle,needle||' and private.maintenance_active(sponsor)');
 needle:='exists(select 1 from private.team_manager_qualifications where member_id=ancestor)';
 if strpos(f,needle)=0 then raise exception 'Manager point ancestor rule changed';end if;
 f:=replace(f,needle,needle||' and private.maintenance_active(ancestor)');
 execute f;
end$$;

do $$declare f text;needle text:='where b.manager_track_points>0 or b.manager_network_generation_points>0';begin
 f:=pg_get_functiondef('public.admin_distribute_manager_bonus(text)'::regprocedure);
 if strpos(f,needle)=0 then raise exception 'Manager distribution function changed';end if;
 f:=replace(f,needle,'where (b.manager_track_points>0 or b.manager_network_generation_points>0) and private.maintenance_active(b.member_id)');
 execute f;
end$$;

revoke all on function private.maintenance_active(uuid,timestamptz) from public,anon,authenticated;
