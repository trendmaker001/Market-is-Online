import sharp from 'sharp';
import {JSDOM} from 'jsdom';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import assert from 'node:assert/strict';
const dom=new JSDOM('',{url:'https://marketisonline.com/',runScripts:'outside-only'}),w=dom.window;
for(const f of ['vendor/jsbarcode-3.12.1.min.js','order-fulfillment.js','invoice-pdf.js'])w.eval(await readFile('dist/'+f,'utf8'));
w.TextEncoder=TextEncoder;w.TextDecoder=TextDecoder;w.eval(await readFile('dist/vendor/pdfmake-0.3.14.min.js','utf8'));w.eval(await readFile('dist/vendor/pdfmake-fonts-0.3.14.js','utf8'));const pdf=w.pdfMake;
const o={id:'qa-order',order_code:'MIO-QA-1048',created_at:'2026-11-12T10:00:00Z',status:'processing',payment_method:'COD',shipping_name:'QA Customer',shipping_phone:'03000000000',shipping_address:'House 18, Street 12, G-11/3',shipping_city:'Islamabad, Pakistan',total_pkr:8400,funding:{payment_state:'partial',paid_pkr:840},shipments:[1,2].map(n=>({id:'shipment-'+n,shipment_code:'MIO-QA-1048-V0'+n,invoice_number:'INV-MIO-QA-1048-V0'+n,vendor_snapshot:{name:'Vendor '+n,country:'Pakistan'},status:'processing',gross_pkr:4000,discount_pkr:0,delivery_pkr:200,total_pkr:4200,paid_pkr:420,items:[{name:'Product '+n,sku:'SKU-'+n,quantity:2,unit_price:2000}]}))};
await mkdir('tmp/pdfs',{recursive:true});
const assets={logo:'data:image/jpeg;base64,'+(await sharp('dist/market-is-online-logo.png').flatten({background:'#fff'}).jpeg().toBuffer()).toString('base64')};
for(const [name,shipments] of [['vendor',[o.shipments[0]]],['all',o.shipments]]){const def=w.MioInvoicePDF.definition(o,shipments,assets);assert.equal(def.pageSize,'A4');const buffer=await pdf.createPdf(def).getBuffer();assert.equal(Buffer.from(buffer).subarray(0,5).toString(),'%PDF-');await writeFile('tmp/pdfs/'+name+'.pdf',buffer);}
const long=structuredClone(o);long.shipments[0].items=Array.from({length:40},(_,i)=>({name:'Long named product '+(i+1)+' with detailed description and variant',sku:'SKU-LONG-'+i,quantity:1,unit_price:100}));const buffer=await pdf.createPdf(w.MioInvoicePDF.definition(long,[long.shipments[0]],assets)).getBuffer();await writeFile('tmp/pdfs/long.pdf',buffer);
console.log('PASS real PDF output: fixed A4, individual vendor, all vendors and long paginated order');dom.window.close();
