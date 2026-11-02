import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {runInNewContext} from 'node:vm';
import {fileURLToPath} from 'node:url';
import {parseHTML} from 'linkedom';
import {filterLocalFiles,folderLibraryEntries} from '../src/library.ts';
import {defaultCleanup,upgradeDefaultCleanup,cleanupDue} from '../src/cleanup.ts';

const item=(id:string,name:string,entryKind:'file'|'directory'='file')=>({id,scope:'scope',key:id,name,mimeType:'',size:4,receivedAt:1,expiresAt:1,entryKind});
const entries=[item('image','PHOTO.JPG'),item('text','notes.txt'),item('video','clip.mp4'),item('folder','folder.jpg','directory'),item('other','paper.pdf')];
test('default age and strict image-size boundary; legacy preset only migration',()=>{
  const rules=defaultCleanup();assert.equal(rules.retentionHours,48);assert.deepEqual(rules.categories,['image']);assert.equal(rules.sizeRule,'smaller');
  assert.equal(cleanupDue({name:'photo.png',size:199999,receivedAt:100},rules,100+48*3600000-1),false);
  assert.equal(cleanupDue({name:'photo.png',size:199999,receivedAt:100},rules,100+48*3600000),true);
  assert.equal(cleanupDue({name:'photo.png',size:200000,receivedAt:100},rules,100+48*3600000),false);
  const legacy={retentionHours:24,categories:['text','image'] as ('text'|'image')[],sizeRule:'atMost' as const,sizeMiB:500000/1048576};
  assert.deepEqual(upgradeDefaultCleanup(legacy),rules);
  const custom={...legacy,retentionHours:72};assert.equal(upgradeDefaultCleanup(custom),custom);
});
test('category filter keeps folders out of image and other, without mutating inventory',()=>{
  assert.deepEqual(filterLocalFiles(folderLibraryEntries(entries),'image').map(entry=>entry.id),['image']);
  assert.deepEqual(filterLocalFiles(entries,'folder').map(entry=>entry.id),['folder']);
  assert.deepEqual(filterLocalFiles(entries,'other').map(entry=>entry.id),['other']);
  assert.equal(filterLocalFiles(entries,'all').length,5);assert.equal(entries.length,5);
});
const require=createRequire(import.meta.url),{build}=require('esbuild');
const code=(await build({entryPoints:[fileURLToPath(new URL('../src/library_view.ts',import.meta.url))],bundle:true,format:'cjs',write:false,platform:'browser',logLevel:'silent'})).outputFiles[0].text;
test('real view filter binding, visible-only select-all and bulk drag, empty category recovery',()=>{
  const {document,window}=parseHTML('<html><body><main id="app"></main></body></html>');
  const module={exports:{}} as {exports:any};
  const context={module,exports:module.exports,document,window,console,URL,Blob,File,TextEncoder,TextDecoder,clearTimeout,setTimeout};
  runInNewContext(code,context);let view:any;
  const render=()=>{document.querySelector('#app')!.innerHTML=view.html(true);view.bind();};
  view=new module.exports.LocalLibraryView({changed:render,inventory:()=>{},close:()=>{},peers:()=>[],signedIn:()=>false,copy:()=>{},stage:()=>{},forward:async()=>{},pendingForward:()=>false,discardForward:async()=>{}});
  view.opened=true;view.entries=entries;for(const entry of entries)view.files.set(entry.id,new File(['data'],entry.name));render();
  assert.ok(document.querySelector('.library-toolbar')!.firstElementChild!.classList.contains('count'));
  assert.ok(document.querySelector('.library-toolbar-scroll [data-library-filter]'));
  const filter=document.querySelector('[data-library-filter]') as any;
  Object.defineProperty(filter,'value',{value:'image'});filter.dispatchEvent(new window.Event('change'));
  assert.equal(view.category,'image');assert.equal(document.querySelectorAll('[data-library-id]').length,1);
  assert.equal(document.querySelector('[data-library-id]')!.getAttribute('data-library-id'),'image');
  assert.deepEqual(Array.from(view.filesForBulkDrag(),(file:any)=>file.name),['PHOTO.JPG']);
  (document.querySelector('[data-library-action="edit"]') as any).click();
  (document.querySelector('[data-library-action="select-all"]') as any).click();assert.deepEqual([...view.selected],['image']);
  view.editing=false;view.setCategory('audio');assert.equal(view.selected.size,0);assert.match(document.querySelector('.library-empty')!.textContent!,/此分类暂无文件/);
  view.setCategory('all');assert.equal(document.querySelectorAll('[data-library-id]').length,5);assert.equal(view.entries.length,5);
});
