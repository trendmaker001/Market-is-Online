import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';
const expires=Date.now()+86400000,aff='AFF-'+ 'A'.repeat(32);
const staleAffiliate={'mio-selling-link':JSON.stringify({code:aff,expires}),'mio-signup-context':JSON.stringify({kind:'customer',code:aff,expires})};
const staleMember={'mio-referral':'REF-OLD-L','mio-signup-context':JSON.stringify({kind:'member',code:'MEM-OLD-L',expires})};
const cases=[
 ['?member=MEM-QA-L#join','member','QA-L',staleAffiliate],
 ['?member=MEM-QA-R#join','member','QA-R',{}],
 ['?ref=REF-QA-R#join','member','QA-R',staleAffiliate],
 ['?affiliate='+aff+'#join','customer',aff,staleMember],
 ['?affiliate='+aff+'#shop','customer',aff,{}],
 ['?ref=MIO-QA#product/test','customer','USR-QA',staleMember],
 ['?affiliate=USR-QA#join','customer','USR-QA',{}],
 ['#join','customer',null,{}],
 ['#shop','customer',null,staleMember]
];
for(const [path,type,code,storage] of cases){
 const run=spawnSync(process.execPath,['tests/interface.mjs'],{encoding:'utf8',env:{...process.env,MIO_SIGNUP_URL:'https://mio.example.test/'+path,MIO_SIGNUP_EXPECT:JSON.stringify({type,code}),MIO_SIGNUP_STORAGE:JSON.stringify(storage)},timeout:30000});
 process.stdout.write(run.stdout);if(run.status!==0)process.stderr.write(run.stderr);assert.equal(run.status,0,path);
}
console.log('PASS all signup routes and stale attribution transitions');
