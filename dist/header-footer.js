/* Enhance the existing public footer without changing its destinations or auth visibility. */
(()=>{
 const footer=document.getElementById('marketplaceFooter');
 if(!footer||!window.matchMedia)return;
 const mobile=window.matchMedia('(max-width:620px)');
 const sections=[...footer.querySelectorAll('.footer-links')].map(source=>{
  const heading=source.querySelector('h3');if(!heading)return null;
  const details=document.createElement('details'),summary=document.createElement('summary'),body=document.createElement('div');
  details.className=source.className;summary.textContent=heading.textContent;body.className='footer-links-body';
  for(const child of [...source.children])if(child!==heading)body.append(child);
  details.append(summary,body);source.replaceWith(details);
  summary.addEventListener('click',event=>{if(!mobile.matches)event.preventDefault()});
  return details;
 }).filter(Boolean);
 const sync=()=>sections.forEach(section=>{section.open=!mobile.matches;section.querySelector('summary').tabIndex=mobile.matches?0:-1});
 sync();mobile.addEventListener('change',sync);
})();
