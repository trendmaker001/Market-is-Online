create table private.marketplace_bundle_types (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 80),
  required_units integer not null check (required_units between 2 and 99),
  ppv_divider numeric(12,4) check (ppv_divider >= 1),
  minimum_pkr numeric(14,2) not null default 3000 check (minimum_pkr >= 0),
  allow_repeats boolean not null default true,
  max_per_product integer check (max_per_product between 1 and required_units),
  status text not null default 'draft' check (status in ('draft','enabled','disabled')),
  display_order integer generated always as identity,
  check (status <> 'enabled' or ppv_divider is not null)
);
insert into private.marketplace_bundle_types(name,required_units,ppv_divider,status)
values ('Bundle 1',3,3,'enabled'),('Bundle 2',5,4,'enabled'),('Bundle 3',7,5,'enabled'),
       ('Bundle 4',10,6,'enabled'),('Bundle 5',15,null,'draft');

create table private.configured_bundle_checkouts (
  requester text not null,
  request_key text not null,
  result jsonb not null,
  primary key (requester,request_key)
);
revoke all on private.marketplace_bundle_types,private.configured_bundle_checkouts from public,anon,authenticated;
alter table public.order_items add column configured_bundle_snapshot jsonb;

create function public.marketplace_bundle_types() returns jsonb
language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'name', name, 'required_units', required_units, 'status', status,
    'allow_repeats', allow_repeats, 'max_per_product', max_per_product,
    'minimum_pkr', minimum_pkr
  ) order by display_order),'[]'::jsonb)
  from private.marketplace_bundle_types where status in ('enabled','draft');
$$;

create function public.admin_marketplace_bundle_types() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required'; end if;
  return jsonb_build_object(
    'types', (select coalesce(jsonb_agg(to_jsonb(t) order by display_order),'[]'::jsonb) from private.marketplace_bundle_types t),
    'reference_rate', (select (config_value#>>'{}')::numeric from public.system_config
      where config_key='MIO_REFERENCE_PRICE_PKR' and effective_to is null order by version desc limit 1)
  );
end $$;

create function public.admin_save_marketplace_bundle_type(
  p_id uuid, p_name text, p_units integer, p_divider numeric, p_minimum numeric,
  p_repeats boolean, p_max integer, p_status text
) returns uuid language plpgsql security definer set search_path='' as $$
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
end $$;

create function private.configured_bundle_quote(p_type uuid,p_vendor uuid,p_items jsonb)
returns jsonb language plpgsql stable set search_path='' as $$
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
end $$;

create function public.quote_marketplace_bundle(p_type uuid,p_vendor uuid,p_items jsonb)
returns jsonb language sql stable security definer set search_path='' as $$
  select private.configured_bundle_quote(p_type,p_vendor,p_items);
$$;

-- A configured order uses the same product, stock, commission and reward triggers
-- as existing bundle orders. Its internal product exists in the catalog only
-- inside the checkout transaction and is archived before commit.
do $migration$
declare definition text; needle text := 'if b is null then return new;end if;';
begin
  definition:=pg_get_functiondef('private.bundle_product_rules()'::regprocedure);
  if strpos(definition,needle)=0 then raise exception 'Expected bundle rules hook is missing'; end if;
  definition:=replace(definition,needle,needle||$hook$
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
$hook$);
  execute definition;
  definition:=pg_get_functiondef('private.sync_bundle_inventory(uuid)'::regprocedure);
  if strpos(definition,'where bundle_definition @>')=0 then raise exception 'Expected inventory hook is missing'; end if;
  execute replace(definition,'where bundle_definition @>','where status<>''archived'' and bundle_definition->>''kind'' is distinct from ''configured'' and bundle_definition @>');
end
$migration$;

create function private.snapshot_configured_bundle() returns trigger
language plpgsql security definer set search_path='' as $$
declare definition jsonb; rate numeric;
begin
  select bundle_definition into definition from public.products where id=new.product_id;
  if definition->>'kind'='configured' then
    select usd_to_pkr_rate into rate from public.orders where id=new.order_id;
    if rate is distinct from (definition->>'reference_rate')::numeric then raise exception 'Bundle conversion rate changed. Review a new quote'; end if;
    new.configured_bundle_snapshot:=definition;
  end if;
  return new;
end $$;
create trigger zzzz_snapshot_configured_bundle before insert on public.order_items
  for each row execute function private.snapshot_configured_bundle();

create function public.place_configured_bundle_order(
  p_type uuid,p_vendor uuid,p_bundle_items jsonb,p_quote_key text,p_request jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
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
end $$;

-- Recalculate available PPV when the existing rate changes while preserving
-- the approved selling price and any previously funded product discount.
do $migration$
declare definition text; needle text := 'base:=new.vendor_submitted_price_pkr;';
begin
  definition:=pg_get_functiondef('private.formula_product_ppv()'::regprocedure);
  if strpos(definition,needle)=0 then raise exception 'Expected product economics hook is missing'; end if;
  execute replace(definition,needle,needle||$hook$
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
$hook$);
  definition:=pg_get_functiondef('public.admin_set_mio_reference_price(numeric)'::regprocedure);
  needle:='update public.products set ppv_per_unit=ppv_per_unit where vendor_submitted_price_pkr>0 and status<>''archived'';';
  if strpos(definition,needle)=0 then raise exception 'Expected rate refresh hook is missing'; end if;
  execute replace(definition,needle,$hook$
    perform set_config('mio.reprice_ppv_only','on',true);
    update public.products set ppv_per_unit=ppv_per_unit
      where vendor_submitted_price_pkr>0 and status<>'archived' and bundle_definition is null;
    perform set_config('mio.reprice_ppv_only','off',true);
$hook$);
end
$migration$;

select set_config('mio.archive_legacy_bundles','on',true);
update public.products set status='archived',updated_at=now()
where bundle_definition is not null and status<>'archived';
select set_config('mio.archive_legacy_bundles','off',true);

revoke execute on function public.admin_save_bundle(uuid,uuid,text,jsonb,numeric,numeric,numeric,jsonb,text,text) from public,anon,authenticated;
revoke all on function private.configured_bundle_quote(uuid,uuid,jsonb),private.snapshot_configured_bundle() from public,anon,authenticated;
revoke all on function public.admin_marketplace_bundle_types(),public.admin_save_marketplace_bundle_type(uuid,text,integer,numeric,numeric,boolean,integer,text)
  from public,anon,authenticated;
grant execute on function public.admin_marketplace_bundle_types(),public.admin_save_marketplace_bundle_type(uuid,text,integer,numeric,numeric,boolean,integer,text) to authenticated;
revoke all on function public.marketplace_bundle_types(),public.quote_marketplace_bundle(uuid,uuid,jsonb),public.place_configured_bundle_order(uuid,uuid,jsonb,text,jsonb) from public,anon,authenticated;
grant execute on function public.marketplace_bundle_types(),public.quote_marketplace_bundle(uuid,uuid,jsonb),public.place_configured_bundle_order(uuid,uuid,jsonb,text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
