import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const source=new URL('..',import.meta.url).pathname.replace(/\/$/,'');
const db=new PGlite(),q=(sql,args=[])=>db.query(sql,args),one=async(sql,args=[])=>Object.values((await q(sql,args)).rows[0])[0];
const uid=n=>{const h=createHash('sha256').update('checkout-wallets:'+n).digest('hex').slice(0,32);return `${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`};
const company=uid(1),buyer=uid(2),as=id=>q("select set_config('request.jwt.claim.sub',$1,false)",[id]);
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb,raw_app_meta_data jsonb);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
alter default privileges grant execute on functions to anon,authenticated,service_role;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid() to anon,authenticated;`);
for(const file of (await readdir(source+'/schema')).filter(x=>/^\d+.*\.sql$/.test(x)).sort())await db.exec(await readFile(source+'/schema/'+file,'utf8'));
// The production PIN helper is installed by the Supabase-only security migration.
await db.exec("create function private.require_transaction_pin(text,uuid) returns void language sql as $$select$$");
for(const file of ['20261103161000_maintenance_foundation.sql','20261103162000_maintenance_payments.sql','20261103163000_maintenance_bonus_eligibility.sql','20261104100000_monthly_maintenance_company_leftover.sql'])
 await db.exec(await readFile(source+'/supabase/migrations/'+file,'utf8'));
await q("update private.operator_setup set email='checkout-company@example.invalid'");
await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,'checkout-company@example.invalid',$2,'{\"provider\":\"google\"}')",[company,JSON.stringify({full_name:'Checkout company',phone:'00000000',terms_accepted:true})]);
await q("insert into public.user_roles(user_id,role) values($1,'admin')",[company]);await q("update public.member_profiles set status='active',terms_accepted_at=now() where user_id=$1",[company]);
const ref=await one('select referral_code from public.member_profiles where user_id=$1',[company]);
await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,'checkout-buyer@example.invalid',$2,'{}')",[buyer,JSON.stringify({full_name:'Checkout buyer',phone:'00000000',terms_accepted:true,referral_code:ref})]);await q("update public.member_profiles set status='active',terms_accepted_at=now() where user_id=$1",[buyer]);
await as(company);await q("select set_config('request.jwt.claims',$1,false)",[JSON.stringify({aal:'aal2',amr:[{method:'totp',timestamp:Math.floor(Date.now()/1000)}]})]);await q("select public.admin_set_usd_to_pkr_rate(300,'Checkout test rate')");await q("select public.set_company_delivery(0,'Checkout test delivery')");
const vendor=await one("select public.create_company_brand('Checkout shop','','')");await q('select public.set_vendor_commission($1,.30)',[vendor]);const product=await one("insert into public.products(vendor_id,name,description,category,price_pkr,stock_quantity,status) values($1,'Checkout product','Checkout test','Tests',1000,100,'approved') returning id",[vendor]);
await q("update public.mio_wallet_accounts set balance=100 where member_id=$1",[buyer]);await q("insert into public.member_income_wallets(member_id,shopping_points,promotion_points) values($1,10000,20) on conflict(member_id)do update set shopping_points=10000,promotion_points=20",[buyer]);await as(buyer);
const activate=(member,code,key)=>q(`insert into public.package_activations(member_id,package_code,package_version,source,base_value,company_fee,payable_price,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,status,activated_at,idempotency_key)
 select $1,package_code,version,'ADMIN',base_value,company_fee,base_value+company_fee,ppv,bv,dp,gp,bp,brp,direct_rate,generation1_rate,binary_entitlement,'approved',now(),$2 from public.package_versions where package_code=$3 and is_active order by version desc limit 1`,[member,key,code]);
await activate(buyer,'BASIC_1','maintenance-buyer-package');
const before=await one('select public.my_maintenance_status()');assert.equal(Number(before.monthly_required_ppv),5);assert.equal(before.monthly_active,true);assert.equal(before.annual_active,true);
const annual=await one("select public.pay_annual_maintenance('1234','annual-one')");assert.equal(annual.fee_mio,20);assert.equal(annual.company_mio,10);assert.equal(annual.distributed_mio+annual.leftover_mio,10);
assert.equal((await one("select public.pay_annual_maintenance('1234','annual-one')")).duplicate,true);
assert.equal(Number(await one('select count(*) from public.annual_maintenance_payments where member_id=$1',[buyer])),1);
assert.equal(Number(await one('select balance from public.mio_wallet_accounts where member_id=$1',[buyer])),80);
console.log('PASS annual 20 MIO Cash Wallet debit, company/network reconciliation and idempotency');
const items=JSON.stringify([{product_id:product,quantity:2}]);
const order=await one("select public.place_maintenance_order($1,'Buyer','00000000','Checkout address','Lahore','maintenance-cod-one','SHOPPING_POINTS','COD','1234')",[items]);
assert.equal(order.maintenance,true);assert.equal(Number(await one('select count(*) from public.member_cod_guarantees where order_id=$1',[order.order_id])),1);
assert.equal(await one('select status from public.member_cod_guarantees where order_id=$1',[order.order_id]),'held');
assert.equal(Number(await one("select count(*) from public.ecommerce_rewards where order_id=$1 and status='pending_delivery'",[order.order_id])),0);
assert.equal((await one("select public.place_maintenance_order($1,'Buyer','00000000','Checkout address','Lahore','maintenance-cod-one','SHOPPING_POINTS','COD','1234')",[items])).duplicate,true);
console.log('PASS maintenance split COD uses refundable guarantee, prevents buyer rewards and is replay-safe');
await as(company);await q("update public.orders set payment_status='confirmed',status='delivered' where id=$1",[order.order_id]);
assert.equal(Number(await one('select count(*) from public.shopping_reward_events where order_id=$1',[order.order_id])),0);
assert.equal(Number(await one('select count(*) from public.point_ledger where source_order_id=$1',[order.order_id])),0);
assert.equal(Number(await one('select ppv_earned from public.maintenance_orders where order_id=$1',[order.order_id]))>0,true);
console.log('PASS delivered maintenance order bypasses ordinary DP/GP/BP and credits progress once');
const report=await one('select public.admin_monthly_maintenance_leftover()');
assert.equal(report.totals.orders,1);
assert.equal(Number(report.totals.leftover_mio),Number(report.totals.ppv)-Number(report.totals.distributed_mio));
assert.equal(report.recent[0].order_id,order.order_id);
assert.equal(Number(await one("select sum(amount) from private.company_treasury_sources() where category='monthly_maintenance_leftover' and source_id=$1",[order.order_id])),Number(report.totals.leftover_mio));
await q("update public.orders set status='delivered' where id=$1",[order.order_id]);
assert.deepEqual(await one('select public.admin_monthly_maintenance_leftover()'),report);
console.log('PASS settled PPV remainder is recorded exactly once in dedicated and company reports');

const {rules}=await one('select public.admin_maintenance_program()');
const tiers=[
 ['Starter','BASIC_1',5,2,8,3,4,1],
 ['Basic','BASIC_2',5,4,9,5,4,3],
 ['Silver','ADVANCED_1',5,6,10,7,4,5],
 ['Gold','ADVANCED_2',10,8,20,9,9,7],
 ['Platinum','PREMIUM',10,10,25,10,9,9]
];
assert.deepEqual(rules.monthly_rates,Array(10).fill(.1));
assert.deepEqual(rules.monthly_ppv,Object.fromEntries(tiers.map(([,code,ppv])=>[code,ppv])));
assert.deepEqual(rules.monthly_levels,Object.fromEntries(tiers.map(([,code,,limit])=>[code,limit])));

async function createMember(member,sponsor){
 const referral=await one('select referral_code from public.member_profiles where user_id=$1',[sponsor]);
 await q("insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values($1,$2,$3,'{}')",
  [member,member+'@example.invalid',JSON.stringify({full_name:'Maintenance test',phone:'00000000',terms_accepted:true,referral_code:referral})]);
}
const chain=[];
let sponsor=company;
for(let depth=11;depth>=1;depth--){
 const member=uid(depth+10);
 await createMember(member,sponsor);
 await activate(member,'PREMIUM','maintenance-chain-'+depth);
 chain[depth]=member;
 sponsor=member;
}
await createMember(uid(30),chain[1]);
const shopper=uid(30);
await activate(shopper,'BASIC_2','maintenance-chain-shopper');
await q('update public.mio_wallet_accounts set balance=1000 where member_id=$1',[shopper]);
const setTier=(member,code)=>q("update public.package_activations set package_code=$2 where member_id=$1 and status='approved'",[member,code]);
const save=(config,version)=>one('select public.admin_set_maintenance_rules($1,$2)',[config,version]);
let version=rules.version;

async function checkBoundary(code,limit,key){
 await setTier(chain[limit],code);
 await setTier(chain[limit+1],code);
 await as(shopper);
 const checkout=await one("select public.place_maintenance_order($1,'Buyer','00000000','Checkout address','Lahore',$2,'STANDARD','MIO','1234')",[items,key]);
 assert.equal(checkout.required_ppv,Number((await one('select public.my_maintenance_status()')).monthly_required_ppv));
 await as(company);
 await q("update public.orders set payment_status='confirmed',status='delivered' where id=$1",[checkout.order_id]);
 const payouts=(await q('select beneficiary_id,generation,amount_mio from public.maintenance_generation_payouts where order_id=$1',[checkout.order_id])).rows;
 const atLimit=payouts.find(p=>p.beneficiary_id===chain[limit]);
 assert.equal(atLimit?.generation,limit);
 assert.equal(Number(atLimit.amount_mio),Math.round(Number(checkout.order_ppv)*.1*1e8)/1e8);
 assert.ok(!payouts.some(p=>p.beneficiary_id===chain[limit+1]));
 await setTier(chain[limit],'PREMIUM');
 await setTier(chain[limit+1],'PREMIUM');
}

for(const [name,code,ppv,limit,highPpv,highLimit,lowPpv,lowLimit] of tiers){
 await checkBoundary(code,limit,'default-'+code);
 await createMember(uid(version+50),company);
 const member=uid(version+50);
 await activate(member,code,'maintenance-config-'+code);
 for(const [targetPpv,targetLimit] of [[highPpv,highLimit],[lowPpv,lowLimit],[ppv,limit]]){
  const snapshot=await save({...rules,monthly_ppv:{...rules.monthly_ppv,[code]:targetPpv},
   monthly_levels:{...rules.monthly_levels,[code]:targetLimit}},version);
  version=snapshot.version;
  assert.deepEqual(snapshot.monthly_ppv,{...rules.monthly_ppv,[code]:targetPpv});
  assert.deepEqual(snapshot.monthly_levels,{...rules.monthly_levels,[code]:targetLimit});
  await as(member);
  assert.equal(Number((await one('select public.my_maintenance_status()')).monthly_required_ppv),targetPpv);
  await as(company);
  if(targetLimit!==limit)await checkBoundary(code,targetLimit,`edited-${code}-${targetLimit}`);
 }
 console.log(`PASS ${name}: PPV ${ppv} → ${highPpv} → ${lowPpv} → ${ppv}; generations ${limit} → ${highLimit} → ${lowLimit} → ${limit}; payout boundary ${limit}/${limit+1}`);
}

const next={...rules,monthly_rates:[.19,.18,.16,.13,.1,.08,.06,.05,.04,.01]};
const updated=await save(next,version);
assert.deepEqual(updated.monthly_rates,next.monthly_rates);
assert.deepEqual(updated.annual_rates,rules.annual_rates);
await assert.rejects(save({...next,monthly_levels:{...rules.monthly_levels,PREMIUM:11}},updated.version),/Invalid package maintenance rule/);
await as(shopper);
const customOrder=await one("select public.place_maintenance_order($1,'Buyer','00000000','Checkout address','Lahore','custom-rates','STANDARD','MIO','1234')",[items]);
await as(company);
await q("update public.orders set payment_status='confirmed',status='delivered' where id=$1",[customOrder.order_id]);
const customPayouts=(await q('select generation,amount_mio from public.maintenance_generation_payouts where order_id=$1 order by generation',[customOrder.order_id])).rows;
assert.deepEqual(customPayouts.map(p=>p.generation),[1,2,3,4,5,6,7,8,9,10]);
assert.deepEqual(customPayouts.map(p=>Number(p.amount_mio)),next.monthly_rates.map(rate=>Math.round(Number(customOrder.order_ppv)*rate*1e8)/1e8));

await assert.rejects(save(next,version),/Settings changed/);
await assert.rejects(save({...next,monthly_rates:[.2,...next.monthly_rates.slice(1)]},updated.version),/exceeds 100 percent/);
await as(buyer);
await assert.rejects(q('select public.admin_monthly_maintenance_leftover()'),/Admin access required/);
await assert.rejects(save(next,updated.version),/Admin access required/);
console.log('PASS separate generation percentages, version checks, and admin-only writes');
await as(shopper);
const annualForStatement=await one("select public.pay_annual_maintenance('1234','annual-statement')");
await as(chain[1]);
await db.exec('set role authenticated');
const statementRows=(await q('select beneficiary_id,maintenance_kind,generation,amount_mio,order_id,annual_payment_id from public.maintenance_generation_payouts')).rows;
assert.ok(statementRows.every(row=>row.beneficiary_id===chain[1]));
assert.equal(Number(statementRows.find(row=>row.maintenance_kind==='monthly'&&row.order_id===customOrder.order_id).amount_mio),Number(customPayouts[0].amount_mio));
assert.equal(Number(statementRows.find(row=>row.maintenance_kind==='annual'&&row.annual_payment_id===annualForStatement.payment_id).amount_mio),7);
await db.exec('reset role');
console.log('PASS income statement data includes both credited payout types and is restricted to the recipient');

await db.close();
