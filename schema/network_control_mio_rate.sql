-- MIO pricing: new order snapshots follow the configured rate. Existing snapshots stay unchanged.
-- Denominators in single-line network percentage formulas intentionally remain unchanged.

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

CREATE OR REPLACE FUNCTION public.place_guest_affiliate_order(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_guest_email text, p_idempotency_key text, p_access_token text, p_affiliate_code text DEFAULT NULL::text)
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
  if auth.uid() is not null then raise exception 'Use member checkout while signed in';end if;
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
  values(oid,'GST-'||upper(substr(replace(oid::text,'-',''),1,10)),null,0,fee,fee,'COD','unconfirmed','placed',trim(p_shipping_name),trim(p_shipping_phone),trim(p_shipping_address),trim(p_shipping_city),'guest:'||email_normalized||':'||p_idempotency_key,private.current_mio_reference_price(),email_normalized,token_hash);
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
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,after_data) values(null,'GUEST_MARKETPLACE_ORDER_PLACED','order',oid,jsonb_build_object('order_code',(select order_code from public.orders where id=oid),'guest',true,'affiliate_attributed',exists(select 1 from public.orders where id=oid and selling_affiliate_id is not null)));
  return (select jsonb_build_object('order_id',id,'order_code',order_code,'status',status) from public.orders where id=oid);
end $function$;

CREATE OR REPLACE FUNCTION private.formula_product_ppv()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.vendors%rowtype; base numeric; discount_rate numeric; available_rate numeric; award_rate numeric;
begin
 select * into v from public.vendors where id=new.vendor_id;
 if TG_OP='INSERT' then new.vendor_submitted_price_pkr:=new.price_pkr;
 elsif not private.has_role('admin') and new.price_pkr is distinct from old.price_pkr then new.vendor_submitted_price_pkr:=new.price_pkr;
 elsif new.vendor_submitted_price_pkr is distinct from old.vendor_submitted_price_pkr then
  raise exception 'Seller submitted price is preserved; use sale price controls';
 else new.vendor_submitted_price_pkr:=old.vendor_submitted_price_pkr; end if;
 base:=new.vendor_submitted_price_pkr;
 if base<=0 and new.status='archived' then new.ppv_per_unit:=0;return new;elsif base<=0 then raise exception 'Seller submitted price must be positive';end if;
 if new.price_pkr>base then raise exception 'Sale price cannot exceed seller submitted price';end if;
 discount_rate:=greatest(base-new.price_pkr,0)/base;
 available_rate:=v.commission_rate-.05-discount_rate;
 if available_rate<0 then raise exception 'Discount exceeds commission after fixed company 5 percent';end if;
 award_rate:=coalesce(new.awarded_rate_override,v.awarded_rate,available_rate);
 if award_rate<0 or award_rate>available_rate then raise exception 'Award percentage exceeds the remaining budget after discount';end if;
 if TG_OP='INSERT' and new.awarded_rate_override is not null and not private.has_role('admin') then raise exception 'Only admin may set product reward overrides';end if;
 if TG_OP='UPDATE' and new.awarded_rate_override is distinct from old.awarded_rate_override and not private.has_role('admin') then raise exception 'Only admin may set product reward overrides';end if;
 new.ppv_per_unit:=trunc(base*award_rate/private.current_mio_reference_price(),4);return new;
end $function$;

CREATE OR REPLACE FUNCTION private.allure_formula()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$ begin
 if exists(select 1 from public.vendors where id=new.vendor_id and is_company_owned and business_name='Allure Care' and source_url like 'https://allurecarein.com%') then
  new.ppv_per_unit:=case when new.price_pkr>0 then trunc(new.price_pkr*0.25/private.current_mio_reference_price()*0.90,4) else null end;
 end if;return new;
end $function$;

CREATE OR REPLACE FUNCTION private.snapshot_item_ppv()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare p public.products%rowtype;begin
 select * into p from public.products where id=new.product_id;
 new.reward_basis_pkr_snapshot:=p.vendor_submitted_price_pkr*new.quantity;
 new.sale_discount_pkr_snapshot:=greatest(new.reward_basis_pkr_snapshot-new.unit_price_pkr*new.quantity,0);
 new.awarded_rate_snapshot:=coalesce(p.awarded_rate_override,(select awarded_rate from public.vendors where id=new.vendor_id),new.commission_rate_snapshot-.05-new.sale_discount_pkr_snapshot/nullif(new.reward_basis_pkr_snapshot,0));
 new.award_scope_snapshot:=case when p.awarded_rate_override is not null then 'product' else 'vendor' end;
 new.ppv_per_unit_snapshot:=trunc(p.vendor_submitted_price_pkr*new.awarded_rate_snapshot/(select coalesce(nullif(o.usd_to_pkr_rate,0),300) from public.orders o where o.id=new.order_id),4);
 new.award_policy_leftover_pkr:=trunc(new.reward_basis_pkr_snapshot*greatest(0,new.commission_rate_snapshot-.05-new.sale_discount_pkr_snapshot/nullif(new.reward_basis_pkr_snapshot,0)-new.awarded_rate_snapshot),4);return new;
end $function$;

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

CREATE OR REPLACE FUNCTION private.post_shopping_rewards_delivered(oid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare buyer uuid;cfg jsonb;funding numeric;b numeric;r jsonb;cap numeric:=110;used numeric:=0;
begin
 select buyer_id,rules_snapshot into buyer,cfg from public.orders where id=oid and payment_status='confirmed';
 if buyer is null then return; end if;
 if cfg='{}'::jsonb then perform private.post_shopping_rewards_legacy(oid);return;end if;
 select coalesce((config_value->>'shopping_ppv_cap')::numeric,110) into cap from public.system_config where config_key='PPV_CAPS' and effective_to is null order by version desc limit 1;
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=oid and a.share_kind='network_rewards';
 select coalesce(sum(trunc(i.ppv_per_unit_snapshot*i.quantity,4)),0) into b from public.order_items i where order_id=oid;
 select coalesce(sum(s.bv),0) into used from public.shopping_reward_events s where s.buyer_id=buyer and s.created_at>private.financial_reset_at();
 b:=least(b,greatest(0,cap-used));
 if b<=0 then return; end if;
 if b*(select coalesce(nullif(usd_to_pkr_rate,0),300) from public.orders where id=oid)>funding then raise exception 'Shopping PPV/BV exceeds verified network funding';end if;
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(oid,buyer,funding,b,trunc(b*.35,4)) on conflict do nothing;
 if not found then return; end if;
 r:=private.distribute_mlm_event(buyer,b,oid,null,cfg);
 update public.shopping_reward_events set direct_generation_mio=(r->>'direct_generation')::numeric,single_line_mio=(r->>'single_line')::numeric where order_id=oid;
end$function$;

CREATE OR REPLACE FUNCTION private.post_shopping_rewards_legacy(oid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare buyer uuid; funding numeric; b numeric; r record; total numeric; scale numeric; paid numeric:=0; single_paid numeric:=0; amount numeric; p uuid; side text; current_member uuid; depth int:=0; lim int; begin
 select buyer_id into buyer from public.orders where id=oid and payment_status='confirmed';
 select coalesce(sum(a.amount_pkr),0) into funding from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=oid and a.share_kind='network_rewards';
 b:=trunc(funding/(select coalesce(nullif(usd_to_pkr_rate,0),300) from public.orders where id=oid),4); if b<=0 then return; end if;
 insert into public.shopping_reward_events(order_id,buyer_id,funded_pkr,bv,binary_reserve_mio) values(oid,buyer,funding,b,trunc(b*0.35,4)) on conflict do nothing;
 if not found then return; end if;
 -- Sale BV funding is stored in shopping_reward_events; buyer only gets PPV.
 select coalesce(sum(nominal),0) into total from private.sale_reward_candidates(buyer,b);
 scale:=case when total>0 then least(1,trunc(b*0.55,4)/total) else 0 end;
 for r in select * from private.sale_reward_candidates(buyer,b) order by depth loop
  amount:=trunc(r.nominal*scale,4); perform private.post_shopping_bonus(oid,r.beneficiary,r.method,r.depth,b,r.nominal,amount);paid:=paid+amount;
 end loop;
 current_member:=buyer;
 loop
  select parent_id,bp.side into p,side from public.binary_placements bp where bp.member_id=current_member;
  exit when p is null; depth:=depth+1;
  if depth>100 then raise exception 'Binary ancestry exceeds limit'; end if;
  if trunc(b/2,4)>0 then insert into public.point_ledger(member_id,point_type,amount,side,source_order_id,entry_kind,idempotency_key) values(p,'BP',trunc(b/2,4),side,oid,'credit','shopping-bp:'||oid||':'||p); end if;
  lim:=case private.current_package_code(p) when 'BASIC_1' then 10 when 'BASIC_2' then 15 when 'ADVANCED_1' then 20 when 'ADVANCED_2' then 25 when 'PREMIUM' then 30 else 0 end;
  if depth<=lim and exists(select 1 from public.member_profiles where user_id=p and status='active') then
   amount:=trunc(b*depth/300,4)-trunc(b*(depth-1)/300,4);
   perform private.post_shopping_bonus(oid,p,'single_line',depth,b,b/300,amount); single_paid:=single_paid+amount;
  end if;
  current_member:=p;
 end loop;
 update public.shopping_reward_events set direct_generation_mio=paid,single_line_mio=single_paid where order_id=oid;
end $function$;

CREATE OR REPLACE FUNCTION private.post_shopping_bonus(oid uuid, beneficiary uuid, method bonus_method, depth integer, base numeric, nominal numeric, amount numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare tx uuid; begin
 if amount<=0 then return; end if;
 insert into public.bonus_transactions(beneficiary_id,method,source_order_id,generation,qualifying_base,rate,gross_amount,payable_amount,currency,formula_version,calculation_trace,idempotency_key)
 values(beneficiary,method,oid,depth,base,case when base>0 then amount/base else 0 end,nominal,amount,'MIO','sale-funded-v2',jsonb_build_object('sale_budget_pkr_per_mio',(select coalesce(nullif(usd_to_pkr_rate,0),300) from public.orders where id=oid),'nominal_mio',nominal,'funded_payable_mio',amount,'method_cap',case when method='single_line' then 0.10 else 0.55 end),'shopping:'||oid||':'||method||':'||beneficiary||':'||depth) on conflict(idempotency_key) do nothing returning id into tx;
 if tx is not null then
  update public.mio_wallet_accounts set balance=balance+amount,updated_at=now() where member_id=beneficiary;
  if not found then raise exception 'Recipient wallet missing'; end if;
  insert into public.mio_ledger(member_id,amount,action,source_order_id,bonus_transaction_id,reason,idempotency_key) values(beneficiary,amount,'bonus_credit',oid,tx,'Shopping BV funded bonus','bonus:'||tx);
 end if;
end $function$;

CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_award()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select * from private.company_treasury_sources_before_ecommerce()
 union all select 'ecommerce',id,'ecommerce_missing_recipient','MIO',amount from public.ecommerce_rewards where status='company_leftover'
 union all select 'order',o.id,'ecommerce_conversion_leftover','PKR',greatest(0,(select coalesce(sum(a.amount_pkr),0) from public.commission_allocations a join public.order_items i on i.id=a.order_item_id where i.order_id=o.id and a.share_kind='network_rewards')-o.reward_ppv_total*coalesce(nullif(o.usd_to_pkr_rate,0),300)) from public.orders o where o.reward_version=2 and o.reward_mode='MIO' and o.rewards_credited_at is not null;
$function$;

CREATE OR REPLACE FUNCTION private.company_treasury_sources_before_activation_offer()
 RETURNS TABLE(source_type text, source_id uuid, category text, currency text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 with funding as(
  select 'order'::text typ,s.order_id id,s.bv base,s.dp,s.gp,s.bp,s.binary_reserve_mio reserve,o.rules_snapshot cfg from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
  union all select 'package',a.id,least(a.bv,a.base_value,a.payable_price-a.company_fee),a.dp,a.gp,a.bp,a.binary_reserve_mio,a.rules_snapshot from public.package_activations a where a.status='approved' and a.source<>'SHOPPING_PPV'
 ),spend as(
  select f.*,coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='direct'),0) direct_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='generation'),0) gen_paid,
   coalesce((select sum(x.payable_amount) from public.bonus_transactions x where x.status in('posted','pending') and ((f.typ='order' and x.source_order_id=f.id) or (f.typ='package' and x.source_activation_id=f.id)) and x.method='single_line'),0) placement_paid from funding f
 )
 select typ,id,'generation_levels_pending','MIO',greatest(0,trunc(gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45),4)-gen_paid) from spend
 union all select typ,id,'generation_manager_pending','MIO',trunc(gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'generation_global_pending','MIO',trunc(gp*coalesce((cfg->>'generation_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'binary_placement_pending','MIO',greatest(0,trunc(bp*coalesce((cfg->>'single_line_cap')::numeric,.10),4)-placement_paid) from spend
 union all select typ,id,'binary_pool_pending','MIO',reserve from spend
 union all select typ,id,'binary_manager_pending','MIO',trunc(bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05),4) from spend
 union all select typ,id,'binary_global_pending','MIO',trunc(bp*coalesce((cfg->>'binary_global_rate')::numeric,.20),4) from spend
 union all select typ,id,'network_formula_leftover','MIO',greatest(0,dp-gp*coalesce((cfg->>'generation_bonus_rate')::numeric,.45)-gp*coalesce((cfg->>'generation_manager_rate')::numeric,.05)-gp*coalesce((cfg->>'generation_global_rate')::numeric,.20)-bp*coalesce((cfg->>'binary_pool_rate')::numeric,.35)-bp*coalesce((cfg->>'single_line_cap')::numeric,.10)-bp*coalesce((cfg->>'binary_manager_rate')::numeric,.05)-bp*coalesce((cfg->>'binary_global_rate')::numeric,.20)-direct_paid) from spend
 union all select 'order',s.order_id,'shopping_conversion_leftover','PKR',greatest(0,s.funded_pkr-s.bv*coalesce(nullif(o.usd_to_pkr_rate,0),300)) from public.shopping_reward_events s join public.orders o on o.id=s.order_id where o.payment_status='confirmed'
 union all select 'package',id,'package_company_fee','MIO',company_fee from public.package_activations where status='approved' and source<>'SHOPPING_PPV'
 union all select 'cycle',c.id,'binary_retention','MIO',coalesce((select sum(company_retention) from public.binary_member_results where cycle_id=c.id),0) from public.binary_cycles c where c.status='posted'
 union all select 'cycle',c.id,'binary_pool_leftover','MIO',greatest(0,c.pool_amount-coalesce((select sum(member_amount+company_retention) from public.binary_member_results where cycle_id=c.id),0)) from public.binary_cycles c where c.status in('posted','unallocated')
 union all select 'commission',a.id,'vendor_company_share','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='company' and o.payment_status='confirmed'
 union all select 'commission',a.id,'ecommerce_leftover','PKR',a.amount_pkr from public.commission_allocations a join public.order_items i on i.id=a.order_item_id join public.orders o on o.id=i.order_id where a.share_kind='unallocated' and o.payment_status='confirmed'
 union all select 'vendor_sale',l.id,'company_brand_proceeds','PKR',l.net_pkr from public.vendor_income_ledger l join public.order_items i on i.id=l.order_item_id join public.orders o on o.id=i.order_id where i.company_owned_snapshot and o.payment_status='confirmed'
 union all select 'order',id,'shipping_receipts','PKR',delivery_fee_pkr from public.orders where payment_status='confirmed';
$function$;
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
CREATE OR REPLACE FUNCTION private.place_maintenance_checkout(p_items jsonb, p_shipping_name text, p_shipping_phone text, p_shipping_address text, p_shipping_city text, p_idempotency_key text, p_checkout_mode text, p_balance_payment_method text, p_transaction_pin text DEFAULT NULL::text)
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
  where x.buyer_id=member and x.idempotency_key=member::text||':'||p_idempotency_key;
 if existing.order_id is not null then
  return jsonb_build_object('order_id',existing.order_id,'checkout_mode',existing.checkout_mode,'payment_method',existing.balance_payment_method,'duplicate',true);
 end if;
 
 oid:=public.place_affiliate_order(p_items,p_shipping_name,p_shipping_phone,p_shipping_address,p_shipping_city,p_idempotency_key,null);
 select * into o from public.orders where id=oid for update;
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
 if method='COD' then
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
