-- Submission is a review request, not approval. Preserve identity, image verification and final economics checks.
begin;
alter table private.verified_product_photos drop constraint verified_product_photos_width_check, drop constraint verified_product_photos_height_check;
alter table private.verified_product_photos add constraint verified_product_photos_width_check check(width>0), add constraint verified_product_photos_height_check check(height>0);
alter table public.products drop constraint products_image_urls_check;
alter table public.products add constraint products_image_urls_check check(jsonb_typeof(image_urls)='array');
create or replace function private.guard_stock_entry() returns trigger language plpgsql security invoker set search_path='' as $$ begin
 if new.stock_quantity is null or new.stock_quantity<0 then raise exception 'Enter stock as a non-negative whole number';end if;
 return new;
end $$;
CREATE OR REPLACE FUNCTION public.save_product_listing(p_product_id uuid, p_vendor_id uuid, p_name text, p_sku text, p_description text, p_category text, p_price numeric, p_stock integer, p_images jsonb, p_submit boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid uuid; previous_mode text; begin
 if not exists(select 1 from public.vendors where id=p_vendor_id and status='active' and (owner_user_id=auth.uid() or private.has_role('admin'))) then raise exception 'Active seller access required'; end if;
 if length(trim(coalesce(p_name,''))) not between 2 and 250 then raise exception 'Enter a product title between 2 and 250 characters'; end if;
 -- Match the configured categories plus the built-in categories shown by the listing form.
 if length(trim(coalesce(p_category,'')))<2 or not (
   exists(select 1 from public.system_config c cross join lateral jsonb_array_elements(c.config_value) x where c.config_key='MARKETPLACE_CATEGORIES' and c.effective_to is null and trim(x->>'name')=trim(p_category))
   or trim(p_category)=any(array['Mobile & Accessories','Electronics & Gadgets','Computers & Gaming','TVs & Home Appliances','Men’s Fashion','Women’s Fashion','Kids & Baby','Shoes','Peshawari Chappal','Bags & Luggage','Jewelry & Watches','Beauty & Cosmetics','Fragrances','Personal Care','Winter Wear','Home & Living','Kitchen & Dining','Grocery & Food','Health & Wellness','Sports & Fitness','Automotive','Tools & Hardware','Pet Supplies','Books & Stationery'])
 ) then raise exception 'Choose a product category from the list'; end if;
 if p_price is null or p_price<=0 or p_price<>round(p_price,2) then raise exception 'Enter a positive PKR price with no more than 2 decimal places'; end if;
 if p_stock is null or p_stock<0 then raise exception 'Enter stock as a non-negative whole number'; end if;
 if p_images is null or jsonb_typeof(p_images)<>'array' then raise exception 'Add product photos as a list'; end if;
 if exists(select 1 from jsonb_array_elements(p_images) x where jsonb_typeof(x)<>'string' or (x#>>'{}') !~ '^https://[^[:space:]]+$') then raise exception 'Use valid HTTPS product photo links'; end if;
 previous_mode:=current_setting('mio.listing_review_save',true);
 perform set_config('mio.listing_review_save','on',true);
 if p_product_id is null then
  insert into public.products(vendor_id,name,sku,description,category,price_pkr,stock_quantity,image_urls,image_url,status) values(p_vendor_id,trim(p_name),nullif(trim(p_sku),''),p_description,trim(p_category),p_price,p_stock,p_images,p_images->>0,case when p_submit then 'pending'::public.product_status else 'draft'::public.product_status end) returning id into pid;
 else
  update public.products set name=trim(p_name),sku=nullif(trim(p_sku),''),description=p_description,category=trim(p_category),price_pkr=p_price,stock_quantity=p_stock,image_urls=p_images,image_url=p_images->>0,status=case when p_submit then 'pending'::public.product_status else 'draft'::public.product_status end,updated_at=now() where id=p_product_id and vendor_id=p_vendor_id returning id into pid;
  if pid is null then raise exception 'Product not found'; end if;
  delete from public.featured_products where product_id=pid;
 end if;
 perform set_config('mio.listing_review_save',coalesce(previous_mode,''),true);
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'PRODUCT_LISTING_SAVED','product',pid,jsonb_build_object('submitted',p_submit));return pid;
end $function$
;

create or replace function public.save_product_listing_with_commission(
 p_country text,p_product_id uuid,p_vendor_id uuid,p_name text,p_sku text,p_description text,
 p_category text,p_price numeric,p_stock integer,p_images jsonb,p_submit boolean,p_commission numeric
) returns uuid language plpgsql security definer set search_path='' as $$
declare pid uuid; vendor_rate numeric; old_proposal jsonb;
begin
 if auth.uid() is null then raise exception 'Active seller access required'; end if;
 select commission_rate into vendor_rate from public.vendors where id=p_vendor_id and status='active'
 and (owner_user_id=auth.uid() or private.has_role('admin'));
 if not found then raise exception 'Active seller access required';end if;
 if p_commission is not null and (p_commission<0 or p_commission>1 or p_commission<>round(p_commission,6)) then
 raise exception 'Enter a product percentage between 0 and 100, with up to 4 decimal places';end if;
 if p_product_id is not null then
  perform 1 from public.products where id=p_product_id and vendor_id=p_vendor_id and bundle_definition is null for update;
  if not found then raise exception 'Product not found or use the bundle builder';end if;
  select to_jsonb(c) into old_proposal from public.product_commission_proposals c where product_id=p_product_id;
 end if;
 pid:=public.save_product_listing_country(p_country,p_product_id,p_vendor_id,p_name,p_sku,p_description,p_category,p_price,p_stock,p_images,p_submit);
 insert into public.product_commission_proposals(product_id,requested_rate,status,submitted_by,submitted_at)
 values(pid,p_commission,'pending',auth.uid(),clock_timestamp())
 on conflict(product_id) do update set requested_rate=excluded.requested_rate,status='pending',submitted_by=excluded.submitted_by,
 submitted_at=excluded.submitted_at,approved_rate=null,reviewed_by=null,reviewed_at=null;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data)
 values(auth.uid(),'PRODUCT_COMMISSION_PROPOSED','product',pid,old_proposal,jsonb_build_object('requested_rate',p_commission,'uses_vendor_default',p_commission is null));
 return pid;
end $$;
revoke all on function public.save_product_listing_with_commission(text,uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean,numeric) from public,anon;
grant execute on function public.save_product_listing_with_commission(text,uuid,uuid,text,text,text,text,numeric,integer,jsonb,boolean,numeric) to authenticated;


create or replace function private.require_verified_product_photos() returns trigger
language plpgsql security definer set search_path='' as $$
declare photo text; previous jsonb:='[]'::jsonb;
begin
 -- Trusted server imports remain possible; customer RPCs always carry auth.uid().
 if auth.uid() is null then return new; end if;
 if TG_OP='UPDATE' and old.vendor_id=new.vendor_id then previous=coalesce(old.image_urls,'[]'::jsonb);if old.image_url is not null then previous=previous||jsonb_build_array(old.image_url);end if;end if;
 for photo in select value from jsonb_array_elements_text(coalesce(new.image_urls,'[]'::jsonb)||case when new.image_url is null then '[]'::jsonb else jsonb_build_array(new.image_url) end) loop
  if not (previous ? photo) and not exists(select 1 from private.verified_product_photos v where v.url=photo and v.vendor_id=new.vendor_id) then
   raise exception 'Upload new photos through the listing form: JPG/PNG/WebP, maximum 5 MB each; 1000 × 1000 pixels is recommended. Refresh the page if you are using an older form.';
  end if;
 end loop;
 return new;
end $$;
revoke all on function private.require_verified_product_photos() from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.formula_product_ppv()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.vendors%rowtype;e jsonb;base numeric;sale numeric;
begin
 if new.bundle_definition is not null then return new;end if;
 select * into v from public.vendors where id=new.vendor_id;
 if tg_op='INSERT' then
  new.vendor_submitted_price_pkr:=new.price_pkr;
  if not private.has_role('admin') and (new.commission_rate_override is not null or new.assigned_ppv is not null or new.ppv_remainder_policy<>'reserve' or new.reward_discount_pkr<>0) then raise exception 'Only admin may set product commission and PPV';end if;
 else
  if not private.has_role('admin') and (new.commission_rate_override is distinct from old.commission_rate_override or new.assigned_ppv is distinct from old.assigned_ppv or new.ppv_remainder_policy is distinct from old.ppv_remainder_policy or new.reward_discount_pkr is distinct from old.reward_discount_pkr or new.awarded_rate_override is distinct from old.awarded_rate_override) then raise exception 'Only admin may set product commission and PPV';end if;
  if not private.has_role('admin') and new.price_pkr is distinct from old.price_pkr then new.vendor_submitted_price_pkr:=new.price_pkr;new.reward_discount_pkr:=0;
  elsif new.vendor_submitted_price_pkr is distinct from old.vendor_submitted_price_pkr then raise exception 'Seller submitted price is preserved';end if;
 end if;
 -- Listing submissions are unpublished; final funding is validated during admin approval.
 if new.status in ('draft','pending') and current_setting('mio.listing_review_save',true)='on' then
  new.ppv_per_unit:=0;new.maximum_ppv:=0;return new;
 end if;
 base:=new.vendor_submitted_price_pkr;
  if tg_op='UPDATE' and current_setting('mio.reprice_ppv_only',true)='on' and private.has_role('admin') then
    e:=private.product_economics(base,new.price_pkr,coalesce(new.commission_rate_override,v.commission_rate),
      private.current_mio_reference_price(),null,'reserve');
    new.maximum_ppv:=(e->>'maximum_ppv')::numeric;
    new.ppv_per_unit:=least(coalesce(new.assigned_ppv,new.maximum_ppv),new.maximum_ppv);
    return new;
  end if;
  if tg_op='UPDATE' and new.stock_quantity is distinct from old.stock_quantity
    and (to_jsonb(new)-array['stock_quantity','updated_at','ppv_per_unit'])
      = (to_jsonb(old)-array['stock_quantity','updated_at','ppv_per_unit']) then
    new.ppv_per_unit:=old.ppv_per_unit;
    return new;
  end if;

 if base<=0 and new.status='archived' then new.ppv_per_unit:=0;new.maximum_ppv:=0;return new;end if;
 sale:=new.price_pkr+new.reward_discount_pkr;
 e:=private.product_economics(base,sale,coalesce(new.commission_rate_override,v.commission_rate),private.current_mio_reference_price(),new.assigned_ppv,new.ppv_remainder_policy);
 new.maximum_ppv:=(e->>'maximum_ppv')::numeric;new.ppv_per_unit:=(e->>'assigned_ppv')::numeric;
 new.reward_discount_pkr:=(e->>'extra_discount')::numeric;new.price_pkr:=(e->>'sale_price')::numeric;
 return new;
end $function$
;
create or replace function public.save_product_listing_country(p_country text,p_product_id uuid,p_vendor_id uuid,p_name text,p_sku text,p_description text,p_category text,p_price numeric,p_stock integer,p_images jsonb,p_submit boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;previous_mode text;begin
 if not private.valid_market_country(p_country) then raise exception 'Select a product country';end if;
 previous_mode:=current_setting('mio.listing_review_save',true);
 perform set_config('mio.listing_review_save','on',true);
 v_id:=public.save_product_listing(p_product_id,p_vendor_id,p_name,p_sku,p_description,p_category,p_price,p_stock,p_images,p_submit);
 update public.products set country_code=p_country where products.id=v_id;
 perform set_config('mio.listing_review_save',coalesce(previous_mode,''),true);
 return v_id;
end$$;

commit;
