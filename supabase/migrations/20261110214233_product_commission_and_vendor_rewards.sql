-- Product-specific economics. Historical order snapshots and ledgers are never rewritten.
alter table public.products add column if not exists commission_rate_override numeric;
alter table public.products add column if not exists assigned_ppv numeric;
alter table public.products add column if not exists maximum_ppv numeric;
alter table public.products add column if not exists ppv_remainder_policy text not null default 'reserve';
alter table public.products add column if not exists reward_discount_pkr numeric not null default 0;
alter table public.order_items add column if not exists economics_version integer;
alter table public.order_items add column if not exists economics_snapshot jsonb;
alter table public.products add constraint product_commission_override_valid check(commission_rate_override between 0 and 1);
alter table public.products add constraint product_assigned_ppv_valid check(assigned_ppv>=0 and assigned_ppv=trunc(assigned_ppv,4));
alter table public.products add constraint product_remainder_policy_valid check(ppv_remainder_policy in ('reserve','discount'));

create or replace function private.product_economics(p_base numeric,p_sale numeric,p_commission numeric,p_rate numeric,p_points numeric default null,p_policy text default 'reserve') returns jsonb
language plpgsql immutable set search_path='' as $$
declare pool numeric;company numeric;intro numeric;budget numeric;max_points numeric;points numeric;extra_discount numeric:=0;reserved numeric;funding numeric;
begin
 if p_base is null or p_sale is null or p_rate is null or p_commission is null or p_base<=0 or p_sale<=0 or p_sale>p_base or p_rate<=0 or p_commission<0 or p_commission>1 or p_policy not in ('reserve','discount') then raise exception 'Enter valid product price, commission and PPV settings';end if;
 pool:=round(p_base*p_commission,2);company:=round(p_base*.05,2);intro:=round(pool*.10,2);
 budget:=pool-company-intro-round(p_base-p_sale,2);
 if budget<0 then raise exception 'Commission must cover the company fee, introducer share and discount';end if;
 max_points:=trunc(budget/p_rate,4);points:=coalesce(p_points,max_points);
 if points<0 or points<>trunc(points,4) or points>max_points then raise exception 'Assigned PPV cannot exceed maximum PPV (%)',max_points;end if;
 -- Round funding upward to a paisa so every assigned point is fully funded.
 funding:=ceil(points*p_rate*100)/100;reserved:=budget-funding;
 if p_policy='discount' then extra_discount:=reserved;reserved:=0;end if;
 if p_sale-extra_discount<=0 then raise exception 'Discount must leave a positive customer price';end if;
 return jsonb_build_object('base',p_base,'commission_rate',p_commission,'commission',pool,'company_fee',company,'introducer',intro,'budget',budget,'maximum_ppv',max_points,'assigned_ppv',points,'network_funding',funding,'reserve',reserved,'extra_discount',extra_discount,'sale_price',p_sale-extra_discount,'reference_rate',p_rate,'policy',p_policy);
end $$;
revoke all on function private.product_economics(numeric,numeric,numeric,numeric,numeric,text) from public,anon,authenticated;

create or replace function private.formula_product_ppv() returns trigger language plpgsql security definer set search_path='' as $$
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
 base:=new.vendor_submitted_price_pkr;
 if base<=0 and new.status='archived' then new.ppv_per_unit:=0;new.maximum_ppv:=0;return new;end if;
 sale:=new.price_pkr+new.reward_discount_pkr;
 e:=private.product_economics(base,sale,coalesce(new.commission_rate_override,v.commission_rate),private.current_mio_reference_price(),new.assigned_ppv,new.ppv_remainder_policy);
 new.maximum_ppv:=(e->>'maximum_ppv')::numeric;new.ppv_per_unit:=(e->>'assigned_ppv')::numeric;
 new.reward_discount_pkr:=(e->>'extra_discount')::numeric;new.price_pkr:=(e->>'sale_price')::numeric;
 return new;
end $$;

create or replace function public.admin_save_product_economics(p_product uuid,p_sale numeric,p_compare numeric,p_commission numeric,p_ppv numeric,p_remainder text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare before_row public.products%rowtype;after_row public.products%rowtype;
begin
 if auth.uid() is null or not private.has_role('admin') then raise exception 'Admin access required';end if;
 if p_sale is null or p_sale<>round(p_sale,2) or (p_compare is not null and (p_compare<p_sale or p_compare<>round(p_compare,2))) or (p_commission is not null and (p_commission<0 or p_commission>1 or p_commission<>round(p_commission,6))) or p_remainder not in ('reserve','discount') then raise exception 'Enter valid pricing, commission and remainder settings';end if;
 select * into before_row from public.products where id=p_product for update;
 if not found then raise exception 'Product not found';end if;
 if before_row.bundle_definition is not null then raise exception 'Use the bundle builder to edit bundle pricing';end if;
 update public.products set price_pkr=p_sale,compare_at_price_pkr=p_compare,commission_rate_override=p_commission,assigned_ppv=p_ppv,ppv_remainder_policy=p_remainder,reward_discount_pkr=0,awarded_rate_override=null,updated_at=now() where id=p_product returning * into after_row;
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,before_data,after_data) values(auth.uid(),'PRODUCT_ECONOMICS_UPDATED','product',p_product,to_jsonb(before_row),to_jsonb(after_row));
 return jsonb_build_object('product_id',p_product,'maximum_ppv',after_row.maximum_ppv,'assigned_ppv',after_row.ppv_per_unit,'sale_price',after_row.price_pkr,'reward_discount',after_row.reward_discount_pkr);
end $$;
revoke all on function public.admin_save_product_economics(uuid,numeric,numeric,numeric,numeric,text) from public,anon;
grant execute on function public.admin_save_product_economics(uuid,numeric,numeric,numeric,numeric,text) to authenticated;

-- Actual product percentage determines the pool. Discount and reserve are explicit.
create or replace function private.snapshot_commission() returns trigger language plpgsql security definer set search_path='' as $$
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
end $$;

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
end $function$
;

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
end $function$
;

create or replace function private.prepare_order_rewards() returns trigger language plpgsql security definer set search_path='' as $$
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
end $$;

create or replace function private.release_vendor_introducer_reward() returns trigger language plpgsql security definer set search_path='' as $$
declare r record;begin
 if new.status='delivered' and new.payment_status='confirmed' then
  for r in select e.id from public.ecommerce_rewards e join public.order_items i on i.id=e.order_item_id where e.order_id=new.id and i.economics_version=3 and e.reward_kind='vendor_introducer' loop perform private.credit_ecommerce_reward(r.id);end loop;
 end if;return new;
end $$;
create trigger zzz_release_vendor_introducer after update of status,payment_status on public.orders for each row execute function private.release_vendor_introducer_reward();
revoke all on function private.release_vendor_introducer_reward() from public,anon,authenticated;

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
end $function$
;

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
end $function$
;

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
 if not private.has_role('admin') and (tg_op='INSERT' or (to_jsonb(new)-array['stock_quantity','updated_at','ppv_per_unit','awarded_rate_override','vendor_submitted_price_pkr']) is distinct from (to_jsonb(old)-array['stock_quantity','updated_at','ppv_per_unit','awarded_rate_override','vendor_submitted_price_pkr'])) then raise exception 'Only admin can manage bundles';end if;
 select * into v from public.vendors where id=new.vendor_id;
 base:=(b->>'base_total')::numeric; price:=(b->>'original_total')::numeric-(b->>'discount_pkr')::numeric;
 points:=(b->>'ppv')::numeric;rate:=(b->>'reference_rate')::numeric;
 if base is null or price is null or points is null or rate is null or base<=0 or price<=0 or points<0 or rate<=0 or price<>new.price_pkr then raise exception 'Invalid bundle price or PPV';end if;
 if coalesce((b->>'economics_version')::integer,0)=3 and ceil(points*rate*100)/100>((b->>'commission_pkr')::numeric-(b->>'company_fee_pkr')::numeric-(b->>'introducer_pkr')::numeric-(base-price)) then raise exception 'Bundle discount and PPV exceed the funded budget';end if;
 new.vendor_submitted_price_pkr:=base;new.ppv_per_unit:=points;
 new.awarded_rate_override:=trunc(points*rate/base,6);
 return new;
end $function$
;

-- Refresh published catalogue calculations under the new policy; order snapshots are untouched.
do $$
declare company uuid;old_uid text:=current_setting('request.jwt.claim.sub',true);b record;items jsonb;points numeric;discount numeric;rate numeric:=private.current_mio_reference_price();
begin
 select company_id into company from private.network_foundation limit 1;
 if company is null then return;end if;
 perform set_config('request.jwt.claim.sub',company::text,true);
 update public.products set ppv_per_unit=ppv_per_unit where bundle_definition is null and status<>'archived' and vendor_submitted_price_pkr>0;
 for b in select * from public.products where bundle_definition is not null and status<>'archived' loop
  select jsonb_agg(jsonb_build_object('product_id',x->>'product_id','quantity',(x->>'quantity')::integer)),sum(p.ppv_per_unit*(x->>'quantity')::integer)
  into items,points from jsonb_array_elements(b.bundle_definition->'items') x join public.products p on p.id=(x->>'product_id')::uuid;
  if b.bundle_definition->>'mode'='half_ppv' then discount:=round(points/2*rate,2);points:=trunc(points/2,4);else discount:=(b.bundle_definition->>'discount_pkr')::numeric;points:=b.ppv_per_unit;end if;
  begin
   perform public.admin_save_bundle(b.id,b.vendor_id,b.name,items,points,discount,rate,b.image_urls,b.status::text,coalesce(b.bundle_definition->>'mode','manual'));
  exception when others then
   -- Never publish an underfunded bundle. Preserve its details for explicit admin review.
   update public.products set status='draft',review_note='Pricing review required after product commission update: '||sqlerrm where id=b.id;
  end;
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(old_uid,''),true);
end $$;
