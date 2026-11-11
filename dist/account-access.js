(function(){
 'use strict';
 function destination(access,kind){
  if(kind==='vendor'){
   if(access.email_verified===false)return {error:'Verify your email before accessing your vendor account.'};
   if(access.has_store)return {route:'seller'};
   if(access.application_status==='pending')return {route:'seller',message:'Your vendor application is awaiting approval.'};
   if(access.store_status==='suspended')return {error:'Your vendor account is paused. Please contact support.'};
   if(access.application_status==='rejected')return {error:'Your vendor application was not approved. Please contact support.'};
   if(access.vendor_only)return {route:'vendor-register',message:'Complete your vendor registration to continue.'};
   return {error:'No vendor account is registered with this email. Use a member’s vendor registration link or contact support.'};
  }
  if(access.vendor_only||access.has_member===false)return {error:'No member account is registered with this email. Please choose Vendor Account.'};
  return {route:'dashboard'};
 }
 window.MioAccountAccess={destination};
})();
