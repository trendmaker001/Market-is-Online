import {readFile,writeFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
// Any shipped frontend change produces a new worker, without caching private responses.
const names=(await readdir('dist')).filter(n=>/\.(js|css|html|webmanifest)$/.test(n)&&n!=='sw.js').sort();
names.push(...(await readdir('dist/icons')).filter(n=>n.endsWith('.png')).sort().map(n=>'icons/'+n));
const hash=createHash('sha256');for(const name of names){hash.update(name);hash.update(await readFile('dist/'+name));}
const version=hash.digest('hex').slice(0,16),path='dist/sw.js';
const source=await readFile(path,'utf8');await writeFile(path,source.replace(/const RELEASE = '[^']+';/,"const RELEASE = '"+version+"';"));
console.log('PWA release',version);
