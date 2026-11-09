/* Display and locally download a verified transfer receipt; never moves funds. */
window.MioTransferReceipt=(()=>{
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const logo='/market-is-online-logo.png';
 const shortReference=value=>{const id=String(value??'');return id.length>18?id.slice(0,8).toUpperCase()+'…'+id.slice(-4).toUpperCase():id};
 const referenceMarkup=value=>`<button type="button" class="transaction-reference" data-copy-reference="${esc(value)}" title="${esc(value)} · Copy full reference" aria-label="Copy full transaction reference ${esc(value)}"><span>${esc(shortReference(value))}</span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h3"/></svg><span class="reference-copy-status" role="status"></span></button>`;
 async function copyReference(button){if(!button)return;const status=button.querySelector('.reference-copy-status');try{await navigator.clipboard.writeText(button.dataset.copyReference);if(status)status.textContent='Copied';setTimeout(()=>{if(status)status.textContent=''},1800)}catch{if(status)status.textContent='Select full reference below';if(!button.nextElementSibling?.matches('.reference-manual-copy')){const input=document.createElement('input');input.className='reference-manual-copy';input.readOnly=true;input.value=button.dataset.copyReference;input.setAttribute('aria-label','Full transaction reference');button.after(input);input.select();}}}
 document.addEventListener('click',e=>copyReference(e.target.closest('[data-copy-reference]')));
 let dialog=null,current=null;
 function clear(){current=null;if(dialog){if(dialog.open&&typeof dialog.close==='function')dialog.close();dialog.remove();dialog=null;}}
 function show(model){
  clear();current=model;dialog=document.createElement('dialog');dialog.className='transfer-receipt-dialog';dialog.setAttribute('aria-labelledby','transferReceiptTitle');
  const cell=v=>`<td>${esc(v)}</td>`;
  const balances=(model.details||[]).filter(([label])=>['Balance before','Balance after'].includes(label));
  const details=(model.details||[]).filter(([label])=>!['Balance before','Balance after'].includes(label));
  dialog.innerHTML=`<article class="transfer-receipt"><header><img src="/market-is-online-logo-header.svg" alt="Market is Online"><div class="transfer-receipt-heading"><h2 id="transferReceiptTitle">${esc(model.heading||'Transfer Receipt')}</h2><span class="transfer-receipt-status">✓ Completed</span></div></header><div class="transfer-receipt-amount"><span>${esc(model.direction)}</span><strong>${esc(model.amount)} <small>MIO</small></strong></div><dl class="transfer-receipt-meta"><div><dt>Reference</dt><dd>${referenceMarkup(model.id)}</dd></div><div><dt>Date &amp; time</dt><dd>${esc(model.date)} PKT</dd></div></dl>${model.details?`<dl class="transfer-receipt-details">${details.map(([label,value])=>`<div class="${label==='Package'?'receipt-package-line':''}"><dt>${esc(label)}</dt><dd>${esc(value)}</dd></div>`).join('')}</dl>`:`<table class="transfer-receipt-table"><colgroup><col style="width:22%"><col style="width:39%"><col style="width:39%"></colgroup><thead><tr><th scope="col">Details</th><th scope="col">Sender</th><th scope="col">Receiver</th></tr></thead><tbody><tr><th scope="row">Name</th>${cell(model.sender.name||'Member')}${cell(model.receiver.name||'Member')}</tr><tr><th scope="row">MIO ID</th>${cell(model.sender.code||'Unavailable')}${cell(model.receiver.code||'Unavailable')}</tr><tr><th scope="row">Wallet</th>${cell(model.source)}${cell(model.destination)}</tr></tbody></table>`}${balances.length?`<div class="receipt-balance-summary">${balances.map(([label,value])=>`<div><span>${esc(label)}</span><strong>${esc(value)}</strong></div>`).join('')}</div>`:''}${model.note?`<p class="transfer-receipt-note"><b>Note</b><span>${esc(model.note)}</span></p>`:''}</article><div class="transfer-receipt-actions"><button type="button" class="btn primary" data-download-receipt aria-label="Download receipt as PNG">↓ Download</button><button type="button" class="btn" data-close-receipt>Close</button></div><p class="transfer-receipt-error" role="status" aria-live="polite"></p>`;
  document.body.append(dialog);dialog.querySelector('[data-close-receipt]').onclick=clear;dialog.addEventListener('close',()=>{if(current===model)clear()});dialog.querySelector('[data-download-receipt]').onclick=async e=>{const button=e.currentTarget;button.disabled=true;try{await download(model)}catch{if(current===model)dialog.querySelector('.transfer-receipt-error').textContent='Receipt download failed. Please try again.'}finally{button.disabled=false}};
  if(typeof dialog.showModal==='function')dialog.showModal();else dialog.setAttribute('open','');
 }
 async function download(model){
  const brand=await new Promise((resolve,reject)=>{const img=new Image();img.onload=()=>resolve(img);img.onerror=reject;img.src=logo});
  if(current!==model)return;
  // Record drawing operations first so long names/notes never exceed a fixed canvas.
  const canvas=document.createElement('canvas');const c=canvas.getContext('2d');if(!c)throw Error('Image export unavailable');
  const draw=[];
  const font=(size,bold=false)=>{c.font=`${bold?'700':'400'} ${size}px Arial, sans-serif`};
  const text=(value,x,y,size=24,bold=false,color='#183e2f')=>draw.push(()=>{font(size,bold);c.fillStyle=color;c.fillText(String(value),x,y)});
  const rect=(x,y,w,h,color)=>draw.push(()=>{c.fillStyle=color;c.fillRect(x,y,w,h)});
  const lines=(value,max,size=24,bold=false)=>{
   font(size,bold);const result=[];
   for(const paragraph of String(value).split('\n')){
    let line='';for(const word of paragraph.split(/\s+/).filter(Boolean)){
     const next=line?line+' '+word:word;
     if(c.measureText(next).width<=max){line=next;continue}
     if(line){result.push(line);line=''}
     for(const ch of word){if(line&&c.measureText(line+ch).width>max){result.push(line);line=''}line+=ch}
    }result.push(line);
   }return result;
  };
  const wrapped=(value,x,y,width,size=24,bold=false,color='#183e2f')=>{const list=lines(value,width,size,bold);list.forEach((line,i)=>text(line,x,y+i*(size+8),size,bold,color));return list.length*(size+8)};
  const rule=y=>rect(36,y,828,1,'#dce7e0');rect(0,0,900,8,'#e6a327');
  draw.push(()=>c.drawImage(brand,0,175,2170,340,36,30,340,340*340/2170));
  let y=110;text(model.heading||'Transfer Receipt',36,y,36,true);text('✓ Completed',652,y+5,25,true,'#08764e');y+=58;
  const directionH=lines(model.direction,780,24).length*32;
  const amountH=lines(model.amount+' MIO',780,48,true).length*56;
  rect(36,y,828,directionH+amountH+32,'#0a654a');wrapped(model.direction,58,y+16,780,24,false,'#d6eee4');wrapped(model.amount+' MIO',58,y+16+directionH,780,48,true,'#ffffff');y+=directionH+amountH+52;
  for(const [label,value] of [['Reference',shortReference(model.id)],['Date & time',model.date+' PKT']]){text(label,36,y,23,false,'#607065');const h=wrapped(value,258,y,606,23,true);y+=Math.max(31,h)+12}rule(y);y+=18;
  if(model.details){
   for(const [label,value] of model.details.filter(([label])=>!['Balance before','Balance after'].includes(label))){text(label,36,y+10,23,false,'#607065');const h=wrapped(value,300,y+10,564,23,true);y+=h+20;rule(y)}
  }else{
  rect(36,y,828,46,'#edf5f0');text('Details',50,y+10,23,true);text('Sender',240,y+10,23,true);text('Receiver',560,y+10,23,true);y+=46;
  for(const [label,left,right] of [['Name',model.sender.name||'Member',model.receiver.name||'Member'],['MIO ID',model.sender.code||'Unavailable',model.receiver.code||'Unavailable'],['Wallet',model.source,model.destination]]){
   text(label,50,y+14,23,false,'#607065');const leftH=wrapped(left,240,y+14,290,23,label==='Name');const rightH=wrapped(right,560,y+14,290,23,label==='Name');y+=Math.max(leftH,rightH)+28;rule(y);
  }
  }
  const balanceRows=(model.details||[]).filter(([label])=>['Balance before','Balance after'].includes(label));
  if(balanceRows.length){y+=16;balanceRows.forEach(([label,value],i)=>{const x=36+i*424;rect(x,y,404,88,i?'#eaf6ef':'#f3f6f4');text(label,x+16,y+10,21,false,'#607065');wrapped(value,x+16,y+42,370,27,true);});y+=108;}
  y+=12;text('Full transaction reference',36,y,17,false,'#607065');y+=25;y+=wrapped(model.id,36,y,828,18,false,'#607065');
  if(model.note){y+=18;text('Note',36,y,23,true);y+=wrapped(model.note,140,y,724,23,false,'#596c61')}
  y+=32;canvas.width=900;canvas.height=Math.ceil(y);c.fillStyle='#ffffff';c.fillRect(0,0,900,canvas.height);c.textBaseline='top';draw.forEach(fn=>fn());
  const output=canvas;
  const blob=await new Promise((resolve,reject)=>output.toBlob(b=>b?resolve(b):reject(Error('Export failed')),'image/png'));if(current!==model)return;
  const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='transfer-receipt-'+String(model.id).replace(/[^a-zA-Z0-9_-]/g,'')+'.png';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);
 }
 return {show,clear,shortReference,referenceMarkup,copyReference};
})();
