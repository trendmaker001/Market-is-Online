import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {JSDOM} from 'jsdom';
const html=await readFile('dist/index.html','utf8');const dom=new JSDOM(html,{runScripts:'outside-only'}),w=dom.window;
w.eval(await readFile('dist/product-content.js','utf8'));const c=w.MioProductContent;c.mount();c.mount();assert.equal(w.document.querySelectorAll('#productContentFields').length,1);
const original='Original description\n## Key features\nwith a second line & <b>text</b>';c.fill(original);assert.equal(w.document.getElementById('prodDescription').value,original);
w.document.getElementById('listing-features').value='Durable\nEasy to clean';w.document.getElementById('listing-specifications').value='Material: Cotton\nSize: 42';w.document.getElementById('listing-warranty').value='12 months';
const saved=c.read();c.fill('Another product');assert.equal(w.document.getElementById('listing-features').value,'');c.fill(saved);assert.equal(w.document.getElementById('prodDescription').value,original);assert.equal(w.document.getElementById('listing-warranty').value,'12 months');assert.equal(c.read(),saved);
const view=w.document.createElement('div');view.innerHTML=c.render(saved);assert.equal(view.querySelectorAll('details').length,4);assert.equal(view.querySelectorAll('li').length,2);assert.equal(view.querySelectorAll('dt').length,2);assert.equal(view.querySelector('b'),null);assert.equal(view.querySelectorAll('details[open]').length,1);assert.ok(!view.textContent.includes('Delivery & returns'));
w.document.getElementById('productForm').reset();assert.equal(w.document.getElementById('listing-features').value,'');
const app=await readFile('dist/app.js','utf8');assert.match(app,/p_description:window.MioProductContent.read\(\)/);assert.match(app,/MioProductContent.fill\(p.description\)/);assert.ok(app.split('MioProductContent.render(p.description)').length>=3);
console.log('PASS Product details: legacy preservation, form save/edit round trip, reset, safe rendering, optional sections, seller/admin integration');dom.window.close();
// Exercise the guided form with native constraints and real preserved input nodes.
const guided=new JSDOM(html,{runScripts:'outside-only',pretendToBeVisual:true}),gw=guided.window,gd=gw.document;
gw.HTMLElement.prototype.scrollIntoView=()=>{};
gw.eval(await readFile('dist/product-content.js','utf8'));gw.MioProductContent.mount();
const get=id=>gd.getElementById(id),step=n=>gd.querySelector('[data-listing-step="'+n+'"]');
assert.equal(get('listingStep0').hidden,false);assert.equal(get('listingStep1').hidden,true);assert.equal(get('productContentFields').open,false);
step(2).click();assert.equal(get('listingStep0').hidden,false,'missing details prevent skipping ahead');
get('productVendor').innerHTML='<option value="store">My Store</option>';get('prodCategory').innerHTML='<option value="care">Skin care</option>';get('prodName').value='<img src=x onerror=alert(1)>';get('prodDescription').value='Accurate description';get('prodSku').value='SKU-123';
step(1).click();assert.equal(get('listingStep1').hidden,false);step(2).click();assert.equal(get('listingStep1').hidden,false,'price required before review');
get('prodPrice').value='1250';get('prodStock').value='199';step(2).click();assert.equal(get('listingStep1').hidden,false,'minimum stock stays enforced');
get('prodStock').value='250';step(2).click();assert.equal(get('listingStep2').hidden,false);assert.match(get('listingReview').textContent,/PKR 1,250/);assert.match(get('listingReview').textContent,/250 units/);assert.equal(get('listingReview').querySelector('img'),null,'review escapes the product title');
step(0).click();assert.equal(get('prodSku').value,'SKU-123');assert.equal(get('prodPrice').value,'1250');assert.equal(get('listingStep0').hidden,false);
get('productForm').reset();assert.equal(get('listingStep0').hidden,false);assert.equal(get('prodSku').value,'');assert.equal(get('prodStock').value,'300');assert.equal(get('productContentFields').open,false);
console.log('PASS guided listing: step navigation, required fields, price and stock constraints, escaped review, retained edits, reset');gw.close();
// Regression: the real listing submit handler must accept every rendered category,
// including built-in categories absent from the saved admin configuration.
const listing=new JSDOM(html,{runScripts:'outside-only'}),lw=listing.window,ld=lw.document;
const appLine=prefix=>app.split('\n').find(line=>line.startsWith(prefix));
let pending,calls=[],errors=[],resets=0,opened='',rpcError=null;
Object.assign(lw,{el:id=>ld.getElementById(id),esc:s=>String(s).replaceAll('&','&amp;').replaceAll('"','&quot;'),session:{user:{id:'seller'}},selectedVendor:'store',listingPhotos:[{url:'https://example.test/1.jpg'},{url:'https://example.test/2.jpg'},{url:'https://example.test/3.jpg'}],isAdmin:false,marketplaceCategories:[{name:'Skincare'},{name:'Custom category'}],submit:(_form,fn)=>{pending=fn().catch(e=>errors.push(e.message));return pending},uploadListingPhotos:async()=>['https://example.test/product.jpg'],db:{rpc:async(name,args)=>{calls.push({name,args});return{error:rpcError}}},toast:()=>{},resetProductForm:()=>resets++,loadSellerProducts:async()=>{},showSellerListingPanel:panel=>opened=panel});
lw.MioProductContent={read:()=> 'Product description'};
const country=ld.createElement('select');country.id='productCountry';country.innerHTML='<option value="PK">Pakistan</option>';ld.getElementById('productForm').append(country);
lw.eval([appLine('const marketplaceCategoryPack='),appLine('function mergeMarketplaceCategories('),appLine('function renderProductCategoryOptions('),appLine("el('productForm').addEventListener('submit'")].join('\n'));
lw.eval('renderProductCategoryOptions()');
ld.getElementById('productVendor').innerHTML='<option value="store">Store</option>';
ld.getElementById('prodName').value='Test perfume';ld.getElementById('prodPrice').value='1250';ld.getElementById('prodStock').value='300';
async function submitListing(category,mode='submit'){
 ld.getElementById('prodCategory').value=category;const button=ld.createElement('button');button.value=mode;
 ld.getElementById('productForm').dispatchEvent(new lw.SubmitEvent('submit',{cancelable:true,submitter:button}));await pending;
}
assert.ok(!lw.marketplaceCategories.some(c=>c.name==='Fragrances'));
const categoryNames=Array.from(ld.getElementById('prodCategory').options,o=>o.value).filter(Boolean);
for(const category of categoryNames){await submitListing(category);assert.equal(errors.length,0,category+' must submit');assert.equal(calls.at(-1).name,'save_product_listing_with_commission');assert.equal(calls.at(-1).args.p_category,category);assert.equal(calls.at(-1).args.p_submit,true)}
assert.equal(calls.at(-1).args.p_commission,null);ld.getElementById('prodCommission').value='25';await submitListing('Fragrances');assert.equal(calls.at(-1).args.p_commission,.25);ld.getElementById('prodCommission').value='';assert.equal(resets,categoryNames.length+1);assert.equal(opened,'existing');
await submitListing('Fragrances','draft');assert.equal(calls.at(-1).args.p_submit,false);
ld.getElementById('editingProduct').value='existing-product';await submitListing('Fragrances');assert.equal(calls.at(-1).args.p_product_id,'existing-product');
const before=calls.length;await submitListing('');assert.equal(calls.length,before);assert.match(errors.pop(),/Choose a product category/);
const bad=ld.createElement('option');bad.value='Invalid category';ld.getElementById('prodCategory').append(bad);await submitListing('Invalid category');assert.equal(calls.length,before);assert.match(errors.pop(),/Choose a product category/);
rpcError={message:'Please retry'};const oldResets=resets;await submitListing('Fragrances');assert.equal(errors.pop(),'Please retry');assert.equal(resets,oldResets);assert.equal(ld.getElementById('prodCategory').value,'Fragrances');
lw.listingPhotos=[];rpcError=null;const beforePhotos=calls.length;await submitListing('Fragrances');assert.match(errors.pop(),/at least 3/);assert.equal(calls.length,beforePhotos);await submitListing('Fragrances','draft');assert.equal(calls.at(-1).args.p_submit,false);lw.listingPhotos=Array.from({length:9},()=>({url:'https://example.test/image.jpg'}));await submitListing('Fragrances');assert.match(errors.pop(),/no more than 8/);
rpcError=null;lw.listingPhotos=Array.from({length:3},()=>({url:'https://example.test/image.jpg'}));const beforeDuplicate=calls.length;const firstSubmit=submitListing('Fragrances');const duplicateSubmit=submitListing('Fragrances');await Promise.all([firstSubmit,duplicateSubmit]);assert.equal(calls.length,beforeDuplicate+1,'ignore second submission while saving');assert.equal(ld.getElementById('productForm').dataset.saving,undefined);
console.log('PASS listing submission: every dropdown category, Fragrances, custom categories, draft/edit mode, blank/invalid rejection and retained input on RPC failure');lw.close();
