(function(){
'use strict';
// Round-robin sellers and rotate each seller's products once per full seller cycle.
// This avoids locking products out when seller/product counts share a divisor.
function fairOrder(items,step=Math.floor(Date.now()/60000)){
 const groups=new Map();for(const item of items){const id=String(item.vendor_id||'');if(!groups.has(id))groups.set(id,[]);groups.get(id).push(item)}
 const sellers=[...groups.keys()].sort();if(!sellers.length)return[];step=Math.max(0,Math.floor(Number(step)||0));
 const sellerOffset=step%sellers.length,productStep=Math.floor(step/sellers.length),order=sellers.slice(sellerOffset).concat(sellers.slice(0,sellerOffset));
 const bins=order.map(id=>{const rows=[...groups.get(id)].sort((a,b)=>(Date.parse(b.created_at)||0)-(Date.parse(a.created_at)||0)||String(a.id).localeCompare(String(b.id))),offset=productStep%rows.length;return rows.slice(offset).concat(rows.slice(0,offset))});
 const result=[];for(let i=0;i<Math.max(...bins.map(b=>b.length));i++)for(const bin of bins)if(bin[i])result.push(bin[i]);return result;
}
function vendorDirectory(stores,products){
 const rows=new Map();for(const v of stores||[])if(v.status==='active')rows.set(String(v.id),{id:v.id,name:v.business_name||'Approved seller',logo:v.logo_url||'',products:[],categories:new Set()});
 for(const p of products){if(p.bundle_definition||p.vendors?.status&&p.vendors.status!=='active')continue;const id=String(p.vendor_id);if(stores!==null&&!rows.has(id))continue;const current=rows.get(id)||{id:p.vendor_id,name:p.vendors?.business_name||'Approved seller',logo:p.vendors?.logo_url||'',products:[],categories:new Set()};current.products.push(p);if(p.category)current.categories.add(p.category);rows.set(id,current)}
 return [...rows.values()].sort((a,b)=>a.name.localeCompare(b.name));
}
function create(api){
 const $=id=>document.getElementById(id),toggle=$('catalogFilterToggle'),panel=$('catalogFilters'),grid=$('productsGrid');let lastInteraction=0,hovered=false;
 function close(focus=false){panel.hidden=true;toggle.setAttribute('aria-expanded','false');if(focus)toggle.focus()}
 function sync(){const count=Number(api.category()!=='all')+Number($('catalogVendorFilter').value!=='all')+Number($('sortSelect').value!=='fair');$('catalogFilterLabel').textContent='Filter'+(count?' · '+count:'');panel.querySelectorAll('[data-category]').forEach(b=>{const selected=b.dataset.category===api.category();b.classList.toggle('active',selected);b.setAttribute('aria-pressed',String(selected))})}
 toggle.onclick=()=>{const open=panel.hidden;panel.hidden=!open;toggle.setAttribute('aria-expanded',String(open));if(open)panel.querySelector('select')?.focus()};
 $('catalogFilterClose').onclick=()=>close(true);$('catalogFilterApply').onclick=()=>close(true);$('catalogFilterReset').onclick=()=>{api.clear();sync()};
 $('catalogVendorFilter').onchange=()=>api.reset();
 const outside=e=>{if(!panel.hidden&&!panel.contains(e.target)&&!toggle.contains(e.target))close()},escape=e=>{if(e.key==='Escape'&&!panel.hidden){e.preventDefault();close(true)}};
 document.addEventListener('click',outside);document.addEventListener('keydown',escape);
 const activity=()=>lastInteraction=Date.now(),hover=e=>{if(e.pointerType==='mouse')hovered=!!e.target.closest('.product')},leave=()=>hovered=false;
 grid.addEventListener('pointermove',hover);grid.addEventListener('pointerleave',leave);grid.addEventListener('pointerdown',activity);grid.addEventListener('keydown',activity);window.addEventListener('scroll',activity,{passive:true});
 function tick(){const step=Math.floor(Date.now()/60000);if(step===api.step()||document.hidden||!api.active()||$('sortSelect').value!=='fair'||$('searchBox').value.trim()||api.expanded()||!panel.hidden||hovered||grid.contains(document.activeElement)||Date.now()-lastInteraction<10000||document.querySelector('.modal.open,dialog[open]')||window.matchMedia?.('(prefers-reduced-motion: reduce)').matches)return false;api.rotate(step);return true}
 const timer=setInterval(tick,10000);document.addEventListener('visibilitychange',tick);sync();
 return {sync,close,tick,destroy(){clearInterval(timer);document.removeEventListener('click',outside);document.removeEventListener('keydown',escape);document.removeEventListener('visibilitychange',tick);window.removeEventListener('scroll',activity);grid.removeEventListener('pointermove',hover);grid.removeEventListener('pointerleave',leave);grid.removeEventListener('pointerdown',activity);grid.removeEventListener('keydown',activity)}};
}
window.MioMarketplaceCatalog={fairOrder,vendorDirectory,create};
})();
