import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,mkdtemp} from 'node:fs/promises';
import {createServer} from 'node:net';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {buildApp} from '../../server/src/server.ts';

// The real UI, local center and the persistent shared Edge profile.
// Clipboard writes stay in a page-only mock. No user browser or device is used.
const root=fileURLToPath(new URL('../../',import.meta.url));
const acceptVersion=process.env.GLOBALSEND_ACCEPT_VERSION || 'receive-selection-clean-ui';
const work=join(root,`artifacts/tmp/web-ui-${acceptVersion}`),shots=join(root,'artifacts/screenshots');
await mkdir(work,{recursive:true});await mkdir(shots,{recursive:true});
const run=await mkdtemp(join(work,'run-')),site=join(run,'site'),profile=sharedBrowserProfile;await mkdir(site,{recursive:true});
const {build}=createRequire(import.meta.url)('esbuild'),source=await readFile(join(root,'web/src/main.ts'),'utf8');
const compiled=await build({stdin:{contents:source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();'),resolveDir:join(root,'web/src'),sourcefile:'ui-acceptance.ts',loader:'ts'},bundle:true,platform:'browser',format:'esm',write:false,loader:{'.css':'empty'}});
await writeFile(join(site,'fixture.js'),compiled.outputFiles[0].text);await writeFile(join(site,'style.css'),await readFile(join(root,'web/src/style.css')));
await writeFile(join(site,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" hidden multiple><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script></html>');
const portServer=createServer();await new Promise(resolve=>portServer.listen(0,'127.0.0.1',resolve));const port=portServer.address().port;await new Promise(resolve=>portServer.close(resolve));
const base=`http://127.0.0.1:${port}/globalsend`,center=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,publicBaseUrl:base,diskReserve:0,production:false,log:false});
const requests=[];center.addHook('onRequest',async req=>{requests.push({method:req.method,path:new URL(req.url,base).pathname});});await center.listen({host:'127.0.0.1',port});
const browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:work,TMP:work}});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,predicate,timeout=15000){let last;const end=Date.now()+timeout;while(Date.now()<end){last=await action();if(predicate(last))return last;await delay(30);}throw new Error('Deadline: '+JSON.stringify(last));}
async function call(path,body,token,method=body===undefined?'GET':'POST'){
  const response=await fetch(base+'/api/v1'+path,{method,headers:{...(body===undefined?{}:{'content-type':Buffer.isBuffer(body)?'application/octet-stream':'application/json'}),...(token?{authorization:'Bearer '+token}:{})},body:body===undefined?undefined:Buffer.isBuffer(body)?body:JSON.stringify(body)});
  const value=await response.json();assert.ok(response.ok,JSON.stringify({path,status:response.status,value}));return value;
}
const peerSockets=[];let socket;
try {
  const address=await poll(async()=>{try{return (await readFile(join(profile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0;const calls=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),pending=calls.get(value.id);if(pending){calls.delete(value.id);value.error?pending.reject(new Error(value.error.message)):pending.resolve(value.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++next;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const page=(method,params)=>send(method,params,sessionId);
  const evaluate=async expression=>{const value=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
  await page('Page.enable');await page('Runtime.enable');
  const systemReducedMotion=await evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches");
  await page('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
  await page('Emulation.setDeviceMetricsOverride',{width:950,height:619,deviceScaleFactor:1,mobile:false});await page('Page.navigate',{url:base+'/app/'});
  await poll(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
  await evaluate("(()=>{const input=document.querySelector('#group-key');input.value='ui-shared-password';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#enroll-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>{window.__copied=value;}}});})()");
  await poll(()=>evaluate('window.__client.connected && window.__client.shared.loaded'),Boolean);

  // Targeted render/interaction check only: no transfer or receipt matrix rerun.
  await delay(100);
  await evaluate(`(()=>{const c=window.__client,now=new Date().toISOString(),expiresAt=new Date(Date.now()+3600000).toISOString(),me=c.session.device.deviceId;c.refresh=async()=>{};c.events=['text-one','text-two'].map((eventId,index)=>({eventId,type:'text.created',cursor:index+1,sourceDeviceId:'ui-peer',targetDeviceId:me,createdAt:now,expiresAt,payload:{text:index?'第二段测试文字':'可选择的正文 https://example.com'}}));c.devices.push({deviceId:'ui-peer',name:'我的手机',platform:'android',online:true});const canvas=document.createElement('canvas');canvas.width=300;canvas.height=180;const ctx=canvas.getContext('2d');ctx.fillStyle='#c4dcd0';ctx.fillRect(0,0,300,180);ctx.fillStyle='#527d65';ctx.fillRect(0,110,300,70);c.transfers=['photo','active'].map((transferId,index)=>({transferId,sourceDeviceId:'ui-peer',targetDeviceId:me,routePreference:'direct',createdAt:now,expiresAt,files:[{fileId:'file',name:index?'传输中的文件.txt':'山间照片.png',mimeType:index?'text/plain':'image/png',size:100,offset:index?30:100,status:index?'uploading':'received',transport:'direct',sha256:'0'.repeat(64)}]}));c.previews.set('photo:file',{kind:'image',url:canvas.toDataURL()});c.rtcLocalFiles.set('photo:file',new File(['local picture'],'山间照片.png',{type:'image/png'}));c.modal=null;c.receiptBatch.clear();c.pendingReceipt=null;c.mobileView='receive';c.filter='all';c.render();})()`);
  const evidence=[];
  async function snapshot(name){await evaluate('document.fonts.ready.then(()=>true)');const shot=await page('Page.captureScreenshot',{format:'jpeg',quality:80,captureBeyondViewport:false});const path=join(shots,`receive-selection-clean-ui-${name}.preview.jpg`);await writeFile(path,Buffer.from(shot.data,'base64'));evidence.push(path);}
  const click=async selector=>{await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'center'})`);const point=await evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);await page('Input.dispatchMouseEvent',{type:'mousePressed',...point,button:'left',clickCount:1});await page('Input.dispatchMouseEvent',{type:'mouseReleased',...point,button:'left',clickCount:1});};
  await evaluate("document.querySelector('[data-action=receive-multi-select]').click()");
  assert.equal(await evaluate("document.querySelectorAll('.dock-items button,.dock-items a[href],.dock-items .card-actions,.dock-items [data-card-menu],.dock-items [data-preview-file],.dock-items [data-read]').length"),0);
  assert.equal(await evaluate("document.querySelectorAll('.dock-items [role=checkbox]').length"),4);
  assert.match(await evaluate("document.querySelector('[data-receive-key=\"file:photo:file\"]').getAttribute('aria-label')"),/选择文件：山间照片/);
  await click('[data-receive-key="text-one"] .card-text');assert.equal(await evaluate("window.__client.selected.has('text-one')"),true);
  await click('[data-receive-key="text-one"] .card-info');assert.equal(await evaluate("window.__client.selected.has('text-one')"),false);
  await click('[data-receive-key="file:photo:file"] img');assert.equal(await evaluate("window.__client.selected.has('file:photo:file')"),true);
  await click('[data-receive-key="file:photo:file"] .card-name');assert.equal(await evaluate("window.__client.selected.has('file:photo:file')"),false);assert.equal(await evaluate('window.__client.modal'),null);
  await evaluate("document.querySelector('[data-action=receive-select-all]').click()");assert.equal(await evaluate('window.__client.selected.size'),4);assert.equal(await evaluate("document.querySelector('[data-action=copy-selected]').textContent"),'复制 2 项');
  await snapshot('desktop');
  await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});await snapshot('phone');
  assert.equal(await evaluate('document.documentElement.scrollWidth>innerWidth'),false);
  await evaluate("document.querySelector('[data-action=receive-multi-select]').click()");
  assert.equal(await evaluate("document.querySelectorAll('.dock-items [data-card-menu]').length"),4);assert.ok(await evaluate("document.querySelector('.dock-items [data-copy]')!==null && document.querySelector('.dock-items [data-hide-text]')!==null && document.querySelector('.dock-items [data-download]')!==null && document.querySelector('.dock-items a[href]')!==null"));
  await click('[data-receive-key="text-one"] .card-text');assert.equal(await evaluate('window.__client.modal'),'reader');await evaluate("document.querySelector('[data-action=close-modal]').click()");
  await click('[data-receive-key="file:photo:file"] .card-preview-button');assert.equal(await evaluate('window.__client.modal'),'file-preview');await evaluate("document.querySelector('[data-action=close-modal]').click()");
  const result={run,profile,checks:{selectionHasNoOrdinaryActionsOrNestedInteractiveSemantics:true,fourCardsExposeCheckboxOnly:true,textContentAndInfoToggle:true,imageAndFilenameToggle:true,allSelectionAndTextCountPreserved:true,phoneNoHorizontalOverflow:true,normalControlsRestored:true,normalTextAndImagePreviewRestored:true},evidence};await send('Target.closeTarget',{targetId});await writeFile(join(run,'result.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
}finally{for(const peer of peerSockets)peer.close();socket?.close();await closeSharedBrowser(browser);await center.close();}
