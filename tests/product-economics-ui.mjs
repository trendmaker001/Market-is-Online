import {JSDOM} from 'jsdom';import {readFile} from 'node:fs/promises';import assert from 'node:assert/strict';
const dom=new JSDOM('<main></main>',{runScripts:'outside-only'}),w=dom.window;w.eval(await readFile('dist/product-economics.js','utf8'));const api=w.MioProductEconomics;
const calls=[];api.mount({db:{rpc:async(name,args)=>{calls.push({name,args});return {data:{}}}},toast:()=>{},reload:async()=>{}});
w.document.querySelector('main').innerHTML=api.form({id:'p1',price_pkr:1000,vendor_submitted_price_pkr:1000},{commission_rate:.3},290);const f=w.document.querySelector('form');api.preview(f);assert.match(f.textContent,/0.7586/);
f.elements.commission.value=20;f.elements.commission.dispatchEvent(new w.Event('input',{bubbles:true}));assert.match(f.textContent,/0.4482/);
f.elements.points.value=.9;f.elements.points.dispatchEvent(new w.Event('input',{bubbles:true}));assert.equal(f.querySelector('[type=submit]').disabled,true);
f.elements.commission.value=30;f.elements.points.value=.5;f.elements.remainder.value='discount';f.elements.remainder.dispatchEvent(new w.Event('change',{bubbles:true}));assert.match(f.textContent,/925.00/);assert.match(f.textContent,/75.00/);assert.equal(f.querySelector('[type=submit]').disabled,false);
f.dispatchEvent(new w.SubmitEvent('submit',{bubbles:true,cancelable:true}));await new Promise(r=>setTimeout(r,5));assert.equal(calls.length,1);assert.equal(calls[0].args.p_commission,.3);assert.equal(calls[0].args.p_ppv,.5);assert.equal(calls[0].args.p_remainder,'discount');
console.log('PASS percentage preview, PPV cap, discount preview and admin save payload');dom.window.close();
