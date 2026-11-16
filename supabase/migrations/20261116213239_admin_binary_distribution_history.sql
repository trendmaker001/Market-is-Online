-- Read-only statements from settled cycle snapshots, never live share balances.
create or replace function private.admin_binary_distribution_history(p_limit integer, p_offset integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  page_size integer := greatest(1, least(coalesce(p_limit,10),20));
  page_offset integer := greatest(0,coalesce(p_offset,0));
  result jsonb;
begin
  if auth.uid() is null or not coalesce(private.has_role('admin'::public.app_role),false) then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  with settled as (
    select c.* from public.binary_cycles c
    where c.status in ('posted','unallocated')
      and c.ends_at >= private.financial_reset_at()
  ), page as (
    select * from settled order by ends_at desc,id desc limit page_size offset page_offset
  ), statements as (
    select c.id,c.ends_at,jsonb_build_object(
      'id',c.id,'cycle_code',c.cycle_code,'distributed_at',c.ends_at,'status',c.status,
      'share_price',c.gross_share_value,'pool_amount',c.pool_amount,
      'total_shares',coalesce(r.shares,0),'total_paid',coalesce(r.paid,0),
      'recipient_count',coalesce(r.recipients,0),'members',coalesce(r.members,'[]'::jsonb)
    ) as statement
    from page c left join lateral (
      select sum(b.completed_shares) as shares,sum(b.member_amount) as paid,count(*) as recipients,
        jsonb_agg(jsonb_build_object(
          'member_id',b.member_id,'name',coalesce(nullif(p.full_name,''),'Member'),
          'mio_id',p.member_code,'shares',b.completed_shares,
          'share_price',case when jsonb_typeof(b.qualification_snapshot->'share_price')='number'
            then (b.qualification_snapshot->>'share_price')::numeric else c.gross_share_value end,
          'paid',b.member_amount,'bp_matched',least(b.consumed_left,b.consumed_right)
        ) order by b.member_amount desc,b.member_id) as members
      from public.binary_member_results b
      left join public.member_profiles p on p.user_id=b.member_id
      where b.cycle_id=c.id and b.member_amount>0
    ) r on true
  )
  select jsonb_build_object('total_cycles',(select count(*) from settled),
    'limit',page_size,'offset',page_offset,
    'cycles',coalesce((select jsonb_agg(statement order by ends_at desc,id desc) from statements),'[]'::jsonb))
  into result;
  return result;
end;
$$;

create or replace function public.admin_binary_distribution_history(p_limit integer default 10,p_offset integer default 0)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select private.admin_binary_distribution_history(p_limit,p_offset);
$$;
revoke all on function private.admin_binary_distribution_history(integer,integer) from public,anon;
revoke all on function public.admin_binary_distribution_history(integer,integer) from public,anon;
grant execute on function private.admin_binary_distribution_history(integer,integer) to authenticated;
grant execute on function public.admin_binary_distribution_history(integer,integer) to authenticated;
comment on function public.admin_binary_distribution_history(integer,integer) is
  'Admin-only paginated historical binary share distributions with recipient snapshot quantities, rates and credited amounts.';
