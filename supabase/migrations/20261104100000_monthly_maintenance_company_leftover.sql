-- Report the settled order remainder as company income from the same
-- immutable settlement record that holds the generation payouts total.
alter function private.company_treasury_sources() rename to company_treasury_sources_before_maintenance;

create function private.company_treasury_sources()
returns table(source_type text,source_id uuid,category text,currency text,amount numeric)
language sql stable security definer set search_path='' as $$
 select s.source_type,s.source_id,s.category,s.currency,s.amount
 from private.company_treasury_sources_before_maintenance() s
 where not (
  s.source_type='order' and s.category in ('shopping_conversion_leftover','ecommerce_conversion_leftover')
  and exists(select 1 from public.maintenance_orders m where m.order_id=s.source_id)
 )
 union all
 select 'order',m.order_id,'monthly_maintenance_leftover','MIO',m.leftover_mio
 from public.maintenance_orders m
 where m.processed_at is not null and m.leftover_mio>0;
$$;

create function public.admin_monthly_maintenance_leftover()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return jsonb_build_object(
  'totals',(select jsonb_build_object('orders',count(*),'ppv',coalesce(sum(ppv_earned),0),
   'distributed_mio',coalesce(sum(distributed_mio),0),'leftover_mio',coalesce(sum(leftover_mio),0))
   from public.maintenance_orders where processed_at is not null),
  'recent',coalesce((select jsonb_agg(to_jsonb(r) order by r.processed_at desc,r.order_id desc)
   from (select m.order_id,o.order_code,m.processed_at,m.ppv_earned,m.distributed_mio,m.leftover_mio
    from public.maintenance_orders m join public.orders o on o.id=m.order_id
    where m.processed_at is not null and m.leftover_mio>0
    order by m.processed_at desc,m.order_id desc limit 25) r),'[]'::jsonb));
end$$;

revoke all on function private.company_treasury_sources(),private.company_treasury_sources_before_maintenance()
 from public,anon,authenticated;
revoke all on function public.admin_monthly_maintenance_leftover() from public,anon;
grant execute on function public.admin_monthly_maintenance_leftover() to authenticated;
notify pgrst,'reload schema';
