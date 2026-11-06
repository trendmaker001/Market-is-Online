/* Presentation controls; checkout and reward calculations remain owned by app.js. */
(function(){
 const mounted=new WeakSet();
 function enhance(){
  document.querySelectorAll('.product .product-foot').forEach(foot=>{
   const ppv=foot.querySelector('.price .ppv-label');if(!ppv)return;
   const price=foot.querySelector('.price'),discount=document.createElement('div');discount.className='card-discount';
   price.querySelectorAll('.original-price,.sale-saving').forEach(el=>discount.append(el));
   if(discount.childElementCount)foot.before(discount);
   foot.classList.add('compact-purchase');foot.insertBefore(ppv,foot.querySelector('.add-cart'));
  });
  const detail=document.getElementById('productDetail');if(!detail)return;
  const price=detail.querySelector('.detail-price'),reward=detail.querySelector('.product-reward');
  if(price&&reward&&!price.parentElement.classList.contains('detail-price-row')){
   const row=document.createElement('div');row.className='detail-price-row';price.before(row);row.append(price,reward);
   const help=reward.querySelector('.ppv-help');if(help){help.classList.add('compact-reward-note');row.after(help);}
  }
  const input=detail.querySelector('#productQuantity');
  if(input&&!mounted.has(input)){
   mounted.add(input);input.setAttribute('aria-label','Quantity');const box=document.createElement('span');box.className='quantity-stepper';input.before(box);
   const minus=document.createElement('button'),plus=document.createElement('button');
   for(const [b,label,text]of [[minus,'Decrease quantity','−'],[plus,'Increase quantity','+']]){b.type='button';b.setAttribute('aria-label',label);b.textContent=text;}
   box.append(minus,input,plus);
   const sync=()=>{const min=Number(input.min)||1,max=Math.max(min,Number(input.max)||99);input.value=String(Math.max(min,Math.min(max,Math.trunc(Number(input.value)||min))));minus.disabled=Number(input.value)<=min;plus.disabled=Number(input.value)>=max;};
   minus.onclick=e=>{e.preventDefault();input.stepDown();sync();input.dispatchEvent(new Event('change',{bubbles:true}));};
   plus.onclick=e=>{e.preventDefault();input.stepUp();sync();input.dispatchEvent(new Event('change',{bubbles:true}));};input.addEventListener('change',sync);sync();
  }
  const frame=detail.querySelector('.detail-image'),thumbs=[...detail.querySelectorAll('.gallery-photo')];
  if(!frame||mounted.has(frame)||thumbs.length<2)return;mounted.add(frame);
  frame.classList.add('swipe-gallery');frame.tabIndex=0;frame.setAttribute('role','region');frame.setAttribute('aria-label','Product photos. Swipe, drag, or use left and right arrow keys.');
  const indicator=document.createElement('span');indicator.className='gallery-position';indicator.setAttribute('aria-live','polite');frame.after(indicator);
  const update=()=>{let i=thumbs.findIndex(b=>b.classList.contains('active'));if(i<0)i=0;indicator.textContent=`${i+1} / ${thumbs.length} · Swipe or drag`;thumbs.forEach((b,n)=>b.setAttribute('aria-pressed',String(n===i)));};
  const move=direction=>{const i=Math.max(0,thumbs.findIndex(b=>b.classList.contains('active')));thumbs[(i+direction+thumbs.length)%thumbs.length].click();update();};
  thumbs.forEach(b=>b.addEventListener('click',()=>queueMicrotask(update)));
  frame.addEventListener('keydown',e=>{if(e.key==='ArrowLeft'||e.key==='ArrowRight'){e.preventDefault();move(e.key==='ArrowLeft'?-1:1);}});
  frame.addEventListener('dragstart',e=>e.preventDefault());let start=null;
  frame.addEventListener('pointerdown',e=>{if(!e.isPrimary||e.button!==0)return;start={x:e.clientX,y:e.clientY,id:e.pointerId};frame.setPointerCapture?.(e.pointerId);frame.classList.add('dragging');});
  frame.addEventListener('pointerup',e=>{if(!start||start.id!==e.pointerId)return;const dx=e.clientX-start.x,dy=e.clientY-start.y;start=null;frame.classList.remove('dragging');if(Math.abs(dx)>=40&&Math.abs(dx)>Math.abs(dy)*1.3)move(dx<0?1:-1);});
  frame.addEventListener('pointercancel',()=>{start=null;frame.classList.remove('dragging');});update();
 }
 let queued=false;const schedule=()=>{if(queued)return;queued=true;queueMicrotask(()=>{queued=false;enhance();});};
 for(const id of ['page-shop','productDetail']){const root=document.getElementById(id);if(root)new MutationObserver(schedule).observe(root,{childList:true,subtree:true});}enhance();
})();
