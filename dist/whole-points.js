/* Transfer entry accepts digits only; never strip punctuation from a pasted amount. */
(()=>{
 const previous=new WeakMap(),isField=e=>e.target?.matches?.('input[data-whole-points]');
 const remember=field=>{if(/^[0-9]*$/.test(field.value))previous.set(field,field.value)};
 document.addEventListener('focusin',e=>{if(isField(e))remember(e.target)});
 document.addEventListener('keydown',e=>{if(!isField(e)||e.ctrlKey||e.metaKey||e.altKey)return;if(['ArrowUp','ArrowDown'].includes(e.key)||(e.key.length===1&&!/^[0-9]$/.test(e.key)))e.preventDefault()});
 document.addEventListener('beforeinput',e=>{if(!isField(e))return;remember(e.target);if(e.data!=null&&!/^[0-9]*$/.test(e.data))e.preventDefault()});
 document.addEventListener('paste',e=>{if(isField(e)&&!/^[0-9]+$/.test(e.clipboardData?.getData('text')||''))e.preventDefault()});
 document.addEventListener('drop',e=>{if(isField(e))e.preventDefault()});
 document.addEventListener('input',e=>{if(!isField(e))return;const field=e.target;if(!/^[0-9]*$/.test(field.value))field.value=previous.get(field)||'';remember(field)});
 document.addEventListener('reset',e=>{for(const field of e.target.querySelectorAll?.('input[data-whole-points]')||[])previous.delete(field)});
})();
