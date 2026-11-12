/* Installation and connectivity UI is independent of account and financial logic. */
(() => {
  'use strict';
  let installEvent=null, installReported=false, registration=null, updateAccepted=false, reloading=false, opener=null, scheduled=false;
  const standalone=()=>window.matchMedia('(display-mode: standalone)').matches || navigator.standalone===true;
  const isIOS=()=>/iPad|iPhone|iPod/.test(navigator.userAgent)||navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1;
  const icon='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M12 3v12m-4-4 4 4 4-4M5 16v4h14v-4"/></svg>';
  const dialog=document.createElement('dialog');dialog.id='pwaInstallDialog';dialog.className='pwa-dialog';dialog.setAttribute('aria-labelledby','pwaInstallTitle');
  dialog.innerHTML='<button type="button" class="pwa-close" aria-label="Close app installation">×</button><img src="/icons/mio-192.png" width="76" height="76" alt=""><p class="pwa-eyebrow">YOUR MARKETPLACE, ONE TAP AWAY</p><h2 id="pwaInstallTitle">Market is Online</h2><p>Keep your marketplace and account close. Add MIO to your home screen.</p><div id="pwaInstallSteps"></div><p class="pwa-install-status" id="pwaInstallStatus" role="status"></p><button type="button" class="pwa-primary" id="pwaInstallNow">Install App</button><small>No APK download needed. An internet connection is required for shopping and account activity.</small>';
  document.body.append(dialog);
  const steps=dialog.querySelector('#pwaInstallSteps'),status=dialog.querySelector('#pwaInstallStatus'),install=dialog.querySelector('#pwaInstallNow');
  const notice=document.createElement('section');notice.id='pwaConnection';notice.className='pwa-notice';notice.hidden=true;notice.setAttribute('role','status');notice.innerHTML='<span></span><button type="button">Reload page</button>';notice.querySelector('button').onclick=()=>location.reload();document.body.append(notice);
  const update=document.createElement('section');update.id='pwaUpdate';update.className='pwa-notice';update.hidden=true;update.setAttribute('aria-label','App update');update.innerHTML='<div><strong>App update ready</strong><p>Save your work before reloading.</p></div><button type="button" data-pwa-update>Update & reload</button><button type="button" data-pwa-later aria-label="Dismiss update notice">×</button>';document.body.append(update);
  function installationSteps(){
    if(isIOS())return '<ol class="pwa-instructions"><li>Open this website in <b>Safari</b>.</li><li>Tap <b>Share → Add to Home Screen</b>.</li><li>Enable <b>Open as Web App</b> if shown, then tap <b>Add</b>.</li></ol>';
    if(/SamsungBrowser/i.test(navigator.userAgent))return '<ol class="pwa-instructions"><li>In <b>Samsung Internet</b>, tap the install / + icon near the address bar if shown.</li><li>Otherwise open the browser menu and choose <b>Add page to → Home screen</b> (or <b>Add to Home screen</b>).</li><li>Confirm <b>Add</b>. Check your phone’s home screens for the M icon. The menu option may create a website shortcut.</li></ol>';
    if(/Android/i.test(navigator.userAgent))return '<ol class="pwa-instructions"><li>Open <b>marketisonline.com</b> in <b>Chrome</b>.</li><li>Tap the browser’s <b>⋮ menu → Add to Home screen</b> or <b>Install app</b>.</li><li>Choose <b>Install</b> if offered and confirm. Allow your phone to finish adding the M icon.</li></ol>';
    return '<p class="pwa-instructions">Open your browser menu and choose <b>Install app</b> or <b>Install and create shortcut</b>. On a computer, look for the install icon in the address bar.</p>';
  }
  function renderInstall(){
    const inApp=standalone();
    install.hidden=false;
    install.textContent=installEvent&&!inApp?'Install App':'Show installation steps';
    let intro=inApp?'<p class="pwa-instructions">You are already using MIO in app mode. Installation help remains available here.</p>':installEvent?'<p class="pwa-instructions">Tap Install App below, then confirm in your browser.</p>':installReported?'<p class="pwa-instructions">Your browser reported an installation. Your phone may still be adding the icon; this does not confirm where it appears.</p>':'';
    steps.innerHTML=intro+installationSteps()+'<details class="pwa-install-help"><summary>Icon missing or opened inside another app?</summary><p>If you opened this link in WhatsApp or another app, use its menu to open the website in Chrome or Safari first.</p><p>On Samsung, check the home screens and search the apps list for <b>Market is Online</b> or <b>MIO</b>. If the icon is missing, use the browser steps above again. In Chrome, choose <b>Install</b> when available; a shortcut is a separate option.</p><p>This Download App button stays available. Installation options depend on your browser and phone.</p></details>';
    document.querySelectorAll('[data-pwa-install]').forEach(button=>{button.hidden=inApp});
  }
  function mount(){
    scheduled=false;
    for(const host of document.querySelectorAll('#memberSidebar,.shopping-account-nav,.vendor-portal-nav,.control-nav,#marketplaceFooter')){
      if(host.querySelector(':scope > [data-pwa-install]'))continue;
      const button=document.createElement('button');button.type='button';button.className='pwa-install-link';button.dataset.pwaInstall='';button.innerHTML=icon+'<span>Download App</span>';
      const signout=host.querySelector(':scope > .sidebar-signout, :scope > [data-account-signout], :scope > .shopping-nav-footer');if(signout)host.insertBefore(button,signout);else host.append(button);
    }
    renderInstall();
  }
  function schedule(){if(scheduled)return;scheduled=true;requestAnimationFrame(mount)}
  new MutationObserver(records=>{if(records.some(r=>[...r.addedNodes].some(n=>n.nodeType===1&&!n.closest?.('#pwaInstallDialog,#pwaUpdate,#pwaConnection')&&!n.matches?.('[data-pwa-install]'))))schedule()}).observe(document.body,{childList:true,subtree:true});
  document.addEventListener('click',event=>{const button=event.target.closest('[data-pwa-install]');if(!button)return;opener=button;status.textContent='';renderInstall();if(!dialog.open)dialog.showModal()});
  dialog.querySelector('.pwa-close').onclick=()=>dialog.close();dialog.addEventListener('click',event=>{if(event.target===dialog){const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)dialog.close()}});dialog.addEventListener('close',()=>{if(opener?.isConnected&&!opener.hidden)opener.focus()});
  window.addEventListener('beforeinstallprompt',event=>{event.preventDefault();installEvent=event;renderInstall()});
  window.addEventListener('appinstalled',()=>{installReported=true;installEvent=null;status.textContent='Your browser reported an installation. If the icon is missing, follow the steps below again.';renderInstall()});
  window.matchMedia('(display-mode: standalone)').addEventListener?.('change',renderInstall);
  install.onclick=async()=>{if(!installEvent||standalone()){status.textContent='Follow the browser steps above and confirm Add or Install on your phone.';steps.scrollIntoView?.({block:'nearest',behavior:'smooth'});return}const prompt=installEvent;installEvent=null;install.disabled=true;try{await prompt.prompt();const choice=await prompt.userChoice;status.textContent=choice.outcome==='accepted'?'Installation requested. Follow your browser’s instructions.':'Installation cancelled. You can try again using the browser steps above.'}catch{status.textContent='Use your browser menu to install the app.'}finally{install.disabled=false;renderInstall()}};
  function connection(){const offline=navigator.onLine===false;notice.hidden=!offline;notice.querySelector('span').textContent='You’re offline. Reconnect before submitting orders, payments or account changes.';document.body.classList.toggle('pwa-offline',offline)}
  window.addEventListener('offline',connection);window.addEventListener('online',connection);connection();
  function showUpdate(){if(registration?.waiting){update.hidden=false;update.querySelector('[data-pwa-update]').disabled=false}}
  update.querySelector('[data-pwa-later]').onclick=()=>{update.hidden=true};
  update.querySelector('[data-pwa-update]').onclick=()=>{if(navigator.onLine===false){notice.hidden=false;return}if(!registration?.waiting){location.reload();return}updateAccepted=true;update.querySelector('[data-pwa-update]').disabled=true;registration.waiting.postMessage({type:'ACTIVATE_UPDATE'});setTimeout(()=>{if(!reloading){updateAccepted=false;update.querySelector('[data-pwa-update]').disabled=false;update.querySelector('p').textContent='Update is taking longer than expected. Please try again.'}},15000)};
  if('serviceWorker' in navigator && window.isSecureContext){
    navigator.serviceWorker.addEventListener('controllerchange',()=>{if(updateAccepted&&!reloading){reloading=true;location.reload()}});
    navigator.serviceWorker.register('/sw.js',{scope:'/',updateViaCache:'none'}).then(reg=>{registration=reg;showUpdate();reg.addEventListener('updatefound',()=>{const worker=reg.installing;worker?.addEventListener('statechange',()=>{if(worker.state==='installed'&&navigator.serviceWorker.controller)showUpdate()})});let lastCheck=Date.now();document.addEventListener('visibilitychange',()=>{if(!document.hidden&&navigator.onLine!==false&&Date.now()-lastCheck>60000){lastCheck=Date.now();reg.update().catch(()=>{});showUpdate()}})}).catch(()=>{/* Installation remains optional; the live website keeps working. */});
  }
  mount();
})();
