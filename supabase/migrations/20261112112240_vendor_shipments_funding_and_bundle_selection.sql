-- Vendor shipments are immutable price snapshots. Legacy orders retain their original totals.
alter table public.member_cod_guarantees drop constraint member_cod_guarantees_mio_amount_check;
alter table public.member_cod_guarantees add constraint member_cod_guarantees_mio_amount_check check(mio_amount>0);
-- Keep the previous response contract available while older clients refresh.
create function private.my_cod_guarantee_requests_v2()
returns table(order_id uuid,order_code text,buyer_name text,total_pkr numeric,status text,mio_rate_snapshot numeric,sponsor_cash_mio numeric,sponsor_shopping_points numeric,requested_at timestamptz,mio_amount numeric)
language sql stable security definer set search_path='' as $$
 select g.order_id,o.order_code,p.full_name,o.total_pkr,g.status,g.mio_rate_snapshot,
 coalesce(w.balance,0),coalesce(i.shopping_points,0),g.requested_at,g.mio_amount
 from public.member_cod_guarantees g join public.orders o on o.id=g.order_id
 join public.member_profiles p on p.user_id=g.buyer_id
 left join public.mio_wallet_accounts w on w.member_id=g.sponsor_id
 left join public.member_income_wallets i on i.member_id=g.sponsor_id
 where auth.uid() is not null and g.sponsor_id=auth.uid() order by g.requested_at desc
$$;
create function public.my_cod_guarantee_requests_v2()
returns table(order_id uuid,order_code text,buyer_name text,total_pkr numeric,status text,mio_rate_snapshot numeric,sponsor_cash_mio numeric,sponsor_shopping_points numeric,requested_at timestamptz,mio_amount numeric)
language sql stable security invoker set search_path='' as $$ select * from private.my_cod_guarantee_requests_v2() $$;
revoke all on function private.my_cod_guarantee_requests_v2(),public.my_cod_guarantee_requests_v2() from public,anon,authenticated;
grant execute on function private.my_cod_guarantee_requests_v2(),public.my_cod_guarantee_requests_v2() to authenticated;
alter table public.order_items add column if not exists sku_snapshot text;
alter table public.order_items add column if not exists image_url_snapshot text;
alter table private.marketplace_bundle_types add column allow_multiple_vendors boolean not null default false;
update private.marketplace_bundle_types set allow_multiple_vendors=true where name in ('Bundle 3','Bundle 4','Bundle 5','Bundle 6');

create table private.order_vendor_shipments(
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id),
 vendor_id uuid not null references public.vendors(id),
 shipment_code text not null unique,
 invoice_number text not null unique,
 vendor_snapshot jsonb not null,
 gross_pkr numeric(14,2) not null check(gross_pkr>=0),
 discount_pkr numeric(14,2) not null check(discount_pkr>=0),
 delivery_pkr numeric(14,2) not null check(delivery_pkr>=0),
 total_pkr numeric(14,2) not null check(total_pkr>=0),
 status public.order_status not null default 'placed',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(order_id,vendor_id),
 check(total_pkr=gross_pkr-discount_pkr+delivery_pkr)
);
alter table private.order_vendor_shipments enable row level security;
revoke all on private.order_vendor_shipments from public,anon,authenticated;
create index order_vendor_shipments_vendor_idx on private.order_vendor_shipments(vendor_id,created_at desc);

create function private.snapshot_invoice_product() returns trigger language plpgsql security definer set search_path='' as $$
begin
 select sku,image_url into new.sku_snapshot,new.image_url_snapshot from public.products where id=new.product_id;
 return new;
end $$;
create trigger snapshot_invoice_product before insert on public.order_items for each row execute function private.snapshot_invoice_product();

create function private.basket_delivery_fee(p_items jsonb) returns numeric language plpgsql stable set search_path='' as $$
declare fee numeric;vendors integer;
begin
 select (config_value->>'fee_pkr')::numeric into fee from public.system_config where config_key='DELIVERY' and effective_to is null order by version desc limit 1;
 if fee is null or fee<0 then raise exception 'Delivery charges are awaiting company configuration';end if;
 select count(distinct p.vendor_id) into vendors from jsonb_to_recordset(p_items) x(product_id uuid,quantity integer) join public.products p on p.id=x.product_id;
 return round(fee*vendors,2);
end $$;

create function private.ensure_order_shipments(p_order uuid) returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;r record;n integer;idx integer:=0;previous_fee numeric:=0;fee numeric;net numeric;extra numeric;
begin
 select * into o from public.orders where id=p_order for update;
 if o.id is null or exists(select 1 from private.order_vendor_shipments where order_id=p_order) then return;end if;
 select count(distinct vendor_id) into n from public.order_items where order_id=p_order;
 if n=0 then return;end if;
 for r in select i.vendor_id,sum(i.line_total_pkr-i.buyer_discount_pkr) net,
 sum(i.buyer_discount_pkr+coalesce((i.configured_bundle_snapshot->>'discount_pkr')::numeric,0)*i.quantity) discount
 from public.order_items i where i.order_id=p_order group by i.vendor_id order by i.vendor_id loop
  idx:=idx+1;fee:=round(o.delivery_fee_pkr*idx/n,2)-previous_fee;previous_fee:=previous_fee+fee;
  insert into private.order_vendor_shipments(order_id,vendor_id,shipment_code,invoice_number,vendor_snapshot,gross_pkr,discount_pkr,delivery_pkr,total_pkr,status)
  select o.id,r.vendor_id,o.order_code||'-V'||lpad(idx::text,2,'0'),'INV-'||o.order_code||'-V'||lpad(idx::text,2,'0'),
   jsonb_build_object('name',v.business_name,'phone',v.contact_phone,'email',v.contact_email,'country',coalesce(v.country_code,'PK')),
   r.net+r.discount,r.discount,fee,r.net+fee,o.status from public.vendors v where v.id=r.vendor_id;
 end loop;
 if (select sum(total_pkr) from private.order_vendor_shipments where order_id=p_order)<>o.total_pkr then raise exception 'Vendor totals do not reconcile with the order';end if;
end $$;

-- A hold is security. It never counts as customer payment or reduces COD.
create function private.order_funding_state(p_order uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.orders%rowtype;f private.customer_order_funding%rowtype;g public.member_cod_guarantees%rowtype;a public.affiliate_guest_order_approvals%rowtype;pay public.order_payment_allocations%rowtype;
 ready boolean:=false;state text:='missing';method text:='Hold / Advance';amount numeric:=0;paid numeric:=0;closed boolean;
begin
 select * into o from public.orders where id=p_order;if not found then return null;end if;
 select * into f from private.customer_order_funding where order_id=p_order;
 select * into g from public.member_cod_guarantees where order_id=p_order;
 select * into a from public.affiliate_guest_order_approvals where order_id=p_order;
 select * into pay from public.order_payment_allocations where order_id=p_order;
 closed:=o.status in ('cancelled','returned');
 paid:=least(o.total_pkr,case when f.status='refunded' then 0 else coalesce(o.customer_advance_pkr,0) end+case when pay.refunded_at is null then coalesce(pay.shopping_points_used,0)+case when pay.balance_payment_method='MIO' then greatest(0,o.total_pkr-coalesce(pay.shopping_points_used,0)) else 0 end else 0 end);
 if o.payment_status='confirmed' and f.status is distinct from 'refunded' and pay.refunded_at is null then paid:=o.total_pkr;end if;
 if f.order_id is not null then
  amount:=f.required_pkr;method:=case f.method when 'ADVANCE' then 'Advance' else 'Sponsor hold' end;
  if f.method='ADVANCE' then ready:=f.status='approved' and f.paid_pkr>=f.required_pkr;state:=case when ready then 'confirmed' when f.status in ('submitted','awaiting_payment') then 'pending' else 'missing' end;
  else ready:=a.status in ('approved','released') and a.hold_mio>=f.hold_mio and a.hold_member_id is not null;state:=case when ready then 'confirmed' when a.status in ('pending','guarantee_requested') then 'pending' else 'missing' end;end if;
 elsif g.order_id is not null then
  method:='MIO hold';amount:=g.mio_amount*g.mio_rate_snapshot;ready:=g.status in ('held','released') and g.payer_id is not null and g.wallet_amount>0;state:=case when ready then 'confirmed' when g.status='pending_sponsor' then 'pending' else 'missing' end;
 elsif pay.order_id is not null and pay.checkout_mode='SHOPPING_POINTS' and pay.shopping_points_used>0 then
  method:='Shopping Points';amount:=pay.shopping_points_used;ready:=true;state:='confirmed';
 elsif a.order_id is not null then
  method:='Sponsor hold';amount:=a.required_pkr;ready:=a.status in ('approved','released') and a.hold_member_id is not null;state:=case when ready then 'confirmed' when a.status in ('pending','guarantee_requested') then 'pending' else 'missing' end;
 end if;
 if paid>=o.total_pkr and o.total_pkr>0 then ready:=true;state:='confirmed';method:='Paid in full';amount:=o.total_pkr;end if;
 return jsonb_build_object('ready',coalesce(ready,false) and not closed,'state',case when closed then 'missing' else state end,'method',method,'required_pkr',amount,'paid_pkr',paid,'due_pkr',case when closed then 0 else greatest(o.total_pkr-paid,0) end,
  'refund_due_pkr',case when f.status='refund_due' then f.paid_pkr else 0 end,
  'hold_mio',coalesce(f.hold_mio,g.mio_amount,a.hold_mio,0),'payment_state',case when f.status='refunded' or pay.refunded_at is not null then 'refunded' when f.status='refund_due' then 'refund_due' when paid>=o.total_pkr then 'paid' when paid>0 then 'partial' else 'unpaid' end);
end $$;

create or replace function private.guard_customer_order_progress() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='cancelled' and new.status is distinct from old.status and exists(select 1 from private.order_vendor_shipments where order_id=old.id and status in('shipped','delivered')) then
  raise exception 'A vendor shipment has already been dispatched. Use the return process instead of cancelling and restoring stock';
 end if;
 if new.status in('cancelled','returned') then return new;end if;
 if new.status is distinct from old.status and new.status in('confirmed','processing','shipped','delivered') then
  if not coalesce((private.order_funding_state(old.id)->>'ready')::boolean,false) then raise exception 'Confirm the required MIO hold or verify the advance payment before accepting or processing this order';end if;
 end if;
 if new.payment_status='confirmed' and old.payment_status<>'confirmed' and new.status<>'delivered' then
  if not (coalesce(new.customer_advance_pkr,0)>=new.total_pkr or exists(select 1 from public.order_payment_allocations p where p.order_id=old.id and p.balance_payment_method='MIO' and p.refunded_at is null)) then raise exception 'Confirm the remaining COD payment only after delivery';end if;
 end if;
 return new;
end $$;

create function private.sync_order_shipments() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status is distinct from old.status and new.status in('cancelled','returned') then
 update private.order_vendor_shipments set status=new.status,updated_at=now() where order_id=new.id;
 update public.order_items set fulfillment_status=new.status where order_id=new.id;
 end if;return new;
end $$;
create trigger zzzz_sync_order_shipments after update of status on public.orders for each row execute function private.sync_order_shipments();

create function private.advance_vendor_shipment(p_shipment uuid,p_status public.order_status) returns jsonb language plpgsql security definer set search_path='' as $$
declare s private.order_vendor_shipments%rowtype;o public.orders%rowtype;stages text[]:=array['placed','confirmed','processing','shipped','delivered'];stage integer;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select o1.* into o from public.orders o1 join private.order_vendor_shipments s1 on s1.order_id=o1.id where s1.id=p_shipment for update of o1;
 select * into s from private.order_vendor_shipments where id=p_shipment for update;
 if s.id is null then raise exception 'Shipment not found';end if;
 if s.status=p_status then return jsonb_build_object('duplicate',true,'order_id',o.id);end if;
 if o.status in('cancelled','returned') or array_position(stages,p_status::text) is distinct from array_position(stages,s.status::text)+1 then raise exception 'Move the shipment to its next stage only';end if;
 if not coalesce((private.order_funding_state(o.id)->>'ready')::boolean,false) then raise exception 'Confirm the required MIO hold or verify the advance payment first';end if;
 update private.order_vendor_shipments set status=p_status,updated_at=now() where id=s.id;
 update public.order_items set fulfillment_status=p_status where order_id=o.id and vendor_id=s.vendor_id;
 select min(array_position(stages,status::text)) into stage from private.order_vendor_shipments where order_id=o.id;
 update public.orders set status=stages[stage]::public.order_status,updated_at=now() where id=o.id and status is distinct from stages[stage]::public.order_status;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'VENDOR_SHIPMENT_ADVANCED','order',o.id,jsonb_build_object('shipment',s.id,'status',s.status),jsonb_build_object('shipment',s.id,'status',p_status));
 return jsonb_build_object('order_id',o.id,'shipment_id',s.id,'status',p_status);
end $$;
create function public.advance_vendor_shipment(p_shipment uuid,p_status public.order_status) returns jsonb language sql security invoker set search_path='' as $$select private.advance_vendor_shipment(p_shipment,p_status)$$;

create or replace function public.advance_order_status(p_order_id uuid,p_status public.order_status) returns void language plpgsql security definer set search_path='' as $$
declare o public.orders%rowtype;r record;stages text[]:=array['placed','confirmed','processing','shipped','delivered'];
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 select * into o from public.orders where id=p_order_id for update;
 if not found then raise exception 'Order not found';end if;
 if o.status=p_status then return;end if;
 if array_position(stages,p_status::text) is distinct from array_position(stages,o.status::text)+1 or o.status in('cancelled','returned') then raise exception 'Move the order to its next stage only';end if;
 perform private.ensure_order_shipments(o.id);
 for r in select id from private.order_vendor_shipments where order_id=o.id and status=o.status order by id loop perform private.advance_vendor_shipment(r.id,p_status);end loop;
end $$;

create function private.order_fulfillment_details(p_order uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o public.orders%rowtype;funding jsonb;shipments jsonb;is_admin boolean;
begin
 if auth.uid() is null then raise exception 'Sign in to view this order';end if;
 is_admin:=private.has_role('admin');select * into o from public.orders where id=p_order;
 if o.id is null or not (is_admin or o.buyer_id is not distinct from auth.uid() or exists(select 1 from private.customer_order_funding where order_id=o.id and customer_id=auth.uid())) then return null;end if;
 funding:=private.order_funding_state(o.id);
 select coalesce(jsonb_agg(to_jsonb(q) order by q.shipment_code),'[]') into shipments from (
 select s.id,s.vendor_id,s.shipment_code,s.invoice_number,s.vendor_snapshot,s.gross_pkr,s.discount_pkr,s.delivery_pkr,s.total_pkr,s.status,
 round((funding->>'paid_pkr')::numeric*sum(s.total_pkr) over(order by s.shipment_code)/nullif(o.total_pkr,0),2)-round((funding->>'paid_pkr')::numeric*(sum(s.total_pkr) over(order by s.shipment_code)-s.total_pkr)/nullif(o.total_pkr,0),2) paid_pkr,
 (select jsonb_agg(jsonb_build_object('id',i.id,'name',i.product_name_snapshot,'sku',i.sku_snapshot,'image_url',i.image_url_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_pkr,'line_total',i.line_total_pkr,'buyer_discount',i.buyer_discount_pkr,'bundle',i.configured_bundle_snapshot,'components',i.bundle_components_snapshot) order by i.id) from public.order_items i where i.order_id=o.id and i.vendor_id=s.vendor_id) items
 from private.order_vendor_shipments s where s.order_id=o.id)q;
 return (to_jsonb(o)-'guest_access_token_hash'-'rules_snapshot'-'idempotency_key'-'reward_sponsor_id'-'reward_second_sponsor_id')||jsonb_build_object('funding',funding,'shipments',shipments,'can_manage',is_admin);
end $$;
create function public.order_fulfillment_details(p_order uuid) returns jsonb language sql stable security invoker set search_path='' as $$select private.order_fulfillment_details(p_order)$$;

create function private.admin_order_funding_states(p_orders uuid[]) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if coalesce(array_length(p_orders,1),0)>500 then raise exception 'Too many order references';end if;
 return (select coalesce(jsonb_object_agg(x,private.order_funding_state(x)),'{}') from unnest(p_orders)x);
end $$;
create function public.admin_order_funding_states(p_orders uuid[]) returns jsonb language sql stable security invoker set search_path='' as $$select private.admin_order_funding_states(p_orders)$$;

revoke all on function private.snapshot_invoice_product(),private.basket_delivery_fee(jsonb),private.ensure_order_shipments(uuid),private.order_funding_state(uuid),private.sync_order_shipments() from public,anon,authenticated;
revoke all on function private.advance_vendor_shipment(uuid,public.order_status),private.order_fulfillment_details(uuid),private.admin_order_funding_states(uuid[]),public.advance_vendor_shipment(uuid,public.order_status),public.order_fulfillment_details(uuid),public.admin_order_funding_states(uuid[]) from public,anon,authenticated;
grant execute on function private.advance_vendor_shipment(uuid,public.order_status),private.order_fulfillment_details(uuid),private.admin_order_funding_states(uuid[]),public.advance_vendor_shipment(uuid,public.order_status),public.order_fulfillment_details(uuid),public.admin_order_funding_states(uuid[]) to authenticated;

alter table private.customer_order_funding add column submitted_pkr numeric(14,2) check(submitted_pkr>0);

CREATE OR REPLACE FUNCTION public.place_marketplace_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare oid uuid; fee numeric; disc numeric; gross numeric; begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 perform pg_advisory_xact_lock(hashtextextended('order-policy:'||auth.uid()::text||':'||p_idempotency_key,0));
 select id into oid from public.orders where buyer_id=auth.uid() and idempotency_key in (p_idempotency_key,auth.uid()::text||':'||p_idempotency_key);
 if oid is not null then perform private.ensure_order_shipments(oid);
 return oid; end if;
 fee:=private.basket_delivery_fee(p_items);
 if fee is null then raise exception 'Delivery charges are awaiting company configuration'; end if;
 oid:=private.place_marketplace_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key);
 select coalesce(sum(buyer_discount_pkr),0),sum(line_total_pkr) into disc,gross from public.order_items where order_id=oid;
 update public.orders set discount_pkr=disc,subtotal_pkr=gross-disc,delivery_fee_pkr=fee,total_pkr=gross-disc+fee where id=oid;
 perform private.ensure_order_shipments(oid);
 return oid;
end $function$;

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
  fee:=private.basket_delivery_fee(p_items);
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
  perform private.ensure_order_shipments(oid);
  perform set_config('mio.affiliate_code','',true);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'CUSTOMER_MARKETPLACE_ORDER_PLACED','order',oid,jsonb_build_object('order_code',(select order_code from public.orders where id=oid),'guest',true,'affiliate_attributed',exists(select 1 from public.orders where id=oid and selling_affiliate_id is not null)));
  return (select jsonb_build_object('order_id',id,'order_code',order_code,'status',status) from public.orders where id=oid);
end $function$;

CREATE OR REPLACE FUNCTION public.place_checkout_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text, p_checkout_mode text, p_balance_payment_method text, p_transaction_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();oid uuid;o public.orders%rowtype;mode text:=upper(trim(coalesce(p_checkout_mode,'STANDARD')));
 method text:=upper(trim(coalesce(p_balance_payment_method,'COD')));rate numeric;hold_required numeric;shopping numeric:=0;cash numeric:=0;cod numeric:=0;
 sponsor uuid;sponsor_cash numeric:=0;sponsor_shopping numeric:=0;existing public.order_payment_allocations%rowtype;
begin
 if member is null then raise exception 'Sign in before placing an order';end if;
 if mode not in('STANDARD','SHOPPING_POINTS') then raise exception 'Choose a valid shopping mode';end if;
 if method not in('COD','MIO') then raise exception 'Choose MIO advance payment or Cash on Delivery';end if;
 perform pg_advisory_xact_lock(hashtextextended('checkout:'||member::text||':'||p_idempotency_key,0));
 select a.* into existing from public.order_payment_allocations a join public.orders x on x.id=a.order_id
  where x.buyer_id=member and x.idempotency_key in (p_idempotency_key,member::text||':'||p_idempotency_key);
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
 hold_required:=(private.customer_order_requirement(o.total_pkr,rate)->>'hold_mio')::numeric;
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
 -- Only a normal full-COD order uses the order-value guarantee. Split Shopping Points + COD never does.
 if mode='STANDARD' and method='COD' then
  if coalesce((select balance from public.mio_wallet_accounts where member_id=member),0)>=hold_required then
   perform private.require_transaction_pin(p_transaction_pin,member);
   update public.mio_wallet_accounts set balance=balance-hold_required,updated_at=now() where member_id=member and balance>=hold_required;
   insert into public.member_cod_guarantees(order_id,buyer_id,payer_id,funding_wallet,wallet_amount,mio_amount,mio_rate_snapshot,status,confirmed_at)
    values(oid,member,member,'cash',hold_required,hold_required,rate,'held',now());
   insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
    values(oid,member,'cash',-hold_required,'guarantee_hold','Refundable COD guarantee',jsonb_build_object('mio_amount',hold_required),'cod-guarantee-hold:'||oid);
  else
   select sponsor_id into sponsor from public.member_profiles where user_id=member;
   if sponsor is null then raise exception 'A direct sponsor is required because your Cash Wallet has insufficient MIO for the required hold';end if;
   select coalesce(balance,0) into sponsor_cash from public.mio_wallet_accounts where member_id=sponsor;
   select coalesce(shopping_points,0) into sponsor_shopping from public.member_income_wallets where member_id=sponsor;
   if coalesce(sponsor_cash,0)<hold_required and coalesce(sponsor_shopping,0)<hold_required*rate then
    raise exception 'Sponsor cannot receive this request: the required MIO or equivalent Shopping Points are required';
   end if;
   insert into public.member_cod_guarantees(order_id,buyer_id,sponsor_id,mio_amount,mio_rate_snapshot,status)
    values(oid,member,sponsor,hold_required,rate,'pending_sponsor');
   perform private.notify_member(sponsor,'guarantee','COD guarantee request','A direct member needs a refundable order security guarantee.','order',oid,jsonb_build_object('buyer_id',member));
  end if;
 end if;
 perform private.notify_member(member,'order','Order placed','Your marketplace order has been placed.','order',oid,jsonb_build_object('checkout_mode',mode,'balance_method',method));
 return jsonb_build_object('order_id',oid,'checkout_mode',mode,'payment_method',method,'shopping_points_used',shopping,'cash_mio_used',cash,'cod_due_pkr',cod,'duplicate',false);
end$function$;

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
 amount:=case when wallet='cash' then g.mio_amount else g.mio_amount*g.mio_rate_snapshot end;
 if wallet='cash' then
  update public.mio_wallet_accounts set balance=balance-amount,updated_at=now() where member_id=member and balance>=amount;
 else
  insert into public.member_income_wallets(member_id) values(member) on conflict(member_id)do nothing;
  update public.member_income_wallets set shopping_points=shopping_points-amount,updated_at=now() where member_id=member and shopping_points>=amount;
 end if;
 if not found then raise exception 'Selected sponsor wallet has insufficient balance';end if;
 insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
 values(p_order_id,member,wallet,-amount,'guarantee_hold','Refundable sponsor COD guarantee',jsonb_build_object('mio_amount',g.mio_amount,'mio_rate',g.mio_rate_snapshot),p_idempotency_key);
 update public.member_cod_guarantees set payer_id=member,funding_wallet=wallet,wallet_amount=amount,status='held',confirmed_at=now(),updated_at=now() where order_id=p_order_id;
 perform private.notify_member(g.buyer_id,'guarantee','COD guarantee approved','Your sponsor approved the refundable order guarantee.','order',p_order_id,jsonb_build_object('wallet',wallet));
 return jsonb_build_object('order_id',p_order_id,'status','held','wallet',wallet,'amount',amount);
end$function$;

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
 update public.orders set payment_status='confirmed',cod_due_pkr=0,updated_at=now() where id=o.id;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),'ORDER_PAYMENT_CONFIRMED','order',o.id,jsonb_build_object('buyer_id',o.buyer_id,'delivery_status',o.status));
 return (select ppv_generated from public.orders where id=o.id);
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
 if p_approve and (p_verified_pkr is null or p_verified_pkr<>coalesce(f.submitted_pkr,f.required_pkr)) then raise exception 'Verify the exact required advance amount: PKR %',coalesce(f.submitted_pkr,f.required_pkr);end if;
 update private.customer_order_funding set status=case when p_approve then 'approved' else 'rejected' end,paid_pkr=case when p_approve then p_verified_pkr else 0 end,
 reviewed_at=now(),reviewer_id=auth.uid(),review_note=trim(p_note) where order_id=p_order_id;
 if p_approve then update public.orders set customer_advance_pkr=p_verified_pkr,cod_due_pkr=total_pkr-p_verified_pkr,payment_status=case when p_verified_pkr>=total_pkr then 'confirmed'::public.payment_status else payment_status end,updated_at=now() where id=p_order_id;end if;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(auth.uid(),case when p_approve then 'CUSTOMER_ADVANCE_APPROVED' else 'CUSTOMER_ADVANCE_REJECTED' end,'order',p_order_id,jsonb_build_object('amount',p_verified_pkr,'note',trim(p_note),'transaction_id',f.transaction_id));
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
    if current_setting('mio.configured_bundle_id',true) is distinct from new.id::text and not coalesce(nullif(current_setting('mio.configured_bundle_ids',true),'')::jsonb ? new.id::text,false)
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
  result jsonb;groups jsonb:='[]';g record;cumulative_ppv numeric:=0;previous_ppv numeric:=0;part_ppv numeric;part_discount numeric;remaining_discount numeric;capacity numeric;
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
    if not found or (not tier.allow_multiple_vendors and product.vendor_id<>p_vendor) or product.status<>'approved' or product.bundle_definition is not null
      then raise exception 'Choose approved regular products from one vendor'; end if;
    select * into vendor from public.vendors where id=product.vendor_id and status='active';
    if not found then raise exception 'A selected vendor is unavailable';end if;
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
      'vendor_id',vendor.id,'vendor_name',vendor.business_name,'sku',product.sku,'base_price',product.vendor_submitted_price_pkr,
      'commission_pkr',round(product.vendor_submitted_price_pkr*coalesce(product.commission_rate_override,vendor.commission_rate),2),'company_fee_pkr',round(product.vendor_submitted_price_pkr*.05,2),'introducer_pkr',round(round(product.vendor_submitted_price_pkr*coalesce(product.commission_rate_override,vendor.commission_rate),2)*.10,2),
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
    'kind','configured','type_id',tier.id,'name',tier.name,'vendor_id',p_vendor,'allow_multiple_vendors',tier.allow_multiple_vendors,'items',items,
    'units',units,'required_units',tier.required_units,'divider',tier.ppv_divider,'minimum_pkr',tier.minimum_pkr,
    'allow_repeats',tier.allow_repeats,'max_per_product',tier.max_per_product,
    'original_total',subtotal,'base_total',base_total,'original_ppv',total_ppv,'ppv',retained,
    'discount_ppv',discount_ppv,'discount_pkr',discount,'price_pkr',subtotal-discount,'reference_rate',rate,
    'complete',units=tier.required_units,'meets_minimum',subtotal-discount>=tier.minimum_pkr,
    'commission_pkr',commission_total,'company_fee_pkr',fee_total,'introducer_pkr',intro_total,'economics_version',3);
  -- Allocate the exact existing total PPV and discount without spending another vendor's budget.
  remaining_discount:=discount;
  for g in select (x->>'vendor_id')::uuid vendor_id,max(x->>'vendor_name') vendor_name,jsonb_agg(x order by x->>'product_id') items,
    sum((x->>'quantity')::int) units,sum((x->>'price_pkr')::numeric*(x->>'quantity')::int) subtotal,
    sum((x->>'base_price')::numeric*(x->>'quantity')::int) base,
    sum((x->>'ppv')::numeric*(x->>'quantity')::int) ppv,
    sum((x->>'commission_pkr')::numeric*(x->>'quantity')::int) commission,
    sum((x->>'company_fee_pkr')::numeric*(x->>'quantity')::int) company,
    sum((x->>'introducer_pkr')::numeric*(x->>'quantity')::int) introducer
    from jsonb_array_elements(items)x group by x->>'vendor_id' order by x->>'vendor_id' loop
    cumulative_ppv:=cumulative_ppv+g.ppv;
    part_ppv:=case when total_ppv=0 then 0 else trunc(retained*cumulative_ppv/total_ppv,4)-previous_ppv end;
    previous_ppv:=previous_ppv+part_ppv;
    capacity:=floor((g.commission-g.company-g.introducer-(g.base-g.subtotal)-ceil(part_ppv*rate*100)/100)*100)/100;
    part_discount:=least(trunc((g.ppv-g.ppv/tier.ppv_divider)*rate,2),greatest(capacity,0));
    if capacity<0 then raise exception 'Vendor PPV exceeds its funded budget';end if;
    groups:=groups||jsonb_build_array(result||jsonb_build_object('vendor_id',g.vendor_id,'vendor_name',g.vendor_name,'items',g.items,'units',g.units,'original_total',g.subtotal,'base_total',g.base,'original_ppv',g.ppv,'ppv',part_ppv,'discount_pkr',part_discount,'price_pkr',g.subtotal-part_discount,'commission_pkr',g.commission,'company_fee_pkr',g.company,'introducer_pkr',g.introducer,'discount_capacity',capacity));
    remaining_discount:=remaining_discount-part_discount;
  end loop;
  if remaining_discount>0 then
    for g in select value,ordinality-1 idx from jsonb_array_elements(groups) with ordinality loop
      part_discount:=least(remaining_discount,(g.value->>'discount_capacity')::numeric-(g.value->>'discount_pkr')::numeric);
      if part_discount>0 then
        groups:=jsonb_set(groups,array[g.idx::text],g.value||jsonb_build_object('discount_pkr',(g.value->>'discount_pkr')::numeric+part_discount,'price_pkr',(g.value->>'price_pkr')::numeric-part_discount));
        remaining_discount:=remaining_discount-part_discount;
      end if;
    end loop;
  end if;
  if remaining_discount<>0 then raise exception 'Vendor discount allocations do not reconcile';end if;
  result:=result||jsonb_build_object('vendors',groups,'vendor_count',jsonb_array_length(groups));
  return result||jsonb_build_object('quote_key',md5(result::text));
end $function$;

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
  country text;part jsonb;bundle_ids jsonb:='[]';
begin

  if member is null then raise exception 'Create your shopping User account before placing an order';end if;
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
  items:=regular_items;
  for part in select value from jsonb_array_elements(quote->'vendors') loop
    bundle_product_id:=gen_random_uuid();bundle_ids:=bundle_ids||to_jsonb(bundle_product_id::text);
    perform set_config('mio.configured_bundle_ids',bundle_ids::text,true);
    select coalesce(v.country_code,'PK') into country from public.vendors v where v.id=(part->>'vendor_id')::uuid;
    insert into public.products(id,vendor_id,name,description,category,image_urls,price_pkr,compare_at_price_pkr,stock_quantity,status,bundle_definition,country_code)
    values(bundle_product_id,(part->>'vendor_id')::uuid,quote->>'name','Customer-selected bundle','Bundles','[]',(part->>'price_pkr')::numeric,(part->>'original_total')::numeric,1,'approved',part,country);
    items:=items||jsonb_build_array(jsonb_build_object('product_id',bundle_product_id,'quantity',1));
  end loop;
  if jsonb_array_length(items)>30 then raise exception 'The basket supports up to 30 vendor/product lines';end if;
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
  update public.products p set status='archived' where bundle_ids ? p.id::text;
  perform set_config('mio.configured_bundle_ids','',true);
  perform set_config('mio.configured_bundle_id','',true);
  insert into private.configured_bundle_checkouts values(v_requester,v_request_key,placed);
  return placed;
end $function$;

create function private.submit_order_payment(p_order uuid,p_account uuid,p_transaction text,p_proof text,p_amount numeric) returns void language plpgsql security definer set search_path='' as $$
declare f private.customer_order_funding%rowtype;o public.orders%rowtype;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select * into o from public.orders where id=p_order for update;
 select * into f from private.customer_order_funding where order_id=p_order for update;
 if f.customer_id is distinct from auth.uid() then raise exception 'Order not found';end if;
 if p_amount is null or p_amount not in(f.required_pkr,o.total_pkr) then raise exception 'Choose the required advance or the full order total';end if;
 if f.status='submitted' and coalesce(f.submitted_pkr,f.required_pkr)<>p_amount then raise exception 'Payment is already under review';end if;
 perform public.submit_shopping_advance_with_proof(p_order,p_account,p_transaction,p_proof);
 update private.customer_order_funding set submitted_pkr=p_amount where order_id=p_order;
end $$;
create function public.submit_order_payment(p_order uuid,p_account uuid,p_transaction text,p_proof text,p_amount numeric) returns void language sql security invoker set search_path='' as $$select private.submit_order_payment(p_order,p_account,p_transaction,p_proof,p_amount)$$;
revoke all on function private.submit_order_payment(uuid,uuid,text,text,numeric),public.submit_order_payment(uuid,uuid,text,text,numeric) from public,anon,authenticated;
grant execute on function private.submit_order_payment(uuid,uuid,text,text,numeric),public.submit_order_payment(uuid,uuid,text,text,numeric) to authenticated;

-- Backfill original prices and share the existing fee; never reprice historical orders.
do $$declare r record;begin
 for r in select id from public.orders where exists(select 1 from public.order_items where order_id=orders.id) order by created_at,id loop perform private.ensure_order_shipments(r.id);end loop;
end $$;
notify pgrst,'reload schema';

CREATE OR REPLACE FUNCTION private.place_maintenance_checkout(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text, p_checkout_mode text, p_balance_payment_method text, p_transaction_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare member uuid:=auth.uid();oid uuid;o public.orders%rowtype;mode text:=upper(trim(coalesce(p_checkout_mode,'STANDARD')));
 method text:=upper(trim(coalesce(p_balance_payment_method,'COD')));rate numeric;hold_required numeric;shopping numeric:=0;cash numeric:=0;cod numeric:=0;
 sponsor uuid;sponsor_cash numeric:=0;sponsor_shopping numeric:=0;existing public.order_payment_allocations%rowtype;
begin
 if member is null then raise exception 'Sign in before placing an order';end if;
 if mode not in('STANDARD','SHOPPING_POINTS') then raise exception 'Choose a valid shopping mode';end if;
 if method not in('COD','MIO') then raise exception 'Choose MIO advance payment or Cash on Delivery';end if;
 perform pg_advisory_xact_lock(hashtextextended('checkout:'||member::text||':'||p_idempotency_key,0));
 select a.* into existing from public.order_payment_allocations a join public.orders x on x.id=a.order_id
  where x.buyer_id=member and x.idempotency_key in (p_idempotency_key,member::text||':'||p_idempotency_key);
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
 hold_required:=(private.customer_order_requirement(o.total_pkr,rate)->>'hold_mio')::numeric;
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
 -- Only a normal full-COD order uses the order-value guarantee. Split Shopping Points + COD never does.
 if method='COD' then
  if coalesce((select balance from public.mio_wallet_accounts where member_id=member),0)>=hold_required then
   perform private.require_transaction_pin(p_transaction_pin,member);
   update public.mio_wallet_accounts set balance=balance-hold_required,updated_at=now() where member_id=member and balance>=hold_required;
   insert into public.member_cod_guarantees(order_id,buyer_id,payer_id,funding_wallet,wallet_amount,mio_amount,mio_rate_snapshot,status,confirmed_at)
    values(oid,member,member,'cash',hold_required,hold_required,rate,'held',now());
   insert into public.order_payment_ledger(order_id,member_id,wallet_kind,amount,entry_kind,note,metadata,idempotency_key)
    values(oid,member,'cash',-hold_required,'guarantee_hold','Refundable COD guarantee',jsonb_build_object('mio_amount',hold_required),'cod-guarantee-hold:'||oid);
  else
   select sponsor_id into sponsor from public.member_profiles where user_id=member;
   if sponsor is null then raise exception 'A direct sponsor is required because your Cash Wallet has insufficient MIO for the required hold';end if;
   select coalesce(balance,0) into sponsor_cash from public.mio_wallet_accounts where member_id=sponsor;
   select coalesce(shopping_points,0) into sponsor_shopping from public.member_income_wallets where member_id=sponsor;
   if coalesce(sponsor_cash,0)<hold_required and coalesce(sponsor_shopping,0)<hold_required*rate then
    raise exception 'Sponsor cannot receive this request: the required MIO or equivalent Shopping Points are required';
   end if;
   insert into public.member_cod_guarantees(order_id,buyer_id,sponsor_id,mio_amount,mio_rate_snapshot,status)
    values(oid,member,sponsor,hold_required,rate,'pending_sponsor');
   perform private.notify_member(sponsor,'guarantee','COD guarantee request','A direct member needs a refundable order security guarantee.','order',oid,jsonb_build_object('buyer_id',member));
  end if;
 end if;
 perform private.notify_member(member,'order','Order placed','Your marketplace order has been placed.','order',oid,jsonb_build_object('checkout_mode',mode,'balance_method',method));
 return jsonb_build_object('order_id',oid,'checkout_mode',mode,'payment_method',method,'shopping_points_used',shopping,'cash_mio_used',cash,'cod_due_pkr',cod,'duplicate',false);
end$function$;

create or replace function public.marketplace_bundle_types() returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'required_units',required_units,'status',status,'allow_repeats',allow_repeats,'max_per_product',max_per_product,'minimum_pkr',minimum_pkr,'display_order',display_order,'allow_multiple_vendors',allow_multiple_vendors) order by display_order),'[]'::jsonb) from private.marketplace_bundle_types where status in('enabled','draft');
$$;

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
   values(new.id,g.payer_id,g.funding_wallet,g.wallet_amount,'guarantee_refund','COD guarantee returned',jsonb_build_object('mio_amount',g.mio_amount),'cod-guarantee-refund:'||new.id) on conflict(idempotency_key)do nothing;
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
end$function$
;
