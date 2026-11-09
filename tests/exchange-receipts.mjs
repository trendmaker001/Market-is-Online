import {JSDOM} from 'jsdom';import {readFile} from 'node:fs/promises';import assert from 'node:assert/strict';
const dom=new JSDOM('<main id="main-content"></main>',{runScripts:'outside-only'}),w=dom.window,d=w.document;
for(const file of ['transfer-receipt','exchange-wallet'])w.eval(await readFile(`dist/${file}.js`,'utf8'));
let direction='sent',deny=false,defer=null,errors=[];
const row=()=>({id:'tx-1',created_at:'2026-11-09T12:26:00Z',full_name:'Other member',member_code:'MIO-2',direction,amount:'550.1234',source_wallet:direction==='fund'?'cash':'exchange',destination_wallet:direction==='sent'?'cash':'exchange',note:'<img src=x onerror=bad()> & note'});
w.MioExchange.mount({go:()=>{},rpc:async(name)=>{
 if(name==='my_exchange_wallet')return {data:{balance:100,received:0,sent:550.1234,funded:0,total:1,rows:[row()]}};
 if(defer)await new Promise(r=>{defer=r});
 if(deny)return {error:{message:'Transfer not found for this account'}};
 return {data:[{transfer_id:'tx-1',created_at:row().created_at,amount:row().amount,sender_id:direction==='received'?'other':'me',sender_name:'<script>Sender</script>',sender_code:'MIO-1',recipient_id:direction==='sent'?'other':'me',recipient_name:'Receiver',recipient_code:'MIO-2'}]};},error:e=>errors.push(e.message)});
const tick=()=>new Promise(r=>setTimeout(r,0));
w.MioExchange.setAccess('PREMIUM','me');
for(direction of ['sent','received','fund']){
 await w.MioExchange.refresh();assert.equal(d.querySelectorAll('#exchangeRows td').length,7);d.querySelector('[data-exchange-receipt]').click();await tick();const receipt=d.querySelector('.transfer-receipt-dialog');assert.ok(receipt);assert.equal(receipt.querySelector('h2').textContent,'Transfer Receipt');assert.match(receipt.textContent,/550\.1234/);assert.match(receipt.textContent,/17:26/);assert.equal(receipt.querySelectorAll('script').length,0);assert.equal(receipt.querySelectorAll('.transfer-receipt-note img').length,0);assert.ok(receipt.querySelector('[data-download-receipt]'));assert.doesNotMatch(receipt.textContent,/Print|www\.|DEMO/);assert.match(receipt.textContent,direction==='sent'?/You sent/:direction==='received'?/You received/:/You funded/);receipt.querySelector('[data-close-receipt]').click();assert.equal(d.querySelector('dialog'),null);
}
deny=true;d.querySelector('[data-exchange-receipt]').click();await tick();assert.equal(d.querySelector('dialog'),null);assert.match(errors.at(-1),/not found/);deny=false;
defer=true;d.querySelector('[data-exchange-receipt]').click();await tick();w.MioExchange.setAccess(null,null);defer();await tick();assert.equal(d.querySelector('dialog'),null);
w.MioExchange.setAccess('PREMIUM','me');defer=null;await w.MioExchange.refresh();d.querySelector('[data-exchange-receipt]').click();await tick();w.MioExchange.setAccess('BASIC_1','me');assert.equal(d.querySelector('dialog'),null);
console.log('PASS verified sent/received/funding receipts, exact amount, Pakistan time, escaping, lookup errors, logout race and tier-change cleanup');dom.window.close();
