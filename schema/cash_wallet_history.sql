-- Read-only Cash Wallet history. No balance writes or new ledger entries.
create or replace function public.my_cash_wallet_history(p_filter text default 'all',p_page integer default 1,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare uid uuid:=auth.uid(); result jsonb;
begin
 if uid is null then raise exception 'Sign in required'; end if;
 if p_filter is null or p_filter not in ('all','received','sent','package','other') then raise exception 'Invalid activity filter'; end if;
 if p_page is null or p_page<1 or p_page>100000 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Invalid page'; end if;
 with ledger as (
  select l.*,coalesce(w.balance,0)-coalesce(sum(l.amount) over(order by l.created_at desc,l.id desc rows between unbounded preceding and 1 preceding),0) as balance_after,
   case when l.action='package_activation' then 'package' when l.action='transfer_in' then 'received' when l.action='transfer_out' then 'sent' else 'other' end as activity_type
  from public.mio_ledger l left join public.mio_wallet_accounts w on w.member_id=l.member_id where l.member_id=uid
 ), filtered as (select * from ledger where p_filter='all' or activity_type=p_filter), totals as (
  select count(*) as total,coalesce(sum(amount) filter(where amount>0),0) as credited,coalesce(-sum(amount) filter(where amount<0),0) as debited from filtered
 ), selected as (
  select l.* from filtered l order by l.created_at desc,l.id desc limit p_limit offset (p_page-1)*p_limit
 ), details as (
  select l.id,l.created_at,l.amount::text,l.action,l.activity_type,l.reason,l.transfer_id,l.activation_id,
   l.balance_after::text,(l.balance_after-l.amount)::text as balance_before,
   own.full_name as member_name,own.member_code,
   coalesce(cp.full_name,peer.full_name) as counterparty_name,coalesce(cp.member_code,peer.member_code) as counterparty_code,
   a.package_code,v.display_name as package_name,prev.package_code as previous_package_code,
   pv.display_name as previous_package_name,
   case when l.amount<0 then own.full_name else coalesce(cp.full_name,peer.full_name) end as sender_name,
   case when l.amount<0 then own.member_code else coalesce(cp.member_code,peer.member_code) end as sender_code,
   case when l.amount>0 then own.full_name else coalesce(cp.full_name,peer.full_name) end as receiver_name,
   case when l.amount>0 then own.member_code else coalesce(cp.member_code,peer.member_code) end as receiver_code,
   coalesce(t.source_wallet,'cash') as source_wallet,coalesce(t.destination_wallet,'cash') as destination_wallet,
   'Completed'::text as status
  from selected l join public.member_profiles own on own.user_id=uid
  left join public.member_profiles cp on cp.user_id=l.counterparty_id
  left join private.exchange_transfers t on t.id=l.transfer_id and uid in(t.actor_id,t.recipient_id)
  left join public.member_profiles peer on peer.user_id=case when t.actor_id=uid then t.recipient_id else t.actor_id end
  left join public.package_activations a on a.id=l.activation_id and a.member_id=uid
  left join public.package_versions v on v.package_code=a.package_code and v.version=a.package_version
  left join lateral (select pa.package_code,pa.package_version from public.package_activations pa where pa.member_id=uid and pa.status='approved' and (pa.activated_at,pa.id)<(a.activated_at,a.id) order by pa.activated_at desc,pa.id desc limit 1) prev on true
  left join public.package_versions pv on pv.package_code=prev.package_code and pv.version=prev.package_version
 ) select jsonb_build_object('balance',coalesce((select balance from public.mio_wallet_accounts where member_id=uid),0)::text,'total',totals.total,'page',p_page,'limit',p_limit,'credited',totals.credited::text,'debited',totals.debited::text,'rows',coalesce((select jsonb_agg(to_jsonb(d) order by d.created_at desc,d.id desc) from details d),'[]'::jsonb)) into result from totals;
 return result;
end $$;
revoke all on function public.my_cash_wallet_history(text,integer,integer) from public,anon;
grant execute on function public.my_cash_wallet_history(text,integer,integer) to authenticated;
