import {JSDOM} from 'jsdom';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const dom=new JSDOM('<form><input data-whole-points type="text" inputmode="numeric"><input id="note"></form>',{runScripts:'outside-only'}),w=dom.window;
w.eval(await readFile('dist/whole-points.js','utf8'));
const input=w.document.querySelector('[data-whole-points]');
input.value='110';input.dispatchEvent(new w.FocusEvent('focusin',{bubbles:true}));
for(const key of ['a','Z','. ','.',',','-','+','e',' ','ArrowUp','ArrowDown'].filter(x=>x.length===1||x.startsWith('Arrow'))){const e=new w.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true});input.dispatchEvent(e);assert.equal(e.defaultPrevented,true,key);}
for(const key of ['0','9','Backspace','Delete','Tab','ArrowLeft','ArrowRight']){const e=new w.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true});input.dispatchEvent(e);assert.equal(e.defaultPrevented,false,key);}
for(const text of ['110.49','110,49','-110','1e3','ABC','12 34']){
 const paste=new w.Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(paste,'clipboardData',{value:{getData:()=>text}});input.dispatchEvent(paste);assert.ok(paste.defaultPrevented);assert.equal(input.value,'110');
 const before=new w.InputEvent('beforeinput',{data:text,inputType:'insertText',bubbles:true,cancelable:true});input.dispatchEvent(before);assert.ok(before.defaultPrevented);
 input.value=text;input.dispatchEvent(new w.Event('input',{bubbles:true}));assert.equal(input.value,'110');
}
const paste=new w.Event('paste',{bubbles:true,cancelable:true});Object.defineProperty(paste,'clipboardData',{value:{getData:()=> '112'}});input.dispatchEvent(paste);assert.equal(paste.defaultPrevented,false);
input.value='112';input.dispatchEvent(new w.Event('input',{bubbles:true}));input.value='112x';input.dispatchEvent(new w.Event('input',{bubbles:true}));assert.equal(input.value,'112');
const note=w.document.getElementById('note'),event=new w.KeyboardEvent('keydown',{key:'a',bubbles:true,cancelable:true});note.dispatchEvent(event);assert.equal(event.defaultPrevented,false);
dom.window.close();console.log('PASS digits-only typing/paste/mobile input fallback; decimal paste never changes the numeric amount; navigation and notes preserved');
