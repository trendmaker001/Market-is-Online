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
 return totals||jsonb_build_object('packages',tiers,'mio_price',private.current_mio_reference_price(),
 'fees',jsonb_build_object('subscription',subscription,'proceed',proceed_fee,'withdrawal',null,'orders',null,'combined',subscription+proceed_fee),
 'fees_since',cutoff,'as_of',now());
end $$;

create or replace function public.admin_network_control_registered_members(p_offset integer default 0,p_limit integer default 25,p_package text default null,p_search text default '')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 or length(coalesce(p_search,''))>100 then raise exception 'Invalid page';end if;
 with members as materialized(select * from private.network_control_members() m
 where not exists(select 1 from private.network_foundation n where n.singleton and n.company_id=m.member_id)
 and (p_package is null or m.package_code=p_package)
 and (coalesce(p_search,'')='' or strpos(lower(coalesce(m.full_name,'')||' '||coalesce(m.member_code,'')),lower(p_search))>0)),
 page as(select * from members order by member_code,member_id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from members),'rows',coalesce(jsonb_agg(to_jsonb(page) order by member_code,member_id),'[]')) into result from page;
 return result;
end $$;


revoke all on function public.admin_network_control_registered_members(integer,integer,text,text) from public,anon;
grant execute on function public.admin_network_control_registered_members(integer,integer,text,text) to authenticated;
