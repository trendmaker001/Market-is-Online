/* Neutral loading state: do not render another account's dashboard shell. */
window.MioRouteShell=(()=>{
 const host=document.getElementById('routeLoading');let failed=false;
 function render(){if(!host||!document.documentElement.classList.contains('route-restoring'))return;host.innerHTML=failed?'<section class="route-loading-state"><h1>Unable to load this page</h1><p>Check your connection and try again.</p><button class="btn primary" data-route-retry>Retry</button></section>':'<div class="route-loading-state" role="status"><span class="route-spinner" aria-hidden="true"></span><span>Loading…</span></div>';host.querySelector('[data-route-retry]')?.addEventListener('click',()=>location.reload())}
 function finish(){document.documentElement.classList.remove('route-restoring');host?.replaceChildren();clearTimeout(timer)}
 function fail(){failed=true;document.documentElement.classList.add('route-restoring');render()}
 const timer=setTimeout(()=>{if(document.documentElement.classList.contains('route-restoring'))fail()},30000);
 render();window.addEventListener('hashchange',render);return{finish,fail};
})();
