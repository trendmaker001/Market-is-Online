/* Structured sections preserve the existing listing save and approval workflow. */
(function(){
 const fields=[['overview','Overview',600,'A short introduction'],['description','Full description',8000,'Describe the product accurately'],['features','Key features',3000,'One feature per line'],['specifications','Specifications',3000,'One per line, e.g. Material: Cotton'],['contents','Package contents',2000,'What is included?'],['care','Usage & care',3000,'Directions, care and precautions'],['warranty','Warranty',1500,'Applicable warranty terms'],['delivery','Delivery & returns',2500,'Applicable delivery and return terms']];
 const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function parse(raw){raw=String(raw||'');const out={};if(!raw.startsWith('## Overview\n'))return {description:raw};let key=null,lines=[];const flush=()=>{if(key)out[key]=lines.join('\n').trim()};for(const line of raw.split('\n')){const f=fields.find(x=>line==='## '+x[1]);if(f){flush();key=f[0];lines=[]}else lines.push(line.replace(/^\\(?=\\|## )/,''))}flush();return out;}
 function serialize(data){return fields.filter(([key])=>key==='overview'||String(data[key]||'').trim()).map(([key,label])=>'## '+label+'\n'+String(data[key]||'').trim().split('\n').map(line=>/^(\\|## )/.test(line)?'\\'+line:line).join('\n')).join('\n\n');}
 function mount(){
  const input=document.getElementById('prodDescription');if(!input||document.getElementById('productContentFields'))return;
  const form=input.form,wrap=document.createElement('details');wrap.id='productContentFields';wrap.className='listing-content-fields listing-more';
  wrap.innerHTML='<summary>More product information <span>Optional</span></summary><div class="listing-more-grid">'+fields.filter(x=>x[0]!=='description').map(([key,label,max,hint])=>`<label for="listing-${key}">${label}<textarea id="listing-${key}" maxlength="${max}" rows="2" placeholder="${esc(hint)}"></textarea></label>`).join('')+'</div>';
  input.maxLength=8000;input.rows=4;const label=document.querySelector('label[for="prodDescription"]');if(label)label.textContent='Description';
  const group=(title,cls)=>{const box=document.createElement('fieldset');box.className='listing-form-section '+cls;const legend=document.createElement('legend');legend.textContent=title;box.append(legend);return box};
  const basics=group('Product details','listing-basics'),pricing=group('Price & stock','listing-pricing'),photos=group('Product photos','listing-photos');
  const store=document.createElement('div');store.className='field';store.append(form.querySelector('label[for="productVendor"]'),document.getElementById('productVendor'));basics.append(store,document.getElementById('prodName').closest('.row'),document.getElementById('prodCategory').closest('.row'),input.closest('.field'));
  pricing.append(document.getElementById('prodPrice').closest('.row'),document.getElementById('prodCommission').closest('.field'));photos.append(form.querySelector('.photo-drop'),document.getElementById('photoPreview'),form.querySelector('details'));
  const side=document.createElement('div');side.className='listing-form-side';side.append(pricing,photos);
  const actions=document.getElementById('newProduct').closest('.row');actions.classList.add('listing-form-actions');actions.querySelector('[value="submit"]').textContent='Send for review';
  form.querySelectorAll(':scope > h3').forEach(e=>e.remove());form.append(basics,side,wrap,actions);form.classList.add('listing-compact-form');
  const stockHelp=document.getElementById('prodStock').parentElement.querySelector('.helper');if(stockHelp){stockHelp.textContent='Minimum 200 when listing or restocking. Sales reduce stock normally.';stockHelp.parentElement.append(stockHelp);}
  mountListingSteps(form,basics,side,wrap,actions);
  const countryHelp=document.getElementById('productCountry')?.parentElement.querySelector('small');if(countryHelp)countryHelp.textContent='Where this product is available.';
 }
 function mountListingSteps(form,basics,side,optional,actions){
  const byId=id=>document.getElementById(id);
  const setLabel=(id,text)=>{const label=form.querySelector('label[for="'+id+'"]');if(label)label.textContent=text};
  setLabel('prodPrice','Price (PKR)');setLabel('prodStock','Available stock');setLabel('prodCategory','Category');setLabel('productCountry','Available in');
  byId('prodName').placeholder='e.g. Aloe Vera Face Wash — 100 ml';byId('prodSku').placeholder='Your product code';
  byId('prodDescription').placeholder='What is it, who is it for, and what does the buyer receive?';
  byId('prodPrice').placeholder='e.g. 1250';byId('prodPrice').inputMode='decimal';byId('prodStock').inputMode='numeric';
  const categoryHelp=byId('prodCategory').parentElement.querySelector('.helper');if(categoryHelp)categoryHelp.textContent='Choose one category that best fits.';
  const priceHelp=byId('prodPrice').parentElement.querySelector('.helper');if(priceHelp)priceHelp.textContent='The company reviews the final sale price.';
  basics.querySelector('legend').textContent='Tell us about your product';
  const nameRow=byId('prodName').closest('.row'),sku=byId('prodSku').closest('.field');nameRow.classList.add('listing-name-row');
  optional.querySelector('.listing-more-grid').prepend(sku);
  const nav=document.createElement('nav');nav.className='listing-steps';nav.setAttribute('aria-label','Create listing steps');
  nav.innerHTML=['Product details','Price & photos','Review'].map((name,i)=>`<button type="button" data-listing-step="${i}" aria-controls="listingStep${i}"><span>${i+1}</span><b>${name}</b></button>`).join('');
  const panels=[0,1,2].map(i=>{const panel=document.createElement('section');panel.id='listingStep'+i;panel.className='listing-step-panel';return panel});
  panels[0].append(basics,optional);panels[1].append(side);
  const review=document.createElement('div');review.className='listing-review';review.id='listingReview';panels[2].append(review);
  const note=document.createElement('p');note.className='listing-submit-note';note.textContent='Send for review to request approval. Your product goes live after company approval. Save draft keeps it unpublished.';panels[2].append(note,actions);
  const controls=document.createElement('div');controls.className='listing-step-controls';controls.innerHTML='<button type="button" class="btn listing-previous">← Back</button><span class="listing-step-status" role="status" aria-live="polite"></span><button type="button" class="btn primary listing-next">Continue →</button>';
  form.append(nav,...panels,controls);form.classList.add('listing-wizard');byId('newProduct').textContent='Clear form';byId('newProduct').classList.add('listing-clear');let current=0;
  const reviewValue=(label,value)=>{const item=document.createElement('div'),key=document.createElement('dt'),text=document.createElement('dd');key.textContent=label;text.textContent=value;item.append(key,text);return item};
  function renderReview(){
   review.replaceChildren();const title=document.createElement('h3');title.textContent='Check your listing';review.append(title);
   const top=document.createElement('div');top.className='listing-review-product';const cover=byId('photoPreview').querySelector('img');
   if(cover){const img=document.createElement('img');img.src=cover.src;img.alt='Product cover';top.append(img)}
   const name=document.createElement('strong');name.textContent=byId('prodName').value;top.append(name);review.append(top);
   const data=document.createElement('dl');data.className='listing-review-values';const option=id=>byId(id)?.selectedOptions[0]?.textContent||'—';
   [['Store',option('productVendor')],['Category',option('prodCategory')],['Available in',option('productCountry')],['Price','PKR '+Number(byId('prodPrice').value||0).toLocaleString('en-PK',{maximumFractionDigits:2})],['Product percentage',byId('prodCommission').value===''?'Vendor default':byId('prodCommission').value+'% (pending review)'],['Stock',byId('prodStock').value+' units'],['Photos',String(byId('photoPreview').querySelectorAll('img').length)]].forEach(([k,v])=>data.append(reviewValue(k,v)));review.append(data);
   const description=document.createElement('p');description.className='listing-review-description';description.textContent=byId('prodDescription').value;review.append(description);
   const optionalCount=fields.filter(([key])=>key!=='description'&&byId('listing-'+key)?.value.trim()).length;
   if(optionalCount){const extra=document.createElement('p');extra.className='helper';extra.textContent=optionalCount+' additional product information sections included.';review.append(extra)}
   const edit=document.createElement('button');edit.type='button';edit.className='listing-review-edit';edit.textContent='Edit product details';edit.onclick=()=>show(0,true);review.append(edit);
  }
  function show(step,focus=false){
   current=step;panels.forEach((panel,i)=>panel.hidden=i!==step);nav.querySelectorAll('button').forEach((button,i)=>{button.classList.toggle('active',i===step);if(i===step)button.setAttribute('aria-current','step');else button.removeAttribute('aria-current')});
   controls.querySelector('.listing-previous').hidden=step===0;controls.querySelector('.listing-next').hidden=step===2;controls.querySelector('.listing-step-status').textContent='Step '+(step+1)+' of 3';
   if(step===2)renderReview();if(focus){nav.scrollIntoView?.({block:'nearest',behavior:'smooth'});nav.querySelector('[data-listing-step="'+step+'"]').focus({preventScroll:true})}
  }
  function validate(step){for(const field of panels[step].querySelectorAll('input,select,textarea')){if(!field.checkValidity()){show(step);let parent=field.closest('details');if(parent)parent.open=true;field.reportValidity();field.focus();return false}}return true}
  function advance(target){if(target>current){for(let i=0;i<target;i++)if(!validate(i))return}show(target,true)}
  nav.addEventListener('click',e=>{const button=e.target.closest('[data-listing-step]');if(button)advance(Number(button.dataset.listingStep))});
  controls.querySelector('.listing-next').onclick=()=>advance(Math.min(2,current+1));controls.querySelector('.listing-previous').onclick=()=>show(Math.max(0,current-1),true);
  form.addEventListener('invalid',e=>{const index=panels.findIndex(p=>p.contains(e.target));if(index>=0){show(index);const details=e.target.closest('details');if(details)details.open=true}},true);
  form.addEventListener('keydown',e=>{if(e.key==='Enter'&&current<2&&e.target.matches('input:not([type="file"])')){e.preventDefault();advance(current+1)}});
  form.addEventListener('reset',()=>{show(0);optional.open=false});
  show(0);
 }
 function read(){const data={description:document.getElementById('prodDescription').value.trim()};for(const [key] of fields)if(key!=='description')data[key]=document.getElementById('listing-'+key)?.value.trim()||'';return serialize(data);}
 function fill(raw){const data=parse(raw);document.getElementById('prodDescription').value=data.description||'';for(const [key] of fields)if(key!=='description')document.getElementById('listing-'+key).value=data[key]||'';}
 function body(key,value){if(key==='features'||key==='contents')return '<ul>'+value.split('\n').filter(x=>x.trim()).map(x=>'<li>'+esc(x.replace(/^[-•]\s*/,''))+'</li>').join('')+'</ul>';if(key==='specifications')return '<dl class="listing-specifications">'+value.split('\n').filter(x=>x.trim()).map(x=>{const i=x.indexOf(':');return i>0?'<div><dt>'+esc(x.slice(0,i))+'</dt><dd>'+esc(x.slice(i+1).trim())+'</dd></div>':'<div><dd>'+esc(x)+'</dd></div>'}).join('')+'</dl>';return '<p class="listing-prose">'+esc(value)+'</p>';}
 function render(raw){const data=parse(raw),rows=fields.filter(([key])=>data[key]?.trim());return rows.length?'<div class="listing-information">'+rows.map(([key,label],i)=>`<details class="listing-information-section" ${i===0?'open':''}><summary>${label}<span aria-hidden="true">+</span></summary><div>${body(key,data[key])}</div></details>`).join('')+'</div>':'<p class="product-muted">The seller has not provided additional product details.</p>';}
 window.MioProductContent={parse,serialize,mount,read,fill,render};
})();
