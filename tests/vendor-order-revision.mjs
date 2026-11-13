process.on('uncaughtException',e=>{console.error(e.message,e.detail||'',e.where||'',e.position||'');process.exit(1)});
import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const source=new URL('..',import.meta.url).pathname.replace(/\/$/,'');
const db=new PGlite(),q=(sql,args=[])=>db.query(sql,args),one=async(sql,args=[])=>Object.values((await q(sql,args)).rows[0])[0];
const uid=n=>{const h=createHash('sha256').update('bundles:'+n).digest('hex').slice(0,32);return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`};
const company=uid(1),buyer=uid(2),as=id=>q("select set_config('request.jwt.claim.sub',$1,false)",[id]);
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb,raw_app_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
alter default privileges grant execute on functions to anon,authenticated,service_role;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid() to anon,authenticated;`);
for(const file of (await readdir(source+'/schema')).filter(x=>/^\d+.*\.sql$/.test(x)).sort())await db.exec(await readFile(source+'/schema/'+file,'utf8'));
await db.exec('alter table public.products add column if not exists country_code text;alter table public.vendors add column if not exists country_code text');
// The production PIN helper is installed by the Supabase-only security migration.
await db.exec("create function private.require_transaction_pin(text,uuid) returns void language sql as $$select$$");
for(const file of ['20261103161000_maintenance_foundation.sql','20261103162000_maintenance_payments.sql','20261103163000_maintenance_bonus_eligibility.sql','20261104100000_monthly_maintenance_company_leftover.sql']) await db.exec(await readFile(source+'/supabase/migrations/'+file,'utf8'));
await q("update private.operator_setup set email='checkout-company@example.invalid'");
await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,'checkout-company@example.invalid',$2,'{\"provider\":\"google\"}')",[company,JSON.stringify({full_name:'Checkout company',phone:'00000000',terms_accepted:true})]);
await q("insert into public.user_roles(user_id,role) values($1,'admin')",[company]);await q("update public.member_profiles set status='active',terms_accepted_at=now() where user_id=$1",[company]);
const ref=await one('select referral_code from public.member_profiles where user_id=$1',[company]);
await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,'checkout-buyer@example.invalid',$2,'{}')",[buyer,JSON.stringify({full_name:'Checkout buyer',phone:'00000000',terms_accepted:true,referral_code:ref})]);await q("update public.member_profiles set status='active',terms_accepted_at=now() where user_id=$1",[buyer]);
await as(company);await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);await q("select public.admin_set_usd_to_pkr_rate(300,'Checkout test rate')");await q("select public.set_company_delivery(0,'Checkout test delivery')");
const vendor=await one("select public.create_company_brand('Checkout shop','','')");await q('select public.set_vendor_commission($1,.30)',[vendor]);const product=await one("insert into public.products(vendor_id,name,description,category,price_pkr,stock_quantity,status) values($1,'Checkout product','Checkout test','Tests',1000,100,'approved') returning id",[vendor]);
await q("update public.mio_wallet_accounts set balance=100 where member_id=$1",[buyer]);await q("insert into public.member_income_wallets(member_id,shopping_points,promotion_points) values($1,10000,20) on conflict(member_id)do update set shopping_points=10000,promotion_points=20",[buyer]);await as(buyer);


await as(company);
await db.exec(await readFile(source+'/supabase/migrations/20261110214233_product_commission_and_vendor_rewards.sql','utf8'));

await db.exec("alter table auth.users add column email_confirmed_at timestamptz");
await db.exec(await readFile(source+'/supabase/migrations/20261110215509_separate_vendor_portal.sql','utf8'));

await db.exec(await readFile(source+'/schema/network_control_mio_price_setter.sql','utf8'));
await q('insert into private.network_foundation(singleton,company_id,founder_id) values(true,$1,$2)',[company,buyer]);
await q("insert into public.system_config(config_key,version,config_value,effective_from,created_by) values('MIO_REFERENCE_PRICE_PKR',1,'300',now(),$1)",[company]);
await db.exec(await readFile(source+'/supabase/migrations/20261111162534_configurable_marketplace_bundles.sql','utf8'));
await db.exec(await readFile(source+'/supabase/migrations/20261111214405_customer_checkout_advance_and_sponsor_hold.sql','utf8'));
await db.exec("create table if not exists private.founder_invites(email text,token_hash text,expires_at timestamptz,redeemed_at timestamptz)");
await as(company);await q("select public.admin_save_product_economics($1,1000,null,null,0,'reserve')",[product]);
await db.exec(await readFile(source+'/supabase/migrations/20261111220641_shopping_user_signup_fields.sql','utf8'));
await db.exec('create trigger require_signup_gender before insert on auth.users for each row execute function private.validate_signup_gender()');
await db.exec(`create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid default gen_random_uuid() primary key,bucket_id text references storage.buckets(id),name text,metadata jsonb,unique(bucket_id,name));alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,insert on storage.objects to authenticated;`);

await db.exec(await readFile(source+'/supabase/migrations/20261112083603_shopping_account_and_affiliate_guest_flow.sql','utf8'));

// Notifications are part of the production schema; install their exact small primitives here.
const notificationSource=await readFile(source+'/supabase/migrations/20261103090000_marketplace_wallet_checkout_notifications.sql','utf8');
if(!await one("select to_regclass('public.member_notifications')"))await db.exec(notificationSource.slice(notificationSource.indexOf('create table public.member_notifications('),notificationSource.indexOf('alter table public.order_payment_allocations')));
await db.exec(notificationSource.slice(notificationSource.indexOf('create or replace function private.notify_member('),notificationSource.indexOf('create or replace function public.place_checkout_order(')));
await q('insert into public.binary_placements(member_id,parent_id,side,placed_by) values($1,null,null,$2) on conflict do nothing',[buyer,company]);
await db.exec(await readFile(source+'/supabase/migrations/20261112095844_shopping_membership_requests_and_notifications.sql','utf8'));
await q('grant usage on schema private to authenticated');

await db.exec(await readFile(source+'/tests/fixtures/order-production-base.sql','utf8'));
await db.exec(await readFile(source+'/supabase/migrations/20261112112240_vendor_shipments_funding_and_bundle_selection.sql','utf8'));
console.log('PASS revision migration installs against existing checkout, bundle, membership and reward functions');

const approx=(a,b)=>assert.ok(Math.abs(Number(a)-Number(b))<.00001,`${a} != ${b}`);
for(const [total,advance,hold] of [[300,300,2],[5999,600,2],[6000,600,2],[6001,600.10,2.0004],[10001,1000.10,3.3337]]){const r=await one('select private.customer_order_requirement($1,300)',[total]);approx(r.required_pkr,advance);approx(r.hold_mio,hold)}
console.log('PASS funding boundaries, small orders, currency rounding and upward MIO rounding');
await as(company);await q("select public.set_company_delivery(200,'Vendor delivery test')");
const v2=await one("select public.create_company_brand('Second vendor','','')");await q('select public.set_vendor_commission($1,.25)',[v2]);
const add=(v,name,price)=>one("insert into public.products(vendor_id,name,description,category,price_pkr,stock_quantity,status) values($1,$2,'Test product','Tests',$3,300,'approved') returning id",[v,name,price]);
const p1=await add(vendor,'First item',2000),p2=await add(v2,'Second item',2000);
const shopper=uid(900),stranger=uid(901);
for(const id of [shopper,stranger])await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,email_confirmed_at) values($1,$2,$3,'{\"provider\":\"email\"}',now())",[id,id+'@example.invalid',JSON.stringify({full_name:'QA customer',phone:'03000000000',registration_type:'customer',terms_accepted:true,country_code:'PK',affiliate_code:(await one('select member_code from public.member_profiles where user_id=$1',[buyer])).replace(/^MIO-/,'USR-')})]);
const lines=[{product_id:p1,quantity:2},{product_id:p2,quantity:2}];
const place=async(key,method='ADVANCE',items=lines)=>{await as(shopper);return one("select public.place_shopping_order($1,'QA Shopper','03000000000','Test delivery address','Islamabad',$2,$3,null)",[JSON.stringify(items),key,method])};
const details=async id=>one('select public.order_fulfillment_details($1)',[id]);
const order=await place('vendor-advance-order');let view=await details(order.order_id);assert.equal(view.shipments.length,2);approx(view.delivery_fee_pkr,400);approx(view.total_pkr,8400);approx(order.required_pkr,840);assert.equal(view.funding.ready,false);assert.equal(new Set(view.shipments.map(s=>s.invoice_number)).size,2);
await as(stranger);assert.equal(await details(order.order_id),null);await assert.rejects(()=>one("select public.advance_vendor_shipment($1,'confirmed')",[view.shipments[0].id]),/Admin/);
await as(company);await assert.rejects(()=>q("select public.advance_order_status($1,'confirmed')",[order.order_id]),/hold|advance/);await assert.rejects(()=>q("select public.admin_confirm_order_payment($1)",[order.order_id]),/only after delivery/);await assert.rejects(()=>q("update public.orders set status='processing' where id=$1",[order.order_id]),/hold|advance/);
await q("select public.set_company_delivery(350,'Rate changed after order')");const retry=await place('vendor-advance-order');assert.equal(retry.order_id,order.order_id);approx((await details(order.order_id)).total_pkr,8400);
console.log('PASS 4 items / 2 vendors = 2 fees; saved totals survive fee changes and retries; private invoice ownership; unfunded orders blocked at API and trigger');
await as(company);const account=await one("select public.admin_save_shopping_payment_account(null,'QA bank','QA account','03000000000','',true)");
async function submitPay(id,amount,reference){await as(shopper);const proof=shopper+'/'+id+'/'+reference+'.png';await q("insert into storage.objects(bucket_id,name,metadata) values('customer-payment-proofs',$1,'{\"mimetype\":\"image/png\",\"size\":300}')",[proof]);await q('select public.submit_order_payment($1,$2,$3,$4,$5)',[id,account,reference,proof,amount])}
await submitPay(order.order_id,840,'VENDOR-ADVANCE-REF');await as(company);await assert.rejects(()=>q('select public.admin_review_shopping_advance($1,true,8400,$2)',[order.order_id,'Wrong amount for evidence']),/exact/);
await q('select public.admin_review_shopping_advance($1,true,840,$2)',[order.order_id,'Verified transaction in bank']);view=await details(order.order_id);assert.equal(view.status,'placed');assert.equal(view.funding.ready,true);approx(view.funding.due_pkr,7560);approx(view.shipments.reduce((s,x)=>s+Number(x.paid_pkr),0),840);
const ships=view.shipments;
for(const stage of ['confirmed','processing','shipped','delivered'])await one('select public.advance_vendor_shipment($1,$2)',[ships[0].id,stage]);view=await details(order.order_id);assert.equal(view.status,'placed');assert.equal(view.rewards_credited_at,null);await assert.rejects(()=>q('select public.cancel_unpaid_order($1)',[order.order_id]),/already been dispatched/);assert.equal((await one("select public.advance_vendor_shipment($1,'delivered')",[ships[0].id])).duplicate,true);
await assert.rejects(()=>q('select public.admin_confirm_order_payment($1)',[order.order_id]),/only after delivery/);
for(const stage of ['confirmed','processing','shipped','delivered'])await one('select public.advance_vendor_shipment($1,$2)',[ships[1].id,stage]);view=await details(order.order_id);assert.equal(view.status,'delivered');assert.equal(view.rewards_credited_at,null);
await q('select public.admin_confirm_order_payment($1)',[order.order_id]);view=await details(order.order_id);assert.equal(view.payment_status,'confirmed');assert.ok(view.rewards_credited_at);const rewards=await one('select count(*) from public.ecommerce_rewards where order_id=$1',[order.order_id]);await q('select public.admin_confirm_order_payment($1)',[order.order_id]);assert.equal(await one('select count(*) from public.ecommerce_rewards where order_id=$1',[order.order_id]),rewards);
console.log('PASS partial advance allocation; independent shipments; parent waits for all vendors; COD confirmation only after delivery; reward release and action retries');
const full=await place('vendor-full-prepayment');view=await details(full.order_id);await submitPay(full.order_id,Number(view.total_pkr),'VENDOR-FULL-PAY');await as(company);await q('select public.admin_review_shopping_advance($1,true,$2,$3)',[full.order_id,view.total_pkr,'Verified full bank payment']);view=await details(full.order_id);assert.equal(view.payment_status,'confirmed');approx(view.funding.due_pkr,0);assert.equal(view.rewards_credited_at,null);
for(const stage of ['confirmed','processing','shipped','delivered'])await q('select public.advance_order_status($1,$2)',[full.order_id,stage]);assert.ok((await details(full.order_id)).rewards_credited_at);
const held=await place('vendor-sponsor-hold','SPONSOR');await as(buyer);await q("select public.review_affiliate_guest_order($1,true,'123456','vendor-hold-review','MIO')",[held.order_id]);await as(shopper);view=await details(held.order_id);assert.equal(view.funding.ready,true);approx(view.funding.due_pkr,view.total_pkr);approx(view.funding.paid_pkr,0);await as(company);await q('select public.cancel_unpaid_order($1)',[held.order_id]);assert.ok((await details(held.order_id)).shipments.every(s=>s.status==='cancelled'));
console.log('PASS full prepayment auto marks paid, delays rewards; sponsor security does not reduce COD; cancellation synchronizes shipments');
const refund=await place('cancelled-advance-order');await submitPay(refund.order_id,Number(refund.required_pkr),'QA-REFUND-ADVANCE');await as(company);await q('select public.admin_review_shopping_advance($1,true,$2,$3)',[refund.order_id,refund.required_pkr,'Verified partial advance']);await q('select public.cancel_unpaid_order($1)',[refund.order_id]);view=await details(refund.order_id);assert.equal(view.funding.payment_state,'refund_due');approx(view.funding.due_pkr,0);approx(view.funding.refund_due_pkr,refund.required_pkr);await q('select public.admin_record_shopping_refund($1,$2)',[refund.order_id,'QA-REFUND-TRANSACTION']);view=await details(refund.order_id);assert.equal(view.funding.payment_state,'refunded');approx(view.funding.paid_pkr,0);approx(view.funding.due_pkr,0);
console.log('PASS cancelled advance is refund pending, records completed refund, and never requests more COD');
await as(company);await q("update private.marketplace_bundle_types set required_units=case display_order when 4 then 9 when 5 then 12 else required_units end,status='enabled',ppv_divider=display_order+2");await q("insert into private.marketplace_bundle_types(name,required_units,ppv_divider,minimum_pkr,allow_repeats,status,display_order) overriding system value values('Bundle 6',15,8,3000,true,'enabled',6)");await q("update private.marketplace_bundle_types set allow_multiple_vendors=true where display_order>=3");
const tiers=await one('select public.marketplace_bundle_types()');
for(const tier of tiers){const items=[{product_id:p1,quantity:tier.required_units-1},{product_id:p2,quantity:1}];if(tier.display_order<=2){await assert.rejects(()=>one('select public.quote_marketplace_bundle($1,$2,$3)',[tier.id,vendor,JSON.stringify(items)]),/one vendor/);continue}const quote=await one('select public.quote_marketplace_bundle($1,$2,$3)',[tier.id,vendor,JSON.stringify(items)]);assert.equal(quote.vendor_count,2);approx(quote.ppv,Math.floor(quote.original_ppv/quote.divider*1e4)/1e4);approx(quote.vendors.reduce((n,v)=>n+Number(v.ppv),0),quote.ppv);approx(quote.vendors.reduce((n,v)=>n+Number(v.price_pkr),0),quote.price_pkr);assert.ok(quote.vendors.every(v=>v.items.every(i=>i.vendor_id===v.vendor_id)));}
const tier=tiers.find(t=>t.display_order===3),selection=[{product_id:p1,quantity:4},{product_id:p2,quantity:3}],quote=await one('select public.quote_marketplace_bundle($1,$2,$3)',[tier.id,vendor,JSON.stringify(selection)]);
await as(shopper);const req={p_items:[{product_id:p1,quantity:1}],p_idempotency_key:'mixed-vendor-bundle-order',p_shipping_name:'QA Shopper',p_shipping_phone:'03000000000',p_shipping_address:'Test delivery address',p_shipping_city:'Islamabad',p_funding_method:'ADVANCE'};
const bundle=await one('select public.place_configured_bundle_order($1,$2,$3,$4,$5)',[tier.id,vendor,JSON.stringify(selection),quote.quote_key,JSON.stringify(req)]);view=await details(bundle.order_id);assert.equal(view.shipments.length,2);approx(view.delivery_fee_pkr,700);approx(view.total_pkr,quote.price_pkr+2000+700);assert.equal((await q('select count(distinct vendor_id) n from public.order_items where order_id=$1',[bundle.order_id])).rows[0].n,2);assert.equal((await one('select public.place_configured_bundle_order($1,$2,$3,$4,$5)',[tier.id,vendor,JSON.stringify(selection),quote.quote_key,JSON.stringify(req)])).duplicate,true);
const stock=await one('select stock_quantity from public.products where id=$1',[p1]);await as(company);await q('select public.cancel_unpaid_order($1)',[bundle.order_id]);assert.equal(Number(await one('select stock_quantity from public.products where id=$1',[p1])),Number(stock)+5);await q('select public.cancel_unpaid_order($1)',[bundle.order_id]);assert.equal(Number(await one('select stock_quantity from public.products where id=$1',[p1])),Number(stock)+5);
console.log('PASS Bundle 1–2 vendor isolation, Bundle 3–6 multiple vendors, unchanged PPV dividers, original seller attribution, combined-cart delivery deduplication, idempotent bundle inventory restoration');
await as(buyer);const member=await one("select public.place_checkout_order($1,'QA Member','03000000000','Delivery address','Islamabad','member-vendor-cod-test','STANDARD','COD','123456')",[JSON.stringify(lines)]);const guarantee=(await q('select * from public.member_cod_guarantees where order_id=$1',[member.order_id])).rows[0];approx(guarantee.mio_amount,2.9);await as(company);await q("select public.set_company_delivery(500,'Another delivery update')");await as(buyer);assert.equal((await one("select public.place_checkout_order($1,'QA Member','03000000000','Delivery address','Islamabad','member-vendor-cod-test','STANDARD','COD','123456')",[JSON.stringify(lines)])).duplicate,true);approx((await details(member.order_id)).delivery_fee_pkr,700);
const split=await one("select public.place_checkout_order($1,'QA Member','03000000000','Delivery address','Islamabad','member-vendor-split-test','SHOPPING_POINTS','COD','123456')",[JSON.stringify(lines)]);assert.equal(Number(await one('select count(*) from public.member_cod_guarantees where order_id=$1',[split.order_id])),0);assert.equal((await details(split.order_id)).funding.ready,true);
console.log('PASS member COD uses total-based hold; saved delivery preserved on retry; established Shopping Points split exception remains valid');
await as(stranger);await q('set role authenticated');assert.equal(await details(order.order_id),null);await assert.rejects(()=>q('select * from private.order_vendor_shipments'),/permission denied/);await assert.rejects(()=>one('select public.admin_order_funding_states($1)',[[order.order_id]]),/Admin/);await q('reset role');
console.log('PASS actual authenticated role cannot read other customer shipments or invoke administrative funding controls');
// Verify the new percentage approval against the current shipment/advance checkout stack.
await as(company);
await db.exec("create or replace function public.current_user_is_admin() returns boolean language sql stable security definer set search_path='' as $$select private.has_role('admin')$$");
await db.exec(await readFile(source+'/supabase/migrations/20261113093126_seller_product_commission_proposals.sql','utf8'));
const oldItems=JSON.stringify((await q('select * from public.order_items where order_id=$1 order by id',[order.order_id])).rows);
const percentageProduct=await add(vendor,'Product percentage integration',1000);
await q("update public.products set status='pending',image_url='https://example.invalid/product.png' where id=$1",[percentageProduct]);
const submission=await one("insert into public.product_commission_proposals(product_id,requested_rate,submitted_by) values($1,.20,$2) returning submitted_at",[percentageProduct,company]);
await one("select public.admin_approve_product_with_economics($1,1000,null,.25,null,'reserve',$2)",[percentageProduct,submission]);
const percentageOrder=await place('approved-percentage-current-checkout','ADVANCE',[{product_id:percentageProduct,quantity:1}]);
const percentageSnapshot=(await q('select * from public.order_items where order_id=$1',[percentageOrder.order_id])).rows[0];
approx(percentageSnapshot.ppv_per_unit_snapshot,.5833);
approx(percentageSnapshot.economics_snapshot.commission,250);
approx(percentageSnapshot.economics_snapshot.company_fee,50);
approx(percentageSnapshot.economics_snapshot.introducer,25);
view=await details(percentageOrder.order_id);assert.equal(view.shipments.length,1);assert.equal(view.funding.ready,false);
await submitPay(percentageOrder.order_id,Number(view.total_pkr),'PERCENTAGE-INTEGRATION-PAY');await as(company);
await q('select public.admin_review_shopping_advance($1,true,$2,$3)',[percentageOrder.order_id,view.total_pkr,'Verified percentage test payment']);
for(const stage of ['confirmed','processing','shipped','delivered'])await q('select public.advance_order_status($1,$2)',[percentageOrder.order_id,stage]);
assert.ok((await details(percentageOrder.order_id)).rewards_credited_at);
const rewardsAfter=JSON.stringify((await q('select * from public.ecommerce_rewards where order_id=$1 order by id',[percentageOrder.order_id])).rows);
await q('select public.admin_confirm_order_payment($1)',[percentageOrder.order_id]);
assert.equal(JSON.stringify((await q('select * from public.ecommerce_rewards where order_id=$1 order by id',[percentageOrder.order_id])).rows),rewardsAfter);
const settledItem=(await q('select * from public.order_items where order_id=$1',[percentageOrder.order_id])).rows[0];
assert.deepEqual(settledItem.economics_snapshot,percentageSnapshot.economics_snapshot);
approx(settledItem.ppv_per_unit_snapshot,percentageSnapshot.ppv_per_unit_snapshot);
await q("select public.admin_save_product_economics($1,1000,null,.40,null,'reserve')",[percentageProduct]);
assert.equal(JSON.stringify((await q('select * from public.order_items where order_id=$1 order by id',[order.order_id])).rows),oldItems);
assert.equal(JSON.stringify((await q('select * from public.order_items where order_id=$1',[percentageOrder.order_id])).rows[0]),JSON.stringify(settledItem));
console.log('PASS approved product percentage survives current advance/shipment checkout, reward release, retry and later rate changes');
await db.close();
