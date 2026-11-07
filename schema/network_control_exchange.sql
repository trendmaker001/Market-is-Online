-- Company is an operational account, not an enrolled member. Wallet reporting retains all accounts.
create or replace function public.admin_network_control_summary()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare totals jsonb; tiers jsonb; subscription numeric; proceed_fee numeric; cutoff timestamptz:=private.financial_reset_at();
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 with members as materialized(select * from private.network_control_members())
 select jsonb_build_object('members',count(*) filter(where not exists(select 1 from private.network_foundation n where n.singleton and n.company_id=members.member_id)),'proceed',coalesce(sum(proceed),0),'cash',coalesce(sum(cash),0),
 'shopping',coalesce(sum(shopping),0),'promotion',coalesce(sum(promotion),0)),
 (select coalesce(jsonb_object_agg(package_code,n),'{}') from (select package_code,count(*) n from members where not exists(select 1 from private.network_foundation n where n.singleton and n.company_id=members.member_id) group by package_code)t)
 into totals,tiers from members;
 select coalesce(sum(company_fee),0) into subscription from public.package_activations
 where status='approved' and source<>'SHOPPING_PPV' and activated_at>cutoff;
 select coalesce(sum(fee_amount),0) into proceed_fee from public.proceed_wallet_conversions where created_at>cutoff;
 return totals||jsonb_build_object('exchange',(select coalesce(sum(balance),0) from private.exchange_wallet_accounts),'packages',tiers,'mio_price',private.current_mio_reference_price(),
 'fees',jsonb_build_object('subscription',subscription,'proceed',proceed_fee,'withdrawal',null,'orders',null,'combined',subscription+proceed_fee),
 'fees_since',cutoff,'as_of',now());
end $$;


-- All existing exchange balances remain liabilities, including company accounts
-- and any account whose package later changes. Never total transfer turnover.
create or replace function public.admin_network_control_exchange(p_offset integer default 0,p_limit integer default 25,p_search text default '')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 or length(coalesce(p_search,''))>100 then raise exception 'Invalid page';end if;
 with wallets as materialized (
 select e.member_id,p.member_code,p.full_name,coalesce(private.current_package_code(e.member_id),'free') package_code,e.balance exchange
 from private.exchange_wallet_accounts e join public.member_profiles p on p.user_id=e.member_id
 where coalesce(p_search,'')='' or strpos(lower(coalesce(p.full_name,'')||' '||coalesce(p.member_code,'')),lower(p_search))>0
 ), page as (select * from wallets order by member_code,member_id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from wallets),'rows',coalesce(jsonb_agg(to_jsonb(page) order by member_code,member_id),'[]')) into result from page;
 return result;
end $$;
revoke all on function public.admin_network_control_exchange(integer,integer,text) from public,anon;
grant execute on function public.admin_network_control_exchange(integer,integer,text) to authenticated;
