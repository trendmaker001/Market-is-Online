-- Fix the server category mismatch and give field-specific listing errors.
-- Optional SKU/details remain optional. Drafts may have 0-8 photos; review needs 3-8.
CREATE OR REPLACE FUNCTION public.save_product_listing(p_product_id uuid, p_vendor_id uuid, p_name text, p_sku text, p_description text, p_category text, p_price numeric, p_stock integer, p_images jsonb, p_submit boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid uuid; begin
 if not exists(select 1 from public.vendors where id=p_vendor_id and status='active' and (owner_user_id=auth.uid() or private.has_role('admin'))) then raise exception 'Active seller access required'; end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 250 then raise exception 'Enter a product title between 2 and 250 characters'; end if;
 if length(trim(coalesce(p_description,'')))<5 then raise exception 'Add a product description of at least 5 characters'; end if;
 -- Match the configured categories plus the built-in categories shown by the listing form.
 if length(trim(coalesce(p_category,'')))<2 or not (
   exists(select 1 from public.system_config c cross join lateral jsonb_array_elements(c.config_value) x where c.config_key='MARKETPLACE_CATEGORIES' and c.effective_to is null and trim(x->>'name')=trim(p_category))
   or trim(p_category)=any(array['Mobile & Accessories','Electronics & Gadgets','Computers & Gaming','TVs & Home Appliances','Men’s Fashion','Women’s Fashion','Kids & Baby','Shoes','Peshawari Chappal','Bags & Luggage','Jewelry & Watches','Beauty & Cosmetics','Fragrances','Personal Care','Winter Wear','Home & Living','Kitchen & Dining','Grocery & Food','Health & Wellness','Sports & Fitness','Automotive','Tools & Hardware','Pet Supplies','Books & Stationery'])
 ) then raise exception 'Choose a product category from the list'; end if;
 if p_price is null or p_price<=0 or p_price<>round(p_price,2) then raise exception 'Enter a positive PKR price with no more than 2 decimal places'; end if;
 if p_stock is null or p_stock<200 or p_stock>1000000 then raise exception 'Enter stock between 200 and 1000000 units'; end if;
 if p_images is null or jsonb_typeof(p_images)<>'array' then raise exception 'Add product photos as a list'; end if;
 if jsonb_array_length(p_images)>8 then raise exception 'Use no more than 8 product photos'; end if;
 if exists(select 1 from jsonb_array_elements(p_images) x where jsonb_typeof(x)<>'string' or (x#>>'{}') !~ '^https://[^[:space:]]+$') then raise exception 'Use valid HTTPS product photo links'; end if;
 if p_submit and jsonb_array_length(p_images)<3 then raise exception 'Add at least 3 product photos before sending for review (maximum 8)'; end if;
 if p_product_id is null then
  insert into public.products(vendor_id,name,sku,description,category,price_pkr,stock_quantity,image_urls,image_url,status) values(p_vendor_id,trim(p_name),nullif(trim(p_sku),''),p_description,trim(p_category),p_price,p_stock,p_images,p_images->>0,case when p_submit then 'pending'::public.product_status else 'draft'::public.product_status end) returning id into pid;
 else
  update public.products set name=trim(p_name),sku=nullif(trim(p_sku),''),description=p_description,category=trim(p_category),price_pkr=p_price,stock_quantity=p_stock,image_urls=p_images,image_url=p_images->>0,status=case when p_submit then 'pending'::public.product_status else 'draft'::public.product_status end,updated_at=now() where id=p_product_id and vendor_id=p_vendor_id returning id into pid;
  if pid is null then raise exception 'Product not found'; end if;
  delete from public.featured_products where product_id=pid;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_LISTING_SAVED','product',pid,jsonb_build_object('submitted',p_submit));return pid;
end $function$
;
