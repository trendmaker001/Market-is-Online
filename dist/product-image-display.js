(function(){
 'use strict';
 const modes={fit:'contain',zoomed:'cover',stretch:'fill'};
 const normalize=value=>Object.hasOwn(modes,value)?value:'zoomed';
 const mode=product=>normalize(product?.product_image_display?.mode);
 function editor(product,esc,safeImage){
  const selected=mode(product),url=safeImage(product.image_url||product.image_urls?.[0]);
  return `<form class="product-image-display-editor" data-product="${esc(product.id)}"><div class="image-display-preview" data-image-mode="${selected}">${url?`<img src="${esc(url)}" alt="Card photo preview">`:''}</div><div class="image-display-controls"><label>Card photo display<select name="mode"><option value="fit" ${selected==='fit'?'selected':''}>Fit — show full photo</option><option value="zoomed" ${selected==='zoomed'?'selected':''}>Zoomed — fill frame</option><option value="stretch" ${selected==='stretch'?'selected':''}>Stretch — fill without cropping</option></select></label><p class="helper">Square frame. Zoomed crops edges; Stretch may distort proportions. Product detail photos stay unchanged.</p><button type="submit" class="btn small">Save photo display</button><span class="image-display-status" role="status"></span></div></form>`;
 }
 function mount({db,isAdmin,onSaved}){
  document.addEventListener('change',e=>{const form=e.target.closest('.product-image-display-editor');if(!form||e.target.name!=='mode')return;form.querySelector('.image-display-preview').dataset.imageMode=normalize(e.target.value);form.querySelector('[role="status"]').textContent='Preview only — save to apply.';});
  document.addEventListener('submit',async e=>{
   const form=e.target;if(!form.matches('.product-image-display-editor'))return;e.preventDefault();if(form.dataset.saving)return;
   const status=form.querySelector('[role="status"]'),button=form.querySelector('button'),select=form.elements.mode;
   if(!isAdmin()){status.textContent='Admin access required.';return;}
   const value=normalize(select.value);form.dataset.saving='true';button.disabled=true;select.disabled=true;status.textContent='Saving…';
   try{const {data,error}=await db.from('product_image_display').upsert({product_id:form.dataset.product,mode:value},{onConflict:'product_id'}).select('product_id,mode').single();if(error)throw error;if(!data||data.mode!==value)throw Error('Photo display could not be saved.');onSaved(data.product_id,data.mode);status.textContent='Saved';}
   catch(error){status.textContent=error.message||'Could not save. Please try again.';}
   finally{delete form.dataset.saving;button.disabled=false;select.disabled=false;}
  });
 }
 window.MioProductImageDisplay={mode,editor,mount};
})();
