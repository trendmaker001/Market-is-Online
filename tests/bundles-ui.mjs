import {JSDOM} from 'jsdom';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const dom=new JSDOM('<main><div id="departments"></div><section id="shopDirectory"></section><section id="control-bundles"></section><section id="control-categories"></section><div id="productDetail"></div></main>',{runScripts:'outside-only',url:'https://example.test',pretendToBeVisual:true});
const w=dom.window;w.structuredClone=structuredClone;w.eval(await readFile('dist/market-bundles.js','utf8'));
const items=[{id:'p1',vendor_id:'v1',name:'Rosemary Oil',price_pkr:1375,ppv_per_unit:1.1853,image_url:'/oil.webp',status:'approved'},{id:'p2',vendor_id:'v1',name:'Aloe Face Wash',price_pkr:1595,ppv_per_unit:1.375,image_url:'/aloe.webp',status:'approved'},{id:'p3',vendor_id:'v1',name:'Sun Block',price_pkr:1695,ppv_per_unit:1.4612,image_url:'/sun.webp',status:'approved'},{id:'other',vendor_id:'v2',name:'Other vendor',price_pkr:100,ppv_per_unit:0,image_url:'/other.webp',status:'approved'}];
const original=[{name:'Skincare',slug:'skincare',icon:'beauty',visible:true},{name:'Hair care',slug:'hair-care',icon:'beauty',visible:true},{name:'Toys',slug:'toys',icon:'toys',visible:true}];
const config=[{config_key:'MARKETPLACE_CATEGORIES',config_value:original},{config_key:'MARKETPLACE_CATEGORY_MOTION',config_value:{enabled:true,speed:'slow',direction:'left'}}];
const calls=[];
const types=[{id:'three',name:'Bundle 1',required_units:3,ppv_divider:3,minimum_pkr:3000,status:'enabled',allow_repeats:true},
 {id:'five',name:'Bundle 2',required_units:5,ppv_divider:4,minimum_pkr:3000,status:'enabled',allow_repeats:true},
 {id:'seven',name:'Bundle 3',required_units:7,ppv_divider:5,minimum_pkr:3000,status:'enabled',allow_repeats:true,allow_multiple_vendors:true},
 {id:'draft',name:'Bundle 5',required_units:15,ppv_divider:null,minimum_pkr:3000,status:'draft',allow_repeats:true}];
const db={from(table){const q={select(){return q},eq(){return q},in(){return q},is(){return q},order(){return q},limit(){return q},then(resolve){return Promise.resolve({data:table==='products'?items:table==='vendors'?[{id:'v1',business_name:'Allure Care'},{id:'v2',business_name:'Other'}]:config}).then(resolve)}};return q},
 rpc:async(name,args)=>{calls.push({name,args});return {data:{
  marketplace_bundle_types:types,
  admin_marketplace_bundle_types:{types,reference_rate:300},
  quote_marketplace_bundle:{complete:true,meets_minimum:true,original_total:4125,price_pkr:3887.94,discount_pkr:237.06,ppv:1.1853}
 }[name]??'saved'} }};
items.forEach(p=>p.stock_quantity=12);
items.push({...items[0],id:'legacy',name:'Legacy listing',bundle_definition:{items:[]}});
const checkouts=[];
const api=w.MioBundles.create({db,isAdmin:()=>true,toast:()=>{},shopView:()=>'bundles',checkout:v=>checkouts.push(v),
 reload:async()=>{},categories:()=>original,setCategories:()=>{},categoryImage:()=>'/image.webp',slug:s=>s.toLowerCase().replaceAll(' ','-')});
const click=selector=>w.document.querySelector(selector).click();
const tick=()=>new Promise(r=>setTimeout(r,20));
api.preselectVendor('v1');
await api.load(items);
assert.equal(w.document.querySelector('[data-bundle-type=draft]').disabled,true);
click('[data-bundle-type=three]');
assert.equal(w.document.querySelector('#configuredBundleVendor').value,'v1');
assert.equal(w.document.activeElement.id,'configuredBundleVendor');
assert.equal(w.document.querySelector('[data-component=other]'),null);
assert.equal(w.document.querySelector('[data-component=legacy]'),null);
assert.equal(w.document.querySelector('[data-component=p1][data-step="-1"]').disabled,true);
for(let i=0;i<3;i++)click('[data-component=p1][data-step="1"]');
await tick();
assert.ok([...w.document.querySelectorAll('[data-step="1"]')].every(b=>b.disabled));
assert.equal(calls.find(c=>c.name==='quote_marketplace_bundle').args.p_items[0].quantity,3);
click('[data-configured-bundle-checkout]');
assert.equal(checkouts[0].quote.price_pkr,3887.94);
click('[data-bundle-type=five]');
assert.equal(w.document.querySelector('.bundle-quantity output').textContent,'3');
assert.equal(w.document.querySelector('[data-configured-bundle-checkout]').disabled,true);
click('[data-bundle-type=seven]');
let vendorPicker=w.document.getElementById('configuredBundleVendor');vendorPicker.value='v2';vendorPicker.dispatchEvent(new w.Event('change',{bubbles:true}));
for(let i=0;i<4;i++)click('[data-component=other][data-step="1"]');await tick();
assert.equal(calls.filter(c=>c.name==='quote_marketplace_bundle').at(-1).args.p_items.length,2);
assert.match(w.document.querySelector('.bundle-selection-vendors').textContent,/Allure Care.*3.*Other.*4/);
vendorPicker=w.document.getElementById('configuredBundleVendor');vendorPicker.value='v1';vendorPicker.dispatchEvent(new w.Event('change',{bubbles:true}));
assert.equal(w.document.querySelector('[data-component=p1][data-step="1"]').closest('.bundle-quantity').querySelector('output').textContent,'3');
click('[data-bundle-type=three]');await tick();
assert.equal(calls.filter(c=>c.name==='quote_marketplace_bundle').at(-1).args.p_items.length,1);
console.log('PASS multi-vendor tier retains selections across vendor browsing; returning to Bundle 1 removes other-vendor selections');
console.log('PASS vendor preselection, draft state, product eligibility, repeat units, controls, tier switch and checkout');
await api.mountAdmin();
click('[data-add-type]');
const f=w.document.querySelector('.bundle-type-form'), fields=f.elements;
fields.name.value='Custom 20';
fields.units.value='20'; fields.divider.value='7'; fields.max.value='4'; fields.status.value='enabled';
fields.samplePrice.value='10000';fields.samplePPV.value='7';
f.dispatchEvent(new w.Event('input',{bubbles:true}));
assert.match(f.querySelector('[data-preview]').textContent,/Retained PPV 1.0000.*1,800.00.*8,200.00/);
f.dispatchEvent(new w.SubmitEvent('submit',{bubbles:true,cancelable:true,submitter:f.querySelector('[type=submit]')}));
await tick();
const bundleSave=calls.find(c=>c.name==='admin_save_marketplace_bundle_type');
assert.deepEqual(JSON.parse(JSON.stringify(bundleSave.args)),{p_id:null,p_name:'Custom 20',p_units:20,p_divider:7,p_minimum:3000,p_repeats:true,p_max:4,p_status:'enabled'});
console.log('PASS admin configuration, reference rate, preview and custom tier save');
await api.mountCategories();w.document.querySelector('[data-category-move="0"][data-delta="1"]').click();
const visible=w.document.querySelector('[data-category-visible="0"]');visible.checked=false;visible.dispatchEvent(new w.Event('change',{bubbles:true}));
w.document.getElementById('categoryMotionSpeed').value='normal';w.document.querySelector('[data-save-category-display]').click();await new Promise(r=>setTimeout(r,20));
const save=calls.find(c=>c.name==='admin_save_category_display');assert.equal(save.args.p_categories[0].name,'Hair care');assert.equal(save.args.p_categories[0].visible,false);assert.equal(save.args.p_motion.speed,'normal');
console.log('PASS category order, visibility and motion are saved together');
api.renderDetail({id:'bundle',name:'Bundle',price_pkr:4081.88,ppv_per_unit:2.0107,image_url:'/all.webp',image_urls:['/all.webp','/oil.webp'],stock_quantity:3,bundle_definition:{items:items.slice(0,3).map(p=>({...p,quantity:1})),original_total:4665,discount_pkr:583.12}});
assert.equal(w.document.querySelectorAll('.bundle-contents li').length,3);assert.equal(w.document.querySelectorAll('[data-bundle-component]').length,3);w.document.querySelector('[data-bundle-component="1"]').click();assert.match(w.document.getElementById('bundleComponentDetail').textContent,/Aloe Face Wash/);assert.equal(w.document.querySelector('[data-bundle-component="1"]').getAttribute('aria-selected'),'true');w.document.querySelector('[data-bundle-component="1"]').dispatchEvent(new w.KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));assert.match(w.document.getElementById('bundleComponentDetail').textContent,/Sun Block/);assert.equal(w.document.querySelector('.add-cart').dataset.id,'bundle');assert.equal(w.document.getElementById('productQuantity').max,'3');
console.log('PASS bundle detail preserves individual photos, contents and the existing cart action');
const css=await readFile('dist/market-bundles.css','utf8');assert.match(css,/configured-bundle-grid\{grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
dom.window.close();
