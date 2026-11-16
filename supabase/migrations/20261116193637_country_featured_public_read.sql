-- Keep the admin role helper out of the anonymous visitor policy.
alter policy country_featured_read on public.country_featured_products using (
 exists(select 1 from public.products p join public.vendors v on v.id=p.vendor_id
 where p.id=product_id and p.country_code=country_featured_products.country_code and v.country_code=country_featured_products.country_code
 and p.status='approved' and p.stock_quantity>0 and v.status='active')
);
create policy country_featured_admin_read on public.country_featured_products for select to authenticated using(private.has_role('admin'));
notify pgrst,'reload schema';
