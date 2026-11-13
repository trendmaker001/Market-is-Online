import {JSDOM} from 'jsdom';import {readFile,access} from 'node:fs/promises';import assert from 'node:assert/strict';
const html=await readFile('dist/index.html','utf8'),doc=new JSDOM(html).window.document,ids=[...doc.querySelectorAll('[id]')].map(x=>x.id);
assert.equal(ids.length,new Set(ids).size,'Duplicate HTML IDs');
const files=[...doc.querySelectorAll('script[src],link[rel=stylesheet],link[rel=icon],link[rel=manifest],link[rel=preload],img[src]')].map(x=>x.getAttribute('src')||x.getAttribute('href')).filter(x=>x.startsWith('/')&&!x.startsWith('//'));
for(const path of files)await access('dist/'+path.slice(1).split('?')[0]);
const pages=new Set([...doc.querySelectorAll('.page')].map(x=>x.id.replace(/^page-/,''))),aliases=new Set(['workspace','transfer','network-graphical','bundles','vendors','categories','my-vendors','vendor-register','dashboard','profile','exchange','deposit','withdraw','top-up','transactions']);
const routes=[...new Set([...doc.querySelectorAll('[data-page],a[href^="#"]')].map(x=>x.dataset.page||x.getAttribute('href').slice(1)))];
for(const route of routes){assert.ok(pages.has(route)||aliases.has(route)||doc.getElementById(route)||/^(account|workspace|admin|product|order|vendor|category)\//.test(route),'Unknown route '+route);}
assert.equal(doc.getElementById('main-content').getAttribute('tabindex'),'-1');
console.log('PASS '+pages.size+' base pages, '+routes.length+' static destinations, '+files.length+' local assets, unique IDs and keyboard skip target');
