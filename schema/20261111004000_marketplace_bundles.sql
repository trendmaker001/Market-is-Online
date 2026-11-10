-- Bundles are first-class catalog products. Existing checkout/payment/reward paths
-- remain authoritative; component stock and an immutable contents snapshot are added.
alter table public.products add column bundle_definition jsonb;
alter table public.order_items add column bundle_components_snapshot jsonb;
alter table public.order_items add column bundle_inventory_returned_at timestamptz;
create index products_bundle_components_idx on public.products using gin(bundle_definition jsonb_path_ops) where bundle_definition is not null;

create function private.bundle_product_rules() returns trigger language plpgsql security definer set search_path='' as $$
declare b jsonb:=new.bundle_definition; v public.vendors%rowtype; base numeric; price numeric; points numeric; rate numeric;
begin
 if tg_op='UPDATE' and old.bundle_definition is not null and b is null then raise exception 'A bundle cannot become a standalone product';end if;
 if b is null then return new;end if;
 if not private.has_role('admin') and (tg_op='INSERT' or (to_jsonb(new)-array['stock_quantity','updated_at','ppv_per_unit','awarded_rate_override','vendor_submitted_price_pkr']) is distinct from (to_jsonb(old)-array['stock_quantity','updated_at','ppv_per_unit','awarded_rate_override','vendor_submitted_price_pkr'])) then raise exception 'Only admin can manage bundles';end if;
 select * into v from public.vendors where id=new.vendor_id;
 base:=(b->>'base_total')::numeric; price:=(b->>'original_total')::numeric-(b->>'discount_pkr')::numeric;
 points:=(b->>'ppv')::numeric;rate:=(b->>'reference_rate')::numeric;
 if base is null or price is null or points is null or rate is null or base<=0 or price<=0 or points<0 or rate<=0 or price<>new.price_pkr then raise exception 'Invalid bundle price or PPV';end if;
 if round(points*rate,2)>round(base*(v.commission_rate-.05)-(base-price),2) then raise exception 'Bundle discount and PPV exceed the funded budget';end if;
 new.vendor_submitted_price_pkr:=base;new.ppv_per_unit:=points;
 new.awarded_rate_override:=trunc(points*rate/base,6);
 return new;
end $$;
revoke all on function private.bundle_product_rules() from public,anon,authenticated;
-- Run before ordinary formulas, then restore the bundle's explicit PPV after them.
create trigger aa_bundle_rules before insert or update on public.products for each row execute function private.bundle_product_rules();
create trigger zzz_bundle_rules before insert or update on public.products for each row execute function private.bundle_product_rules();
do $$declare f text;begin
 f:=pg_get_functiondef('private.formula_product_ppv()'::regprocedure);
 f:=regexp_replace(f,'\mbegin\M', 'begin if new.bundle_definition is not null then return new;end if;', 'i');
 if f not like '%bundle_definition%' then raise exception 'Product formula hook missing';end if;execute f;
end $$;

create function public.admin_save_bundle(p_id uuid,p_vendor uuid,p_name text,p_items jsonb,p_ppv numeric,p_discount numeric,p_rate numeric,p_images jsonb,p_status text default 'draft',p_mode text default 'manual') returns uuid
language plpgsql security definer set search_path='' as $$
declare pid uuid:=coalesce(p_id,gen_random_uuid());r record;p public.products%rowtype;v public.vendors%rowtype;oldrow jsonb;
 items jsonb:='[]';total numeric:=0;base numeric:=0;points numeric:=0;stock integer:=2147483647;def jsonb;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if length(trim(coalesce(p_name,''))) not between 3 and 100 or p_status not in ('draft','approved','archived') or p_mode not in ('manual','half_ppv') then raise exception 'Enter a bundle name and valid publication status';end if;
 if p_ppv is null or p_ppv<0 or p_ppv<>trunc(p_ppv,4) or p_rate is null or p_rate<=0 or p_rate>100000 or p_discount is null or p_discount<0 or p_discount<>round(p_discount,2) then raise exception 'Enter valid PPV (up to 4 decimals), discount and conversion rate';end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 2 and 20 then raise exception 'Select 2 to 20 different products';end if;
 if p_images is null or jsonb_typeof(p_images)<>'array' or jsonb_array_length(p_images) not between 1 and 8 or exists(select 1 from jsonb_array_elements_text(p_images) x where x !~ '^(https://[^[:space:]]+|/[a-zA-Z0-9][^[:space:]]*)$') then raise exception 'Add 1 to 8 valid product images';end if;
 select * into v from public.vendors where id=p_vendor and status='active';if not found then raise exception 'Select an active vendor';end if;
 if p_id is not null then select to_jsonb(x) into oldrow from public.products x where id=p_id and bundle_definition is not null for update;if not found then raise exception 'Bundle not found';end if;end if;
 if exists(select 1 from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) where product_id is null or quantity is null or quantity not between 1 and 99) or (select count(distinct x->>'product_id') from jsonb_array_elements(p_items)x)<>jsonb_array_length(p_items) then raise exception 'Use distinct products and quantities from 1 to 99';end if;
 for r in select * from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) order by product_id loop
  select * into p from public.products where id=r.product_id for update;
  if not found or p.vendor_id<>p_vendor or p.status<>'approved' or p.bundle_definition is not null then raise exception 'Select approved individual products from the chosen vendor';end if;
  total:=total+p.price_pkr*r.quantity;base:=base+p.vendor_submitted_price_pkr*r.quantity;points:=points+coalesce(p.ppv_per_unit,0)*r.quantity;
  stock:=least(stock,p.stock_quantity/r.quantity);
  items:=items||jsonb_build_array(jsonb_build_object('product_id',p.id,'quantity',r.quantity,'name',p.name,'image_url',p.image_url,'price_pkr',p.price_pkr,'ppv',p.ppv_per_unit));
 end loop;
 if p_discount>=total or p_ppv>points or round(p_ppv*p_rate,2)>round(base*(v.commission_rate-.05)-(base-total+p_discount),2) then raise exception 'Discount and PPV exceed the available bundle budget';end if;
 if p_status='approved' and stock<1 then raise exception 'Every selected product needs sufficient stock';end if;
 def:=jsonb_build_object('items',items,'original_total',total,'base_total',base,'original_ppv',points,'ppv',p_ppv,'discount_pkr',p_discount,'reference_rate',p_rate,'mode',p_mode);
 if p_id is null then
  insert into public.products(id,vendor_id,name,description,category,image_url,image_urls,price_pkr,compare_at_price_pkr,stock_quantity,status,bundle_definition,country_code)
  values(pid,p_vendor,trim(p_name),'A curated bundle from '||v.business_name,'Bundles',p_images->>0,p_images,total-p_discount,total,stock,p_status::public.product_status,def,coalesce(to_jsonb(v)->>'country_code',to_jsonb(p)->>'country_code','PK'));
 else
  update public.products set vendor_id=p_vendor,name=trim(p_name),image_url=p_images->>0,image_urls=p_images,price_pkr=total-p_discount,compare_at_price_pkr=total,stock_quantity=stock,status=p_status::public.product_status,bundle_definition=def,updated_at=now() where id=pid;
 end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'BUNDLE_SAVED','product',pid,oldrow,jsonb_build_object('name',p_name,'status',p_status,'definition',def));return pid;
end $$;
revoke all on function public.admin_save_bundle(uuid,uuid,text,jsonb,numeric,numeric,numeric,jsonb,text,text) from public,anon;
grant execute on function public.admin_save_bundle(uuid,uuid,text,jsonb,numeric,numeric,numeric,jsonb,text,text) to authenticated;

create function private.sync_bundle_inventory(p_component uuid) returns void language plpgsql security definer set search_path='' as $$
declare b record;available integer;
begin
 for b in select id,bundle_definition from public.products where bundle_definition @> jsonb_build_object('items',jsonb_build_array(jsonb_build_object('product_id',p_component))) order by id loop
  select min(case when p.status='approved' and p.price_pkr=(x->>'price_pkr')::numeric and p.ppv_per_unit=(x->>'ppv')::numeric then p.stock_quantity/(x->>'quantity')::integer else 0 end) into available
  from jsonb_array_elements(b.bundle_definition->'items') x join public.products p on p.id=(x->>'product_id')::uuid;
  update public.products set stock_quantity=coalesce(available,0) where id=b.id and stock_quantity is distinct from coalesce(available,0);
 end loop;
end $$;
create function private.bundle_component_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.bundle_definition is not null then return new;end if;
 -- Changed component economics make offers unavailable until admin saves again.
 perform private.sync_bundle_inventory(new.id);return new;
end $$;
create trigger bundle_component_changed after update on public.products for each row when (old.* is distinct from new.*) execute function private.bundle_component_changed();

create function private.reserve_bundle_components() returns trigger language plpgsql security definer set search_path='' as $$
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
end $$;
create trigger aaa_reserve_bundle_components before insert on public.order_items for each row execute function private.reserve_bundle_components();

-- Override only bundle snapshots, before AFTER INSERT reward preparation runs.
create function private.snapshot_bundle_reward() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.products%rowtype;v public.vendors%rowtype;rate numeric;available numeric;base numeric;discount numeric;
begin
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
end $$;
create trigger zzz_snapshot_bundle_reward before insert on public.order_items for each row execute function private.snapshot_bundle_reward();

create function private.return_bundle_inventory() returns trigger language plpgsql security definer set search_path='' as $$
declare i record;r record;
begin
 if new.status not in('cancelled','returned') or old.status in('cancelled','returned') then return new;end if;
 for i in select * from public.order_items where order_id=new.id and bundle_components_snapshot is not null and bundle_inventory_returned_at is null for update loop
  for r in select (x->>'product_id')::uuid id,(x->>'quantity')::integer qty from jsonb_array_elements(i.bundle_components_snapshot)x order by 1 loop
   update public.products set stock_quantity=stock_quantity+r.qty,updated_at=now() where id=r.id;
  end loop;
  update public.order_items set bundle_inventory_returned_at=now() where id=i.id;
 end loop;return new;
end $$;
create trigger zzz_return_bundle_inventory after update of status on public.orders for each row execute function private.return_bundle_inventory();
revoke all on function private.sync_bundle_inventory(uuid),private.bundle_component_changed(),private.reserve_bundle_components(),private.snapshot_bundle_reward(),private.return_bundle_inventory() from public,anon,authenticated;

create function public.admin_save_category_display(p_categories jsonb,p_motion jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v integer;r jsonb;begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_motion is null or (p_motion->>'speed') not in('slow','normal','fast') or (p_motion->>'direction') not in('left','right') then raise exception 'Select a scrolling speed and direction';end if;
 if exists(select 1 from jsonb_array_elements(p_categories)x where coalesce(x->>'image_url','')<>'' and (x->>'image_url') !~ '^(https://[^[:space:]]+|/[a-zA-Z0-9][^[:space:]]*)$') then raise exception 'Use a valid category image URL';end if;
 perform pg_advisory_xact_lock(hashtextextended('marketplace-category-display',0));
 r:=public.admin_set_marketplace_categories(p_categories);
 select coalesce(max(version),0)+1 into v from public.system_config where config_key='MARKETPLACE_CATEGORY_MOTION';
 update public.system_config set effective_to=clock_timestamp() where config_key='MARKETPLACE_CATEGORY_MOTION' and effective_to is null;
 insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('MARKETPLACE_CATEGORY_MOTION',v,jsonb_build_object('enabled',coalesce((p_motion->>'enabled')::boolean,false),'speed',p_motion->>'speed','direction',p_motion->>'direction'),clock_timestamp(),auth.uid());
 return r;
end $$;
revoke all on function public.admin_save_category_display(jsonb,jsonb) from public,anon;
grant execute on function public.admin_save_category_display(jsonb,jsonb) to authenticated;

-- The order builder namespaces request keys. Re-check its returned order before
-- touching payment wallets so a retried checkout cannot attempt a second debit.
do $$declare f text;begin
 f:=pg_get_functiondef('public.place_checkout_order(jsonb,text,text,text,text,text,text,text,text)'::regprocedure);
 f:=replace(f,'select * into o from public.orders where id=oid for update;', $body$select * into o from public.orders where id=oid for update;
 select * into existing from public.order_payment_allocations where order_id=oid and member_id=member;
 if existing.order_id is not null then
  return jsonb_build_object('order_id',existing.order_id,'checkout_mode',existing.checkout_mode,'payment_method',existing.balance_payment_method,'duplicate',true);
 end if;$body$);
 if f not like '%order_id=oid and member_id=member%' then raise exception 'Checkout retry hook missing';end if;execute f;
end $$;
notify pgrst,'reload schema';
