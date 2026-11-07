-- Read-only reporting: balances are liabilities, collected fees are income.
create or replace function private.network_control_members()
returns table(member_id uuid, member_code text, full_name text, package_code text, proceed numeric, cash numeric, shopping numeric, promotion numeric)
language sql stable security definer set search_path='' as $$
 select p.user_id,p.member_code,p.full_name,coalesce(private.current_package_code(p.user_id),'free'),
 coalesce(w.proceed_mio,0),coalesce(c.balance,0),coalesce(w.shopping_points,0),coalesce(w.promotion_points,0)
 from public.member_profiles p
 left join public.member_income_wallets w on w.member_id=p.user_id
 left join public.mio_wallet_accounts c on c.member_id=p.user_id
$$;
revoke all on function private.network_control_members() from public,anon,authenticated;

create or replace function public.admin_network_control_summary()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare totals jsonb; tiers jsonb; subscription numeric; proceed_fee numeric; cutoff timestamptz:=private.financial_reset_at();
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 with members as materialized(select * from private.network_control_members())
 select jsonb_build_object('members',count(*),'proceed',coalesce(sum(proceed),0),'cash',coalesce(sum(cash),0),
 'shopping',coalesce(sum(shopping),0),'promotion',coalesce(sum(promotion),0)),
 (select coalesce(jsonb_object_agg(package_code,n),'{}') from (select package_code,count(*) n from members group by package_code)t)
 into totals,tiers from members;
 select coalesce(sum(company_fee),0) into subscription from public.package_activations
 where status='approved' and source<>'SHOPPING_PPV' and activated_at>cutoff;
 select coalesce(sum(fee_amount),0) into proceed_fee from public.proceed_wallet_conversions where created_at>cutoff;
 return totals||jsonb_build_object('packages',tiers,'mio_price',private.current_mio_reference_price(),
 'fees',jsonb_build_object('subscription',subscription,'proceed',proceed_fee,'withdrawal',null,'orders',null,'combined',subscription+proceed_fee),
 'fees_since',cutoff,'as_of',now());
end $$;

create or replace function public.admin_network_control_members(p_offset integer default 0,p_limit integer default 25,p_package text default null,p_search text default '')
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
 if p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 or length(coalesce(p_search,''))>100 then raise exception 'Invalid page';end if;
 with members as materialized(select * from private.network_control_members() m
 where (p_package is null or m.package_code=p_package)
 and (coalesce(p_search,'')='' or strpos(lower(coalesce(m.full_name,'')||' '||coalesce(m.member_code,'')),lower(p_search))>0)),
 page as(select * from members order by member_code,member_id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from members),'rows',coalesce(jsonb_agg(to_jsonb(page) order by member_code,member_id),'[]')) into result from page;
 return result;
end $$;

create or replace function public.admin_network_control_fees(p_kind text,p_offset integer default 0,p_limit integer default 25)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;cutoff timestamptz:=private.financial_reset_at();
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_kind not in('subscription','proceed') or p_kind is null or p_offset is null or p_offset<0 or p_limit is null or p_limit<1 or p_limit>100 then raise exception 'Invalid fee page';end if;
 with fees as materialized(
 select a.id,a.member_id,a.activated_at created_at,a.company_fee amount,a.package_code reference from public.package_activations a
 where p_kind='subscription' and a.status='approved' and a.source<>'SHOPPING_PPV' and a.activated_at>cutoff
 union all select c.id,c.member_id,c.created_at,c.fee_amount,'Proceed conversion' from public.proceed_wallet_conversions c where p_kind='proceed' and c.created_at>cutoff),
 page as(select f.*,p.member_code,p.full_name from fees f left join public.member_profiles p on p.user_id=f.member_id order by f.created_at desc,f.id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from fees),'rows',coalesce(jsonb_agg(to_jsonb(page) order by created_at desc,id),'[]')) into result from page;
 return result;
end $$;

revoke all on function public.admin_network_control_summary() from public,anon;
revoke all on function public.admin_network_control_members(integer,integer,text,text) from public,anon;
revoke all on function public.admin_network_control_fees(text,integer,integer) from public,anon;
grant execute on function public.admin_network_control_summary() to authenticated;
grant execute on function public.admin_network_control_members(integer,integer,text,text) to authenticated;
grant execute on function public.admin_network_control_fees(text,integer,integer) to authenticated;
