import assert from 'node:assert/strict';
export async function run({q,w,rows,calls,tick}){
 const store=(id,country)=>({id,business_name:country+' Store',country_code:country,status:'active'});
 const product=(id,country,vendor)=>({id,vendor_id:vendor,name:country+' Product',country_code:country,status:'approved',stock_quantity:10,price_pkr:100,category:'Beauty',vendors:store(vendor,country)});
 rows.products=[product('pk-product','PK','pk-store'),product('ae-product','AE','ae-store')];rows.vendors=[store('pk-store','PK'),store('ae-store','AE')];
 await q.loadMarketplace();await tick();assert.match(q.el('productsGrid').textContent,/PK Product/);assert.doesNotMatch(q.el('productsGrid').textContent,/AE Product/);
 const requests=calls.filter(c=>c.readTable==='products');assert.ok(requests.some(c=>c.filters.some(([key,v])=>key==='country_code'&&v==='PK')&&c.filters.some(([key,v])=>key==='vendors.country_code'&&v==='PK')),'both product and vendor countries must be sent as server filters');
 q.el('productsGrid').querySelector('.add-cart').click();assert.equal(q.cart.size,1);
 q.setProfile({full_name:'PROFILE MEMBER',country_code:'PK'});await q.marketCountry.change('AE');await tick();assert.match(q.el('productsGrid').textContent,/AE Product/);assert.doesNotMatch(q.el('productsGrid').textContent,/PK Product/);assert.equal(q.cart.size,0);assert.equal(q.marketplaceVendors().length,1);assert.equal(q.marketplaceVendors()[0].id,'ae-store');
 q.setShopView('vendors');assert.match(q.el('shopDirectory').textContent,/AE Store/);assert.doesNotMatch(q.el('shopDirectory').textContent,/PK Store/);
 await q.marketCountry.change('US');await tick();assert.equal(q.marketplaceVendors().length,0);assert.match(q.el('productsGrid').textContent,/No approved products/);assert.equal(q.el('marketHero').hidden,true);
 await q.marketCountry.change('PK');await tick();q.renderProduct('ae-product');assert.match(q.el('productDetail').textContent,/Product unavailable/);
 assert.equal(w.localStorage.getItem('mio-market-country-v1'),'PK');
 console.log('PASS complete app country filtering, query predicates, product/vendor directories, unavailable-country empty state, foreign product deep-link and cart reset');
}
