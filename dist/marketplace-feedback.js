(function(){
 'use strict';
 const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function create(api){
  let summaries=new Map(),loaded=false,ticker=null,reviewRequest=0;
  function ratingContent(id){
   if(!loaded)return '<span class="rating-score"><span class="rating-stars" aria-hidden="true">☆☆☆☆☆</span><small>Loading…</small></span>';
   const r=summaries.get(id),count=Number(r?.rating_count)||0,score=count?Number(r.average_rating):0;
   if(!count)return '<span class="rating-score rating-empty" aria-label="Not rated yet"><span class="rating-stars" aria-hidden="true">☆☆☆☆☆</span><small>Not rated yet</small></span>';
   return `<span class="rating-score" aria-label="${score.toFixed(1)} out of 5, ${count} ratings"><span class="rating-stars" aria-hidden="true"><span style="width:${score*20}%">★★★★★</span>☆☆☆☆☆</span><b>${score.toFixed(1)}</b><small class="customer-rating-label">(${count})</small></span>`;
  }
  function markup(p){return `<span class="product-rating" data-product-rating="${escape(p.id)}">${ratingContent(p.id)}</span>`;}
  function refresh(){document.querySelectorAll('[data-product-rating]').forEach(e=>e.innerHTML=ratingContent(e.dataset.productRating));}
  async function loadRatings(ids){
   try {const next=new Map();for(let i=0;i<ids.length;i+=1000){const {data,error}=await api.db.rpc('marketplace_rating_summaries',{p_ids:ids.slice(i,i+1000)});if(error)throw error;for(const r of data||[])next.set(r.product_id,r);}summaries=next;loaded=true;refresh();}
   catch {document.querySelectorAll('[data-product-rating]').forEach(e=>e.innerHTML='<span class="rating-score"><span class="rating-stars" aria-hidden="true">☆☆☆☆☆</span><small>Unavailable</small></span>');}
  }
  function setSummary(id,data){summaries.set(id,{rating_count:data.count,average_rating:data.average});loaded=true;refresh();}
  async function mountReviews(id){
   const host=document.getElementById('productReviews');if(!host)return;const token=++reviewRequest,uid=api.getSession()?.user.id;
   const current=()=>token===reviewRequest&&host.isConnected&&uid===api.getSession()?.user.id;
   host.innerHTML='<p role="status">Loading customer feedback…</p>';
   let data;
   try{const result=await api.db.rpc('marketplace_product_reviews',{p_product_id:id,p_offset:0});if(result.error)throw result.error;data=result.data;if(!data)throw Error('No feedback response');}
   catch{if(!current())return;host.innerHTML='<p role="status">Customer feedback could not load.</p><button type="button" class="btn review-retry">Try again</button>';host.querySelector('button').onclick=()=>mountReviews(id);return;}
   if(!current())return;
   setSummary(id,data);let offset=0;
   host.innerHTML=`<div class="review-summary">${markup({id})}</div><div class="customer-reviews"></div><button type="button" class="btn review-more hidden">Load more reviews</button><p class="review-status" role="status"></p>`;
   const list=host.querySelector('.customer-reviews'),more=host.querySelector('.review-more'),status=host.querySelector('.review-status');
   function append(rows){for(const r of rows){const rating=Math.max(1,Math.min(5,Math.round(Number(r.rating)||1)));list.insertAdjacentHTML('beforeend',`<article class="customer-review"><div><strong>${r.is_mine?'Your rating':'Customer rating'}</strong><time>${escape(new Date(r.updated_at).toLocaleDateString('en-GB'))}</time></div><span class="customer-stars" aria-label="${rating} out of 5 stars">${'★'.repeat(rating)}${'☆'.repeat(5-rating)}</span>${r.body?`<p>${escape(r.body)}</p>`:'<small>Rating only</small>'}</article>`);}offset+=rows.length;more.classList.toggle('hidden',!rows.length||offset>=Number(data.review_count??data.count));}
   append(data.reviews||[]);
   if(!offset)list.innerHTML='<p class="reviews-empty">'+(Number(data.count)?'No written customer reviews yet. Ratings are shown above.':'No customer ratings yet.')+'</p>';
   more.onclick=async()=>{if(more.disabled)return;more.disabled=true;status.textContent='';try{
    const response=await api.db.rpc('marketplace_product_reviews',{p_product_id:id,p_offset:offset});if(response.error)throw response.error;
    if(!current())return;append(response.data?.reviews||[]);more.textContent='Load more reviews';
   }catch{if(current()){status.textContent='More reviews could not load. Please try again.';more.textContent='Try again';}}
   finally{if(current())more.disabled=false;}};
  }
  async function mountOrder(orderId){
   const host=document.getElementById('orderReviewPanel'),uid=api.getSession()?.user.id;if(!host||!uid)return;
   const {data:items,error}=await api.db.rpc('my_order_review_items',{p_order_id:orderId});if(!host.isConnected||uid!==api.getSession()?.user.id)return;
   if(error){host.innerHTML='<p>Purchase ratings could not load.</p>';return;}if(!items?.length){host.replaceChildren();return;}
   host.innerHTML='<h2>Rate your delivered products</h2>'+items.map((item,index)=>`<details class="order-rating-item"><summary>${escape(item.name)}<span>${item.rating?'Edit rating':'Give Rating'} →</span></summary><form class="customer-review-form" data-review-index="${index}"><label>Your rating<select name="rating" required><option value="">Choose stars</option>${[5,4,3,2,1].map(n=>`<option value="${n}" ${Number(item.rating)===n?'selected':''}>${n} stars</option>`).join('')}</select></label><label>Your review (optional)<textarea name="body" maxlength="2000" rows="3">${escape(item.body||'')}</textarea></label><button class="btn primary">Save rating</button><p class="review-status" role="status"></p></form></details>`).join('');
   host.querySelectorAll('form').forEach(form=>form.onsubmit=async e=>{e.preventDefault();const item=items[Number(form.dataset.reviewIndex)],button=form.querySelector('button'),status=form.querySelector('.review-status');button.disabled=true;try{const r=await api.db.rpc('submit_order_product_review',{p_order_id:orderId,p_product_id:item.product_id,p_rating:Number(form.elements.rating.value),p_body:form.elements.body.value.trim()});if(r.error)throw r.error;if(uid!==api.getSession()?.user.id)return;setSummary(item.product_id,r.data);status.textContent='Your rating has been saved.';form.closest('details').querySelector('summary span').textContent='Edit rating →';api.toast('Rating saved');}catch(err){status.textContent=err.message||'Could not save rating';}finally{button.disabled=false;}});
  }

  function renderTicker(){
   let host=document.getElementById('marketTicker');if(!host){document.getElementById('marketHero')?.insertAdjacentHTML('afterend','<section id="marketTicker" class="market-ticker shop-home-section hidden" aria-label="Marketplace announcements"></section>');host=document.getElementById('marketTicker');}if(!host)return;
   host.classList.toggle('hidden',!ticker?.enabled);if(!ticker?.enabled){host.replaceChildren();return;}
   const messages=(ticker.messages||[]).map(m=>`<span>${escape(m)}</span>`).join('');
   const paused=host.classList.contains('is-paused');
   const focused=host.contains(document.activeElement);
   host.innerHTML=`<div class="ticker-window"><div class="ticker-track"><div class="ticker-segment">${messages}</div><div class="ticker-segment" aria-hidden="true">${messages}</div></div></div><button type="button" class="ticker-pause" aria-label="${paused?'Resume announcements':'Pause announcements'}" aria-pressed="${paused}">${paused?'▶':'Ⅱ'}</button>`;
   if(focused)host.querySelector('button').focus({preventScroll:true});
   host.querySelector('button').onclick=e=>{const paused=host.classList.toggle('is-paused');e.currentTarget.textContent=paused?'▶':'Ⅱ';e.currentTarget.setAttribute('aria-label',paused?'Resume announcements':'Pause announcements');e.currentTarget.setAttribute('aria-pressed',String(paused));};
  }
  async function loadTicker(){const {data,error}=await api.db.rpc('marketplace_ticker_settings');if(!error&&data){ticker=data;renderTicker();}}
  async function mountAdmin(){
   const hero=document.getElementById('heroBannerForm');if(!hero||document.getElementById('tickerAdminForm'))return;
   hero.closest('.card')?.insertAdjacentHTML('afterend',`<section class="card ticker-editor"><div class="card-head"><div><h3>Scrolling announcement strip</h3><p>Three messages below the marketplace carousel.</p></div></div><form class="card-body form" id="tickerAdminForm">${[1,2,3].map(n=>`<label>Message ${n}<input name="message${n}" maxlength="200" required></label>`).join('')}<label class="ticker-enable"><input type="checkbox" name="enabled"> Show announcement strip</label><button class="btn primary">Save messages</button><p role="status" class="ticker-save-status"></p></form></section>`);
   const form=document.getElementById('tickerAdminForm');if(!form)return;await loadTicker();for(let i=1;i<=3;i++)form.elements['message'+i].value=ticker?.messages?.[i-1]||'';form.elements.enabled.checked=ticker?.enabled!==false;
   form.onsubmit=async e=>{e.preventDefault();const button=form.querySelector('button'),status=form.querySelector('.ticker-save-status');button.disabled=true;try{const {data,error}=await api.db.rpc('admin_save_marketplace_ticker',{p_messages:[1,2,3].map(n=>form.elements['message'+n].value.trim()),p_enabled:form.elements.enabled.checked});if(error)throw error;ticker=data;renderTicker();status.textContent='Saved. The marketplace strip is updated.';}catch(err){status.textContent=err.message||'Could not save messages';}finally{button.disabled=false;}};
  }
  return {markup,loadRatings,mountReviews,mountOrder,loadTicker,mountAdmin};
 }
 window.MioFeedback={create};
})();
