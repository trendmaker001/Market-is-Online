-- Current production entry points captured for integration regression. No customer data.
CREATE OR REPLACE FUNCTION private.bundle_component_changed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.bundle_definition is not null then return new;end if;
 -- Changed component economics make offers unavailable until admin saves again.
 perform private.sync_bundle_inventory(new.id);return new;
end $function$;

CREATE OR REPLACE FUNCTION private.bundle_product_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b jsonb:=new.bundle_definition; v public.vendors%rowtype; base numeric; price numeric; points numeric; rate numeric;
begin
 if tg_op='UPDATE' and old.bundle_definition is not null and b is null then raise exception 'A bundle cannot become a standalone product';end if;
 if b is null then return new;end if;
  if b->>'kind'='configured' then
    if tg_op='UPDATE' and old.status='archived' and new.status='archived'
      and (to_jsonb(new)-array['stock_quantity','updated_at','ppv_per_unit'])
        = (to_jsonb(old)-array['stock_quantity','updated_at','ppv_per_unit']) then
      new.ppv_per_unit:=old.ppv_per_unit;
      return new;
    end if;
    if current_setting('mio.configured_bundle_id',true) is distinct from new.id::text
      then raise exception 'Configured bundles can only be created during checkout'; end if;
    new.vendor_submitted_price_pkr:=(b->>'base_total')::numeric;
    new.ppv_per_unit:=(b->>'ppv')::numeric;
    new.awarded_rate_override:=trunc(new.ppv_per_unit*(b->>'reference_rate')::numeric/new.vendor_submitted_price_pkr,6);
    return new;
  end if;
  if tg_op='UPDATE' and new.status='archived' and current_setting('mio.archive_legacy_bundles',true)='on' then
    return new;
  end if;
  if new.status='approved' then raise exception 'Use configurable bundle types for new purchases'; end if;

 if not private.has_role('admin') and (tg_op='INSERT' or (to_jsonb(new)-array['stock_quantity','updated_at','ppv_per_unit','awarded_rate_override','vendor_submitted_price_pkr']) is distinct from (to_jsonb(old)-array['stock_quantity','updated_at','ppv_per_unit','awarded_rate_override','vendor_submitted_price_pkr'])) then raise exception 'Only admin can manage bundles';end if;
 select * into v from public.vendors where id=new.vendor_id;
 base:=(b->>'base_total')::numeric; price:=(b->>'original_total')::numeric-(b->>'discount_pkr')::numeric;
 points:=(b->>'ppv')::numeric;rate:=(b->>'reference_rate')::numeric;
 if base is null or price is null or points is null or rate is null or base<=0 or price<=0 or points<0 or rate<=0 or price<>new.price_pkr then raise exception 'Invalid bundle price or PPV';end if;
 if coalesce((b->>'economics_version')::integer,0)=3 and ceil(points*rate*100)/100>((b->>'commission_pkr')::numeric-(b->>'company_fee_pkr')::numeric-(b->>'introducer_pkr')::numeric-(base-price)) then raise exception 'Bundle discount and PPV exceed the funded budget';end if;
 new.vendor_submitted_price_pkr:=base;new.ppv_per_unit:=points;
 new.awarded_rate_override:=trunc(points*rate/base,6);
 return new;
end $function$;

CREATE OR REPLACE FUNCTION private.close_customer_order_funding()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if new.status in('cancelled','returned') and old.status is distinct from new.status then
  update private.customer_order_funding set status=case when paid_pkr>0 then 'refund_due' else 'cancelled' end where order_id=new.id and status not in('refund_due','refunded','cancelled');
 end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION private.configured_bundle_quote(p_type uuid, p_vendor uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  tier private.marketplace_bundle_types%rowtype;
  vendor public.vendors%rowtype;
  item record;
  product public.products%rowtype;
  items jsonb := '[]';
  units integer := 0;
  rate numeric;
  subtotal numeric := 0;
  base_total numeric := 0;
  total_ppv numeric := 0;
  commission_total numeric := 0;
  fee_total numeric := 0;
  intro_total numeric := 0;
  retained numeric;
  discount_ppv numeric;
  discount numeric;
  result jsonb;
begin
  select * into tier from private.marketplace_bundle_types where id=p_type and status='enabled';
  if not found then raise exception 'This bundle type is unavailable'; end if;
  select * into vendor from public.vendors where id=p_vendor and status='active';
  if not found then raise exception 'Select an active vendor'; end if;
  select (config_value#>>'{}')::numeric into rate from public.system_config
    where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null order by version desc limit 1;
  if rate is null or rate <= 0 then raise exception 'The administrator must configure the PPV conversion rate'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Select bundle products'; end if;
  if jsonb_array_length(p_items)>tier.required_units then raise exception 'Too many product selections'; end if;
  if (select count(distinct x->>'product_id') from jsonb_array_elements(p_items) x)<>jsonb_array_length(p_items)
    then raise exception 'Use one quantity for each selected product'; end if;
  for item in select * from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) order by product_id loop
    if item.quantity is null or item.quantity < 1 or item.quantity >
      (case when tier.allow_repeats then coalesce(tier.max_per_product,tier.required_units) else 1 end)
      then raise exception 'A product exceeds the per-product quantity limit'; end if;
    select * into product from public.products where id=item.product_id;
    if not found or product.vendor_id<>p_vendor or product.status<>'approved' or product.bundle_definition is not null
      then raise exception 'Choose approved regular products from one vendor'; end if;
    if product.stock_quantity<item.quantity then raise exception 'A selected product has insufficient stock'; end if;
    units:=units+item.quantity;
    subtotal:=subtotal+product.price_pkr*item.quantity;
    base_total:=base_total+product.vendor_submitted_price_pkr*item.quantity;
    total_ppv:=total_ppv+coalesce(product.ppv_per_unit,0)*item.quantity;
    commission_total:=commission_total+round(product.vendor_submitted_price_pkr*coalesce(product.commission_rate_override,vendor.commission_rate),2)*item.quantity;
    fee_total:=fee_total+round(product.vendor_submitted_price_pkr*.05,2)*item.quantity;
    intro_total:=intro_total+round(round(product.vendor_submitted_price_pkr*coalesce(product.commission_rate_override,vendor.commission_rate),2)*.10,2)*item.quantity;
    items:=items||jsonb_build_array(jsonb_build_object(
      'product_id',product.id,'quantity',item.quantity,'name',product.name,'image_url',product.image_url,
      'price_pkr',product.price_pkr,'ppv',coalesce(product.ppv_per_unit,0),
      'commission_rate',coalesce(product.commission_rate_override,vendor.commission_rate)));
  end loop;
  if units>tier.required_units then raise exception 'Bundle has too many units'; end if;
  retained:=trunc(total_ppv/tier.ppv_divider,4);
  discount_ppv:=total_ppv-total_ppv/tier.ppv_divider;
  discount:=trunc(discount_ppv*rate,2);
  if units>0 and (subtotal-discount<=0 or ceil(retained*rate*100)/100>
    commission_total-fee_total-intro_total-(base_total-subtotal+discount))
    then raise exception 'Bundle exceeds the approved product PPV budget'; end if;
  result:=jsonb_build_object(
    'kind','configured','type_id',tier.id,'name',tier.name,'vendor_id',vendor.id,'items',items,
    'units',units,'required_units',tier.required_units,'divider',tier.ppv_divider,'minimum_pkr',tier.minimum_pkr,
    'allow_repeats',tier.allow_repeats,'max_per_product',tier.max_per_product,
    'original_total',subtotal,'base_total',base_total,'original_ppv',total_ppv,'ppv',retained,
    'discount_ppv',discount_ppv,'discount_pkr',discount,'price_pkr',subtotal-discount,'reference_rate',rate,
    'complete',units=tier.required_units,'meets_minimum',subtotal-discount>=tier.minimum_pkr,
    'commission_pkr',commission_total,'company_fee_pkr',fee_total,'introducer_pkr',intro_total,'economics_version',3);
  return result||jsonb_build_object('quote_key',md5(result::text));
end $function$;

CREATE OR REPLACE FUNCTION private.customer_order_requirement(p_total numeric, p_rate numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
begin
 if p_total is null or p_total<=0 or p_rate is null or p_rate<=0 then raise exception 'Invalid order total or reference rate';end if;
 return jsonb_build_object('required_pkr',least(p_total,case when p_total<=6000 then 600 else round(p_total*.10,2) end),
 'hold_mio',case when p_total<=6000 then 2 else ceil(round(p_total*.10,2)/p_rate*10000)/10000 end,'rate_snapshot',p_rate);
end $function$;

CREATE OR REPLACE FUNCTION private.guard_customer_order_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f private.customer_order_funding%rowtype;
begin
 select * into f from private.customer_order_funding where order_id=old.id;
 if f.order_id is null then return new;end if;
 if new.status in('cancelled','returned') then return new;end if;
 if (new.status<>old.status and new.status in('confirmed','processing','shipped','delivered')) or (new.payment_status='confirmed' and old.payment_status<>'confirmed') then
  if f.method='ADVANCE' and f.status<>'approved' then raise exception 'Advance payment must be verified before processing this order';end if;
  if f.method='SPONSOR' and not exists(select 1 from public.affiliate_guest_order_approvals where order_id=old.id and status in('approved','released')) then raise exception 'Sponsor hold must be approved before processing this order';end if;
 end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION private.notify_order_payment_entry()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform private.notify_member(new.member_id,
  case when new.entry_kind in('checkout_refund','guarantee_refund') then 'refund' when new.wallet_kind='shopping' then 'shopping' else 'wallet' end,
  case when new.entry_kind in('checkout_refund','guarantee_refund') then 'Order wallet refund' when new.wallet_kind='shopping' then 'Shopping Points used' else 'Cash Wallet order activity' end,
  new.note,'order',new.order_id,jsonb_build_object('wallet',new.wallet_kind,'amount',new.amount,'entry_kind',new.entry_kind));
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.place_shopping_order_core(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_guest_email text, p_idempotency_key text, p_access_token text, p_affiliate_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  oid uuid:=gen_random_uuid();
  existing public.orders%rowtype;
  prod public.products%rowtype;
  item record;
  fee numeric;
  gross numeric(14,2):=0;
  disc numeric(14,2):=0;
  email_normalized text:=lower(trim(coalesce(p_guest_email,'')));
  phone_normalized text:=regexp_replace(coalesce(p_shipping_phone,''),'[^0-9+]','','g');
  token_hash text;
begin
  -- Authorization is enforced by the authenticated/affiliate-only public entry points.
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Basket is empty';end if;
  if jsonb_array_length(p_items)>30 then raise exception 'Too many basket lines';end if;
  if exists(select 1 from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) where product_id is null or quantity is null or quantity<1 or quantity>99) then raise exception 'Invalid basket line';end if;
  if email_normalized!~'^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'Enter a valid email address';end if;
  if length(trim(coalesce(p_shipping_name,'')))<2 or length(trim(coalesce(p_shipping_name,'')))>120 then raise exception 'Enter a valid delivery name';end if;
  if length(phone_normalized)<7 or length(phone_normalized)>20 then raise exception 'Enter a valid delivery phone';end if;
  if length(trim(coalesce(p_shipping_address,'')))<8 or length(trim(coalesce(p_shipping_address,'')))>500 then raise exception 'Enter a complete delivery address';end if;
  if length(trim(coalesce(p_shipping_city,'')))<2 or length(trim(coalesce(p_shipping_city,'')))>100 then raise exception 'Enter a valid city';end if;
  if length(coalesce(p_idempotency_key,''))<12 or length(coalesce(p_access_token,''))<32 then raise exception 'Invalid guest order request';end if;
  token_hash:=md5(p_access_token);
  perform pg_advisory_xact_lock(hashtextextended('guest-order:'||email_normalized||':'||p_idempotency_key,0));
  select * into existing from public.orders where idempotency_key='guest:'||email_normalized||':'||p_idempotency_key;
  if existing.id is not null then
    if existing.guest_access_token_hash<>token_hash then raise exception 'Guest order token mismatch';end if;
    return jsonb_build_object('order_id',existing.id,'order_code',existing.order_code,'status',existing.status);
  end if;
  if (select count(*) from public.orders where buyer_id is null and lower(guest_email)=email_normalized and regexp_replace(shipping_phone,'[^0-9+]','','g')=phone_normalized and created_at>now()-interval '1 hour' and status not in('cancelled','returned'))>=5 then
    raise exception 'Too many recent guest orders. Please try again later';
  end if;
  select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
  if fee is null then raise exception 'Delivery charges are awaiting company configuration';end if;
  perform set_config('mio.affiliate_code',coalesce(trim(p_affiliate_code),''),true);
  insert into public.orders(id,order_code,buyer_id,subtotal_pkr,delivery_fee_pkr,total_pkr,payment_method,payment_status,status,shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key,usd_to_pkr_rate,guest_email,guest_access_token_hash)
  values(oid,'USR-'||upper(substr(replace(oid::text,'-',''),1,10)),null,0,fee,fee,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),trim(p_shipping_address),trim(p_shipping_city),'guest:'||email_normalized||':'||p_idempotency_key,private.current_mio_reference_price(),email_normalized,token_hash);
  for item in select product_id,sum(quantity)::integer quantity from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) group by product_id order by product_id loop
    select * into prod from public.products where id=item.product_id for update;
    if prod.id is null or prod.status<>'approved' or prod.stock_quantity<item.quantity then raise exception 'A selected product is unavailable or out of stock';end if;
    if not exists(select 1 from public.vendors v where v.id=prod.vendor_id and v.status='active') then raise exception 'Seller is not active';end if;
    update public.products set stock_quantity=stock_quantity-item.quantity,updated_at=now() where id=prod.id;
    insert into public.order_items(order_id,product_id,vendor_id,product_name_snapshot,unit_price_pkr,quantity) values(oid,prod.id,prod.vendor_id,prod.name,prod.price_pkr,item.quantity);
    gross:=gross+prod.price_pkr*item.quantity;
  end loop;
  if gross<=0 then raise exception 'Basket total must be positive';end if;
  select coalesce(sum(buyer_discount_pkr),0) into disc from public.order_items where order_id=oid;
  update public.orders set discount_pkr=disc,subtotal_pkr=gross-disc,total_pkr=gross-disc+fee where id=oid;
  perform set_config('mio.affiliate_code','',true);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'CUSTOMER_MARKETPLACE_ORDER_PLACED','order',oid,jsonb_build_object('order_code',(select order_code from public.orders where id=oid),'guest',true,'affiliate_attributed',exists(select 1 from public.orders where id=oid and selling_affiliate_id is not null)));
  return (select jsonb_build_object('order_id',id,'order_code',order_code,'status',status) from public.orders where id=oid);
end $function$;

CREATE OR REPLACE FUNCTION private.reserve_bundle_components()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b public.products%rowtype;r record;p public.products%rowtype;items jsonb:='[]';
begin
 select * into b from public.products where id=new.product_id;
 if b.bundle_definition is null then return new;end if;
 if b.status<>'approved' or new.unit_price_pkr<>b.price_pkr or new.vendor_id<>b.vendor_id then raise exception 'Bundle changed; refresh your basket';end if;
 for r in select (x->>'product_id')::uuid id,(x->>'quantity')::integer qty from jsonb_array_elements(b.bundle_definition->'items')x order by 1 loop
  select * into p from public.products where id=r.id for update;
  if not found or p.status<>'approved' or p.vendor_id<>b.vendor_id or p.bundle_definition is not null or p.stock_quantity<r.qty*new.quantity or not exists(select 1 from jsonb_array_elements(b.bundle_definition->'items')x where (x->>'product_id')::uuid=p.id and (x->>'price_pkr')::numeric=p.price_pkr and (x->>'ppv')::numeric=p.ppv_per_unit) then raise exception 'A bundle product is unavailable or out of stock';end if;
  update public.products set stock_quantity=stock_quantity-r.qty*new.quantity,updated_at=now() where id=p.id;
  items:=items||jsonb_build_array(jsonb_build_object('product_id',p.id,'name',p.name,'quantity',r.qty*new.quantity,'image_url',p.image_url));
 end loop;
 new.bundle_components_snapshot:=items;return new;
end $function$;

CREATE OR REPLACE FUNCTION private.return_bundle_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare i record;r record;
begin
 if new.status not in('cancelled','returned') or old.status in('cancelled','returned') then return new;end if;
 for i in select * from public.order_items where order_id=new.id and bundle_components_snapshot is not null and bundle_inventory_returned_at is null for update loop
  for r in select (x->>'product_id')::uuid id,(x->>'quantity')::integer qty from jsonb_array_elements(i.bundle_components_snapshot)x order by 1 loop
   update public.products set stock_quantity=stock_quantity+r.qty,updated_at=now() where id=r.id;
  end loop;
  update public.order_items set bundle_inventory_returned_at=now() where id=i.id;
 end loop;return new;
end $function$;

CREATE OR REPLACE FUNCTION private.shopping_order_details(p_order uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return coalesce((select jsonb_agg(x.data order by x.created_at desc) from (
 select o.created_at,jsonb_build_object('id',o.id,'order_code',o.order_code,'status',o.status,'payment_status',o.payment_status,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'created_at',o.created_at,
 'shipping_name',o.shipping_name,'shipping_city',o.shipping_city,'shipping_address',o.shipping_address,
 'funding',to_jsonb(f)-'customer_id'-'transaction_key'-'reviewer_id',
 'sponsor_status',a.status,'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.product_name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_pkr)),'[]') from public.order_items i where i.order_id=o.id)) as data
 from private.customer_order_funding f join public.orders o on o.id=f.order_id left join public.affiliate_guest_order_approvals a on a.order_id=o.id
 where f.customer_id=auth.uid() and o.id=p_order order by o.created_at desc limit 1) x),'[]')->0;
end $function$;

CREATE OR REPLACE FUNCTION private.shopping_order_notification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c uuid;entity uuid;ordercode text;route text;title text;body text;
begin
 if tg_table_name='customer_order_funding' then
  if tg_op='UPDATE' and new.status is not distinct from old.status then return new;end if;
  c:=new.customer_id;entity:=new.order_id;select order_code into ordercode from public.orders where id=new.order_id;
  route:=case when new.method='ADVANCE' then 'account/prepayments/'||new.order_id else 'account/orders/'||new.order_id end;
  if tg_op='INSERT' then title:='Order saved';body:='Order '||ordercode||case when new.method='ADVANCE' then ' is saved. Complete its advance payment to continue.' else ' is awaiting sponsor hold approval.' end;
  else title:='Payment '||replace(new.status,'_',' ');body:='Order '||ordercode||': your advance payment is '||replace(new.status,'_',' ')||'.'||case when nullif(new.review_note,'') is not null then ' '||left(new.review_note,500) else '' end;end if;
 elsif tg_table_name='orders' then
  if new.status is not distinct from old.status then return new;end if;
  select customer_id into c from private.customer_order_funding where order_id=new.id;
  entity:=new.id;route:='account/orders/'||new.id;title:='Order '||replace(new.status::text,'_',' ');body:='Order '||new.order_code||' is now '||replace(new.status::text,'_',' ')||'.';
 else
  if new.status is not distinct from old.status then return new;end if;
  select f.customer_id,o.order_code into c,ordercode from private.customer_order_funding f join public.orders o on o.id=f.order_id where f.order_id=new.order_id and f.method='SPONSOR';
  entity:=new.order_id;route:='account/orders/'||new.order_id;title:='Sponsor hold updated';body:='Order '||ordercode||': sponsor security is '||replace(new.status,'_',' ')||'.';
 end if;
 if c is not null then perform private.notify_shopper(c,case tg_table_name when 'orders' then 'order' when 'customer_order_funding' then 'payment' else 'sponsor' end,title,body,route,entity);end if;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION private.snapshot_bundle_reward()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.products%rowtype;v public.vendors%rowtype;rate numeric;available numeric;base numeric;discount numeric;
begin
 if new.economics_version=3 then return new;end if;

 select * into p from public.products where id=new.product_id;if p.bundle_definition is null then return new;end if;
 select * into v from public.vendors where id=p.vendor_id;
 base:=p.vendor_submitted_price_pkr;discount:=base-p.price_pkr;
 rate:=(p.bundle_definition->>'ppv')::numeric*(p.bundle_definition->>'reference_rate')::numeric/base;
 available:=v.commission_rate-.05-discount/base;
 if rate>available then raise exception 'Bundle reward budget changed; contact the store';end if;
 new.ppv_per_unit_snapshot:=(p.bundle_definition->>'ppv')::numeric;
 new.awarded_rate_snapshot:=rate;new.award_scope_snapshot:='product';
 new.award_policy_leftover_pkr:=trunc(base*new.quantity*(available-rate),4);
 new.commission_split_snapshot:=jsonb_build_object('company',5,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',0,'network_rewards',rate*100,'unallocated',(available-rate)*100);
 return new;
end $function$;

CREATE OR REPLACE FUNCTION private.snapshot_configured_bundle()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare definition jsonb; rate numeric;
begin
  select bundle_definition into definition from public.products where id=new.product_id;
  if definition->>'kind'='configured' then
    select usd_to_pkr_rate into rate from public.orders where id=new.order_id;
    if rate is distinct from (definition->>'reference_rate')::numeric then raise exception 'Bundle conversion rate changed. Review a new quote'; end if;
    new.configured_bundle_snapshot:=definition;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION private.sync_bundle_inventory(p_component uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare b record;available integer;
begin
 for b in select id,bundle_definition from public.products where status<>'archived' and bundle_definition->>'kind' is distinct from 'configured' and bundle_definition @> jsonb_build_object('items',jsonb_build_array(jsonb_build_object('product_id',p_component))) order by id loop
  select min(case when p.status='approved' and p.price_pkr=(x->>'price_pkr')::numeric and p.ppv_per_unit=(x->>'ppv')::numeric then p.stock_quantity/(x->>'quantity')::integer else 0 end) into available
  from jsonb_array_elements(b.bundle_definition->'items') x join public.products p on p.id=(x->>'product_id')::uuid;
  update public.products set stock_quantity=coalesce(available,0) where id=b.id and stock_quantity is distinct from coalesce(available,0);
 end loop;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_confirm_order_payment(p_order_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare o public.orders%rowtype;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null then raise exception 'Order not found';end if;
 if o.payment_status='confirmed' then return o.ppv_generated;end if;
 if o.payment_status<>'unconfirmed' or o.status in ('cancelled','returned') then raise exception 'Order is not eligible for payment confirmation';end if;
 update public.orders set payment_status='confirmed',updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'ORDER_PAYMENT_CONFIRMED','order',o.id,jsonb_build_object('buyer_id',o.buyer_id,'delivery_status',o.status));
 return (select ppv_generated from public.orders where id=o.id);
end $function$;

CREATE OR REPLACE FUNCTION public.admin_marketplace_bundle_types()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  return jsonb_build_object(
    'types', (select coalesce(jsonb_agg(to_jsonb(t) order by display_order),'[]'::jsonb) from private.marketplace_bundle_types t),
    'reference_rate', (select (config_value#>>'{}')::numeric from public.system_config
      where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null order by version desc limit 1)
  );
end $function$;

CREATE OR REPLACE FUNCTION public.admin_review_shopping_advance(p_order_id uuid, p_approve boolean, p_verified_pkr numeric, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f private.customer_order_funding%rowtype;o public.orders%rowtype;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select * into o from public.orders where id=p_order_id for update;
 select * into f from private.customer_order_funding where order_id=p_order_id for update;
 if f.order_id is null or f.method<>'ADVANCE' then raise exception 'Advance payment not found';end if;
 if f.status='approved' and p_approve then return;end if;
 if f.status<>'submitted' or o.status<>'placed' then raise exception 'Payment is not awaiting review';end if;
 if p_approve is null or length(trim(coalesce(p_note,'')))<10 then raise exception 'Verification or rejection note required';end if;
 if p_approve and (p_verified_pkr is null or p_verified_pkr<>f.required_pkr) then raise exception 'Verify the exact required advance amount: PKR %',f.required_pkr;end if;
 update private.customer_order_funding set status=case when p_approve then 'approved' else 'rejected' end,paid_pkr=case when p_approve then f.required_pkr else 0 end,
 reviewed_at=now(),reviewer_id=auth.uid(),review_note=trim(p_note) where order_id=p_order_id;
 if p_approve then update public.orders set customer_advance_pkr=f.required_pkr,cod_due_pkr=total_pkr-f.required_pkr,status='confirmed',updated_at=now() where id=p_order_id;end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),case when p_approve then 'CUSTOMER_ADVANCE_APPROVED' else 'CUSTOMER_ADVANCE_REJECTED' end,'order',p_order_id,jsonb_build_object('amount',p_verified_pkr,'note',trim(p_note),'transaction_id',f.transaction_id));
end $function$;

CREATE OR REPLACE FUNCTION public.admin_save_bundle(p_id uuid, p_vendor uuid, p_name text, p_items jsonb, p_ppv numeric, p_discount numeric, p_rate numeric, p_images jsonb, p_status text DEFAULT 'draft'::text, p_mode text DEFAULT 'manual'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pid uuid:=coalesce(p_id,gen_random_uuid());r record;p public.products%rowtype;v public.vendors%rowtype;oldrow jsonb;
 items jsonb:='[]';total numeric:=0;base numeric:=0;points numeric:=0;stock integer:=2147483647;def jsonb;commission_total numeric:=0;company_total numeric:=0;intro_total numeric:=0;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if length(trim(coalesce(p_name,''))) not between 3 and 100 or p_status not in ('draft','approved','archived') or p_mode not in ('manual','half_ppv') then raise exception 'Enter a bundle name and valid publication status';end if;
 if p_ppv is null or p_ppv<0 or p_ppv<>trunc(p_ppv,4) or p_rate is null or p_rate<=0 or p_rate>100000 or p_discount is null or p_discount<0 or p_discount<>round(p_discount,2) then raise exception 'Enter valid PPV (up to 4 decimals), discount and conversion rate';end if;
 if p_rate<>private.current_mio_reference_price() then raise exception 'Refresh the current PKR per PPV rate before saving';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 2 and 20 then raise exception 'Select 2 to 20 different products';end if;
 if p_images is null or jsonb_typeof(p_images)<>'array' or jsonb_array_length(p_images) not between 1 and 8 or exists(select 1 from jsonb_array_elements_text(p_images) x where x !~ '^(https://[^[:space:]]+|/[a-zA-Z0-9][^[:space:]]*)$') then raise exception 'Add 1 to 8 valid product images';end if;
 select * into v from public.vendors where id=p_vendor and status='active';if not found then raise exception 'Select an active vendor';end if;
 if p_id is not null then select to_jsonb(x) into oldrow from public.products x where id=p_id and bundle_definition is not null for update;if not found then raise exception 'Bundle not found';end if;end if;
 if exists(select 1 from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) where product_id is null or quantity is null or quantity not between 1 and 99) or (select count(distinct x->>'product_id') from jsonb_array_elements(p_items)x)<>jsonb_array_length(p_items) then raise exception 'Use distinct products and quantities from 1 to 99';end if;
 for r in select * from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) order by product_id loop
  select * into p from public.products where id=r.product_id for update;
  if not found or p.vendor_id<>p_vendor or p.status<>'approved' or p.bundle_definition is not null then raise exception 'Select approved individual products from the chosen vendor';end if;
  total:=total+p.price_pkr*r.quantity;base:=base+p.vendor_submitted_price_pkr*r.quantity;points:=points+coalesce(p.ppv_per_unit,0)*r.quantity;
  commission_total:=commission_total+round(p.vendor_submitted_price_pkr*coalesce(p.commission_rate_override,v.commission_rate),2)*r.quantity;
  company_total:=company_total+round(p.vendor_submitted_price_pkr*.05,2)*r.quantity;
  intro_total:=intro_total+round(round(p.vendor_submitted_price_pkr*coalesce(p.commission_rate_override,v.commission_rate),2)*.10,2)*r.quantity;
  stock:=least(stock,p.stock_quantity/r.quantity);
  items:=items||jsonb_build_array(jsonb_build_object('product_id',p.id,'quantity',r.quantity,'name',p.name,'image_url',p.image_url,'price_pkr',p.price_pkr,'ppv',p.ppv_per_unit,'commission_rate',coalesce(p.commission_rate_override,v.commission_rate)));
 end loop;
 if p_discount>=total or p_ppv>points or ceil(p_ppv*p_rate*100)/100>commission_total-company_total-intro_total-(base-total+p_discount) then raise exception 'Discount and PPV exceed the available bundle budget';end if;
 if p_status='approved' and stock<1 then raise exception 'Every selected product needs sufficient stock';end if;
 def:=jsonb_build_object('items',items,'original_total',total,'base_total',base,'original_ppv',points,'ppv',p_ppv,'discount_pkr',p_discount,'reference_rate',p_rate,'mode',p_mode,'economics_version',3,'commission_pkr',commission_total,'company_fee_pkr',company_total,'introducer_pkr',intro_total);
 if p_id is null then
  insert into public.products(id,vendor_id,name,description,category,image_url,image_urls,price_pkr,compare_at_price_pkr,stock_quantity,status,bundle_definition,country_code)
  values(pid,p_vendor,trim(p_name),'A curated bundle from '||v.business_name,'Bundles',p_images->>0,p_images,total-p_discount,total,stock,p_status::public.product_status,def,coalesce(to_jsonb(v)->>'country_code',to_jsonb(p)->>'country_code','PK'));
 else
  update public.products set vendor_id=p_vendor,name=trim(p_name),image_url=p_images->>0,image_urls=p_images,price_pkr=total-p_discount,compare_at_price_pkr=total,stock_quantity=stock,status=p_status::public.product_status,bundle_definition=def,updated_at=now() where id=pid;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'BUNDLE_SAVED','product',pid,oldrow,jsonb_build_object('name',p_name,'status',p_status,'definition',def));return pid;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_save_marketplace_bundle_type(p_id uuid, p_name text, p_units integer, p_divider numeric, p_minimum numeric, p_repeats boolean, p_max integer, p_status text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare saved uuid; previous jsonb;
begin
  if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  if p_divider is not null and (p_divider < 1 or p_divider > 99999999 or p_divider <> trunc(p_divider,4))
    then raise exception 'Enter a PPV divider of at least 1, with up to four decimals'; end if;
  if p_minimum is null or p_minimum < 0 or p_minimum <> trunc(p_minimum,2)
    then raise exception 'Enter a valid minimum product total'; end if;
  if p_status='enabled' and p_divider is null then raise exception 'Set the PPV divider before enabling this type'; end if;
  if p_id is null then
    insert into private.marketplace_bundle_types(name,required_units,ppv_divider,minimum_pkr,allow_repeats,max_per_product,status)
    values(trim(p_name),p_units,p_divider,p_minimum,p_repeats,p_max,p_status) returning id into saved;
  else
    select to_jsonb(t) into previous from private.marketplace_bundle_types t where id=p_id for update;
    update private.marketplace_bundle_types set name=trim(p_name),required_units=p_units,ppv_divider=p_divider,
      minimum_pkr=p_minimum,allow_repeats=p_repeats,max_per_product=p_max,status=p_status
    where id=p_id returning id into saved;
    if saved is null then raise exception 'Bundle type not found'; end if;
  end if;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data)
  select auth.uid(),'BUNDLE_TYPE_SAVED','bundle_type',saved,previous,to_jsonb(t)
  from private.marketplace_bundle_types t where id=saved;
  return saved;
end $function$;

CREATE OR REPLACE FUNCTION public.advance_order_status(p_order_id uuid, p_status order_status)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype; states public.order_status[]:=array['placed','confirmed','processing','shipped','delivered']::public.order_status[]; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null then raise exception 'Order not found'; end if;
 if o.status=p_status then return; end if;
 if array_position(states,p_status) is null or array_position(states,o.status) is null or array_position(states,p_status)<>array_position(states,o.status)+1 then raise exception 'Order must advance one fulfillment stage at a time'; end if;
 update public.orders set status=p_status,updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'ORDER_STATUS_CHANGED','order',o.id,jsonb_build_object('status',o.status),jsonb_build_object('status',p_status));
end $function$;

CREATE OR REPLACE FUNCTION public.cancel_unpaid_order(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype; item record; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into o from public.orders where id=p_order_id for update;
 if o.id is null or (o.buyer_id is distinct from auth.uid() and not private.has_role('admin') and not exists(select 1 from private.customer_order_funding f where f.order_id=o.id and f.customer_id=auth.uid())) then raise exception 'Order not found'; end if;
 if exists(select 1 from private.customer_order_funding where order_id=o.id and (status='submitted' or (not private.has_role('admin') and status in('approved','refund_due')))) then raise exception 'Payment is under review or paid; contact support to cancel';end if;
 if o.status='cancelled' then return; end if;
 if o.payment_status<>'unconfirmed' or o.status not in('placed','confirmed','processing') or (not private.has_role('admin') and o.status<>'placed') then raise exception 'This order cannot be cancelled here; contact the company'; end if;
 for item in select product_id,sum(quantity)::integer qty from public.order_items where order_id=o.id group by product_id order by product_id loop
  update public.products set stock_quantity=stock_quantity+item.qty,updated_at=now() where id=item.product_id;
 end loop;
 update public.orders set status='cancelled',updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'UNPAID_ORDER_CANCELLED','order',o.id,jsonb_build_object('status',o.status),jsonb_build_object('status','cancelled','inventory_restored',true));
end $function$;

CREATE OR REPLACE FUNCTION public.guest_order_status(p_order_code text, p_access_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;a public.affiliate_guest_order_approvals%rowtype;
begin
 if length(coalesce(p_access_token,''))<32 then raise exception 'Guest order access denied';end if;
 select * into o from public.orders where upper(order_code)=upper(trim(p_order_code)) and buyer_id is null and guest_access_token_hash=md5(p_access_token);
 if o.id is null then raise exception 'Guest order access denied';end if;
 select * into a from public.affiliate_guest_order_approvals where order_id=o.id;
 return jsonb_build_object('id',o.id,'order_code',o.order_code,'created_at',o.created_at,'status',o.status,'payment_status',o.payment_status,'payment_method',o.payment_method,
 'affiliate_attributed',o.selling_affiliate_id is not null,'sponsor_approval_status',a.status,'hold_mio',a.hold_mio,'required_pkr',a.required_pkr,
 'sponsor_confirmation',case when a.status in('approved','released','cancelled_refunded')then 'confirmed' when a.status='guarantee_requested'then 'awaiting sponsor guarantee' else a.status end,
 'admin_confirmation',case when o.payment_status='confirmed'or o.status in('confirmed','processing','shipped','delivered')then 'confirmed' else 'pending' end,
 'security_guarantee',a.hold_type,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'shipping_name',o.shipping_name,'shipping_phone',o.shipping_phone,'shipping_address',o.shipping_address,'shipping_city',o.shipping_city,
 'items',coalesce((select jsonb_agg(jsonb_build_object('product_name_snapshot',i.product_name_snapshot,'quantity',i.quantity,'unit_price_pkr',i.unit_price_pkr,'line_total_pkr',i.line_total_pkr)order by i.created_at)from public.order_items i where i.order_id=o.id),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.marketplace_bundle_types()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'name', name, 'required_units', required_units, 'status', status,
    'allow_repeats', allow_repeats, 'max_per_product', max_per_product,
    'minimum_pkr', minimum_pkr
  ) order by display_order),'[]'::jsonb)
  from private.marketplace_bundle_types where status in ('enabled','draft');
$function$;

CREATE OR REPLACE FUNCTION public.my_affiliate_guest_order_approvals()
 RETURNS TABLE(order_id uuid, order_code text, status text, hold_mio numeric, hold_type text, hold_amount numeric, role text, is_paid boolean, available_mio numeric, available_ppv numeric, created_at timestamp with time zone, approved_at timestamp with time zone, released_at timestamp with time zone, guest_name text, guest_city text, total_pkr numeric, payment_status payment_status, fulfillment_status order_status, item_count bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select a.order_id,o.order_code,a.status,a.hold_mio,a.hold_type,a.hold_amount,
  case when a.sponsor_id=auth.uid() then 'SELLER' else 'GUARANTOR' end,
  exists(select 1 from public.package_activations p where p.member_id=a.sponsor_id and p.status='approved'),
  coalesce((select w.balance from public.mio_wallet_accounts w where w.member_id=auth.uid()),0),
  coalesce((select sum(l.amount) from public.point_ledger l where l.member_id=auth.uid() and l.point_type='PPV'),0),
  a.created_at,a.approved_at,a.released_at,o.shipping_name,o.shipping_city,o.total_pkr,o.payment_status,o.status,count(i.id)
 from public.affiliate_guest_order_approvals a join public.orders o on o.id=a.order_id
 left join public.order_items i on i.order_id=o.id
 where (a.sponsor_id=auth.uid() or(a.status='guarantee_requested' and a.hold_member_id=auth.uid())) and not exists(select 1 from private.customer_order_funding f where f.order_id=a.order_id and f.method='ADVANCE')
 group by a.order_id,o.id order by a.created_at desc
$function$;

CREATE OR REPLACE FUNCTION public.my_direct_referrals()
 RETURNS TABLE(member_code text, full_name text, created_at timestamp with time zone, status account_status)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select mp.member_code,mp.full_name,mp.created_at,mp.status
  from public.member_profiles mp
  where (select auth.uid()) is not null and mp.sponsor_id=(select auth.uid())
  order by mp.created_at desc;
$function$;

CREATE OR REPLACE FUNCTION public.my_shopping_orders()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 return coalesce((select jsonb_agg(x.data order by x.created_at desc) from (
 select o.created_at,jsonb_build_object('id',o.id,'order_code',o.order_code,'status',o.status,'payment_status',o.payment_status,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'created_at',o.created_at,
 'shipping_name',o.shipping_name,'shipping_city',o.shipping_city,'shipping_address',o.shipping_address,
 'funding',to_jsonb(f)-'customer_id'-'transaction_key'-'reviewer_id',
 'sponsor_status',a.status,'items',(select coalesce(jsonb_agg(jsonb_build_object('name',i.product_name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_pkr)),'[]') from public.order_items i where i.order_id=o.id)) as data
 from private.customer_order_funding f join public.orders o on o.id=f.order_id left join public.affiliate_guest_order_approvals a on a.order_id=o.id
 where f.customer_id=auth.uid() order by o.created_at desc limit 100) x),'[]');
end $function$;

CREATE OR REPLACE FUNCTION public.place_checkout_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text, p_checkout_mode text, p_balance_payment_method text, p_transaction_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();oid uuid;o public.orders%rowtype;mode text:=upper(trim(coalesce(p_checkout_mode,'STANDARD')));
 method text:=upper(trim(coalesce(p_balance_payment_method,'COD')));rate numeric;shopping numeric:=0;cash numeric:=0;cod numeric:=0;
 sponsor uuid;sponsor_cash numeric:=0;sponsor_shopping numeric:=0;existing public.order_payment_allocations%rowtype;
begin
 if member is null then raise exception 'Sign in before placing an order';end if;
 if mode not in('STANDARD','SHOPPING_POINTS') then raise exception 'Choose a valid shopping mode';end if;
 if method not in('COD','MIO') then raise exception 'Choose MIO advance payment or Cash on Delivery';end if;
 perform pg_advisory_xact_lock(hashtextextended('checkout:'||member::text||':'||p_idempotency_key,0));
 select a.* into existing from public.order_payment_allocations a join public.orders x on x.id=a.order_id
  where x.buyer_id=member and x.idempotency_key=p_idempotency_key;
 if existing.order_id is not null then
  return jsonb_build_object('order_id',existing.order_id,'checkout_mode',existing.checkout_mode,'payment_method',existing.balance_payment_method,'duplicate',true);
 end if;

 oid:=public.place_affiliate_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key,null);
 select * into o from public.orders where id=oid for update;
 select * into existing from public.order_payment_allocations where order_id=oid and member_id=member;
 if existing.order_id is not null then
  return jsonb_build_object('order_id',existing.order_id,'checkout_mode',existing.checkout_mode,'payment_method',existing.balance_payment_method,'duplicate',true);
 end if;
 rate:=coalesce(nullif(o.usd_to_pkr_rate,0),300);
 insert into public.member_income_wallets(member_id) values(member) on conflict(member_id) do nothing;
 if mode='SHOPPING_POINTS' then
  shopping:=round(o.subtotal_pkr*.5,2);
  update public.member_income_wallets set shopping_points=shopping_points-shopping,updated_at=now()
   where member_id=member and shopping_points>=shopping;
  if not found then raise exception 'Shopping Points need at least PKR % for this order',shopping;end if;
  insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
   values(oid,member,'shopping',-shopping,'checkout_debit','50% paid with Shopping Points',jsonb_build_object('pkr_value',shopping),'shopping-checkout:'||oid);
 end if;
 if method='MIO' then
  perform private.require_transaction_pin(p_transaction_pin,member);
  cash:=round((o.total_pkr-shopping)/rate,8);
  update public.mio_wallet_accounts set balance=balance-cash,updated_at=now() where member_id=member and balance>=cash;
  if not found then raise exception 'Cash Wallet needs % MIO for this order',cash;end if;
  insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
   values(oid,member,'cash',-cash,'checkout_debit','Marketplace advance payment',jsonb_build_object('pkr_value',o.total_pkr-shopping,'mio_rate',rate),'cash-checkout:'||oid);
 else
  cod:=o.total_pkr-shopping;
 end if;
 insert into public.order_payment_allocations(order_id,member_id,checkout_mode,balance_payment_method,mio_rate_snapshot,shopping_points_used,cash_mio_used,cod_due_pkr)
 values(oid,member,mode,method,rate,shopping,cash,cod);
 update public.orders set checkout_mode=mode,balance_payment_method=method,mio_rate_snapshot=rate,shopping_points_used=shopping,
  cash_mio_used=cash,cod_due_pkr=cod,payment_method=case when mode='SHOPPING_POINTS' and method='MIO' then 'SHOPPING_MIO' when mode='SHOPPING_POINTS' then 'SHOPPING_COD' when method='MIO' then 'MIO' else 'COD' end,
  payment_status=case when method='MIO' then 'confirmed'::public.payment_status else 'unconfirmed'::public.payment_status end,updated_at=now() where id=oid;
 -- Only a normal full-COD order uses the 2 MIO guarantee. Split Shopping Points + COD never does.
 if mode='STANDARD' and method='COD' then
  if coalesce((select balance from public.mio_wallet_accounts where member_id=member),0)>=2 then
   perform private.require_transaction_pin(p_transaction_pin,member);
   update public.mio_wallet_accounts set balance=balance-2,updated_at=now() where member_id=member and balance>=2;
   insert into public.member_cod_guarantees(order_id,buyer_id,payer_id,funding_wallet,wallet_amount,mio_rate_snapshot,status,confirmed_at)
    values(oid,member,member,'cash',2,rate,'held',now());
   insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
    values(oid,member,'cash',-2,'guarantee_hold','Refundable COD guarantee',jsonb_build_object('mio_amount',2),'cod-guarantee-hold:'||oid);
  else
   select sponsor_id into sponsor from public.member_profiles where user_id=member;
   if sponsor is null then raise exception 'A direct sponsor is required because your Cash Wallet has less than 2 MIO';end if;
   select coalesce(balance,0) into sponsor_cash from public.mio_wallet_accounts where member_id=sponsor;
   select coalesce(shopping_points,0) into sponsor_shopping from public.member_income_wallets where member_id=sponsor;
   if coalesce(sponsor_cash,0)<2 and coalesce(sponsor_shopping,0)<2*rate then
    raise exception 'Sponsor cannot receive this request: 2 MIO or equivalent Shopping Points are required';
   end if;
   insert into public.member_cod_guarantees(order_id,buyer_id,sponsor_id,mio_rate_snapshot,status)
    values(oid,member,sponsor,rate,'pending_sponsor');
   perform private.notify_member(sponsor,'guarantee','COD guarantee request','A direct member needs a refundable 2 MIO order guarantee.','order',oid,jsonb_build_object('buyer_id',member));
  end if;
 end if;
 perform private.notify_member(member,'order','Order placed','Your marketplace order has been placed.','order',oid,jsonb_build_object('checkout_mode',mode,'balance_method',method));
 return jsonb_build_object('order_id',oid,'checkout_mode',mode,'payment_method',method,'shopping_points_used',shopping,'cash_mio_used',cash,'cod_due_pkr',cod,'duplicate',false);
end$function$;

CREATE OR REPLACE FUNCTION public.place_configured_bundle_order(p_type uuid, p_vendor uuid, p_bundle_items jsonb, p_quote_key text, p_request jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_requester text;
  v_request_key text := p_request->>'p_idempotency_key';
  member uuid := auth.uid();
  access_token text := p_request->>'p_access_token';
  regular_items jsonb := coalesce(p_request->'p_items','[]');
  guest_email text := lower(trim(p_request->>'p_guest_email'));
  bundle_product_id uuid := gen_random_uuid();
  quote jsonb;
  placed jsonb;
  items jsonb;
  country text;
begin

  if member is null and (private.resolve_shopping_referral(p_request->>'p_affiliate_code') is null or coalesce(p_request->>'p_funding_method','SPONSOR')<>'SPONSOR') then
    raise exception 'Guest checkout needs a valid User referral and sponsor hold; advance payment requires an account';
  end if;
  if length(coalesce(v_request_key,'')) not between 12 and 120 then raise exception 'Invalid checkout request key'; end if;
  if member is null then
    if length(coalesce(access_token,''))<32 or guest_email is null then raise exception 'Guest checkout details required'; end if;
    v_requester:='guest:'||guest_email||':'||md5(access_token);
  else v_requester:=member::text;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('bundle-checkout:'||v_requester||':'||v_request_key,0));
  select result into placed from private.configured_bundle_checkouts c
    where c.requester=v_requester and c.request_key=v_request_key;
  if found then return placed||jsonb_build_object('duplicate',true); end if;
  if jsonb_typeof(regular_items)<>'array' or jsonb_array_length(regular_items)>29 then raise exception 'Invalid basket'; end if;
  if jsonb_typeof(p_bundle_items) is distinct from 'array' or jsonb_array_length(p_bundle_items)>99 then raise exception 'Invalid bundle selection'; end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('mio-reference-price-pkr',0));
  perform 1 from private.marketplace_bundle_types where private.marketplace_bundle_types.id=p_type for share;
  perform 1 from public.vendors where public.vendors.id=p_vendor for share;
  perform p.id from public.products p
    where p.id in (select (x->>'product_id')::uuid from jsonb_array_elements(p_bundle_items||regular_items) x)
    order by p.id for update;
  quote:=private.configured_bundle_quote(p_type,p_vendor,p_bundle_items);
  if not (quote->>'complete')::boolean then raise exception 'Complete the required bundle units'; end if;
  if p_quote_key is distinct from quote->>'quote_key' then
    return jsonb_build_object('quote_changed',true,'quote',quote);
  end if;
  if not (quote->>'meets_minimum')::boolean then
    raise exception 'Final bundle product total must be at least PKR % before delivery',quote->>'minimum_pkr';
  end if;
  select coalesce(to_jsonb(v)->>'country_code','PK') into country from public.vendors v where v.id=p_vendor;
  perform set_config('mio.configured_bundle_id',bundle_product_id::text,true);
  insert into public.products(id,vendor_id,name,description,category,image_urls,price_pkr,compare_at_price_pkr,stock_quantity,status,bundle_definition,country_code)
  values(bundle_product_id,p_vendor,quote->>'name','Customer-selected bundle','Bundles','[]',(quote->>'price_pkr')::numeric,
    (quote->>'original_total')::numeric,1,'approved',quote,country);
  items:=regular_items||jsonb_build_array(jsonb_build_object('product_id',bundle_product_id,'quantity',1));
  if member is null then
    placed:=public.place_guest_affiliate_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',
      p_request->>'p_shipping_address',p_request->>'p_shipping_city',guest_email,'bundle:'||v_request_key,
      access_token,p_request->>'p_affiliate_code');
  elsif (exists(select 1 from private.customer_identities where user_id=member) and not exists(select 1 from public.member_profiles where user_id=member)) or nullif(trim(p_request->>'p_affiliate_code'),'') is not null then
    placed:=public.place_shopping_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',p_request->>'p_shipping_address',p_request->>'p_shipping_city','bundle:'||v_request_key,coalesce(p_request->>'p_funding_method','ADVANCE'),p_request->>'p_affiliate_code');
  elsif coalesce((p_request->>'maintenance')::boolean,false) then
    placed:=public.place_maintenance_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',
      p_request->>'p_shipping_address',p_request->>'p_shipping_city','bundle:'||v_request_key,p_request->>'p_checkout_mode',
      p_request->>'p_balance_payment_method',p_request->>'p_transaction_pin');
  else
    placed:=public.place_checkout_order(items,p_request->>'p_shipping_name',p_request->>'p_shipping_phone',
      p_request->>'p_shipping_address',p_request->>'p_shipping_city','bundle:'||v_request_key,p_request->>'p_checkout_mode',
      p_request->>'p_balance_payment_method',p_request->>'p_transaction_pin');
  end if;
  if not exists(select 1 from public.order_items where order_id=(placed->>'order_id')::uuid and product_id=bundle_product_id)
    then raise exception 'Order request key is already in use'; end if;
  update public.products p set status='archived' where p.id=bundle_product_id;
  perform set_config('mio.configured_bundle_id','',true);
  insert into private.configured_bundle_checkouts values(v_requester,v_request_key,placed);
  return placed;
end $function$;

CREATE OR REPLACE FUNCTION public.place_shopping_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text, p_funding_method text DEFAULT 'ADVANCE'::text, p_affiliate_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c private.customer_identities%rowtype;email text;code text:=nullif(trim(p_affiliate_code),'');placed jsonb;o public.orders%rowtype;requirement jsonb;key text;
begin
 if auth.uid() is null then raise exception 'Create or sign in to your User account before placing an order';end if;
 insert into private.customer_identities(user_id,full_name,phone,country_code,sponsor_id,terms_accepted_at)
 select user_id,full_name,phone,coalesce(country_code,'PK'),sponsor_id,terms_accepted_at from public.member_profiles where user_id=auth.uid() and terms_accepted_at is not null
 on conflict(user_id) do nothing;
 select * into c from private.customer_identities where user_id=auth.uid();
 if c.user_id is null then raise exception 'Shopping User account required';end if;
 if c.terms_accepted_at is null then raise exception 'Complete your shopping profile and consent first';end if;
 select lower(u.email) into email from auth.users u where u.id=auth.uid() and u.email_confirmed_at is not null;
 if email is null then raise exception 'Verify your email before placing an order';end if;
 if p_funding_method is null or p_funding_method not in('ADVANCE','SPONSOR') then raise exception 'Choose advance payment or sponsor hold';end if;
 if length(coalesce(p_idempotency_key,'')) not between 12 and 150 then raise exception 'Valid order request reference required';end if;
 key:='customer:'||auth.uid()||':'||p_idempotency_key;
 perform pg_advisory_xact_lock(hashtextextended(key,0));
 select x.* into o from public.orders x join private.customer_order_funding f on f.order_id=x.id and f.customer_id=auth.uid()
 where x.idempotency_key='guest:'||email||':'||key;
 if found then return jsonb_build_object('order_id',o.id,'order_code',o.order_code,'status',o.status,'duplicate',true);end if;
 if code is null and c.sponsor_id is not null then select member_code into code from public.member_profiles where user_id=c.sponsor_id;end if;
 if p_funding_method='SPONSOR' and code is null then raise exception 'A linked sponsor is required';end if;

 if code is not null then
  select member_code into code from public.member_profiles where user_id=private.resolve_shopping_referral(code);
  if code is null then raise exception 'User referral link is no longer valid';end if;
 end if;
 placed:=private.place_shopping_order_core(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,email,key,gen_random_uuid()::text,code);
 select * into o from public.orders where id=(placed->>'order_id')::uuid for update;
 requirement:=private.customer_order_requirement(o.total_pkr,o.usd_to_pkr_rate);
 insert into private.customer_order_funding(order_id,customer_id,method,required_pkr,hold_mio,rate_snapshot,status)
 values(o.id,auth.uid(),p_funding_method,(requirement->>'required_pkr')::numeric,(requirement->>'hold_mio')::numeric,o.usd_to_pkr_rate,case p_funding_method when 'ADVANCE' then 'awaiting_payment' else 'pending' end);
 update public.affiliate_guest_order_approvals set hold_mio=(requirement->>'hold_mio')::numeric,hold_amount=(requirement->>'hold_mio')::numeric,
 required_pkr=(requirement->>'required_pkr')::numeric,rate_snapshot=o.usd_to_pkr_rate where order_id=o.id;
 update public.orders set cod_due_pkr=total_pkr where id=o.id;
 return placed||requirement||jsonb_build_object('funding_method',p_funding_method);
end $function$;

CREATE OR REPLACE FUNCTION public.quote_marketplace_bundle(p_type uuid, p_vendor uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select private.configured_bundle_quote(p_type,p_vendor,p_items);
$function$;

CREATE OR REPLACE FUNCTION public.review_affiliate_guest_order(p_order_id uuid, p_approve boolean, p_transaction_pin text, p_idempotency_key text, p_hold_method text DEFAULT 'MIO'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();a public.affiliate_guest_order_approvals%rowtype;o public.orders%rowtype;
 item record;paid boolean;ppv_balance numeric;direct_sponsor uuid;method text:=upper(coalesce(p_hold_method,'MIO'));
begin
 if member is null then raise exception 'Sign in first';end if;
 if length(trim(coalesce(p_idempotency_key,'')))<8 then raise exception 'Valid request reference required';end if;
 perform pg_advisory_xact_lock(hashtextextended('affiliate-approval:'||p_order_id::text,0));
 if p_approve is null then raise exception 'Choose approve or reject';end if;
 perform 1 from public.orders where id=p_order_id for update;
 if exists(select 1 from private.customer_order_funding f where f.order_id=p_order_id and f.method<>'SPONSOR') then raise exception 'Customer selected advance payment, not sponsor hold';end if;
 if exists(select 1 from public.orders where id=p_order_id and status in('cancelled','returned')) then raise exception 'This order is already closed';end if;

 select * into a from public.affiliate_guest_order_approvals where order_id=p_order_id for update;
 if a.order_id is null or a.sponsor_id<>member then raise exception 'Affiliate order approval not found';end if;
 select * into o from public.orders where id=p_order_id for update;
 if a.status not in('pending','guarantee_requested') then return jsonb_build_object('order_id',a.order_id,'status',a.status,'hold_type',a.hold_type);end if;
 if o.status in('cancelled','returned') then raise exception 'This order is already closed';end if;
 if not p_approve then
  for item in select product_id,sum(quantity)::integer qty from public.order_items where order_id=o.id group by product_id order by product_id loop
   update public.products set stock_quantity=stock_quantity+item.qty,updated_at=now() where id=item.product_id;
  end loop;
  update public.orders set status='cancelled',updated_at=now() where id=o.id;
  update public.affiliate_guest_order_approvals set status='rejected',rejected_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
  return jsonb_build_object('order_id',o.id,'status','rejected');
 end if;
 select exists(select 1 from public.package_activations p where p.member_id=member and p.status='approved') into paid;
 if paid and method<>'MIO' then raise exception 'Paid members must use the Cash Wallet guarantee';end if;
 if method='SPONSOR' then
  if paid then raise exception 'Sponsor guarantee is available to free accounts only';end if;
  select sponsor_id into direct_sponsor from public.member_profiles where user_id=member;
  if direct_sponsor is null then raise exception 'No direct sponsor is available for this request';end if;
  update public.affiliate_guest_order_approvals set status='guarantee_requested',hold_type='SPONSOR_MIO',hold_member_id=direct_sponsor,
   guarantee_requested_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
  return jsonb_build_object('order_id',o.id,'status','guarantee_requested');
 end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 if method='PPV' then
  if paid then raise exception 'PPV guarantee is available to free accounts only';end if;
  select coalesce(sum(amount),0) into ppv_balance from public.point_ledger where member_id=member and point_type='PPV';
  if ppv_balance<a.hold_mio then raise exception 'Insufficient PPV for the required order guarantee';end if;
  insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
   values(member,'PPV',-a.hold_mio,o.id,'debit','affiliate-ppv-hold:'||o.id) on conflict(idempotency_key)do nothing;
 else
  update public.mio_wallet_accounts set balance=balance-a.hold_mio,updated_at=now() where member_id=member and balance>=a.hold_mio;
  if not found then raise exception 'Cash Wallet balance is below the required order guarantee';end if;
  insert into public.mio_ledger(member_id,amount,action,source_order_id,reason,idempotency_key)
   values(member,-a.hold_mio,'affiliate_order_hold',o.id,'Refundable guest-order security guarantee','affiliate-hold:'||o.id)on conflict(idempotency_key)do nothing;
  method:='MIO';
 end if;
 update public.affiliate_guest_order_approvals set status='approved',hold_amount=a.hold_mio,hold_type=method,hold_member_id=member,approved_at=now(),approval_request_key=p_idempotency_key,updated_at=now() where order_id=o.id;
 return jsonb_build_object('order_id',o.id,'status','approved','hold_type',method,'hold_amount',a.hold_mio);
end
$function$;

CREATE OR REPLACE FUNCTION public.set_company_delivery(p_fee numeric, p_policy text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ver integer; begin
 if not private.has_role('admin') then raise exception 'Workspace access required'; end if;
 if p_fee is null or p_fee<0 or p_fee>100000 or p_fee<>round(p_fee,2) or length(trim(coalesce(p_policy,'')))<10 then raise exception 'Enter a valid shipping charge and delivery policy'; end if;
 perform pg_advisory_xact_lock(hashtextextended('delivery-config',0));
 select coalesce(max(version),0)+1 into ver from public.system_config where config_key='DELIVERY';
 update public.system_config set effective_to=now() where config_key='DELIVERY' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('DELIVERY',ver,jsonb_build_object('fee_pkr',p_fee,'policy',trim(p_policy)),now(),auth.uid());
 insert into public.audit_logs(actor_id,action,entity_type,after_data) values(auth.uid(),'DELIVERY_CONFIGURED','system_config',jsonb_build_object('version',ver,'fee_pkr',p_fee));
end $function$;

CREATE OR REPLACE FUNCTION public.shopping_order_details(p_order uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$select private.shopping_order_details(p_order)$function$;

CREATE OR REPLACE FUNCTION private.create_affiliate_guest_approval_trigger()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$begin
 perform private.create_affiliate_guest_approval(new.id);return new;
end$function$;

CREATE OR REPLACE FUNCTION private.enforce_affiliate_guest_approval()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare approval text;
begin
 if exists(select 1 from private.customer_order_funding where order_id=old.id and method='ADVANCE') then return new;end if;
 if old.buyer_id is not null or old.selling_affiliate_id is null then return new;end if;
 select status into approval from public.affiliate_guest_order_approvals where order_id=old.id;
 if coalesce(approval,'pending') not in('approved','released') and(
  (new.payment_status='confirmed' and old.payment_status<>'confirmed')or
  (new.status in('confirmed','processing','shipped','delivered')and new.status<>old.status)
 )then raise exception 'Selling member approval is required before processing this guest order';end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.guard_cod_order_progress()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if (new.status<>old.status or new.payment_status<>old.payment_status) and exists(
  select 1 from public.member_cod_guarantees g where g.order_id=new.id and g.status not in('held','released','cancelled_refunded')
 ) and new.status not in('cancelled','returned') then raise exception 'COD guarantee approval is required before processing this order';end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.post_vendor_sale()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare i public.order_items%rowtype; cumul numeric; previous numeric; k text; amount numeric; beneficiary uuid; state text; rate numeric; begin
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' then
  for i in select * from public.order_items where order_id=new.id loop
   if i.distribution_basis<>'sale_v2' then raise exception 'Legacy unpaid order requires explicit reconciliation';end if;
   insert into public.vendor_income_ledger(vendor_id,order_item_id,gross_pkr,commission_pkr,net_pkr) values(i.vendor_id,i.id,i.line_total_pkr,i.commission_pool_pkr,i.line_total_pkr-i.commission_pool_pkr) on conflict(order_item_id) do nothing;
   cumul:=0;previous:=0;
   foreach k in array array['company','buyer_discount','affiliate','sponsor','second_upline','introducer','network_rewards','unallocated'] loop
    rate:=(i.commission_split_snapshot->>k)::numeric;cumul:=cumul+rate;
    amount:=case k when 'buyer_discount' then i.buyer_discount_pkr else greatest(0,least(i.commission_pool_pkr-previous,round(coalesce(i.reward_basis_pkr_snapshot,i.line_total_pkr)*cumul/100,2)-previous)) end;previous:=previous+amount;
    beneficiary:=case k when 'buyer_discount' then new.buyer_id when 'company' then (select company_id from private.network_foundation limit 1) when 'affiliate' then i.affiliate_id_snapshot when 'sponsor' then i.sponsor_id_snapshot when 'second_upline' then i.second_upline_id_snapshot when 'introducer' then i.introducer_id_snapshot end;
    state:=case when k='buyer_discount' then 'discount_applied' when k='network_rewards' or (k='introducer' and i.economics_version=3) then 'reserved' when beneficiary is null then 'held' else 'earned' end;
    if amount>0 then insert into public.commission_allocations(order_item_id,share_kind,beneficiary_id,amount_pkr,status) values(i.id,k,beneficiary,amount,state) on conflict(order_item_id,share_kind) do nothing;end if;
   end loop;
   if previous<>i.commission_pool_pkr then raise exception 'Sale allocation does not reconcile';end if;
  end loop;perform private.post_shopping_rewards(new.id);
 end if;return new;
end $function$;

CREATE OR REPLACE FUNCTION private.prepare_order_rewards()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare o public.orders%rowtype;b numeric;r record;recipient uuid;amt numeric;cumul numeric:=0;previous numeric:=0;intro numeric;
begin
 select * into o from public.orders where id=new.order_id;if o.reward_version<>2 then return new;end if;
 b:=trunc(new.ppv_per_unit_snapshot*new.quantity,4);
 update public.orders set reward_ppv_total=reward_ppv_total+b where id=o.id;
 if o.reward_mode='MIO' and b>0 then
  for r in select * from (values
   (1,case when o.selling_affiliate_id is null then 'cashback' else 'affiliate' end,o.reward_owner_id,.70),
   (2,'sponsor',o.reward_sponsor_id,.20),(3,'second_sponsor',o.reward_second_sponsor_id,.10)
  ) x(seq,kind,beneficiary,rate) order by seq loop
   recipient:=r.beneficiary;if o.selling_affiliate_id is not null and recipient=o.buyer_id then recipient:=null;end if;
   cumul:=cumul+r.rate;amt:=trunc(b*cumul,4)-previous;previous:=previous+amt;
   insert into public.ecommerce_rewards(order_id,order_item_id,beneficiary_id,reward_kind,base_points,rate,amount,status)
   values(o.id,new.id,recipient,r.kind,b,r.rate,amt,'pending_delivery') on conflict(order_item_id,reward_kind) do nothing;
  end loop;
 end if;
 if new.economics_version=3 then
  intro:=trunc((new.economics_snapshot->>'introducer')::numeric*new.quantity/o.usd_to_pkr_rate,4);
  if intro>0 then insert into public.ecommerce_rewards(order_id,order_item_id,beneficiary_id,reward_kind,base_points,rate,amount,status)
   values(o.id,new.id,new.introducer_id_snapshot,'vendor_introducer',trunc((new.economics_snapshot->>'commission')::numeric*new.quantity/o.usd_to_pkr_rate,4),.10,intro,'pending_delivery') on conflict(order_item_id,reward_kind) do nothing;end if;
 end if;return new;
end $function$;

CREATE OR REPLACE FUNCTION private.refund_checkout_and_guarantee()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a public.order_payment_allocations%rowtype;g public.member_cod_guarantees%rowtype;
begin
 if new.status not in('cancelled','returned') and not(new.status='delivered' and new.payment_status='confirmed') then return new;end if;
 select * into g from public.member_cod_guarantees where order_id=new.id for update;
 if g.order_id is not null and g.status='held' then
  if g.funding_wallet='cash' then update public.mio_wallet_accounts set balance=balance+g.wallet_amount,updated_at=now() where member_id=g.payer_id;
  else update public.member_income_wallets set shopping_points=shopping_points+g.wallet_amount,updated_at=now() where member_id=g.payer_id;end if;
  insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
   values(new.id,g.payer_id,g.funding_wallet,g.wallet_amount,'guarantee_refund','COD guarantee returned',jsonb_build_object('mio_amount',2),'cod-guarantee-refund:'||new.id) on conflict(idempotency_key)do nothing;
  update public.member_cod_guarantees set status=case when new.status in('cancelled','returned') then 'cancelled_refunded' else 'released' end,released_at=now(),updated_at=now() where order_id=new.id;
  perform private.notify_member(g.payer_id,'refund','COD guarantee returned','The refundable order guarantee has returned to its original wallet.','order',new.id);
 elsif g.order_id is not null and g.status='pending_sponsor' and new.status in('cancelled','returned') then
  update public.member_cod_guarantees set status='cancelled_refunded',released_at=now(),updated_at=now() where order_id=new.id;
 end if;
 if new.status in('cancelled','returned') then
  select * into a from public.order_payment_allocations where order_id=new.id for update;
  if a.order_id is not null and a.refunded_at is null then
   if a.cash_mio_used>0 then
    update public.mio_wallet_accounts set balance=balance+a.cash_mio_used,updated_at=now() where member_id=a.member_id;
    insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,idempotency_key)
     values(new.id,a.member_id,'cash',a.cash_mio_used,'checkout_refund','Marketplace Cash Wallet refund','cash-checkout-refund:'||new.id) on conflict do nothing;
   end if;
   if a.shopping_points_used>0 then
    update public.member_income_wallets set shopping_points=shopping_points+a.shopping_points_used,updated_at=now() where member_id=a.member_id;
    insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,idempotency_key)
     values(new.id,a.member_id,'shopping',a.shopping_points_used,'checkout_refund','Marketplace Shopping Points refund','shopping-checkout-refund:'||new.id) on conflict do nothing;
   end if;
   update public.order_payment_allocations set refunded_at=now() where order_id=new.id;
   perform private.notify_member(a.member_id,'refund','Order payment refunded','Wallet payments for the closed order were returned.','order',new.id);
  end if;
 end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.release_order_rewards()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  o public.orders%rowtype;
  ppv numeric; total numeric; funding numeric; r record; outcome jsonb;
  net_base numeric; dp_base numeric; gp_base numeric; bp_base numeric; brp_base numeric;
  direct_amount numeric; remaining_base numeric;
  fee_rate numeric := .10; cap numeric := 110; used numeric := 0;
begin
  if exists(select 1 from public.maintenance_orders where order_id=new.id) then perform private.release_maintenance_order(new.id);return new;end if;
select * into o from public.orders where id = new.id for update;
  if o.status in ('cancelled','returned') and o.rewards_credited_at is null then
    update public.ecommerce_rewards set status = 'cancelled'
    where order_id = o.id and status = 'pending_delivery';
    return new;
  end if;
  if o.status <> 'delivered' or o.payment_status <> 'confirmed' or o.rewards_credited_at is not null then return new; end if;

  select coalesce(sum(trunc(coalesce(ppv_per_unit_snapshot,unit_price_pkr/o.usd_to_pkr_rate)*quantity,4)),0)
    into ppv from public.order_items where order_id=o.id;
  if o.reward_owner_id is null then
    update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;
    perform private.sync_company_treasury(); return new;
  end if;
  if o.reward_mode='PPV' then
    select s.cap,s.used into cap,used from private.shopping_ppv_cap_status(o.reward_owner_id)s;
    ppv:=least(ppv,greatest(0,cap-used));
  end if;
  if o.reward_version=1 then
    o.reward_owner_id:=o.buyer_id;
    perform private.post_shopping_rewards(o.id);
  else
    select coalesce(sum(a.amount_pkr),0) into funding
    from public.commission_allocations a join public.order_items i on i.id=a.order_item_id
    where i.order_id=o.id and a.share_kind='network_rewards';
    if ppv*coalesce(nullif(o.usd_to_pkr_rate,0),300)>funding then raise exception 'Order rewards exceed verified funding'; end if;
    if o.reward_mode='MIO' then
      for r in select id from public.ecommerce_rewards where order_id=o.id order by id loop
        perform private.credit_ecommerce_reward(r.id);
      end loop;
      update public.orders set rewards_credited_at=now(),ppv_generated=0 where id=o.id;
      perform private.sync_company_treasury(); return new;
    elsif ppv>0 then
      fee_rate:=coalesce((o.rules_snapshot->>'shopping_admin_fee_rate')::numeric,.10);
      if fee_rate<0 or fee_rate>1 then raise exception 'Invalid shopping admin fee rate'; end if;
      net_base:=trunc(ppv*(1-fee_rate),4);
      dp_base:=trunc(net_base*coalesce((o.rules_snapshot->>'shopping_dp_factor')::numeric,1),4);
      select coalesce(max(c.nominal),0) into direct_amount
      from private.mlm_point_candidates(o.reward_owner_id,dp_base,0,o.rules_snapshot)c
      where c.method='direct';
      if direct_amount<0 or direct_amount>dp_base then raise exception 'Shopping direct bonus exceeds available net base'; end if;
      remaining_base:=greatest(0,dp_base-direct_amount);
      gp_base:=trunc(remaining_base*coalesce((o.rules_snapshot->>'generation_plan_rate')::numeric,.5),4);
      bp_base:=trunc(remaining_base*coalesce((o.rules_snapshot->>'binary_plan_rate')::numeric,.5),4);
      brp_base:=bp_base;
      insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,dp,gp,bp,brp,binary_reserve_mio)
      values(o.id,o.reward_owner_id,funding,net_base,dp_base,gp_base,bp_base,brp_base,
        trunc(bp_base*coalesce((o.rules_snapshot->>'binary_pool_rate')::numeric,.35),4))
      on conflict do nothing;
      if found then
        outcome:=private.distribute_mlm_event(o.reward_owner_id,dp_base,o.id,null,o.rules_snapshot);
        update public.shopping_reward_events
        set direct_generation_mio=(outcome->>'direct_generation')::numeric,
            single_line_mio=(outcome->>'single_line')::numeric where order_id=o.id;
      end if;
    end if;
  end if;
  if ppv>0 then
    insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key)
    values(o.reward_owner_id,'PPV',ppv,o.id,'credit','order:'||o.id::text||':ppv')
    on conflict(idempotency_key) do nothing;
  end if;
  if o.reward_mode='PPV' and used+ppv>=cap then
    update public.member_profiles set shopping_reward_mode='MIO',updated_at=now()
    where user_id=o.reward_owner_id;
  end if;
  update public.orders set ppv_generated=ppv,rewards_credited_at=now() where id=o.id;
  select coalesce(sum(amount),0) into total from public.point_ledger
  where member_id=o.reward_owner_id and point_type='PPV';
  perform private.activate_next_ppv_package(o.reward_owner_id,o.id,total);
  perform private.sync_company_treasury(); return new;
end
$function$;

CREATE OR REPLACE FUNCTION private.release_vendor_introducer_reward()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;begin
 if new.status='delivered' and new.payment_status='confirmed' then
  for r in select e.id from public.ecommerce_rewards e join public.order_items i on i.id=e.order_item_id where e.order_id=new.id and i.economics_version=3 and e.reward_kind='vendor_introducer' loop perform private.credit_ecommerce_reward(r.id);end loop;
 end if;return new;
end $function$;

CREATE OR REPLACE FUNCTION private.snapshot_commission()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare p public.products%rowtype;v public.vendors%rowtype;e jsonb;base numeric;commission numeric;company numeric;intro numeric;funding numeric;reserve_amount numeric;rate numeric;budget numeric;
begin
 select * into p from public.products where id=new.product_id;select * into v from public.vendors where id=new.vendor_id;
 select usd_to_pkr_rate into rate from public.orders where id=new.order_id;
 if rate is null or rate<=0 then raise exception 'Order conversion rate missing';end if;
 base:=p.vendor_submitted_price_pkr;
 if p.bundle_definition is null then
  e:=private.product_economics(base,p.price_pkr,coalesce(p.commission_rate_override,v.commission_rate),rate,p.ppv_per_unit,'reserve');
  company:=(e->>'company_fee')::numeric;intro:=(e->>'introducer')::numeric;commission:=(e->>'commission')::numeric;funding:=(e->>'network_funding')::numeric;reserve_amount:=(e->>'reserve')::numeric;
 else
  if coalesce((p.bundle_definition->>'economics_version')::integer,0)<>3 then raise exception 'Bundle needs a pricing review before purchase';end if;
  if exists(select 1 from jsonb_array_elements(p.bundle_definition->'items') item
    left join public.products component on component.id=(item->>'product_id')::uuid
    where component.id is null or component.status<>'approved' or component.vendor_id<>p.vendor_id
      or component.price_pkr is distinct from (item->>'price_pkr')::numeric
      or component.ppv_per_unit is distinct from (item->>'ppv')::numeric
      or coalesce(component.commission_rate_override,v.commission_rate) is distinct from (item->>'commission_rate')::numeric) then
    raise exception 'Bundle product pricing changed; refresh bundle settings before purchase';
  end if;
  commission:=(p.bundle_definition->>'commission_pkr')::numeric;company:=(p.bundle_definition->>'company_fee_pkr')::numeric;intro:=(p.bundle_definition->>'introducer_pkr')::numeric;
  funding:=ceil(p.ppv_per_unit*rate*100)/100;reserve_amount:=commission-company-intro-(base-p.price_pkr)-funding;
  if reserve_amount<0 then raise exception 'Bundle PPV exceeds current funded budget';end if;
  e:=jsonb_build_object('reference_rate',rate,'policy','reserve');
 end if;
 new.economics_version:=3;new.economics_snapshot:=e||jsonb_build_object('commission',commission,'company_fee',company,'introducer',intro,'network_funding',funding,'reserve',reserve_amount,'assigned_ppv',p.ppv_per_unit,'mio_rates',jsonb_build_array(.70,.20,.10));
 new.reward_basis_pkr_snapshot:=base*new.quantity;new.sale_discount_pkr_snapshot:=(base-p.price_pkr)*new.quantity;
 new.commission_rate_snapshot:=commission/base;new.company_owned_snapshot:=v.is_company_owned;new.introducer_id_snapshot:=v.introduced_by;
 new.awarded_rate_snapshot:=funding/base;new.award_scope_snapshot:='product';new.award_policy_leftover_pkr:=reserve_amount*new.quantity;
 new.ppv_per_unit_snapshot:=p.ppv_per_unit;new.distribution_basis:='sale_v2';new.buyer_discount_pkr:=0;
 new.commission_pool_pkr:=(commission-(base-p.price_pkr))*new.quantity;
 new.commission_split_snapshot:=jsonb_build_object('company',company/base*100,'buyer_discount',0,'affiliate',0,'sponsor',0,'second_upline',0,'introducer',intro/base*100,'network_rewards',funding/base*100,'unallocated',reserve_amount/base*100);
 return new;
end $function$;

CREATE OR REPLACE FUNCTION private.snapshot_item_ppv()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare p public.products%rowtype;begin
 if new.economics_version=3 then return new;end if;

 select * into p from public.products where id=new.product_id;
 new.reward_basis_pkr_snapshot:=p.vendor_submitted_price_pkr*new.quantity;
 new.sale_discount_pkr_snapshot:=greatest(new.reward_basis_pkr_snapshot-new.unit_price_pkr*new.quantity,0);
 new.awarded_rate_snapshot:=coalesce(p.awarded_rate_override,(select awarded_rate from public.vendors where id=new.vendor_id),new.commission_rate_snapshot-.05-new.sale_discount_pkr_snapshot/nullif(new.reward_basis_pkr_snapshot,0));
 new.award_scope_snapshot:=case when p.awarded_rate_override is not null then 'product' else 'vendor' end;
 new.ppv_per_unit_snapshot:=trunc(p.vendor_submitted_price_pkr*new.awarded_rate_snapshot/(select coalesce(nullif(o.usd_to_pkr_rate,0),300) from public.orders o where o.id=new.order_id),4);
 new.award_policy_leftover_pkr:=trunc(new.reward_basis_pkr_snapshot*greatest(0,new.commission_rate_snapshot-.05-new.sale_discount_pkr_snapshot/nullif(new.reward_basis_pkr_snapshot,0)-new.awarded_rate_snapshot),4);return new;
end $function$;

CREATE OR REPLACE FUNCTION private.snapshot_mlm_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 new.rules_snapshot:=private.current_mlm_rules();
 if TG_TABLE_NAME='package_activations' then new.binary_reserve_mio:=case when new.source<>'SHOPPING_PPV' then trunc(new.bp*coalesce((new.rules_snapshot->>'binary_pool_rate')::numeric,.35),4) else 0 end;end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION private.snapshot_order_reward_mode()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare code text:=upper(trim(coalesce(current_setting('mio.affiliate_code',true),'')));
  seller uuid; cap_locked boolean:=false;
begin
  if code<>'' then
    select user_id into seller from public.member_profiles
    where (upper(member_code)=code or upper(replace(member_code,'MIO-',''))=code
      or upper(referral_code)=regexp_replace(code,'-[LR]$',''))
      and status in('active','inactive') and terms_accepted_at is not null;
    if seller is null then raise exception 'Selling link is no longer valid'; end if;
  end if;
  if seller=new.buyer_id then seller:=null; end if;
  new.selling_affiliate_id:=seller; new.reward_owner_id:=coalesce(seller,new.buyer_id);
  select case when private.package_eligible(user_id) then shopping_reward_mode else 'PPV' end,sponsor_id
    into new.reward_mode,new.reward_sponsor_id from public.member_profiles where user_id=new.reward_owner_id;
  if new.reward_owner_id is not null then
    select s.locked into cap_locked from private.shopping_ppv_cap_status(new.reward_owner_id)s;
  end if;
  if cap_locked then
    new.reward_mode:='MIO';
    update public.member_profiles set shopping_reward_mode='MIO',updated_at=now()
      where user_id=new.reward_owner_id and shopping_reward_mode<>'MIO';
  end if;
  select sponsor_id into new.reward_second_sponsor_id
    from public.member_profiles where user_id=new.reward_sponsor_id;
  new.reward_mode:=coalesce(new.reward_mode,'PPV'); return new;
end
$function$;

CREATE OR REPLACE FUNCTION private.snapshot_retail_price()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ begin
 select compare_at_price_pkr into new.compare_at_price_pkr_snapshot from public.products where id=new.product_id;
 new.retail_saving_pkr:=greatest(coalesce(new.compare_at_price_pkr_snapshot,new.unit_price_pkr)-new.unit_price_pkr,0)*new.quantity;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION public.place_affiliate_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text, p_affiliate_code text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare oid uuid; begin
 perform set_config('mio.affiliate_code',coalesce(trim(p_affiliate_code),''),true);
 oid:=public.place_marketplace_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key);
 perform set_config('mio.affiliate_code','',true);return oid;
end $function$;

CREATE OR REPLACE FUNCTION public.place_marketplace_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare oid uuid; fee numeric; disc numeric; gross numeric; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended('order-policy:'||auth.uid()::text||':'||p_idempotency_key,0));
 select id into oid from public.orders where buyer_id=auth.uid() and idempotency_key=p_idempotency_key;
 if oid is not null then return oid; end if;
 select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
 if fee is null then raise exception 'Delivery charges are awaiting company configuration'; end if;
 oid:=private.place_marketplace_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key);
 select coalesce(sum(buyer_discount_pkr),0),sum(line_total_pkr) into disc,gross from public.order_items where order_id=oid;
 update public.orders set discount_pkr=disc,subtotal_pkr=gross-disc,delivery_fee_pkr=fee,total_pkr=gross-disc+fee where id=oid;
 return oid;
end $function$;

CREATE OR REPLACE FUNCTION private.place_marketplace_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  buyer uuid := (select auth.uid());
  order_id uuid := gen_random_uuid();
  order_code text;
  rate numeric(14,6);
  item record;
  prod public.products%rowtype;
  item_subtotal numeric(14,2) := 0;
  existing_id uuid;
begin
  if buyer is null then raise exception 'Sign in before placing an order'; end if;
  if not exists(select 1 from public.member_profiles where user_id=buyer and status in ('active','inactive') and terms_accepted_at is not null) then raise exception 'Active account required'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Basket is empty'; end if;
  if jsonb_array_length(p_items)>30 then raise exception 'Too many basket lines'; end if;
  if length(coalesce(p_idempotency_key,''))<12 then raise exception 'Invalid order request key'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order:'||buyer::text||':'||p_idempotency_key,0));
  select id into existing_id from public.orders where buyer_id=buyer and idempotency_key=buyer::text||':'||p_idempotency_key;
  if existing_id is not null then return existing_id; end if;
  if length(trim(coalesce(p_shipping_name,'')))<2 or length(trim(coalesce(p_shipping_phone,'')))<5
    or length(trim(coalesce(p_shipping_address,'')))<5 or length(trim(coalesce(p_shipping_city,'')))<2 then
    raise exception 'Complete delivery details are required';
  end if;
  rate:=private.current_mio_reference_price();

  order_code := 'MIO-' || upper(substr(replace(order_id::text,'-',''),1,10));
  insert into public.orders(id,order_code,buyer_id,subtotal_pkr,delivery_fee_pkr,total_pkr,payment_method,payment_status,status,
    shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key,usd_to_pkr_rate)
  values(order_id,order_code,buyer,0,0,0,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),
    trim(p_shipping_address),trim(p_shipping_city),buyer::text||':'||p_idempotency_key,rate);

  if exists(select 1 from jsonb_to_recordset(p_items) as x(product_id uuid,quantity integer) where product_id is null or quantity is null or quantity<1 or quantity>99) then raise exception 'Invalid basket line'; end if;
  for item in select product_id,sum(quantity)::integer as quantity from jsonb_to_recordset(p_items) as x(product_id uuid,quantity integer) group by product_id order by product_id loop
    if item.quantity is null or item.quantity<1 or item.quantity>99 then raise exception 'Invalid item quantity'; end if;
    select * into prod from public.products where id=item.product_id for update;
    if prod.id is null or prod.status <> 'approved' or prod.stock_quantity < item.quantity then
      raise exception 'A selected product is unavailable or out of stock';
    end if;
    if not exists(select 1 from public.vendors v where v.id=prod.vendor_id and v.status='active') then raise exception 'Seller is not active'; end if;
    update public.products set stock_quantity=stock_quantity-item.quantity,updated_at=now() where id=prod.id;
    insert into public.order_items(order_id,product_id,vendor_id,product_name_snapshot,unit_price_pkr,quantity)
      values(order_id,prod.id,prod.vendor_id,prod.name,prod.price_pkr,item.quantity);
    item_subtotal := item_subtotal+(prod.price_pkr*item.quantity);
  end loop;
  if item_subtotal<=0 then raise exception 'Basket total must be positive'; end if;
  update public.orders set subtotal_pkr=item_subtotal,total_pkr=item_subtotal where id=order_id;
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data)
    values(buyer,'MARKETPLACE_ORDER_PLACED','order',order_id,
      jsonb_build_object('order_code',order_code,'subtotal_pkr',item_subtotal,'usd_to_pkr_rate',rate,'ppv_status','pending payment confirmation'));
  return order_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.review_cod_guarantee(p_order_id uuid, p_approve boolean, p_wallet text, p_transaction_pin text, p_idempotency_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();g public.member_cod_guarantees%rowtype;wallet text:=lower(trim(coalesce(p_wallet,'cash')));amount numeric;
begin
 if member is null then raise exception 'Sign in first';end if;
 perform pg_advisory_xact_lock(hashtextextended('cod-guarantee:'||p_order_id::text,0));
 select * into g from public.member_cod_guarantees where order_id=p_order_id for update;
 if g.order_id is null or g.sponsor_id<>member or g.status<>'pending_sponsor' then raise exception 'Pending sponsor guarantee request not found';end if;
 if not p_approve then
  update public.member_cod_guarantees set status='declined',updated_at=now() where order_id=p_order_id;
  perform private.notify_member(g.buyer_id,'guarantee','Guarantee declined','Your sponsor declined the COD guarantee request.','order',p_order_id);
  return jsonb_build_object('order_id',p_order_id,'status','declined');
 end if;
 if wallet not in('cash','shopping') then raise exception 'Choose Cash Wallet or Shopping Points';end if;
 perform private.require_transaction_pin(p_transaction_pin,member);
 amount:=case when wallet='cash' then 2 else 2*g.mio_rate_snapshot end;
 if wallet='cash' then
  update public.mio_wallet_accounts set balance=balance-amount,updated_at=now() where member_id=member and balance>=amount;
 else
  insert into public.member_income_wallets(member_id) values(member) on conflict(member_id)do nothing;
  update public.member_income_wallets set shopping_points=shopping_points-amount,updated_at=now() where member_id=member and shopping_points>=amount;
 end if;
 if not found then raise exception 'Selected sponsor wallet has insufficient balance';end if;
 insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
 values(p_order_id,member,wallet,-amount,'guarantee_hold','Refundable sponsor COD guarantee',jsonb_build_object('mio_amount',2,'mio_rate',g.mio_rate_snapshot),p_idempotency_key);
 update public.member_cod_guarantees set payer_id=member,funding_wallet=wallet,wallet_amount=amount,status='held',confirmed_at=now(),updated_at=now() where order_id=p_order_id;
 perform private.notify_member(g.buyer_id,'guarantee','COD guarantee approved','Your sponsor approved the refundable order guarantee.','order',p_order_id,jsonb_build_object('wallet',wallet));
 return jsonb_build_object('order_id',p_order_id,'status','held','wallet',wallet,'amount',amount);
end$function$;

CREATE OR REPLACE FUNCTION public.submit_shopping_advance_with_proof(p_order_id uuid, p_account_id uuid, p_transaction_id text, p_proof_path text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f private.customer_order_funding%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 perform 1 from public.orders where id=p_order_id for update;
 select * into f from private.customer_order_funding where order_id=p_order_id for update;
 if f.customer_id is distinct from auth.uid() then raise exception 'Order not found';end if;
 if p_proof_path is null or split_part(p_proof_path,'/',1)<>auth.uid()::text or split_part(p_proof_path,'/',2)<>p_order_id::text or not exists(
 select 1 from storage.objects where bucket_id='customer-payment-proofs' and name=p_proof_path
 and metadata->>'mimetype' in('image/jpeg','image/png','image/webp') and (metadata->>'size')::numeric between 1 and 5242880
 ) then raise exception 'Upload a valid payment screenshot for this order';end if;
 if f.status='submitted' and f.proof_path is distinct from p_proof_path then raise exception 'Payment is already under review';end if;
 perform public.submit_shopping_advance(p_order_id,p_account_id,p_transaction_id);
 update private.customer_order_funding set proof_path=p_proof_path where order_id=p_order_id and status='submitted';
end $function$;

CREATE OR REPLACE FUNCTION public.admin_shopping_payments()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 return jsonb_build_object('accounts',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from private.customer_payment_accounts a),'[]'),
 'summary',(select jsonb_build_object('submitted',count(*) filter(where status='submitted'),'refund_due',count(*) filter(where status='refund_due'),'pending_pkr',coalesce(sum(required_pkr) filter(where status='submitted'),0)) from private.customer_order_funding where method='ADVANCE'),
 'payments',coalesce((select jsonb_agg(x.data order by x.priority,x.created_at desc) from (select f.created_at,case f.status when 'submitted' then 0 when 'refund_due' then 1 else 2 end as priority,to_jsonb(f)||jsonb_build_object('order_code',o.order_code,'total_pkr',o.total_pkr,'cod_due_pkr',o.cod_due_pkr,'customer_name',o.shipping_name,'order_status',o.status) as data from private.customer_order_funding f join public.orders o on o.id=f.order_id where f.method='ADVANCE' order by priority,f.created_at desc limit 100) x),'[]'));
end $function$;

CREATE OR REPLACE FUNCTION public.my_cod_guarantee_requests()
 RETURNS TABLE(order_id uuid, order_code text, buyer_name text, total_pkr numeric, status text, mio_rate_snapshot numeric, sponsor_cash_mio numeric, sponsor_shopping_points numeric, requested_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select g.order_id,o.order_code,p.full_name,o.total_pkr,g.status,g.mio_rate_snapshot,
  coalesce(w.balance,0),coalesce(i.shopping_points,0),g.requested_at
 from public.member_cod_guarantees g join public.orders o on o.id=g.order_id
 join public.member_profiles p on p.user_id=g.buyer_id
 left join public.mio_wallet_accounts w on w.member_id=g.sponsor_id
 left join public.member_income_wallets i on i.member_id=g.sponsor_id
 where g.sponsor_id=auth.uid() order by g.requested_at desc
$function$;

CREATE OR REPLACE FUNCTION public.place_maintenance_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text, p_checkout_mode text, p_balance_payment_method text, p_transaction_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();r jsonb:=private.current_maintenance_rules();code text;target numeric;placed jsonb;oid uuid;ppv numeric;
begin
 if not private.monthly_required(member) then raise exception 'Monthly maintenance is disabled for your country';end if; if member is null or not private.package_eligible(member) then raise exception 'Active package required';end if;
 if coalesce((r->>'enabled')::boolean,false)=false then raise exception 'Maintenance is unavailable';end if;
 if upper(coalesce(p_checkout_mode,'')) not in('STANDARD','SHOPPING_POINTS') then raise exception 'Choose a valid payment option';end if;
 code:=private.current_package_code(member);target:=(r->'monthly_ppv'->>code)::numeric;
 if target is null or target<=0 then raise exception 'Package maintenance rule is missing';end if;
 placed:=private.place_maintenance_checkout(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,
  p_idempotency_key,p_checkout_mode,p_balance_payment_method,p_transaction_pin);
 oid:=(placed->>'order_id')::uuid;
 if coalesce((placed->>'duplicate')::boolean,false) then
  if not exists(select 1 from public.maintenance_orders where order_id=oid and member_id=member) then raise exception 'Order key already belongs to regular shopping';end if;
  return placed||jsonb_build_object('maintenance',true);
 end if;
 select coalesce(sum(ppv_per_unit_snapshot*quantity),0) into ppv from public.order_items where order_id=oid;
 if ppv<=0 then raise exception 'Select products with PPV for monthly maintenance';end if;
 insert into public.maintenance_orders(order_id,member_id,package_code,required_ppv,config_snapshot)
 values(oid,member,code,target,r);
 -- The maintenance buyer receives no cashback, affiliate or ordinary shopping reward.
 update public.ecommerce_rewards set status='cancelled' where order_id=oid and status in('pending_delivery','held_activation');
 return placed||jsonb_build_object('maintenance',true,'order_ppv',ppv,'required_ppv',target);
end$function$;

CREATE OR REPLACE FUNCTION public.submit_shopping_advance(p_order_id uuid, p_account_id uuid, p_transaction_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare f private.customer_order_funding%rowtype;a private.customer_payment_accounts%rowtype;o public.orders%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select * into o from public.orders where id=p_order_id for update;
 select * into f from private.customer_order_funding where order_id=p_order_id for update;
 if f.customer_id is distinct from auth.uid() then raise exception 'Order not found';end if;
 if f.method<>'ADVANCE' or o.status<>'placed' then raise exception 'Order is not awaiting an advance';end if;
 if f.status='approved' then raise exception 'Payment already approved';end if;
 if f.status='submitted' then
  if f.payment_account_id=p_account_id and f.transaction_key=lower(regexp_replace(trim(p_transaction_id),'\s','','g')) then return;end if;
  raise exception 'Payment is already under review';
 end if;
 if f.status not in('awaiting_payment','rejected') then raise exception 'Payment submission is not available';end if;
 if length(trim(coalesce(p_transaction_id,''))) not between 4 and 120 then raise exception 'Enter a valid transaction ID';end if;
 select * into a from private.customer_payment_accounts where id=p_account_id and active;
 if a.id is null then raise exception 'Select an active payment account';end if;
 update private.customer_order_funding set status='submitted',payment_account_id=a.id,account_snapshot=to_jsonb(a)-'created_at'-'updated_at',
 transaction_id=trim(p_transaction_id),transaction_key=lower(regexp_replace(trim(p_transaction_id),'\s','','g')),submitted_at=now(),review_note=null where order_id=p_order_id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'CUSTOMER_ADVANCE_SUBMITTED','order',p_order_id,jsonb_build_object('required_pkr',f.required_pkr,'transaction_id',trim(p_transaction_id)));
end $function$;
