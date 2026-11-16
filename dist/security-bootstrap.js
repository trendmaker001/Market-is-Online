/* Site-wide browser hardening helpers; scripts are external so CSP can reject inline handlers. */
document.documentElement.classList.add('route-restoring');
document.addEventListener('error',event=>{
 const image=event.target;if(!(image instanceof HTMLImageElement))return;
 if(image.hasAttribute('data-remove-on-error'))image.remove();
 if(image.hasAttribute('data-fallback-on-error')){image.hidden=true;if(image.nextElementSibling)image.nextElementSibling.hidden=false;}
},true);
