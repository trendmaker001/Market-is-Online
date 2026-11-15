/* Registration fields. Phone parsing: libphonenumber-js 1.13.16 (MIT), bundled locally. */
(function(){
'use strict';
const configs={
 signupForm:{name:'#fullName',phone:'#phone',password:'#signupPassword'},
 onboardingForm:{name:'#joinName',phone:'#joinPhone'},
 vendorSignupForm:{name:'[name="fullName"]',phone:'[name="phone"]',password:'[name="password"]'},
 shoppingAuthForm:{name:'[name="full_name"]',phone:'[name="phone"]',password:'[name="password"]'},
 checkoutForm:{name:'#shipName',phone:'#shipPhone',password:'[name="shoppingPassword"]'},
 sellerForm:{phone:'#sellerPhone'}
};
const bindings=new WeakMap();
function canonicalPhone(value,country){
 const raw=String(value||'').trim();if(!raw)return '';
 const lib=window.libphonenumber,code=lib?.isSupportedCountry(country)?lib.getCountryCallingCode(country):'';
 const clean=raw.replace(/[\s().-]/g,'').replace(/^00/,'+');
 if(!/^\+?\d+$/.test(clean))throw Error('Enter a phone number using digits only.');
 // Parsing removes a national trunk prefix, while preserving significant zeros (e.g. Italy).
 const parsed=lib?.parsePhoneNumberFromString(clean,country||undefined);
 if(parsed){if(code&&parsed.countryCallingCode!==code)throw Error('Phone country code must match your selected country.');return parsed.number}
 if(clean.startsWith('+')){if(code&&!clean.startsWith('+'+code))throw Error('Phone country code must match your selected country.');return clean}
 if(!code)throw Error('Enter your full phone number with its international country code.');
 return '+'+code+clean;
}
function enhanceCountry(select){
 const form=select.form,config=configs[form?.id];if(!config||bindings.has(form))return;
 const field=select.closest('.field')||select.closest('label');if(!field)return;
 field.classList.add('registration-country-first');
 if(form.id==='checkoutForm'){const name=form.querySelector(config.name);name?.closest('.field')?.before(field)}else form.prepend(field);
 const name=config.name?form.querySelector(config.name):null,phone=form.querySelector(config.phone),password=config.password?form.querySelector(config.password):null;
 const b={select,name,phone,password};bindings.set(form,b);
 if(name){name.autocapitalize='characters';name.classList.add('registration-uppercase');const upper=()=>{if(name.value===name.value.toUpperCase())return;const start=name.selectionStart,end=name.selectionEnd;name.value=name.value.toUpperCase();if(start!==null)name.setSelectionRange(start,end)};name.addEventListener('input',e=>{if(!e.isComposing)upper()});name.addEventListener('compositionend',upper);name.addEventListener('change',upper);upper()}
 if(phone){
  const national=phone.cloneNode();national.removeAttribute('name');national.id=(phone.id||form.id+'Phone')+'National';national.type='tel';national.autocomplete='tel-national';national.placeholder='Enter your mobile number';national.removeAttribute('minlength');national.removeAttribute('maxlength');national.removeAttribute('pattern');
  const group=document.createElement('div');group.className='registration-phone';const prefix=document.createElement('span');prefix.className='registration-dial-code';prefix.setAttribute('aria-label','Country calling code');group.append(prefix,national);phone.before(group);phone.type='hidden';
  const label=form.querySelector('label[for="'+phone.id+'"]');if(label)label.htmlFor=national.id;
  b.national=national;b.prefix=prefix;b.lastValue=phone.value;
  b.sync=()=>{const c=select.value,lib=window.libphonenumber;let code=lib?.isSupportedCountry(c)?lib.getCountryCallingCode(c):'';prefix.textContent=code?'+'+code:'+';national.disabled=phone.disabled;national.required=phone.required;const parsed=lib?.parsePhoneNumberFromString(phone.value,c||undefined);national.value=parsed&&(!code||parsed.countryCallingCode===code)?parsed.nationalNumber:phone.value;b.lastValue=phone.value;national.setCustomValidity('')};
  national.addEventListener('input',()=>{national.setCustomValidity('');try{phone.value=canonicalPhone(national.value,select.value);b.lastValue=phone.value}catch{phone.value=national.value;b.lastValue=phone.value}});
  phone.addEventListener('change',b.sync);select.addEventListener('change',()=>{if(phone.value!==b.lastValue)b.sync();try{phone.value=canonicalPhone(national.value,select.value);b.lastValue=phone.value}catch{}b.sync()});
  new MutationObserver(b.sync).observe(phone,{attributes:true,attributeFilter:['disabled','required']});b.sync();
 }
 if(password){
  const wrap=password.closest('.field')||password.closest('label');
  const confirmation=document.createElement(wrap?.classList.contains('field')?'div':'label');confirmation.className='field registration-confirm';
  const input=document.createElement('input');input.type='password';input.name=(password.name||password.id)+'Confirm';input.id=(password.id||form.id+'Password')+'Confirm';input.required=true;input.autocomplete='new-password';input.placeholder='Re-enter your password';
  if(confirmation.tagName==='LABEL')confirmation.append('Confirm password');else{const label=document.createElement('label');label.htmlFor=input.id;label.textContent='Confirm password';confirmation.append(label)}
  confirmation.append(input);wrap?.after(confirmation);b.confirm=input;
  password.placeholder='Enter your password';password.autocomplete='new-password';
  const check=()=>{input.setCustomValidity(!input.disabled&&input.value&&input.value!==password.value?'Passwords do not match.':'')};password.addEventListener('input',check);input.addEventListener('input',check);
 }
 if(['signupForm','vendorSignupForm'].includes(form.id)&&name&&phone&&password&&b.confirm){
  const container=input=>input.closest('.field')||input.closest('label');
  const nameField=container(name),phoneField=container(phone),emailField=container(form.querySelector('input[type="email"]')),passwordField=container(password),confirmField=container(b.confirm);
  field.after(nameField);const contact=document.createElement('div');contact.className='row';nameField.after(contact);contact.append(phoneField,emailField);
  const secrets=document.createElement('div');secrets.className='row';contact.after(secrets);secrets.append(passwordField,confirmField);
  form.querySelectorAll(':scope > .row').forEach(row=>{if(!row.children.length)row.remove()});
 }
 form.addEventListener('submit',event=>{try{prepare(form)}catch(error){event.preventDefault();event.stopImmediatePropagation();const target=b.confirm?.validationMessage?b.confirm:b.national;target?.setCustomValidity(error.message);target?.reportValidity();}} ,true);
 form.addEventListener('reset',()=>queueMicrotask(()=>{if(b.confirm){b.confirm.value='';b.confirm.setCustomValidity('')}b.sync?.()}));
}
function mode(form,signup){const b=bindings.get(form);if(!b)return;if(b.confirm){b.confirm.disabled=!signup;b.confirm.required=signup;b.confirm.closest('.registration-confirm').hidden=!signup;if(!signup){b.confirm.value='';b.confirm.setCustomValidity('')}}b.sync?.()}
function prepare(form){
 const b=bindings.get(form);if(!b)return;
 if(b.name)b.name.value=b.name.value.toUpperCase();
 if(b.phone&&!b.phone.disabled&&!b.select.disabled){const value=b.phone.value!==b.lastValue?b.phone.value:b.national.value;try{b.phone.value=canonicalPhone(value,b.select.value);b.lastValue=b.phone.value;b.national.setCustomValidity('')}catch(error){b.national.setCustomValidity(error.message);throw error}}
 if(b.confirm&&!b.confirm.disabled&&b.password.value!==b.confirm.value){b.confirm.setCustomValidity('Passwords do not match.');throw Error('Passwords do not match.')}if(b.confirm)b.confirm.setCustomValidity('');
}
function clear(form){const b=bindings.get(form);if(b?.confirm){b.confirm.value='';b.confirm.setCustomValidity('')}}
window.MioRegistration={enhanceCountry,prepare,mode,clear,canonicalPhone};
})();
