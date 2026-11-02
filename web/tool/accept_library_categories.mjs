import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import {build} from 'esbuild';
import {createServer} from 'node:http';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import assert from 'node:assert/strict';

const root=fileURLToPath(new URL('../../',import.meta.url));
const run=process.env.GS_LIBRARY_ACCEPTANCE_DIR || join(root,'artifacts/tmp/cleanup-library112');await mkdir(run,{recursive:true});
await build({entryPoints:[join(root,'web/src/style.css')],bundle:true,outfile:join(run,'style.css'),logLevel:'silent'});
await build({stdin:{resolveDir:join(root,'web/src'),contents:`
import {LocalLibraryView} from './library_view';
import {AppearancePreferences} from './appearance';
const appearance=new AppearancePreferences(document,()=>null,()=>{});appearance.set({mode:'dark',accent:'purple'});
window.__errors=[];addEventListener('error',event=>window.__errors.push(event.message));
const image=await (await fetch('./test-image.png')).blob();
const entries=[['photo','photo.jpg','image/jpeg'],['notes','notes.txt','text/plain'],['video','clip.mp4','video/mp4'],['folder','Course files','inode/directory'],['other','paper.pdf','application/pdf']].map(([id,name,mimeType],index)=>({id,scope:'fixture',key:id,name,mimeType,size:1024+index,receivedAt:Date.now()-index*1000,expiresAt:Infinity,entryKind:id==='folder'?'directory':'file'}));
const files=new Map(entries.map(entry=>[entry.id,new File([entry.id==='photo'?image:'fixture'],entry.name,{type:entry.mimeType})]));
const removed=[];const render=()=>{document.querySelector('#app').innerHTML=view.html(true);view.bind();};
const view=new LocalLibraryView({changed:render,inventory:()=>{},close:()=>{},peers:()=>[],signedIn:()=>false,copy:()=>{},stage:()=>{},forward:async()=>{},pendingForward:()=>false,discardForward:async()=>{}});
view.service={get:async id=>files.get(id),remove:async id=>removed.push(id)};view.entries=entries;view.opened=true;window.__view=view;window.__removed=removed;render();
`},bundle:true,format:'esm',outfile:join(run,'fixture.js'),logLevel:'silent'});
await writeFile(join(run,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="./style.css"><main id="app" style="max-width:880px;margin:auto"></main><script type="module" src="./fixture.js"></script></html>');
const allowed=new Map([['/','index.html'],['/index.html','index.html'],['/fixture.js','fixture.js'],['/style.css','style.css'],['/test-image.png','test-image.png']]);
const server=createServer(async(req,res)=>{const file=allowed.get(new URL(req.url,'http://localhost').pathname);if(!file){res.writeHead(404).end();return;}res.setHeader('content-type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.png')?'image/png':'text/html');res.end(await readFile(join(run,file)));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const base=`http://127.0.0.1:${server.address().port}`;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(action,accept){const end=Date.now()+15000;let value;while(Date.now()<end){value=await action();if(accept(value))return value;await wait(40);}throw new Error('Timeout: '+JSON.stringify(value));}
let browser,socket,closePage;
try {
  browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
  const address=await until(async()=>{try{return(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let id=0;const pending=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=pending.get(value.id);if(call){pending.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});socket.send(JSON.stringify({id:n,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});const page=(method,params={})=>send(method,params,sessionId);closePage=()=>send('Target.closeTarget',{targetId});
  const evaluate=async expression=>{const value=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
  await page('Page.navigate',{url:base});await until(()=>evaluate('!!window.__view && !!document.querySelector(".library-grid img")?.complete'),Boolean);
  const states=[];
  for(const width of [950,390,280]) {
    await page('Emulation.setDeviceMetricsOverride',{width,height:width===950?650:844,deviceScaleFactor:1,mobile:width<500});
    await evaluate(`(()=>{const select=document.querySelector('[data-library-filter]');select.value='image';select.dispatchEvent(new Event('change'));})()`);await wait(80);
    const state=await evaluate(`(()=>{const toolbar=document.querySelector('.library-toolbar').getBoundingClientRect(),filter=document.querySelector('[data-library-filter]').getBoundingClientRect(),count=document.querySelector('.library-toolbar>.count').getBoundingClientRect(),scroll=document.querySelector('.library-toolbar-scroll');return {countLeft:count.left-toolbar.left,actionsWidth:scroll.clientWidth,actionsContentWidth:scroll.scrollWidth,category:window.__view.category,count:document.querySelectorAll('[data-library-id]').length,height:toolbar.height,filterWidth:filter.width,pageOverflow:document.documentElement.scrollWidth>innerWidth,retention:document.querySelector('#library-retention').value,size:document.querySelector('#library-size-mib').value,checked:[...document.querySelectorAll('[data-library-category]:checked')].map(node=>node.dataset.libraryCategory)};})()`);
    assert.ok(state.countLeft>=8 && state.countLeft<=12);assert.equal(state.category,'image');assert.equal(state.count,1);assert.equal(state.pageOverflow,false);assert.ok(state.height<=56);assert.ok(state.filterWidth>=64);assert.equal(state.retention,'2');assert.equal(state.size,'200');assert.deepEqual(state.checked,['image']);states.push({width,...state});
    const fixedLeft=await evaluate(`document.querySelector('.library-toolbar>.count').getBoundingClientRect().left`);
    await evaluate(`document.querySelector('.library-toolbar-scroll').scrollLeft=10000`);
    assert.equal(await evaluate(`document.querySelector('.library-toolbar>.count').getBoundingClientRect().left`),fixedLeft);
    if(width===280)assert.ok(state.actionsContentWidth>state.actionsWidth);
    const image=await page('Page.captureScreenshot',{format:'jpeg',quality:85});await writeFile(join(run,`web-category-${width}.jpg`),Buffer.from(image.data,'base64'));
  }
  await evaluate(`(()=>{document.querySelector('[data-library-action="edit"]').click();document.querySelector('[data-library-action="select-all"]').click();})()`);
  assert.deepEqual(await evaluate('[...window.__view.selected]'),['photo']);
  await evaluate('window.__view.deleteSelected()');assert.deepEqual(await evaluate('window.__removed'),['photo']);
  await evaluate("window.__view.setCategory('all')");assert.equal(await evaluate('document.querySelectorAll("[data-library-id]").length'),4);
  assert.deepEqual(await evaluate('window.__errors'),[]);
  await writeFile(join(run,'browser-result.json'),JSON.stringify({passed:true,browserProfile,states,visibleOnlySelectionAndDeletion:true},null,2));console.log('PASS category selection, compact toolbar, default form, visible-only deletion, 950/390/280 render and fixed left count');
} finally {await closePage?.().catch(()=>{});socket?.close();await closeSharedBrowser(browser);await new Promise(resolve=>server.close(resolve));}
