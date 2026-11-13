begin;
create or replace function public.set_featured_products(p_product_ids uuid[])
returns integer language plpgsql security definer set search_path='' as $$
declare admin_id uuid:=auth.uid(); n integer;
begin
  if admin_id is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if (select count(distinct x) from unnest(coalesce(p_product_ids,'{}'::uuid[])) x)<>coalesce(array_length(p_product_ids,1),0) then
    raise exception 'Duplicate featured product';
  end if;
  if exists(select 1 from unnest(coalesce(p_product_ids,'{}'::uuid[])) x
    where not exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
      where p.id=x and p.status='approved' and p.stock_quantity>0 and v.status='active')) then
    raise exception 'Choose approved products from active vendors';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('mio-featured-products',0));
  -- Positions are positive: explicitly scope the intentional list replacement.
  -- Compatible with safeupdate on production API connections.
  delete from public.featured_products where position >= 1;
  insert into public.featured_products(position,product_id,selected_by)
    select ordinality,product_id,admin_id from unnest(coalesce(p_product_ids,'{}'::uuid[])) with ordinality u(product_id,ordinality);
  n:=coalesce(array_length(p_product_ids,1),0);
  insert into public.audit_logs(actor_id,action,entity_type,after_data)
    values(admin_id,'FEATURED_PRODUCTS_SET','featured_products',jsonb_build_object('count',n,'product_ids',p_product_ids));
  return n;
end $$;
revoke all on function public.set_featured_products(uuid[]) from public,anon;
grant execute on function public.set_featured_products(uuid[]) to authenticated;
commit;
