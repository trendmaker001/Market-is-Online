import {readFile,writeFile,mkdir} from 'node:fs/promises';
import sharp from 'sharp';
// Reuse the original brand artwork through an SVG viewport; no new/reinterpreted logo.
const header=await readFile('dist/market-is-online-logo-header.svg','utf8');
const inner=header.slice(header.indexOf('>')+1,header.lastIndexOf('</svg>'));
await mkdir('dist/icons',{recursive:true});
function mark(size,maskable=false){const width=size*(maskable?.64:.78),height=width*340/470;return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><rect width="${size}" height="${size}" fill="#000000"/><svg x="${(size-width)/2}" y="${(size-height)/2}" width="${width}" height="${height}" viewBox="0 175 470 340">${inner}</svg></svg>`}
for(const [name,size,maskable] of [['mio-black-192',192,false],['mio-black-512',512,false],['mio-black-maskable-512',512,true],['mio-black-apple-180',180,false]])await sharp(Buffer.from(mark(size,maskable))).png().toFile('dist/icons/'+name+'.png');
