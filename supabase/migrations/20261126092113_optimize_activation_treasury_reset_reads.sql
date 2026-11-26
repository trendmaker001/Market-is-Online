CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_maintenance()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
with cutoff as materialized (select private.financial_reset_at() as at), eligible as (
 select 'package'::text typ,id from public.package_activations,cutoff where coalesce(activated_at,requested_at)>cutoff.at
 union all select 'order',id from public.orders,cutoff where greatest(created_at,coalesce(rewards_credited_at,created_at),updated_at)>cutoff.at
 union all select 'cycle',id from public.binary_cycles,cutoff where created_at>cutoff.at
 union all select 'commission',id from public.commission_allocations,cutoff where created_at>cutoff.at
 union all select 'vendor_sale',id from public.vendor_income_ledger,cutoff where created_at>cutoff.at
 union all select 'ecommerce',id from public.ecommerce_rewards,cutoff where created_at>cutoff.at
 union all select 'order_item',id from public.order_items,cutoff where created_at>cutoff.at
)
select s.source_type,s.source_id,s.category,s.currency,s.amount
from private.company_treasury_sources_before_award() s join eligible e on (e.typ,e.id)=(s.source_type,s.source_id)
union all
select 'order_item',i.id,case when i.award_scope_snapshot='product' then 'product_award_leftover' else 'vendor_award_leftover' end,'PKR',i.award_policy_leftover_pkr
from public.order_items i join public.orders o on o.id=i.order_id cross join cutoff
where o.rewards_credited_at is not null and o.payment_status='confirmed' and i.awarded_rate_snapshot is not null and i.created_at>cutoff.at;
$function$;
