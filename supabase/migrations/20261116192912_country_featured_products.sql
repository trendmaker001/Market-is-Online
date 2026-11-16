-- Independent featured lists, one per shopping country. Preserve legacy selections.
set lock_timeout='3s';
set statement_timeout='30s';
create table public.country_featured_products (
 country_code text not null check(private.valid_market_country(country_code)),
 position bigint not null check(position>0),
 product_id uuid not null references public.products(id) on delete cascade,
 selected_by uuid references auth.users(id),
 selected_at timestamptz not null default now(),
 primary key(country_code,position),unique(country_code,product_id)
);
create index country_featured_product_idx on public.country_featured_products(product_id);
create index country_featured_editor_idx on public.country_featured_products(selected_by);
alter table public.country_featured_products enable row level security;
revoke all on public.country_featured_products from public,anon,authenticated;
grant select on public.country_featured_products to anon,authenticated;
create policy country_featured_read on public.country_featured_products for select to anon,authenticated using (
 private.has_role('admin') or exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
 where p.id=product_id and p.country_code=country_featured_products.country_code and v.country_code=country_featured_products.country_code
 and p.status='approved' and p.stock_quantity>0 and v.status='active')
);
insert into public.country_featured_products(country_code,position,product_id,selected_by,selected_at)
select p.country_code,row_number() over(partition by p.country_code order by f.position),f.product_id,f.selected_by,f.selected_at
from public.featured_products f join public.products p on p.id=f.product_id join public.vendors v on v.id=p.vendor_id
where private.valid_market_country(p.country_code) and v.country_code=p.country_code;

create function private.country_featured_save(p_country text,p_product_ids uuid[],p_expected uuid[]) returns integer
language plpgsql security definer set search_path='' as $$
declare previous uuid[];n integer;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 perform private.require_recent_totp();
 if not private.valid_market_country(p_country) then raise exception 'Choose a valid country';end if;
 if p_product_ids is null or p_expected is null then raise exception 'Reload the country selection';end if;
 if (select count(distinct x) from unnest(p_product_ids) x)<>cardinality(p_product_ids) then raise exception 'Duplicate or empty featured product';end if;
 perform pg_advisory_xact_lock(hashtextextended('country_featured:'||p_country,0));
 select coalesce(array_agg(product_id order by position),'{}'::uuid[]) into previous from public.country_featured_products where country_code=p_country;
 if previous is distinct from p_expected then raise exception 'Featured products changed. Reload this country before saving';end if;
 -- Lock chosen store/product rows so an overlapping country move cannot race validation.
 perform p.id from public.products p join public.vendors v on v.id=p.vendor_id where p.id=any(p_product_ids) order by v.id,p.id for share of p,v;
 if exists(select 1 from unnest(p_product_ids) x where not exists(
  select 1 from public.products p join public.vendors v on v.id=p.vendor_id where p.id=x
  and p.country_code=p_country and v.country_code=p_country and p.status='approved' and p.stock_quantity>0 and v.status='active')) then
  raise exception 'Choose available products from active vendors in this country';end if;
 delete from public.country_featured_products where country_code=p_country;
 insert into public.country_featured_products(country_code,position,product_id,selected_by)
 select p_country,ordinality,product_id,auth.uid() from unnest(p_product_ids) with ordinality u(product_id,ordinality);
 n:=cardinality(p_product_ids);
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'COUNTRY_FEATURED_PRODUCTS_SET','featured_products',jsonb_build_object('country_code',p_country,'product_ids',p_product_ids,'previous_product_ids',previous));
 return n;
end $$;
create function public.set_country_featured_products(p_country text,p_product_ids uuid[],p_expected uuid[]) returns integer
language sql security invoker set search_path='' as $$select private.country_featured_save(p_country,p_product_ids,p_expected)$$;
revoke all on function private.country_featured_save(text,uuid[],uuid[]),public.set_country_featured_products(text,uuid[],uuid[]) from public,anon,authenticated;
grant execute on function private.country_featured_save(text,uuid[],uuid[]),public.set_country_featured_products(text,uuid[],uuid[]) to authenticated;
-- Old tabs must reload; they must not overwrite the former global list.
create or replace function public.set_featured_products(p_product_ids uuid[]) returns integer language plpgsql security invoker set search_path='' as $$
begin raise exception 'Reload the admin page and select a country before saving featured products';end $$;
notify pgrst,'reload schema';
