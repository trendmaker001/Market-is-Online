(function(){
 'use strict';
 const $=id=>document.getElementById(id),esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const image=s=>/^(https:\/\/[^\s]+|\/[a-z0-9][^\s]*)$/i.test(s||'')?s:'';
 const money=n=>'PKR '+Number(n||0).toLocaleString('en-PK',{minimumFractionDigits:2,maximumFractionDigits:2});
 function create(api){
  let publicProducts=[],busy=false,categories=[],categoryIndex=0,categoryQuery='',motion={enabled:true,speed:'slow',direction:'left'},animation=0,pauseUntil=0,hover=false,manualPause=false;
  const carton='/assets/bundles/configured-carton.webp';
  let types=null, activeVendors=[], selectedType='', selectedVendor='', quantities=new Map(), quote=null, quoteError='', quoteVersion=0;
  let typeLoadError='', adminTypes=[], adminRate=null;
  const selectedItems=()=>[...quantities].map(([product_id,quantity])=>({product_id,quantity}));
  const selectedUnits=()=>[...quantities.values()].reduce((total,qty)=>total+qty,0);
  const limitFor=(type,product)=>Math.min(Number(product.stock_quantity)||0,
   type.allow_repeats ? type.max_per_product ?? type.required_units : 1);
  const regularProducts=()=>publicProducts.filter(p=>!p.bundle_definition && Number(p.stock_quantity)>0);
  function preselectVendor(vendor){
   if(selectedVendor!==vendor){selectedVendor=vendor;quantities.clear();quote=null;quoteVersion++;}
  }
  function renderMarketplace(host,all=false,keepVendor=false){
   if(!host)return;
   if(!all){
    host.innerHTML='<div class="bundle-section-head"><h2>Bundles</h2><button class="btn" type="button" data-shop-view="bundles">Build a bundle</button></div>';
    return;
   }
   if(!types){
    host.innerHTML='<h1>Bundles</h1><p role="status">'+esc(typeLoadError||'Loading bundle types…')+'</p>';
    return;
   }
   const type=types.find(row=>row.id===selectedType&&row.status==='enabled');
   const products=regularProducts().filter(p=>p.vendor_id===selectedVendor);
   const units=selectedUnits();
   const ready=quote?.complete&&quote?.meets_minimum;
   const markup=`<section class="configured-bundles">
    <h1>Build a bundle</h1>
    <div class="configured-bundle-grid">${types.map(row=>`<article class="configured-bundle-card ${row.id===selectedType?'selected':''}">
     <img src="${carton}" alt="" width="540" height="360" loading="lazy">
     <h2>${esc(row.name)}</h2><p>${row.required_units} units</p>
     <button type="button" class="btn bundle-select" data-bundle-type="${row.id}" aria-pressed="${row.id===selectedType}" ${row.status!=='enabled'?'disabled':''}>${row.status==='draft'?'Coming soon':row.id===selectedType?'✓ Selected':'Select bundle'}</button>
    </article>`).join('')||'<p>Bundles are currently unavailable.</p>'}</div>
    ${type?`<div class="configured-bundle-builder">
     <label class="bundle-vendor-field">Vendor<select id="configuredBundleVendor"><option value="">Select a vendor</option>${activeVendors.map(v=>`<option value="${v.id}" ${v.id===selectedVendor?'selected':''}>${esc(v.business_name)}</option>`).join('')}</select></label>
     ${selectedVendor?`<div class="bundle-builder-progress"><strong>${units} of ${type.required_units} units</strong><span>${type.allow_repeats?'You can repeat products':'Choose one unit per product'}</span></div>
     <div class="bundle-picker-grid">${products.map(p=>{const qty=quantities.get(p.id)||0;return `<article class="bundle-picker-row">
      ${image(p.image_url)?`<img src="${esc(image(p.image_url))}" alt="" width="56" height="56" loading="lazy">`:''}
      <div><h3>${esc(p.name)}</h3><small>${money(p.price_pkr)}</small></div>
      <div class="bundle-quantity"><button type="button" data-component="${p.id}" data-step="-1" aria-label="Remove one ${esc(p.name)}" ${!qty?'disabled':''}>−</button><output aria-label="Selected quantity">${qty}</output><button type="button" data-component="${p.id}" data-step="1" aria-label="Add one ${esc(p.name)}" ${units>=type.required_units||qty>=limitFor(type,p)?'disabled':''}>+</button></div>
     </article>`;}).join('')||'<p>This vendor has no available regular products.</p>'}</div>
     <div id="configuredBundleQuote" class="bundle-checkout-summary" aria-live="polite">
      ${quoteError?`<p role="alert">${esc(quoteError)}</p>`:''}
      ${quote?`<dl><dt>Current product total</dt><dd>${money(quote.original_total)}</dd><dt>Extra bundle discount</dt><dd>−${money(quote.discount_pkr)}</dd><dt>Retained bundle PPV</dt><dd>${Number(quote.ppv).toFixed(4)}</dd><dt>Final product total</dt><dd><strong>${money(quote.price_pkr)}</strong></dd></dl>`:units===type.required_units&&!quoteError?'<p>Checking latest prices and stock…</p>':''}
      ${quote?.complete&&!quote.meets_minimum?`<p role="alert">The final product total must reach ${money(quote.minimum_pkr)} before delivery. Replace a product or choose a larger bundle above.</p>`:''}
      <button type="button" class="btn primary" data-configured-bundle-checkout ${!ready?'disabled':''}>Continue to checkout</button>
     </div>`:'<p>Choose a vendor to see its products.</p>'}
    </div>`:''}
   </section>`;
   const vendorField=keepVendor&&host.querySelector('.bundle-vendor-field');
   if(vendorField){
    // Keep the native dropdown connected while its product list updates.
    const updated=document.createElement('template');
    updated.innerHTML=markup;
    const builder=updated.content.querySelector('.configured-bundle-builder');
    builder.querySelector('.bundle-vendor-field').remove();
    while(vendorField.nextSibling)vendorField.nextSibling.remove();
    vendorField.after(...builder.childNodes);
   }else host.innerHTML=markup;
   host.querySelectorAll('[data-bundle-type]').forEach(button=>button.onclick=()=>{
    selectedType=button.dataset.bundleType;
    const next=types.find(row=>row.id===selectedType);
    let remaining=next.required_units;
    for(const [id,qty] of quantities){
     const p=products.find(row=>row.id===id);
     const keep=p?Math.min(remaining,qty,limitFor(next,p)):0;
     if(keep)quantities.set(id,keep);else quantities.delete(id);
     remaining-=keep;
    }
    refreshQuote(host);
    host.querySelector(`[data-bundle-type="${selectedType}"]`)?.focus();
   });
   const vendor=host.querySelector('#configuredBundleVendor');
   if(vendor)vendor.onchange=()=>{preselectVendor(vendor.value);refreshQuote(host,true);};
   host.querySelectorAll('[data-component]').forEach(button=>button.onclick=()=>{
    const id=button.dataset.component, step=Number(button.dataset.step);
    const p=products.find(row=>row.id===id), old=quantities.get(id)||0;
    if(!p||step>0&&(units>=type.required_units||old>=limitFor(type,p)))return;
    const next=old+step;
    if(next>0)quantities.set(id,next);else quantities.delete(id);
    refreshQuote(host);
    const replacement=host.querySelector(`[data-component="${id}"][data-step="${step}"]`);
    if(replacement&&!replacement.disabled)replacement.focus();
    else host.querySelector(`[data-component="${id}"][data-step="${-step}"]:not([disabled])`)?.focus();
   });
   const checkout=host.querySelector('[data-configured-bundle-checkout]');
   if(checkout)checkout.onclick=()=>{if(ready)api.checkout({type:selectedType,vendor:selectedVendor,items:selectedItems(),quote});};
  }
  async function refreshQuote(host,keepVendor=false){
   const version=++quoteVersion;
   quote=null;quoteError='';
   renderMarketplace(host,true,keepVendor);
   const type=types.find(row=>row.id===selectedType);
   if(!type||!selectedVendor||selectedUnits()!==type.required_units)return;
   try{
    const result=await api.db.rpc('quote_marketplace_bundle',{p_type:selectedType,p_vendor:selectedVendor,p_items:selectedItems()});
    if(result.error)throw result.error;
    if(version!==quoteVersion)return;
    quote=result.data;
   }catch(error){if(version!==quoteVersion)return;quoteError=error.message||'Could not check the bundle';}
   if(api.shopView()==='bundles'){
    const active=document.activeElement;
    const control=active?.dataset.component;
    const step=active?.dataset.step;
    renderMarketplace(host,true);
    if(control)host.querySelector(`[data-component="${control}"][data-step="${step}"]:not([disabled])`)?.focus();
   }
  }
  async function load(items){
   publicProducts=items;
   let host=$('marketBundleSection');
   if(!host){
    host=document.createElement('section');host.id='marketBundleSection';host.className='shop-home-section bundle-section';
    $('departments')?.closest('section')?.after(host);
   }
   if(host){host.classList.toggle('hidden',api.shopView()!=='home');renderMarketplace(host);}
   const [bundleTypes,vendorList,settings]=await Promise.all([
    api.db.rpc('marketplace_bundle_types'),
    api.db.from('vendors').select('id,business_name').eq('status','active').order('business_name'),
    api.db.from('system_config').select('config_value').eq('config_key','MARKETPLACE_CATEGORY_MOTION').is('effective_to',null).order('version',{ascending:false}).limit(1)
   ]);
   if(!bundleTypes.error&&Array.isArray(bundleTypes.data))types=bundleTypes.data;
   else typeLoadError='Bundle types could not load. Refresh to try again.';
   const visibleVendors=new Map(regularProducts().map(p=>[p.vendor_id,{id:p.vendor_id,business_name:p.vendors?.business_name||'Vendor'}]));
   for(const vendor of vendorList.data||[])visibleVendors.set(vendor.id,vendor);
   activeVendors=[...visibleVendors.values()].sort((a,b)=>a.business_name.localeCompare(b.business_name));
   if(!settings.error&&settings.data?.[0]?.config_value)motion={...motion,...settings.data[0].config_value};
   startMotion();
   if(api.shopView()==='bundles')renderMarketplace($('shopDirectory'),true);
  }
  async function mountAdmin(){
   if(!api.isAdmin())return;
   const host=$('control-bundles');
   if(!host)return;
   const r=await api.db.rpc('admin_marketplace_bundle_types');
   if(!api.isAdmin())return;
   if(r.error){host.textContent=r.error.message;return;}
   adminTypes=r.data.types;adminRate=r.data.reference_rate;
   renderAdmin(host);
  }
  function renderAdmin(host){
   host.innerHTML=`<div class="commerce-studio">
    <header class="studio-heading"><h2>Bundle types</h2><button type="button" class="btn primary" data-add-type>Add bundle type</button></header>
    <div class="configured-admin-types">${adminTypes.map(t=>`<article class="studio-card">
     <h3>${esc(t.name)}</h3><dl><dt>Required units</dt><dd>${t.required_units}</dd><dt>PPV divider</dt><dd>${t.ppv_divider??'Pending'}</dd><dt>Minimum total</dt><dd>${money(t.minimum_pkr)}</dd><dt>Status</dt><dd>${esc(t.status)}</dd></dl>
     <div class="bundle-admin-actions"><button type="button" class="btn" data-edit-type="${t.id}">Edit</button>
     <button type="button" class="btn" data-toggle-type="${t.id}" ${t.ppv_divider==null?'disabled':''}>${t.status==='enabled'?'Disable':'Enable'}</button></div>
    </article>`).join('')}</div><div id="bundleTypeEditor"></div><p role="status" id="bundleTypeStatus"></p>
   </div>`;
   host.querySelector('[data-add-type]').onclick=()=>renderTypeEditor(host,{name:'',required_units:15,minimum_pkr:3000,status:'draft',allow_repeats:true});
   host.querySelectorAll('[data-edit-type]').forEach(b=>b.onclick=()=>renderTypeEditor(host,adminTypes.find(t=>t.id===b.dataset.editType)));
   host.querySelectorAll('[data-toggle-type]').forEach(b=>b.onclick=()=>{
    const t=adminTypes.find(row=>row.id===b.dataset.toggleType);
    return saveType(host,{...t,status:t.status==='enabled'?'disabled':'enabled'},b);
   });
  }
  async function saveType(host,t,button){
   if(busy)return;
   busy=true;button.disabled=true;
   const status=host.querySelector('#bundleTypeStatus');
   try{
    const result=await api.db.rpc('admin_save_marketplace_bundle_type',{
     p_id:t.id||null,p_name:t.name,p_units:t.required_units,p_divider:t.ppv_divider??null,
     p_minimum:t.minimum_pkr,p_repeats:t.allow_repeats,p_max:t.max_per_product??null,p_status:t.status
    });
    if(result.error)throw result.error;
    await mountAdmin();
    await api.reload();
    api.toast('Bundle type saved');
   }catch(error){status.textContent=error.message||'Could not save bundle type';}
   finally{busy=false;button.disabled=false;}
  }
  function renderTypeEditor(host,t){
   const editor=host.querySelector('#bundleTypeEditor');
   editor.innerHTML=`<form class="studio-card bundle-type-form"><h3>${t.id?'Edit bundle type':'Add bundle type'}</h3>
    <div class="studio-two">
     <label>Name<input name="name" required maxlength="80" value="${esc(t.name)}"></label>
     <label>Required units<input name="units" required type="number" min="2" max="99" value="${t.required_units}"></label>
     <label>PPV divider<input name="divider" type="number" min="1" step=".0001" value="${t.ppv_divider??''}"></label>
     <label>Minimum product total (PKR)<input name="minimum" required type="number" min="0" step=".01" value="${t.minimum_pkr}"></label>
     <label>Maximum per product<input name="max" type="number" min="1" placeholder="Bundle size" value="${t.max_per_product??''}"></label>
     <label>Status<select name="status">${['draft','enabled','disabled'].map(s=>`<option value="${s}" ${t.status===s?'selected':''}>${s}</option>`).join('')}</select></label>
    </div><label class="bundle-repeat"><input type="checkbox" name="repeat" ${t.allow_repeats?'checked':''}> Allow repeated products</label>
    <details><summary>Calculation preview</summary><p>Current conversion rate: ${adminRate==null?'Unavailable':money(adminRate)+' per PPV'}</p>
     <div class="studio-two"><label>Example current product total<input type="number" name="samplePrice" min="0" step=".01"></label><label>Example approved PPV<input type="number" name="samplePPV" min="0" step=".0001"></label></div><output data-preview></output>
    </details><button class="btn primary" type="submit">Save bundle type</button></form>`;
   const form=editor.querySelector('form'),f=form.elements;
   const preview=()=>{
    f.max.max=f.units.value;f.max.disabled=!f.repeat.checked;
    const divider=Number(f.divider.value),points=Number(f.samplePPV.value);
    const out=editor.querySelector('[data-preview]');
    if(divider<1||adminRate==null||!f.samplePrice.value||!f.samplePPV.value){out.textContent='Enter sample totals and a divider.';return;}
    const retained=Math.floor(points/divider*10000)/10000;
    const discount=Math.floor((points-points/divider)*Number(adminRate)*100)/100;
    const price=Number(f.samplePrice.value)-discount;
    out.textContent=`Retained PPV ${retained.toFixed(4)} · Extra discount ${money(discount)} · Final products ${money(price)}`+(price<Number(f.minimum.value)?' · Below minimum':'');
   };
   form.oninput=preview;
   form.onsubmit=e=>{
    e.preventDefault();
    return saveType(host,{...t,name:f.name.value.trim(),required_units:Number(f.units.value),
     ppv_divider:f.divider.value?Number(f.divider.value):null,minimum_pkr:Number(f.minimum.value),
     allow_repeats:f.repeat.checked,max_per_product:f.repeat.checked&&f.max.value?Number(f.max.value):null,status:f.status.value},e.submitter||form.querySelector('button[type="submit"]'));
   };
   preview();f.name.focus();
  }
  function renderDetail(p){
   const root=$('productDetail');if(!root)return;const b=p.bundle_definition,photos=[...new Set([p.image_url,...(p.image_urls||[]),...b.items.map(i=>i.image_url)])].filter(image);
   root.innerHTML=`<div class="bundle-detail"><a href="#bundles" class="bundle-back">← Bundles</a><div class="bundle-detail-grid"><div class="bundle-gallery"><img id="bundleMainImage" src="${esc(image(p.image_url))}" alt="${esc(p.name)}"><div class="bundle-thumbnails">${photos.map((src,i)=>`<button type="button" data-bundle-photo="${esc(src)}" aria-label="View bundle image ${i+1}"><img src="${esc(src)}" alt=""></button>`).join('')}</div></div><div class="bundle-detail-copy"><small>${esc(p.vendors?.business_name||'Vendor')} · ${b.items.length} products</small><h1>${esc(p.name)}</h1><div class="bundle-prices"><del>${money(b.original_total)}</del><strong>${money(p.price_pkr)}</strong></div><div class="bundle-card-meta"><span>Save ${money(b.discount_pkr)}</span><b>${Number(p.ppv_per_unit).toFixed(4)} PPV</b></div><h2>Included in this bundle</h2><ul class="bundle-contents">${b.items.map(i=>`<li><img src="${esc(image(i.image_url))}" alt=""><span>${esc(i.name)}</span><b>× ${i.quantity}</b></li>`).join('')}</ul><label class="bundle-quantity">Quantity<input id="productQuantity" type="number" value="1" min="1" max="${Math.min(99,p.stock_quantity)}"></label><button class="btn primary add-cart" data-id="${esc(p.id)}" data-quantity>Add bundle to cart</button><small class="bundle-note">Rewards apply after delivery and payment confirmation.</small></div></div><section class="bundle-products-section"><div class="bundle-section-head"><div><small>EVERY ITEM, IN DETAIL</small><h2>Explore your bundle</h2></div><span>${b.items.length} products included</span></div><div class="bundle-product-tabs" role="tablist" aria-label="Included products">${b.items.map((i,n)=>`<button type="button" role="tab" id="bundleTab${n}" aria-controls="bundleComponentDetail" aria-selected="${n===0}" tabindex="${n===0?'0':'-1'}" data-bundle-component="${n}"><img src="${esc(image(i.image_url))}" alt=""><span>${esc(i.name)}<small>Quantity ${i.quantity}</small></span></button>`).join('')}</div><div id="bundleComponentDetail" role="tabpanel" aria-labelledby="bundleTab0"></div></section></div>`;
   const selectComponent=n=>{
    const item=b.items[n],product=publicProducts.find(x=>x.id===item.product_id)||item;
    const pictures=[...new Set([product.image_url,...(product.image_urls||[])])].filter(image);
    root.querySelectorAll('[data-bundle-component]').forEach((button,k)=>{button.setAttribute('aria-selected',String(k===n));button.tabIndex=k===n?0:-1});
    const panel=$('bundleComponentDetail');panel.setAttribute('aria-labelledby','bundleTab'+n);
    panel.innerHTML=`<div class="bundle-component-grid"><div class="bundle-component-gallery"><img class="bundle-component-cover" src="${esc(image(product.image_url||item.image_url))}" alt="${esc(product.name||item.name)}"><div class="bundle-thumbnails">${pictures.map((src,k)=>`<button type="button" data-component-photo="${esc(src)}" aria-label="View product photo ${k+1}"><img src="${esc(src)}" alt=""></button>`).join('')}</div></div><div class="bundle-component-copy"><span class="pill">${esc(product.category||'Included product')}</span><h3>${esc(product.name||item.name)}</h3><dl><div><dt>Quantity in bundle</dt><dd>${item.quantity}</dd></div><div><dt>Individual product price</dt><dd>${money(product.price_pkr||item.price_pkr)}</dd></div>${product.sku?`<div><dt>SKU</dt><dd>${esc(product.sku)}</dd></div>`:''}</dl><div class="product-description">${window.MioProductContent?.render(product.description)||`<p>${esc(product.description||'Open the individual product page for the full product information.')}</p>`}</div>${item.product_id?`<a class="btn" href="#product/${esc(item.product_id)}">View individual product →</a>`:''}<small class="bundle-note">Included in the bundle price. No additional charge for this item.</small></div></div>`;
    panel.querySelectorAll('[data-component-photo]').forEach(button=>button.onclick=()=>{panel.querySelector('.bundle-component-cover').src=button.dataset.componentPhoto});
   };
   root.querySelectorAll('[data-bundle-component]').forEach((button,n)=>{button.onclick=()=>selectComponent(n);button.onkeydown=e=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const next=e.key==='Home'?0:e.key==='End'?b.items.length-1:(n+(e.key==='ArrowRight'?1:-1)+b.items.length)%b.items.length;selectComponent(next);root.querySelector('[data-bundle-component="'+next+'"]').focus()}});
   if(b.items.length)selectComponent(0);
   root.querySelectorAll('[data-bundle-photo]').forEach(button=>button.onclick=()=>{$('bundleMainImage').src=button.dataset.bundlePhoto});
  }
  async function upload(file,folder){if(!['image/png','image/jpeg','image/webp'].includes(file.type)||file.size>5242880)throw Error('Use PNG, JPG or WebP up to 5 MB');const path=folder+'/'+crypto.randomUUID()+'.'+({ 'image/png':'png','image/jpeg':'jpg','image/webp':'webp'}[file.type]);const r=await api.db.storage.from('marketplace-banners').upload(path,file,{contentType:file.type,cacheControl:'31536000',upsert:false});if(r.error)throw r.error;return api.db.storage.from('marketplace-banners').getPublicUrl(path).data.publicUrl}
  async function mountCategories(){if(!api.isAdmin())return;const r=await api.db.from('system_config').select('config_key,config_value').in('config_key',['MARKETPLACE_CATEGORIES','MARKETPLACE_CATEGORY_MOTION']).is('effective_to',null).order('version',{ascending:false});if(r.error)throw r.error;if(!api.isAdmin())return;categories=structuredClone(r.data?.find(x=>x.config_key==='MARKETPLACE_CATEGORIES')?.config_value||api.categories());motion={...motion,...r.data?.find(x=>x.config_key==='MARKETPLACE_CATEGORY_MOTION')?.config_value};categoryIndex=Math.min(categoryIndex,categories.length-1);renderCategories()}
  function renderCategories(){const host=$('control-categories');if(!host)return;const c=categories[categoryIndex];host.innerHTML=`<div class="commerce-studio"><header class="studio-heading"><div><small>E-commerce Controls</small><h2>Categories</h2></div><button class="btn primary" type="button" data-add-category>+ Add category</button></header><div class="category-editor-grid"><section class="studio-card"><label class="studio-search">Search categories<input id="categorySearch" type="search" value="${esc(categoryQuery)}" placeholder="Search categories"></label><div class="category-studio-list">${categories.map((c,i)=>`<div class="category-studio-row ${i===categoryIndex?'selected':''}" data-category-row="${i}" ${categoryQuery&&!c.name.toLowerCase().includes(categoryQuery.toLowerCase())?'hidden':''} draggable="true"><span class="category-grip" aria-hidden="true">⠿</span><img src="${esc(image(c.image_url)||api.categoryImage(c.name))}" alt=""><strong>${esc(c.name)}</strong><label class="studio-switch"><input type="checkbox" data-category-visible="${i}" ${c.visible!==false?'checked':''}><span>${c.visible===false?'Hidden':'Visible'}</span></label><div class="category-order"><button type="button" data-category-move="${i}" data-delta="-1" aria-label="Move ${esc(c.name)} up" ${i===0?'disabled':''}>↑</button><button type="button" data-category-move="${i}" data-delta="1" aria-label="Move ${esc(c.name)} down" ${i===categories.length-1?'disabled':''}>↓</button></div><button class="btn small" type="button" data-category-edit="${i}">Edit</button></div>`).join('')}</div></section><aside class="studio-card category-detail"><h3>Category details</h3>${c?`<img class="category-detail-image" src="${esc(image(c.image_url)||api.categoryImage(c.name))}" alt=""><label class="btn small upload-control">Replace image<input id="categoryImageUpload" type="file" accept="image/png,image/jpeg,image/webp"></label><label>Name<input id="categoryEditName" maxlength="60" value="${esc(c.name)}"></label><label>Display order<input id="categoryEditOrder" type="number" min="1" max="${categories.length}" value="${categoryIndex+1}"></label><small class="bundle-note">Used category names are preserved to keep product listings connected.</small><button class="btn" type="button" data-category-remove>Remove unused category</button>`:''}</aside></div><section class="studio-card category-motion"><h3>Category strip motion</h3><div class="category-motion-controls"><label class="studio-switch"><input id="categoryMotionEnabled" type="checkbox" ${motion.enabled?'checked':''}>Auto-scroll</label><label>Speed<select id="categoryMotionSpeed"><option value="slow" ${motion.speed==='slow'?'selected':''}>Slow</option><option value="normal" ${motion.speed==='normal'?'selected':''}>Normal</option><option value="fast" ${motion.speed==='fast'?'selected':''}>Fast</option></select></label><label>Direction<select id="categoryMotionDirection"><option value="left" ${motion.direction==='left'?'selected':''}>Left</option><option value="right" ${motion.direction==='right'?'selected':''}>Right</option></select></label><span>Pauses on hover, touch &amp; keyboard focus</span></div><div class="category-strip-preview">${categories.filter(c=>c.visible!==false).slice(0,8).map(c=>`<div><img src="${esc(image(c.image_url)||api.categoryImage(c.name))}" alt=""><span>${esc(c.name)}</span></div>`).join('')}</div></section><footer class="studio-actions"><p id="categoryStudioStatus" role="status"></p><button type="button" class="btn primary" data-save-category-display>Save changes</button></footer></div>`;
   $('categorySearch').oninput=e=>{categoryQuery=e.target.value;host.querySelectorAll('[data-category-row]').forEach(row=>row.hidden=!categories[Number(row.dataset.categoryRow)].name.toLowerCase().includes(categoryQuery.toLowerCase()))};
   let drag=null;host.querySelectorAll('[data-category-row]').forEach(row=>{row.ondragstart=e=>{drag=Number(row.dataset.categoryRow);e.dataTransfer?.setData('text/plain',String(drag))};row.ondragover=e=>e.preventDefault();row.ondrop=e=>{e.preventDefault();if(drag!==null)moveCategory(drag,Number(row.dataset.categoryRow));drag=null}});
   const read=()=>{if(c){c.name=$('categoryEditName').value.trim();if(!c.slug)c.slug=api.slug(c.name);c.icon=c.icon||'beauty'}motion={enabled:$('categoryMotionEnabled').checked,speed:$('categoryMotionSpeed').value,direction:$('categoryMotionDirection').value}};
   function moveCategory(from,to){read();if(to<0||to>=categories.length)return;const [item]=categories.splice(from,1);categories.splice(to,0,item);categoryIndex=to;renderCategories()}
   host.onchange=e=>{if(e.target.matches('[data-category-visible]')){read();categories[Number(e.target.dataset.categoryVisible)].visible=e.target.checked;renderCategories()}else if(e.target.id==='categoryEditOrder')moveCategory(categoryIndex,Number(e.target.value)-1);else if(e.target.id!=='categoryImageUpload')read()};
   host.onclick=async e=>{try{const edit=e.target.closest('[data-category-edit]'),move=e.target.closest('[data-category-move]');if(edit){read();categoryIndex=Number(edit.dataset.categoryEdit);renderCategories()}else if(move)moveCategory(Number(move.dataset.categoryMove),Number(move.dataset.categoryMove)+Number(move.dataset.delta));else if(e.target.closest('[data-add-category]')){read();categories.push({name:'New category',slug:'category-'+Date.now(),icon:'beauty',visible:true});categoryIndex=categories.length-1;categoryQuery='';renderCategories();$('categoryEditName').select()}else if(e.target.closest('[data-category-remove]')){read();categories.splice(categoryIndex,1);categoryIndex=Math.max(0,categoryIndex-1);renderCategories()}else if(e.target.closest('[data-save-category-display]')){if(busy)return;read();busy=true;const btn=e.target.closest('button');btn.disabled=true;const r=await api.db.rpc('admin_save_category_display',{p_categories:categories,p_motion:motion});if(r.error)throw r.error;api.setCategories(structuredClone(categories));await api.reload();$('categoryStudioStatus').textContent='Categories and scrolling settings saved.';api.toast('Category settings saved');btn.disabled=false}}catch(error){$('categoryStudioStatus').textContent=error.message;api.toast(error.message)}finally{busy=false;host.querySelector('[data-save-category-display]')?.removeAttribute('disabled')}};
   if($('categoryImageUpload'))$('categoryImageUpload').onchange=async e=>{try{if(!e.target.files[0]||busy)return;busy=true;read();c.image_url=await upload(e.target.files[0],'categories');renderCategories()}catch(error){api.toast(error.message)}finally{busy=false}};
  }
  function startMotion(){cancelAnimationFrame(animation);const rail=$('departments');if(!rail)return;
   let pause=$('categoryMotionPause');if(!pause){pause=document.createElement('button');pause.id='categoryMotionPause';pause.type='button';pause.className='market-circle-all';pause.onclick=()=>{manualPause=!manualPause;pause.textContent=manualPause?'Resume':'Pause';pause.setAttribute('aria-pressed',String(manualPause))};rail.closest('section')?.querySelector('.market-circle-controls')?.prepend(pause)}
   const reduced=window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;pause.hidden=!motion.enabled||!!reduced;
   rail.classList.toggle('is-auto-moving',motion.enabled&&!reduced);if(!motion.enabled||reduced)return;
   rail.onpointerenter=e=>{if(e.pointerType!=='touch')hover=true};rail.onpointerleave=()=>{hover=false};rail.onpointerdown=()=>{pauseUntil=performance.now()+6000};rail.onwheel=()=>{pauseUntil=performance.now()+6000};rail.onfocusin=()=>{pauseUntil=performance.now()+6000};rail.onkeydown=()=>{pauseUntil=performance.now()+6000};
   pause.textContent=manualPause?'Resume':'Pause';let previous=performance.now(),position=rail.scrollLeft,direction=motion.direction==='right'?-1:1;
   function tick(now){const delta=Math.min(50,now-previous);previous=now;const max=rail.scrollWidth-rail.clientWidth;const active=$('page-shop')?.classList.contains('active')&&api.shopView()==='home';
    if(active&&!document.hidden&&!hover&&!manualPause&&now>pauseUntil&&!rail.contains(document.activeElement)&&max>1){position=Math.max(0,Math.min(max,position+direction*({slow:15,normal:25,fast:40}[motion.speed]||15)*delta/1000));rail.scrollLeft=position;if(position>=max||position<=0)direction*=-1}else position=rail.scrollLeft;
    animation=requestAnimationFrame(tick)
   }animation=requestAnimationFrame(tick);
  }
  return {load,renderMarketplace,renderDetail,preselectVendor,mountAdmin,mountCategories,startMotion};
 }
 window.MioBundles={create};
})();
