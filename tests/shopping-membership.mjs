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
await db.exec('alter table public.products add column if not exists country_code text');
// The production PIN helper is installed by the Supabase-only security migration.
await db.exec("create function private.require_transaction_pin(text,uuid) returns void language sql as $$select$$");
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
await db.exec(await readFile(source+'/supabase/migrations/20261113200000_separate_member_user_affiliate_codes.sql','utf8'));
const signup=async(n,referral=null,verified=true)=>{const id=uid(n);await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,email_confirmed_at) values($1,$2,$3,'{\"provider\":\"email\"}',$4)",[id,'membership-'+n+'@example.invalid',JSON.stringify({full_name:'Customer '+n,phone:'03000000000',registration_type:'customer',terms_accepted:true,affiliate_code:referral,shipping_address:'Saved street address',shipping_city:'Islamabad'}),verified?new Date().toISOString():null]);return id};
const code=await one('select affiliate_code from public.member_profiles where user_id=$1',[buyer]);
const direct=await signup(500),linked=await signup(501,code),other=await signup(502),unverified=await signup(503,code,false);
const request=async(id)=>{await as(id);return (await one('select public.request_shopping_membership(true)')).request};
const review=(id,approve,side=null,note='')=>one('select public.review_shopping_membership($1,$2,$3,$4)',[id,approve,side,note]);
await as(unverified);await assert.rejects(()=>request(unverified),/Verify your email/);
await as(linked);await assert.rejects(()=>q('select public.request_shopping_membership(false)'),/accept/);
const lr=await request(linked);assert.equal(lr.status,'pending_sponsor');assert.equal(lr.sponsor_id,buyer);assert.ok(lr.sponsor_member_code.startsWith('MIO-'));assert.equal((await request(linked)).id,lr.id);
assert.equal(Number(await one('select count(*) from public.member_profiles where user_id=$1',[linked])),0);
await as(other);await assert.rejects(()=>review(lr.id,true,'LEFT'),/assigned sponsor/);assert.equal((await one('select public.shopping_messages()')).total,0);await assert.rejects(()=>one('select public.shopping_membership_queue(true)'),/Admin/);
await as(buyer);await assert.rejects(()=>review(lr.id,true),/Left or Right/);assert.equal(Number(await one('select count(*) from public.member_profiles where user_id=$1',[linked])),0);
await assert.rejects(()=>review(lr.id,true,'LEFT'),/activate a plan/);assert.equal(Number(await one('select count(*) from public.member_profiles where user_id=$1',[linked])),0);await q("select public.activate_package_with_mio('BASIC_1','membership-sponsor-plan')");assert.equal((await review(lr.id,true,'LEFT')).status,'completed');assert.equal((await review(lr.id,true,'RIGHT')).already_reviewed,true);
assert.equal((await one('select side from public.binary_placements where member_id=$1',[linked])),'LEFT');assert.equal((await one('select sponsor_id from public.member_profiles where user_id=$1',[linked])),buyer);
assert.equal(Number(await one('select count(*) from public.package_activations where member_id=$1',[linked])),0);
console.log('PASS linked User approval, separate codes, consent, email verification, mandatory leg, duplicate prevention, no paid package');
const dr=await request(direct);assert.equal(dr.status,'pending_admin');await as(buyer);await assert.rejects(()=>review(dr.id,true,'RIGHT'),/Admin/);
await as(company);assert.equal((await review(dr.id,true)).status,'awaiting_founder');assert.equal(Number(await one('select count(*) from public.member_profiles where user_id=$1',[direct])),0);assert.equal(await one('select sponsor_id from private.customer_identities where user_id=$1',[direct]),buyer);
assert.equal((await review(dr.id,true,'RIGHT')).already_reviewed,true);assert.equal(Number(await one('select count(*) from public.member_profiles where user_id=$1',[direct])),0);
await as(direct);assert.match(JSON.stringify(await one('select public.shopping_messages()')),/Admin approved/);
await as(buyer);assert.ok((await one('select public.shopping_membership_queue()')).rows.some(r=>r.id===dr.id));assert.equal((await review(dr.id,true,'RIGHT')).status,'completed');assert.equal(await one('select parent_id from public.binary_placements where member_id=$1',[direct]),buyer);
console.log('PASS direct request requires admin, then Founder-only placement; admin cannot complete Founder placement');
const decline=await signup(504,code);const rr=await request(decline);await as(buyer);await assert.rejects(()=>review(rr.id,false),/reason/);await review(rr.id,false,null,'Please update your profile');await as(decline);assert.equal((await one('select public.shopping_membership_status()')).request.status,'declined');assert.equal(Number(await one('select count(*) from public.member_profiles where user_id=$1',[decline])),0);assert.match(JSON.stringify(await one('select public.shopping_messages()')),/Please update/);
const messages=await one('select public.shopping_messages()');await as(other);await q('select public.read_shopping_messages($1)',[messages.rows[0].id]);await as(decline);assert.ok((await one('select public.shopping_messages()')).unread>0);await q('select public.read_shopping_messages()');assert.equal((await one('select public.shopping_messages()')).unread,0);
console.log('PASS decline reason, customer inbox isolation, mark-one/all-read ownership');
const shopper=await signup(505,code);await as(shopper);const profile=await one('select public.my_shopping_account()');assert.equal(profile.shipping_city,'Islamabad');assert.equal(profile.shipping_address,'Saved street address');
const place=method=>one("select public.place_shopping_order($1,'Customer','03000000000','Saved street address','Islamabad',$2,$3,null)",[JSON.stringify([{product_id:product,quantity:1}]),'new-flow-'+method,method]);
const advance=await place('ADVANCE'),hold=await place('SPONSOR');assert.ok((await one('select public.shopping_messages()')).rows.some(r=>r.route==='account/prepayments/'+advance.order_id));assert.ok((await one('select public.shopping_messages()')).rows.some(r=>r.route==='account/orders/'+hold.order_id));
const details=await one('select public.shopping_order_details($1)',[advance.order_id]);assert.equal(details.id,advance.order_id);await as(other);assert.equal(await one('select public.shopping_order_details($1)',[advance.order_id]),null);
await as(buyer);await q("select public.review_affiliate_guest_order($1,true,'123456','new-flow-hold-review','MIO')",[hold.order_id]);await as(shopper);assert.ok((await one('select public.shopping_messages()')).rows.some(r=>r.message.includes('approved')));
await as(company);const bank=await one("select public.admin_save_shopping_payment_account(null,'Test','Test Account','12345678','',true)");await as(shopper);await q("select public.submit_shopping_advance($1,$2,'NEW-FLOW-ADVANCE')",[advance.order_id,bank]);await as(company);await q("select public.admin_review_shopping_advance($1,true,600,'Verified bank transfer')",[advance.order_id]);await as(shopper);const after=await one('select public.shopping_messages()');assert.ok(after.rows.some(r=>r.title==='Payment approved'));assert.ok(after.rows.some(r=>r.title==='Order confirmed'));assert.equal((await one('select public.shopping_order_details($1)',[advance.order_id])).cod_due_pkr,400);
console.log('PASS order-specific payment/sponsor/status notifications, secure detail links and initial saved address');
for(const sig of ['public.place_guest_affiliate_order(jsonb,text,text,text,text,text,text,text,text)','public.place_configured_bundle_order(uuid,uuid,jsonb,text,jsonb)','public.join_network_from_shopping(text,boolean)'])assert.equal(await one("select has_function_privilege('anon',$1,'execute')",[sig]),false);
assert.equal(await one("select has_function_privilege('authenticated','public.join_network_from_shopping(text,boolean)','execute')"),false);
await as(other);await q('set role authenticated');await assert.rejects(()=>q('select * from private.shopping_membership_requests'),/permission denied/);await assert.rejects(()=>q("select public.review_shopping_membership($1,true,'LEFT','')",[lr.id]),/assigned sponsor/);await q('reset role');
console.log('PASS anonymous placement and old upgrade revoked; request tables private; actual authenticated role enforced');
// Install the current read functions and exercise visibility after real User-to-Member approval.
await db.exec(`alter table public.member_profiles add column if not exists country_code text;
alter table public.member_profiles add column if not exists gender text;
create table if not exists private.member_admin_baselines(member_id uuid primary key,package_assigned boolean default false,package_code text,activation_id uuid,package_assigned_at timestamptz,consumed_left numeric default 0,consumed_right numeric default 0);`);
for(const file of ['20261103161000_maintenance_foundation.sql','20261103162000_maintenance_payments.sql','20261103163000_maintenance_bonus_eligibility.sql'])await db.exec(await readFile(source+'/supabase/migrations/'+file,'utf8'));
await db.exec(await readFile(source+'/tests/fixtures/production-binary-qualification.sql','utf8'));
await db.exec(await readFile(source+'/tests/fixtures/network-visibility-production.sql','utf8'));
await as(buyer);
const beforeBinary=await one("select public.my_network_identity('binary',null,10)");
assert.ok(beforeBinary.nodes.some(n=>n.id===linked&&n.package===null));
await db.exec(await readFile(source+'/supabase/migrations/20261112130218_paid_binary_tree_visibility.sql','utf8'));
for(const kind of ['binary','single_line','pool']){
 const tree=await one('select public.my_network($1,null,10)',[kind]);
 assert.ok(tree.nodes.some(n=>n.id===buyer));assert.ok(tree.nodes.every(n=>n.package));
 assert.ok(!tree.nodes.some(n=>n.id===linked||n.id===direct));
 const original=beforeBinary.nodes.find(n=>n.id===buyer),visible=await one("select public.my_network_identity('binary',null,10)");
 const {placement_path,...unchanged}=visible.nodes.find(n=>n.id===buyer);assert.deepEqual(unchanged,original);assert.equal(placement_path,'');
}
assert.ok((await one("select public.my_network_identity('generation',null,10)")).nodes.some(n=>n.id===linked));
await as(linked);assert.equal((await one("select public.my_network_identity('single_line',null,30)")).nodes.length,0);
console.log('PASS approved User-to-Member remains Free and hidden from both binary views; paid metrics and Generation membership unchanged');
const paidChild=await signup(506,code),pc=await request(paidChild);await as(buyer);await review(pc.id,true,'LEFT');
assert.equal(await one('select parent_id from public.binary_placements where member_id=$1',[paidChild]),linked);
await q('update public.mio_wallet_accounts set balance=100 where member_id=$1',[paidChild]);await as(paidChild);
await q("select public.activate_package_with_mio('BASIC_1','paid-child-tree-test')");
await as(buyer);const nested=await one("select public.my_network_identity('binary',null,10)");
assert.ok(!nested.nodes.some(n=>n.id===linked));const child=nested.nodes.find(n=>n.id===paidChild);
assert.equal(child.parent_id,linked);assert.equal(child.placement_path,'LL');assert.equal(child.depth,2);
await as(linked);const fromFree=await one("select public.my_network_identity('single_line',null,30)");assert.equal(fromFree.nodes.length,1);assert.equal(fromFree.nodes[0].id,paidChild);assert.equal(fromFree.nodes[0].placement_path,'L');
await as(company);const adminTree=await one("select public.my_network_identity('binary',null,0)");assert.ok(adminTree.nodes.every(n=>n.package));assert.ok(adminTree.nodes.some(n=>n.id===paidChild));
await as(buyer);await q('set role authenticated');assert.ok((await one("select public.my_network_identity('binary',null,10)")).nodes.every(n=>n.package));await assert.rejects(()=>q("select private.paid_binary_tree_view('{}','binary')"),/permission denied/);await q('reset role');
await as(other);await assert.rejects(async()=>q("select public.my_network_identity('binary',$1,10)",[await one('select member_code from public.member_profiles where user_id=$1',[paidChild])]),/Active account|outside/);
console.log('PASS paid descendant below hidden Free parent preserves exact side/depth, admin view, private helper permissions and unrelated-user rejection');
const snapshot=async()=>{const result={};for(const table of ['binary_placements','member_profiles','point_ledger','package_activations','system_config'])result[table]=await one("select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]') from public."+table+' t');return result};
const originalData=await snapshot();await as(buyer);
for(const kind of ['binary','single_line','generation','vendor'])await one('select public.my_network_identity($1,null,10)',[kind]);
assert.deepEqual(await snapshot(),originalData);
await q('update public.mio_wallet_accounts set balance=100 where member_id=$1',[linked]);await as(linked);await q("select public.activate_package_with_mio('BASIC_1','free-to-paid-tree-test')");await as(buyer);
assert.ok((await one("select public.my_network_identity('binary',null,10)")).nodes.some(n=>n.id===linked));
console.log('PASS tree reads leave placement, points, package and config records untouched; actual paid activation makes the member visible');

// Count only paid Members while preserving hidden placement paths.
await db.exec(await readFile(source+'/supabase/migrations/20261113210000_paid_binary_team_counts.sql','utf8'));
await as(buyer);
const paidCounts=await one('select private.binary_team_counts($1)',[buyer]);assert.deepEqual(paidCounts,{left:2,right:0});
const buyerCode=await one('select member_code from public.member_profiles where user_id=$1',[buyer]);
const detail=await one('select public.member_binary_placement_details($1)',[buyerCode]);assert.equal(detail.total_team,2);assert.equal(detail.levels.reduce((n,x)=>n+x.member_count,0),2);
const treeCounts=(await one("select public.my_network_identity('binary',null,10)")).nodes.find(n=>n.id===buyer);assert.equal(treeCounts.left_team_count,2);assert.equal(treeCounts.right_team_count,0);
const financialBefore=await snapshot();await one('select public.member_binary_placement_details($1)',[buyerCode]);assert.deepEqual(await snapshot(),financialBefore);
for(const kind of ['generation','binary','single_line','vendor']){await as(other);await assert.rejects(()=>one('select public.my_network_identity($1,null,10)',[kind]),/Active account|Sign in/);}
await db.exec('alter table private.founder_invites add column if not exists singleton boolean default true,add column if not exists pending_user_id uuid');
const newMembers=[];
for(const [n,side] of [[701,'L'],[702,'R']]){
 const id=uid(n),referral=await one('select referral_code from public.member_profiles where user_id=$1',[buyer]);
 await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,email_confirmed_at) values($1,$2,$3,'{\"provider\":\"email\"}',now())",[id,'new-member-'+n+'@example.invalid',JSON.stringify({registration_type:'member',full_name:'New Member '+side,phone:'03000000000',gender:'male',country_code:'PK',terms_accepted:true,referral_code:'MEM-'+referral+'-'+side})]);
 newMembers.push(id);await as(buyer);
 assert.equal(await one('select sponsor_id from public.member_profiles where user_id=$1',[id]),buyer);
 assert.equal(Number(await one('select count(*) from public.binary_placements where member_id=$1',[id])),0);
 assert.ok((await one("select public.my_network_identity('generation',null,10)")).nodes.some(n=>n.id===id));
 for(const kind of ['binary','single_line'])assert.ok(!(await one('select public.my_network_identity($1,null,10)',[kind])).nodes.some(n=>n.id===id));
 await q('update public.mio_wallet_accounts set balance=100 where member_id=$1',[id]);await as(id);await q("select public.activate_package_with_mio('BASIC_1',$1)",['new-member-activation-'+n]);await as(buyer);
 for(const kind of ['binary','single_line']){const activated=(await one('select public.my_network_identity($1,null,10)',[kind])).nodes.find(n=>n.id===id);assert.ok(activated);assert.ok(activated.placement_path.startsWith(side));}
 assert.equal(Number(await one('select count(*) from public.binary_placements where member_id=$1',[id])),1);
}
await as(buyer);const finalCounts=await one('select private.binary_team_counts($1)',[buyer]);assert.deepEqual(finalCounts,{left:3,right:1});
assert.equal((await one('select public.member_binary_placement_details($1)',[buyerCode])).total_team,4);
console.log('PASS shopping Users denied all trees; new MEM Left/Right joins appear in Generation only until paid activation; paid-only team/level counts and exact placement preserved without financial changes');

await db.close();
