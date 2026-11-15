import assert from 'node:assert/strict';
export async function run({q,w,calls,rows,fixtures,tick}){
 const d=w.document;let pin='txauth_'+'a'.repeat(64),resolvePin;
 w.MioDashboard=new Proxy({hasTransactionPin:()=>true,requestTransactionPin:async()=>pin},{get:(t,p)=>t[p]||(()=>Promise.resolve())});
 const owner='qa';q.setSession({user:{id:owner}});q.setAdmin(false);q.setRouteReady(false);q.updateAuthNavigation();
 rows.member_profiles=[{user_id:owner,full_name:'SENDER',member_code:'MIO-SENDER',country_code:'PK',status:'active',terms_accepted_at:'2026-01-01'}];
 const card=()=>d.querySelector('.action-confirmation'),close=()=>card()?.querySelector('.action-confirmation-close').click();
 const openGold=()=>{w.MioSubscriptions.select('regular');return d.querySelector('[data-code="ADVANCED_2"]')};
 fixtures.activate_package_with_mio='activation-1';q.setProfile(rows.member_profiles[0]);rows.package_activations=[{id:'activation-1',member_id:owner,activated_at:'2026-11-15T18:45:31Z'}];
 openGold().click();await tick();await tick();assert.match(card().textContent,/Congratulations, SENDER!/);assert.match(card().textContent,/Gold/);assert.match(card().textContent,/15 Nov 2026/);assert.match(card().textContent,/11:45:31 pm PKT/);assert.match(card().textContent,/110.00 MIO/);assert.equal(calls.filter(c=>c.rpc==='activate_package_with_mio').at(-1).args.p_transaction_pin,pin);close();
 fixtures.activate_package_with_mio={__error:{message:'Invalid transaction PIN'}};openGold().click();await tick();assert.match(card().textContent,/Incorrect PIN/);assert.doesNotMatch(card().textContent,/Congratulations|Activated/);close();
 fixtures.activate_package_with_mio={__error:{message:'Insufficient balance'}};openGold().click();await tick();assert.equal(card(),null);assert.match(d.getElementById('toast').textContent,/Insufficient/);
 fixtures.activate_package_with_mio={__error:{message:'Insufficient MIO Points. Required: 550.00 MIO. Available in Cash Wallet: 549.9994 MIO. Shortfall: 0.0006 MIO.'}};openGold().click();await tick();assert.match(card().textContent,/549\.9994/);assert.match(card().textContent,/0\.0006/);assert.doesNotMatch(card().textContent,/Congratulations/);close();
 pin=null;const prior=calls.filter(c=>c.rpc==='activate_package_with_mio').length;openGold().click();await tick();assert.equal(calls.filter(c=>c.rpc==='activate_package_with_mio').length,prior);assert.equal(card(),null);
 // Two plan clicks during PIN entry must not enqueue a second purchase, and identity changes abort.
 w.MioDashboard.requestTransactionPin=()=>new Promise(resolve=>resolvePin=resolve);openGold().click();d.querySelector('[data-code="ADVANCED_1"]').click();q.setSession({user:{id:'other'}});q.updateAuthNavigation();resolvePin('1234');await tick();assert.equal(calls.filter(c=>c.rpc==='activate_package_with_mio').length,prior);assert.equal(card(),null);
 q.setSession({user:{id:owner}});q.updateAuthNavigation();w.MioDashboard.requestTransactionPin=async()=> '1234';fixtures.mio_transfer_to_member_code='transfer-1';fixtures.lookup_mio_transfer_receipt=[{transfer_id:'transfer-1',sender_id:owner,sender_name:'SENDER',sender_code:'MIO-SENDER',recipient_name:'Recipient Name',recipient_code:'MIO-RECIPIENT',amount:25,created_at:'2026-11-15T19:01:02Z'}];
 const f=d.getElementById('transferForm'),code=d.getElementById('memberCode'),amount=d.getElementById('transferAmount');
 async function verify(){code.value='MIO-RECIPIENT';d.getElementById('verifyCashRecipient').click();await tick();amount.value='25'}
 await verify();f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();await tick();assert.match(card().textContent,/Points Transferred Successfully!/);assert.match(card().textContent,/POINTS TRANSFERRED/);assert.match(card().textContent,/25.00 MIO/);assert.match(card().textContent,/16 Nov 2026/);assert.match(card().textContent,/00:01:02 am PKT|12:01:02 am PKT/);assert.match(card().textContent,/Recipient Name/);assert.ok(card().querySelector('.action-confirmation-download'));close();
 fixtures.mio_transfer_to_member_code={__error:{message:'Invalid transaction PIN'}};await verify();f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();assert.match(card().textContent,/Incorrect PIN/);assert.doesNotMatch(card().textContent,/Completed|POINTS TRANSFERRED/);close();
 fixtures.mio_transfer_to_member_code={__error:{message:'Insufficient balance'}};f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();assert.equal(card(),null);
 // Successful cards are cleared when the authenticated identity changes.
 fixtures.mio_transfer_to_member_code='transfer-2';f.dispatchEvent(new w.Event('submit',{cancelable:true}));await tick();await tick();assert.ok(card());q.setSession(null);q.updateAuthNavigation();assert.equal(card(),null);
 w.memberMioRows=[{id:'precision-in',action:'transfer_in',amount:'549.9994',created_at:'2026-11-15T13:11:13Z'}];q.resetHistoryFilters();q.renderMioHistory();assert.match(d.getElementById('mioHistory').textContent,/549\.9994/);assert.doesNotMatch(d.getElementById('mioHistory').textContent,/550\.00/);
 console.log('PASS real activation and cash-transfer handlers: confirmed success cards, exact points wording, wrong PIN errors, failures/cancellation, duplicate activation prevention, account-switch abort and sign-out clearing');
}
