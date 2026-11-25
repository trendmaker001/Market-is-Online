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
 // Inspect a small thumbnail only for square photos with two matching white gutters.
 const cropCache=new Map();
 const cardSelector='.product-image img.product-photo';
 function measureGutters(image){
  if(Math.abs(image.naturalWidth/image.naturalHeight-1)>0.015)return 1;
  const size=128,canvas=document.createElement('canvas');
  canvas.width=canvas.height=size;
  const ctx=canvas.getContext('2d',{willReadFrequently:true});
  ctx.drawImage(image,0,0,size,size);
  const rgba=ctx.getImageData(0,0,size,size).data;
  function margin(vertical,reverse){
   for(let i=0;i<size/2;i++){
    let colored=0;
    const line=reverse?size-1-i:i;
    for(let j=1;j<size-1;j++){
     const pixel=(vertical?j*size+line:line*size+j)*4;
     if(rgba[pixel+3]>20 && Math.min(rgba[pixel],rgba[pixel+1],rgba[pixel+2])<247)colored++;
    }
    if(colored>=32)return i;
    if(colored>2 && i+1<size/2){
     // Allow one antialiased transition line at the artwork boundary.
     const next=reverse?line-1:line+1;
     let count=0;
     for(let j=1;j<size-1;j++){
      const k=(vertical?j*size+next:next*size+j)*4;
      if(rgba[k+3]>20 && Math.min(rgba[k],rgba[k+1],rgba[k+2])<247)count++;
     }
     return count>=32?i:0;
    }
   }
   return 0;
  }
  function pairedMargin(vertical){
   const a=margin(vertical,false),b=margin(vertical,true);
   return Math.abs(a-b)<=2 && Math.min(a,b)>=2?Math.min(a,b):0;
  }
  const edge=Math.max(pairedMargin(true),pairedMargin(false));
  return edge?size/(size-2*Math.min(32,edge+1)):1;
 }
 async function cropFactor(image,src){
  if(image.naturalWidth!==image.naturalHeight)return 1;
  if(new URL(src,location.href).origin===location.origin)return measureGutters(image);
  const probe=new Image();
  probe.crossOrigin='anonymous';
  probe.src=src;
  await probe.decode();
  return measureGutters(probe);
 }
 function fillCard(event){
  const image=event.target;
  if(!image.matches?.(cardSelector))return;
  const src=image.currentSrc||image.src;
  if(!cropCache.has(src)){
   if(cropCache.size>=512)cropCache.delete(cropCache.keys().next().value);
   cropCache.set(src,cropFactor(image,src).catch(()=>1));
  }
  cropCache.get(src).then(scale=>{
   if(image.isConnected && (image.currentSrc||image.src)===src)
    image.style.setProperty('--card-photo-scale',String(scale));
  });
 }
 document.addEventListener('load',fillCard,true);
 document.querySelectorAll(cardSelector).forEach(image=>{if(image.complete && image.naturalWidth)fillCard({target:image});});
 window.MioProductImageDisplay={mode,editor,mount};
})();
