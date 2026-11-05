(function(){
 'use strict';
 const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function create(api){
  let summaries=new Map(),loaded=false,ticker=null,reviewRequest=0;
  const sample=id=>3.5+([...String(id)].reduce((a,c)=>(Math.imul(a,31)+c.charCodeAt(0))>>>0,7)%4)*.5;
  function ratingContent(id){
   if(!loaded)return '<small>Ratings loading…</small>';
   const r=summaries.get(id),count=Number(r?.rating_count)||0,score=count?Number(r.average_rating):sample(id);
   return `<span class="rating-score"><span class="rating-stars" aria-hidden="true"><span style="width:${score*20}%">★★★★★</span>☆☆☆☆☆</span><b>${score.toFixed(1)}</b><span>/ 5</span></span><small class="${count?'customer-rating-label':'sample-rating-label'}">${count?`${count} customer rating${count===1?'':'s'}`:'Sample rating—not customer feedback'}</small>`;
  }
  function markup(p){return `<span class="product-rating" data-product-rating="${escape(p.id)}">${ratingContent(p.id)}</span>`;}
  function refresh(){document.querySelectorAll('[data-product-rating]').forEach(e=>e.innerHTML=ratingContent(e.dataset.productRating));}
  async function loadRatings(ids){
   try {const next=new Map();for(let i=0;i<ids.length;i+=1000){const {data,error}=await api.db.rpc('marketplace_rating_summaries',{p_ids:ids.slice(i,i+1000)});if(error)throw error;for(const r of data||[])next.set(r.product_id,r);}summaries=next;loaded=true;refresh();}
   catch {document.querySelectorAll('[data-product-rating]').forEach(e=>e.innerHTML='<small>Ratings temporarily unavailable</small>');}
  }
  function setSummary(id,data){summaries.set(id,{rating_count:data.count,average_rating:data.average});loaded=true;refresh();}
  async function mountReviews(id){
   const host=document.getElementById('productReviews');if(!host)return;const token=++reviewRequest,uid=api.getSession()?.user.id;
   host.innerHTML='<p role="status">Loading customer feedback…</p>';
   const {data,error}=await api.db.rpc('marketplace_product_reviews',{p_product_id:id,p_offset:0});
   if(token!==reviewRequest||!host.isConnected||uid!==api.getSession()?.user.id)return;
   if(error){host.innerHTML='<p>Customer feedback could not load.</p><button type="button" class="btn review-retry">Try again</button>';host.querySelector('button').onclick=()=>mountReviews(id);return;}
   setSummary(id,data);let offset=0;
   host.innerHTML=`<div class="review-summary">${markup({id})}<p>Ratings reflect members’ opinions. Purchases are not verified.</p></div><div class="customer-reviews"></div><button type="button" class="btn review-more hidden">Load more ratings</button>${uid?`<form class="customer-review-form"><h3>${data.mine?'Update your rating':'Rate this product'}</h3><label>Your rating<select name="rating" required><option value="">Choose stars</option>${[5,4,3,2,1].map(n=>`<option value="${n}" ${Number(data.mine?.rating)===n?'selected':''}>${n} star${n===1?'':'s'}</option>`).join('')}</select></label><label>Your review <small>(optional · publicly visible)</small><textarea name="body" maxlength="2000" rows="3" placeholder="Share your experience with this product">${escape(data.mine?.body||'')}</textarea></label><small>One rating per member. Updating replaces your previous rating.</small><button class="btn primary" type="submit">${data.mine?'Update rating':'Submit rating'}</button><p class="review-status" role="status"></p></form>`:'<p><button type="button" class="btn primary" data-page="login">Sign in to rate or review</button></p>'}`;
   const list=host.querySelector('.customer-reviews'),more=host.querySelector('.review-more');
   function append(rows){for(const r of rows){list.insertAdjacentHTML('beforeend',`<article class="customer-review"><div><strong>${r.is_mine?'Your rating':'Member rating'}</strong><time>${escape(new Date(r.updated_at).toLocaleDateString('en-GB'))}</time></div><span class="customer-stars" aria-label="${Number(r.rating)} out of 5 stars">${'★'.repeat(Number(r.rating))}${'☆'.repeat(5-Number(r.rating))}</span>${r.body?`<p>${escape(r.body)}</p>`:'<small>Rating only</small>'}</article>`);}offset+=rows.length;more.classList.toggle('hidden',offset>=Number(data.count));}
   append(data.reviews||[]);if(!data.count)list.innerHTML='<p class="reviews-empty">No customer ratings yet. Be the first to share your experience.</p>';
   more.onclick=async()=>{more.disabled=true;const response=await api.db.rpc('marketplace_product_reviews',{p_product_id:id,p_offset:offset});if(response.error){more.textContent='Could not load · Try again';}else append(response.data.reviews||[]);more.disabled=false;};
   const form=host.querySelector('form');if(form)form.onsubmit=async e=>{e.preventDefault();const button=form.querySelector('button'),status=form.querySelector('.review-status');button.disabled=true;status.textContent='Saving…';try{const result=await api.db.rpc('submit_product_review',{p_product_id:id,p_rating:Number(form.elements.rating.value),p_body:form.elements.body.value.trim()});if(result.error)throw result.error;if(uid!==api.getSession()?.user.id)return;setSummary(id,result.data);await mountReviews(id);api.toast('Your rating has been saved');}catch(err){status.textContent=err.message||'Could not save. Please try again.';}finally{button.disabled=false;}};
  }
  function renderTicker(){
   let host=document.getElementById('marketTicker');if(!host){document.getElementById('marketHero')?.insertAdjacentHTML('afterend','<section id="marketTicker" class="market-ticker shop-home-section hidden" aria-label="Marketplace announcements"></section>');host=document.getElementById('marketTicker');}if(!host)return;
   host.classList.toggle('hidden',!ticker?.enabled);if(!ticker?.enabled){host.replaceChildren();return;}
   const messages=(ticker.messages||[]).map(m=>`<span>${escape(m)}</span>`).join('');
   host.innerHTML=`<div class="ticker-window"><div class="ticker-track"><div class="ticker-segment">${messages}</div><div class="ticker-segment" aria-hidden="true">${messages}</div></div></div><button type="button" class="ticker-pause" aria-label="Pause announcements" aria-pressed="false">Ⅱ</button>`;
   host.querySelector('button').onclick=e=>{const paused=host.classList.toggle('is-paused');e.currentTarget.textContent=paused?'▶':'Ⅱ';e.currentTarget.setAttribute('aria-label',paused?'Resume announcements':'Pause announcements');e.currentTarget.setAttribute('aria-pressed',String(paused));};
  }
  async function loadTicker(){const {data,error}=await api.db.rpc('marketplace_ticker_settings');if(!error&&data){ticker=data;renderTicker();}}
  async function mountAdmin(){
   const hero=document.getElementById('heroBannerForm');if(!hero||document.getElementById('tickerAdminForm'))return;
   hero.closest('.card')?.insertAdjacentHTML('afterend',`<section class="card ticker-editor"><div class="card-head"><div><h3>Scrolling announcement strip</h3><p>Three messages below the marketplace carousel.</p></div></div><form class="card-body form" id="tickerAdminForm">${[1,2,3].map(n=>`<label>Message ${n}<input name="message${n}" maxlength="200" required></label>`).join('')}<label class="ticker-enable"><input type="checkbox" name="enabled"> Show announcement strip</label><button class="btn primary">Save messages</button><p role="status" class="ticker-save-status"></p></form></section>`);
   const form=document.getElementById('tickerAdminForm');if(!form)return;await loadTicker();for(let i=1;i<=3;i++)form.elements['message'+i].value=ticker?.messages?.[i-1]||'';form.elements.enabled.checked=ticker?.enabled!==false;
   form.onsubmit=async e=>{e.preventDefault();const button=form.querySelector('button'),status=form.querySelector('.ticker-save-status');button.disabled=true;try{const {data,error}=await api.db.rpc('admin_save_marketplace_ticker',{p_messages:[1,2,3].map(n=>form.elements['message'+n].value.trim()),p_enabled:form.elements.enabled.checked});if(error)throw error;ticker=data;renderTicker();status.textContent='Saved. The marketplace strip is updated.';}catch(err){status.textContent=err.message||'Could not save messages';}finally{button.disabled=false;}};
  }
  return {markup,loadRatings,mountReviews,loadTicker,mountAdmin};
 }
 window.MioFeedback={create};
})();
