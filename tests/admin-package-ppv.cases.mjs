import assert from 'node:assert/strict';

export async function testAdminPackagePPV({db,q,one,save,state,target,other,as,admin}) {
 await q('insert into public.member_income_wallets(member_id) values($1) on conflict do nothing',[target]);
 const rejects=async(action,pattern)=>{
  await db.exec('savepoint rejected_request');
  try {await assert.rejects(action,pattern);}
  finally {await db.exec('rollback to savepoint rejected_request; release savepoint rejected_request');}
 };
 const total=()=>one("select coalesce(sum(amount),0)::float8 from public.point_ledger where member_id=$1 and point_type='PPV'",[target]);
 const counts=()=>one(`select jsonb_build_object(
 'other_points',(select count(*) from public.point_ledger where point_type<>'PPV'),
 'bonuses',(select count(*) from public.bonus_transactions),
 'mio',(select count(*) from public.mio_ledger),
 'income',(select count(*) from public.income_wallet_ledger),
 'manager',(select count(*) from public.manager_point_ledger),
 'wallets',(select jsonb_agg(to_jsonb(w) order by member_id) from public.member_income_wallets w),
 'cash',(select jsonb_agg(to_jsonb(w) order by member_id) from public.mio_wallet_accounts w))`);
 const plans=(await q("select distinct on(package_code) package_code,ppv::float8 ppv from public.package_versions where is_active order by package_code,version desc")).rows.sort((a,b)=>a.ppv-b.ppv);
 // Every package must grant its full PPV when assigned to a free account.
 for(const p of plans){
  await db.exec('begin');
  try {
   const before=await counts(),mode=await one('select shopping_reward_mode from public.member_profiles where user_id=$1',[target]);
   const expected=(await state()).account,key=crypto.randomUUID();
   await save('account',{package_code:p.package_code},expected,key);
   assert.equal(await total(),p.ppv);
   await save('account',{package_code:p.package_code},expected,key);
   await save('account',{package_code:p.package_code});
   assert.equal(await total(),p.ppv,'Retries and repeated saves cannot duplicate PPV');
   assert.deepEqual(await counts(),before,'Package PPV must not create any other points, bonuses or wallet changes');
   assert.equal(await one('select shopping_reward_mode from public.member_profiles where user_id=$1',[target]),mode);
  } finally {await db.exec('rollback');}
 }
 await db.exec('begin');
 try {
  const order=await one(`insert into public.orders(order_code,buyer_id,subtotal_pkr,total_pkr,shipping_name,shipping_phone,shipping_address,shipping_city,idempotency_key)
   values('PPV-TEST',$1,100,100,'Test','000','Test','Test','ppv-test-order') returning id`,[target]);
  await q("insert into public.point_ledger(member_id,point_type,amount,source_order_id,entry_kind,idempotency_key) values($1,'PPV',3,$2,'credit','ppv-test-shopping')",[target,order]);
  const before=await counts();
  for(const p of plans){
   await save('account',{package_code:p.package_code});
   assert.equal(await total(),p.ppv+3,'Shopping PPV stays additional during upgrades');
  }
  const highest=plans.at(-1);
  await save('account',{package_code:plans[0].package_code});
  await save('account',{package_code:null});
  await save('account',{package_code:highest.package_code});
  assert.equal(await total(),highest.ppv+3,'Downgrade/remove/reassign preserves PPV without double credit');
  const stale=(await state()).account;
  await save('account',{package_code:plans[0].package_code});
  await rejects(()=>save('account',{package_code:highest.package_code},stale),/data changed/);
  await rejects(()=>save('account',{package_code:'INVALID'}),/Unknown package/);
  assert.equal(await total(),highest.ppv+3);
  assert.deepEqual(await counts(),before);
 } finally {await db.exec('rollback');}
 await db.exec('begin');
 try {
  const highest=plans.at(-1);
  await save('points',{ppv:highest.ppv});
  await save('account',{package_code:highest.package_code});
  assert.equal(await total(),highest.ppv,'Existing manual PPV must not be duplicated');
  await as(other);
  await rejects(()=>save('account',{package_code:plans[0].package_code},{},crypto.randomUUID(),target),/Admin/);
  await as(admin);
  await db.exec("set test.totp='no'");
  await rejects(()=>save('account',{package_code:plans[0].package_code}),/Authenticator/);
 } finally {await db.exec('rollback');await as(admin);}
 console.log('PASS automatic package PPV: all tiers, retries, upgrades, shopping isolation, reassign, manual credit, stale saves and authorization');
}
