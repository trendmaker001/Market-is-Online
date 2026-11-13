// Read dimensions from image bytes, never from caller-provided metadata.
export const MAX_BYTES=5*1024*1024;
export function inspectImage(bytes,mime){
 if(!bytes.length)throw Error('No photo data received. Refresh the page and choose the photo again');
 if(bytes.length>MAX_BYTES)throw Error('Each photo must be no more than 5 MB');
 const v=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),text=(at,n)=>String.fromCharCode(...bytes.subarray(at,at+n));
 let width=0,height=0,type='';
 if(bytes.length>=33&&text(0,8)==='\x89PNG\r\n\x1a\n'&&text(12,4)==='IHDR'&&v.getUint32(8)===13){type='image/png';width=v.getUint32(16);height=v.getUint32(20)}
 else if(bytes.length>=12&&bytes[0]===255&&bytes[1]===216){
  type='image/jpeg';let at=2;
  while(at+4<=bytes.length){if(bytes[at++]!==255)break;while(bytes[at]===255)at++;const marker=bytes[at++];if(marker===217||marker===218)break;if(marker===1||(marker>=208&&marker<=215))continue;if(at+2>bytes.length)break;const len=v.getUint16(at);if(len<2||at+len>bytes.length)break;
   if([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)&&len>=8){height=v.getUint16(at+3);width=v.getUint16(at+5);break}at+=len;
  }
 }else if(bytes.length>=30&&text(0,4)==='RIFF'&&text(8,4)==='WEBP'&&v.getUint32(4,true)+8===bytes.length){
  type='image/webp';const tag=text(12,4),size=v.getUint32(16,true);if(size+20>bytes.length)throw Error('This photo is damaged. Upload a valid JPG, PNG or WebP image');
  if(tag==='VP8X'&&size>=10){if(bytes[20]&2)throw Error('Use a still product photo, not an animated image');width=1+bytes[24]+(bytes[25]<<8)+(bytes[26]<<16);height=1+bytes[27]+(bytes[28]<<8)+(bytes[29]<<16)}
  else if(tag==='VP8 '&&size>=10&&text(23,3)==='\x9d\x01\x2a'){width=v.getUint16(26,true)&16383;height=v.getUint16(28,true)&16383}
  else if(tag==='VP8L'&&size>=5&&bytes[20]===47){const bits=v.getUint32(21,true);width=1+(bits&16383);height=1+((bits>>>14)&16383)}
 }
 if(!width||!height||(type!==mime&&mime!=='application/octet-stream'))throw Error('Upload a valid JPG, PNG or WebP photo matching its file type');
 return {width,height,type,bytes:bytes.length,extension:{'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[type]};
}
export async function readLimitedBody(req){
 const length=Number(req.headers.get('content-length')||0);if(length>MAX_BYTES)throw Error('Each photo must be no more than 5 MB');
 const reader=req.body?.getReader();if(!reader)throw Error('Choose a product photo');const chunks=[];let size=0;
 try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>MAX_BYTES){await reader.cancel();throw Error('Each photo must be no more than 5 MB')}chunks.push(value)}}finally{reader.releaseLock()}
 const bytes=new Uint8Array(size);let at=0;for(const chunk of chunks){bytes.set(chunk,at);at+=chunk.length}return bytes;
}
