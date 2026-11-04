-- Read-only personal earning history. Every existing ledger row appears once, classified
-- from its saved order and payment allocation; maintenance payouts remain their own rows.
create or replace function public.my_shopping_earning_history()
returns table (
 id uuid, beneficiary_id uuid, order_code text, product_name_snapshot text,
 reward_kind text, rate numeric, base_points numeric, amount numeric,
 status text, created_at timestamptz, source_name text, source_code text,
 shopping_channel text, record_type text, generation integer
)
language plpgsql stable security definer set search_path = '' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 return query
 select e.id, e.beneficiary_id, o.order_code, i.product_name_snapshot,
        e.reward_kind, e.rate, e.base_points, e.amount, e.status, e.created_at,
        buyer.full_name, buyer.member_code,
        case when m.order_id is not null then 'maintenance'
             when coalesce(a.checkout_mode,o.checkout_mode) = 'SHOPPING_POINTS' then 'shopping_points'
             else 'normal' end::text, 'marketplace'::text, null::integer
 from public.ecommerce_rewards e
 join public.orders o on o.id=e.order_id
 join public.order_items i on i.id=e.order_item_id
 left join public.order_payment_allocations a on a.order_id=o.id
 left join public.maintenance_orders m on m.order_id=o.id
 left join public.member_profiles buyer on buyer.user_id=o.buyer_id
 where e.beneficiary_id=auth.uid()
 union all
 select p.id, p.beneficiary_id, coalesce(o.order_code,'Annual renewal')::text,
        case when p.maintenance_kind='monthly' then 'Monthly maintenance shopping' else 'Annual maintenance renewal' end::text,
        (p.maintenance_kind||'_maintenance')::text,p.rate,p.base_mio,p.amount_mio,
        'posted'::text,p.created_at,buyer.full_name,buyer.member_code,
        'maintenance'::text,'maintenance_payout'::text,p.generation
 from public.maintenance_generation_payouts p
 left join public.orders o on o.id=p.order_id
 left join public.member_profiles buyer on buyer.user_id=o.buyer_id
 where p.beneficiary_id=auth.uid()
 order by created_at desc,id;
end $$;
revoke all on function public.my_shopping_earning_history() from public,anon,authenticated;
grant execute on function public.my_shopping_earning_history() to authenticated;
notify pgrst,'reload schema';
