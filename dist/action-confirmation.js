/* Persistent transaction confirmations. Show only after a successful server response. */
window.MioActionConfirmation=(()=>{
 'use strict';
 let dialog=null,identity=null,restoreFocus=null;
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const number=v=>new Intl.NumberFormat('en-US',{minimumFractionDigits:2,maximumFractionDigits:4}).format(Number(v));
 function clear(){const old=dialog;dialog=null;if(old){if(old.open&&old.close)old.close();old.remove()}document.body.classList.remove('action-confirmation-open');if(restoreFocus?.isConnected)restoreFocus.focus({preventScroll:true});restoreFocus=null;}
 function setIdentity(uid){if(uid!==identity){clear();identity=uid}}
 function show(model){
  if(!identity||model.owner!==identity)return;
  clear();restoreFocus=document.activeElement;
  const transfer=model.kind==='transfer',error=model.kind==='error';
  const title=error?model.title:transfer?'Points Transferred Successfully!':'Congratulations!';
  const message=error?model.message:transfer?'Your MIO Points have been transferred successfully.':`Your ${model.plan} subscription is now active.`;
  const card=document.createElement('dialog');dialog=card;card.className='action-confirmation'+(error?' action-confirmation-error':'');card.setAttribute('aria-labelledby','actionConfirmationTitle');card.setAttribute('aria-describedby','actionConfirmationMessage');card.setAttribute('closedby','none');
  const person=(label,p)=>`<div class="action-person"><span>${label}</span><div><strong>${esc(p?.name||'Member')}</strong><small>${esc(p?.code||'')}</small></div></div>`;
  card.innerHTML=`<article class="action-confirmation-card"><button type="button" class="action-confirmation-close" aria-label="Close confirmation">×</button><div class="action-confirmation-mark" aria-hidden="true">${error?'!':'✓'}</div><h2 id="actionConfirmationTitle">${esc(title)}</h2><p id="actionConfirmationMessage" class="action-confirmation-message">${esc(message)}</p>${!transfer&&!error?'<p class="action-confirmation-welcome">Welcome to the next step of your Market Is Online journey. Explore your membership benefits and make the most of your new plan.</p>':''}${error?'':`<div class="action-confirmation-value"><span>${transfer?'POINTS TRANSFERRED':'YOUR SUBSCRIPTION'}</span>${transfer?`<strong>${number(model.amount)} <small>MIO</small></strong>`:`<strong>${esc(model.plan)}</strong><b>${number(model.amount)} MIO Points</b>`}<em>✓ ${transfer?'Completed':'Activated'}</em></div>`}${transfer?`<div class="action-confirmation-people">${person('FROM',model.sender)}<div class="action-person-arrow" aria-hidden="true">↓</div>${person('TO',model.receiver)}</div><div class="action-confirmation-verified">✓ Recipient verified</div>${model.download?'<button type="button" class="btn action-confirmation-download">↓ Download receipt</button>':''}`:''}<p class="action-confirmation-status" role="status" aria-live="polite"></p><small class="action-confirmation-hint">Close this card whenever you’re ready.</small></article>`;
  document.body.append(card);document.body.classList.add('action-confirmation-open');
  card.querySelector('.action-confirmation-close').onclick=clear;
  card.addEventListener('cancel',e=>e.preventDefault());
  card.querySelector('.action-confirmation-download')?.addEventListener('click',async e=>{const button=e.currentTarget;button.disabled=true;try{await model.download();if(dialog===card)card.querySelector('.action-confirmation-status').textContent='Receipt downloaded.'}catch{if(dialog===card)card.querySelector('.action-confirmation-status').textContent='Receipt download is unavailable. Please try again or open Transaction history.'}finally{button.disabled=false}});
  if(card.showModal)card.showModal();else card.setAttribute('open','');
  card.querySelector('.action-confirmation-close').focus();
 }
 function credentialError(error){const message=String(error?.message||error||'');if(/(?:invalid|incorrect|wrong).*(?:transaction\s+)?pin|pin.*(?:invalid|incorrect|wrong)/i.test(message))return {title:'Incorrect PIN',message:'Your transaction PIN is incorrect. Please enter the correct PIN and try again.'};if(/invalid login credentials|(?:invalid|incorrect|wrong).*password|password.*(?:invalid|incorrect|wrong)|password verification failed/i.test(message))return {title:'Incorrect password',message:'Your password is incorrect. Please enter the correct password and try again.'};return null;}
 function showCredentialError(error,owner){const message=credentialError(error);if(!message||!identity||owner!==identity)return false;show({kind:'error',owner,...message});return true;}
 return {show,clear,setIdentity,credentialError,showCredentialError};
})();
