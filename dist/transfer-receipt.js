/* Display and locally download a verified transfer receipt; never moves funds. */
window.MioTransferReceipt=(()=>{
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const logo='/market-is-online-logo.png';
 let dialog=null,current=null;
 function clear(){current=null;if(dialog){if(dialog.open&&typeof dialog.close==='function')dialog.close();dialog.remove();dialog=null;}}
 function show(model){
  clear();current=model;dialog=document.createElement('dialog');dialog.className='transfer-receipt-dialog';dialog.setAttribute('aria-labelledby','transferReceiptTitle');
  const party=(title,p,wallet)=>`<section class="transfer-receipt-party"><h3>${title}</h3><strong>${esc(p.name||'Member')}</strong><span>${esc(p.code||'Member code unavailable')}</span><small>${title==='Sender'?'From':'To'}: ${esc(wallet)}</small></section>`;
  dialog.innerHTML=`<article class="transfer-receipt"><header><img src="${logo}" alt="Market is Online"><h2 id="transferReceiptTitle">Transfer Receipt</h2></header><div class="transfer-receipt-success"><span aria-hidden="true">✓</span><h3>${esc(model.title)}</h3><p>${esc(model.direction)}</p><strong>${esc(model.amount)} <small>MIO</small></strong></div><dl class="transfer-receipt-meta"><div><dt>Receipt reference</dt><dd>${esc(model.id)}</dd></div><div><dt>Date &amp; time (Pakistan)</dt><dd>${esc(model.date)}</dd></div><div><dt>Status</dt><dd>Completed</dd></div></dl><div class="transfer-receipt-parties">${party('Sender',model.sender,model.source)}${party('Receiver',model.receiver,model.destination)}</div>${model.note?`<p class="transfer-receipt-note"><b>Note</b><span>${esc(model.note)}</span></p>`:''}<div class="transfer-receipt-total"><strong>Total transferred</strong><strong>${esc(model.amount)} MIO</strong></div></article><div class="transfer-receipt-actions"><button type="button" class="btn primary" data-download-receipt aria-label="Download receipt as PNG">↓ Download</button><button type="button" class="btn" data-close-receipt>Close</button></div><p class="transfer-receipt-error" role="status" aria-live="polite"></p>`;
  document.body.append(dialog);dialog.querySelector('[data-close-receipt]').onclick=clear;dialog.addEventListener('close',()=>{if(current===model)clear()});dialog.querySelector('[data-download-receipt]').onclick=async e=>{const button=e.currentTarget;button.disabled=true;try{await download(model)}catch{if(current===model)dialog.querySelector('.transfer-receipt-error').textContent='Receipt download failed. Please try again.'}finally{button.disabled=false}};
  if(typeof dialog.showModal==='function')dialog.showModal();else dialog.setAttribute('open','');
 }
 async function download(model){
  const brand=await new Promise((resolve,reject)=>{const img=new Image();img.onload=()=>resolve(img);img.onerror=reject;img.src=logo});
  if(current!==model)return;
  const canvas=document.createElement('canvas');canvas.width=1000;canvas.height=2400;const c=canvas.getContext('2d');if(!c)throw Error('Image export unavailable');
  c.fillStyle='#ffffff';c.fillRect(0,0,1000,2400);c.textBaseline='top';
  const font=(size,bold=false)=>{c.font=`${bold?'700':'400'} ${size}px Arial, sans-serif`};
  const text=(value,x,y,size=24,bold=false,color='#183e2f')=>{font(size,bold);c.fillStyle=color;c.fillText(String(value),x,y)};
  const lines=(value,max,size=24,bold=false)=>{font(size,bold);const result=[];let line='';for(const ch of String(value)){if(ch==='\n'){result.push(line);line='';continue}if(c.measureText(line+ch).width>max&&line){result.push(line);line=''}line+=ch}result.push(line);return result};
  const wrapped=(value,x,y,width,size=24,bold=false,color='#183e2f')=>{const list=lines(value,width,size,bold);list.forEach((line,i)=>text(line,x,y+i*(size+10),size,bold,color));return list.length*(size+10)};
  const centered=(value,y,size,bold=false,color)=>{font(size,bold);text(value,(1000-c.measureText(value).width)/2,y,size,bold,color)};
  const rule=y=>{c.fillStyle='#dce7e0';c.fillRect(60,y,880,2)};
  const logoW=Math.min(480,brand.naturalWidth),logoH=logoW*brand.naturalHeight/brand.naturalWidth;c.drawImage(brand,(1000-logoW)/2,45,logoW,logoH);
  let y=45+logoH+30;centered('Transfer Receipt',y,44,true);y+=80;c.fillStyle='#07865b';c.beginPath();c.arc(500,y+34,34,0,Math.PI*2);c.fill();centered('✓',y+8,44,true,'#ffffff');y+=92;
  centered(model.title,y,34,true);y+=50;centered(model.direction,y,25,false,'#596c61');y+=58;centered(model.amount+' MIO',y,52,true,'#08764e');y+=86;rule(y);y+=26;
  for(const [label,value] of [['Receipt reference',model.id],['Date & time (Pakistan)',model.date],['Status','Completed']]){text(label,60,y,23,false,'#607065');const h=wrapped(value,400,y,540,23,true);y+=Math.max(38,h)+16}rule(y);y+=28;
  const parties=[['Sender',model.sender,model.source],['Receiver',model.receiver,model.destination]];
  const heights=parties.map(([,p,w])=>100+lines(p.name||'Member',380,27,true).length*37+lines(p.code||'Member code unavailable',380,23).length*33+lines(w,380,23).length*33);
  const boxH=Math.max(...heights);parties.forEach(([label,p,w],i)=>{const x=60+i*450;c.fillStyle='#eef9f3';c.fillRect(x,y,430,boxH);text(label.toUpperCase(),x+24,y+22,22,true,'#08764e');let yy=y+62;yy+=wrapped(p.name||'Member',x+24,yy,380,27,true);yy+=wrapped(p.code||'Member code unavailable',x+24,yy+6,380,23,false,'#596c61')+12;wrapped((i?'To: ':'From: ')+w,x+24,yy,380,23,false,'#596c61')});y+=boxH+30;
  if(model.note){text('Note',60,y,23,true);y+=36;y+=wrapped(model.note,60,y,880,23,false,'#596c61')+22}
  rule(y);y+=26;text('Total transferred',60,y,29,true);font(29,true);text(model.amount+' MIO',940-c.measureText(model.amount+' MIO').width,y,29,true,'#08764e');y+=70;
  const output=document.createElement('canvas');output.width=1000;output.height=Math.ceil(y);output.getContext('2d').drawImage(canvas,0,0);
  const blob=await new Promise((resolve,reject)=>output.toBlob(b=>b?resolve(b):reject(Error('Export failed')),'image/png'));if(current!==model)return;
  const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='transfer-receipt-'+String(model.id).replace(/[^a-zA-Z0-9_-]/g,'')+'.png';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);
 }
 return {show,clear};
})();
