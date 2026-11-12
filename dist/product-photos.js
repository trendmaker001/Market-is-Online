(function(){
'use strict';
const MAX_BYTES=5*1024*1024,TYPES=['image/jpeg','image/png','image/webp'];
async function validate(file){
 if(!TYPES.includes(file.type))throw Error('Use a JPG, PNG or WebP photo');
 if(!file.size||file.size>MAX_BYTES)throw Error('Each photo must be no more than 5 MB');
 const url=URL.createObjectURL(file);
 try{return await new Promise((resolve,reject)=>{const img=new Image(),timer=setTimeout(()=>reject(Error('Photo could not be read. Please choose it again')),15000);img.onload=()=>{clearTimeout(timer);if(img.naturalWidth!==1000||img.naturalHeight!==1000)return reject(Error(`This photo is ${img.naturalWidth} × ${img.naturalHeight} px. Required: exactly 1000 × 1000 px`));resolve({width:1000,height:1000,size:file.size})};img.onerror=()=>{clearTimeout(timer);reject(Error('This photo cannot be opened. Choose a valid JPG, PNG or WebP image'))};img.src=url})}finally{URL.revokeObjectURL(url)}
}
async function fromURL(url){
 if(!/^https:\/\//i.test(url))throw Error('Enter a valid HTTPS photo link');
 let response;try{response=await fetch(url,{signal:AbortSignal.timeout(15000),credentials:'omit',referrerPolicy:'no-referrer'})}catch{throw Error('This link cannot be read. Download the photo and choose it from your device')}
 if(!response.ok)throw Error('Photo link could not load. Choose the file from your device');
 if(Number(response.headers.get('content-length'))>MAX_BYTES)throw Error('Each photo must be no more than 5 MB');
 const reader=response.body.getReader(),chunks=[];let size=0;
 try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>MAX_BYTES){await reader.cancel();throw Error('Each photo must be no more than 5 MB')}chunks.push(value)}}finally{reader.releaseLock()}
 const blob=new Blob(chunks,{type:response.headers.get('content-type')?.split(';')[0]||''});await validate(blob);return blob;
}
async function upload(db,vendor,file){
 await validate(file);
 const {data,error}=await db.functions.invoke('product-photo-upload',{body:file,headers:{'Content-Type':file.type,'x-vendor-id':vendor}});
 if(error){let message='Photo upload failed. Please retry';try{const result=await error.context.json();if(result.error)message=result.error}catch{}throw Error(message)}
 if(data?.error||!data?.url)throw Error(data?.error||'Photo upload failed. Please retry');return data;
}
window.MioProductPhotos={validate,fromURL,upload,MAX_BYTES};
})();
