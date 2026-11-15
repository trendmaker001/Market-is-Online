import assert from 'node:assert/strict';
export async function run({q,w,calls,rows,fixtures,tick}){
 const d=w.document;let pin='1234',resolvePin;
 w.MioDashboard=new Proxy({hasTransactionPin:()=>true,requestTransactionPin:async()=>pin},{get:(t,p)=>t[p]||(()=>Promise.resolve())});
 const owner='qa';q.setSession({user:{id:owner}});q.setAdmin(false);q.setRouteReady(false);q.updateAuthNavigation();
 rows.member_profiles=[{user_id:owner,full_name:'SENDER',member_code:'MIO-SENDER',country_code:'PK',status:'active',terms_accepted_at:'2026-01-01'}];
 const card=()=>d.querySelector('.action-confirmation'),close=()=>card()?.querySelector('.action-confirmation-close').click();
 const openGold=()=>{w.MioSubscriptions.select('regular');return d.querySelector('[data-code="ADVANCED_2"]')};
 fixtures.activate_package_with_mio='activation-1';
 openGold().click();await tick();await tick();assert.match(card().textContent,/Congratulations!/);assert.match(card().textContent,/Gold/);assert.match(card().textContent,/110.00 MIO/);assert.equal(calls.filter(c=>c.rpc==='activate_package_with_mio').at(-1).args.p_transaction_pin,'1234');close();
 fixtures.activate_package_with_mio={__error:{message:'Invalid transaction PIN'}};openGold().click();await tick();assert.match(card().textContent,/Incorrect PIN/);assert.doesNotMatch(card().textContent,/Congratulations|Activated/);close();
 fixtures.activate_package_with_mio={__error:{message:'Insufficient balance'}};openGold().click();await tick();assert.equal(card(),null);assert.match(d.getElementById('toast').textContent,/Insufficient/);
 pin=null;const prior=calls.filter(c=>c.rpc==='activate_package_with_mio').length;openGold().click();await tick();assert.equal(calls.filter(c=>c.rpc==='activate_package_with_mio').length,prior);assert.equal(card(),null);
 // Two plan clicks during PIN entry must not enqueue a second purchase, and identity changes abort.
 w.MioDashboard.requestTransactionPin=()=>new Promise(resolve=>resolvePin=resolve);openGold().click();d.querySelector('[data-code="ADVANCED_1"]').click();q.setSession({user:{id:'other'}});q.updateAuthNavigation();resolvePin('1234');await tick();assert.equal(calls.filter(c=>c.rpc==='activate_package_with_mio').length,prior);assert.equal(card(),null);
 q.setSession({user:{id:owner}});q.updateAuthNavigation();w.MioDashboard.requestTransactionPin=async()=> '1234';fixtures.mio_transfer_to_member_code='transfer-1';
 const f=d.getElementById('transferForm'),code=d.getElementById('memberCode'),amount=d.getElementById('transferAmount');
 async function verify(){code.value='MIO-RECIPIENT';d.getElementById('verifyCashRecipient').click();await tick();amount.value='25'}
 await verify();f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();await tick();assert.match(card().textContent,/Points Transferred Successfully!/);assert.match(card().textContent,/POINTS TRANSFERRED/);assert.match(card().textContent,/25.00 MIO/);assert.match(card().textContent,/Recipient Name/);assert.ok(card().querySelector('.action-confirmation-download'));close();
 fixtures.mio_transfer_to_member_code={__error:{message:'Invalid transaction PIN'}};await verify();f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();assert.match(card().textContent,/Incorrect PIN/);assert.doesNotMatch(card().textContent,/Completed|POINTS TRANSFERRED/);close();
 fixtures.mio_transfer_to_member_code={__error:{message:'Insufficient balance'}};f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();assert.equal(card(),null);
 // Successful cards are cleared when the authenticated identity changes.
 fixtures.mio_transfer_to_member_code='transfer-2';f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();await tick();assert.ok(card());q.setSession(null);q.updateAuthNavigation();assert.equal(card(),null);
 console.log('PASS real activation and cash-transfer handlers: confirmed success cards, exact points wording, wrong PIN errors, failures/cancellation, duplicate activation prevention, account-switch abort and sign-out clearing');
}
