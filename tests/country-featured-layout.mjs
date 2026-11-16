import {mkdir,writeFile,cp} from 'node:fs/promises';
export async function render({q,w}){
 const out=process.env.MIO_COUNTRY_LAYOUT;await mkdir(out,{recursive:true});await cp('dist',out,{recursive:true});
 const save=async name=>{const doc=new w.DOMParser().parseFromString(w.document.documentElement.outerHTML,'text/html');doc.querySelectorAll('script').forEach(x=>x.remove());doc.documentElement.classList.remove('route-restoring');await writeFile(out+'/'+name+'.html','<!doctype html>'+doc.documentElement.outerHTML);};
 q.setRouteReady(false);q.go('shop');q.setShopView('home');q.setHeroBanners([{image_url:'/assets/winter-edit-campaign.webp',title:'Marketplace collection'}]);q.renderHeroSlides();await save('country-market');
 q.el('marketCountryBar').querySelector('.country-search-trigger').click();await save('country-dropdown');q.el('marketCountryBar').querySelector('.country-search-trigger').click();
 q.go('admin');q.showWorkspace('storefront');q.el('featuredProductsPanel').classList.remove('hidden');q.el('featuredCategoriesPanel').classList.add('hidden');await save('country-featured-admin');
 await writeFile(out+'/country-responsive.html',`<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0;background:#dce7df;font:14px Arial}header{padding:10px;background:white;display:flex;gap:10px}iframe{display:block;border:0;margin:15px auto;background:white;height:850px}</style><header>Responsive QA <select id="width"><option>390</option><option>360</option><option>1366</option></select><select id="page"><option value="country-market">Marketplace</option><option value="country-dropdown">Country dropdown</option><option value="country-featured-admin">Featured admin</option></select></header><iframe id="view" width="390" src="/country-market.html"></iframe><script>width.onchange=()=>view.width=width.value;page.onchange=()=>view.src='/'+page.value+'.html';</script>`);
 console.log('Country UI screenshots fixture ready:',out);
}
