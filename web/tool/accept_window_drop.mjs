import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {createServer} from 'node:net';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../../server/src/server.ts';

const root=fileURLToPath(new URL('../../',import.meta.url));
const run=join(root,'artifacts/tmp/web-drop-'+Date.now()),site=join(run,'site');await mkdir(site,{recursive:true});
const {build}=createRequire(import.meta.url)('esbuild');
const source=await readFile(join(root,'web/src/main.ts'),'utf8');
const output=await build({stdin:{contents:source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();'),resolveDir:join(root,'web/src'),sourcefile:'drop-acceptance.ts',loader:'ts'},bundle:true,platform:'browser',format:'esm',write:false,loader:{'.css':'empty'}});
await writeFile(join(site,'fixture.js'),output.outputFiles[0].text);
await writeFile(join(site,'style.css'),await readFile(join(root,'web/src/style.css')));
await writeFile(join(site,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" multiple hidden><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script></html>');
const original=join(run,'桌面原件.txt');await writeFile(original,'来自桌面 GlobalSend 的原始文件\n不复制路径文字。');
const reservation=createServer();await new Promise(resolve=>reservation.listen(0,'127.0.0.1',resolve));const port=reservation.address().port;await new Promise(resolve=>reservation.close(resolve));
const base=`http://127.0.0.1:${port}/globalsend`;
const center=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,publicBaseUrl:base,diskReserve:0,production:false,log:false});await center.listen({host:'127.0.0.1',port});
const browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,accept,timeout=15000){let value;const end=Date.now()+timeout;while(Date.now()<end){value=await action();if(accept(value))return value;await delay(30);}throw new Error('Deadline: '+JSON.stringify(value));}
let socket,closePage;const evidence=[];
try{
 const address=await poll(async()=>{try{return (await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
 socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
 let sequence=0;const pending=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=pending.get(value.id);if(call){pending.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}});
 const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
 const {targetId}=await send('Target.createTarget',{url:'about:blank'});const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});const page=(method,params={})=>send(method,params,sessionId);
 const evaluate=async expression=>{const value=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
 closePage=async()=>{await evaluate('(()=>{const c=window.__client;if(c){c.stagedTexts=[];c.picked=[];c.shared.dirty=false;c.busy=false;}})()').catch(()=>{});await send('Target.closeTarget',{targetId});};
 await page('Page.enable');await page('Runtime.enable');await page('Emulation.setDeviceMetricsOverride',{width:950,height:650,deviceScaleFactor:1,mobile:false});
 await page('Page.navigate',{url:base+'/app/'});await poll(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
 await evaluate("(async()=>{const c=window.__client;c.groupKey='web-drop-acceptance';await c.enroll();})()");await poll(()=>evaluate('window.__client.connected && window.__client.shared.loaded'),Boolean);
 await evaluate(`(()=>{window.__trace=[];window.__overlay=[];window.__errors=[];addEventListener('error',event=>window.__errors.push(event.message));for(const type of ['dragenter','dragover','dragleave','drop'])document.addEventListener(type,event=>window.__trace.push({type,trusted:event.isTrusted,types:[...event.dataTransfer.types],files:event.dataTransfer.files.length,prevented:event.defaultPrevented}),true);new MutationObserver(()=>{window.__overlay.push(!!document.querySelector('#window-drop.visible'))}).observe(document.querySelector('#app'),{subtree:true,attributes:true,attributeFilter:['class']});})()`);
 const coords=async selector=>evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);
 const drag=async(data,target,options={})=>{const point=await coords(target);await evaluate('window.__overlay=[];window.__trace=[]');await page('Input.dispatchDragEvent',{type:'dragEnter',...point,data});
  for(const selector of ['.brand','[data-queue-drop]','.target-devices','[data-queue-drop]']){const p=await coords(selector);await page('Input.dispatchDragEvent',{type:'dragOver',...p,data});await delay(20);assert.equal(await evaluate("!!document.querySelector('#window-drop.visible')"),true);}
  if(options.rerender){await evaluate('window.__client.render()');assert.equal(await evaluate("!!document.querySelector('#window-drop.visible')"),true);}
  const flashes=await evaluate('window.__overlay.filter(value=>!value).length');assert.equal(flashes,0,'overlay stays visible while crossing controls');
  await page('Input.dispatchDragEvent',{type:'drop',...point,data});await poll(()=>evaluate("!document.querySelector('#window-drop.visible')"),Boolean);await delay(30);return evaluate('window.__trace');};
 // Chrome's actual OS-facing drop pipeline, with a real disk File (not setInputFiles or a JS File mock).
 for(let i=0;i<3;i++){
  if(i===1)await evaluate("(()=>{const c=window.__client;c.internalPayload={text:'stale previous gesture'};document.querySelector('[data-queue-drop]').dataset.internalDrag='true'})()");
  const trace=await drag({items:[],files:[original],dragOperationsMask:1},i===2?'[data-queue-drop]':'.brand',{rerender:i===0});
  await poll(()=>evaluate('window.__client.picked.length'),count=>count===i+1);
  assert.equal(await evaluate('window.__client.picked.at(-1).text()'),'来自桌面 GlobalSend 的原始文件\n不复制路径文字。');
  assert.ok(trace.some(event=>event.type==='drop'&&event.trusted&&event.files===1));evidence.push({case:'disk-file-'+i,trace});
 }
 for(const [type,text,expected,target] of [
  ['text/plain','  文字拖入\n保留空白  ','  文字拖入\n保留空白  ','.brand'],
  ['text/uri-list','# hyperlink\r\nhttps://example.com/drop\r\n','https://example.com/drop','[data-queue-drop]'],
  ['text/html','<p>网页文字</p><p>第二行<br>第三行</p>','网页文字\n第二行\n第三行','.brand'],
 ]){
  const trace=await drag({items:[{mimeType:type,data:text}],dragOperationsMask:1},target);await poll(()=>evaluate('window.__client.stagedTexts.at(-1)?.text'),value=>value===expected);evidence.push({case:type,trace});
 }
 const mixed=await drag({items:[{mimeType:'application/x-globalsend-card',data:'1'},{mimeType:'text/plain',data:'另一个 GlobalSend 网页窗口'}],dragOperationsMask:1},'.brand');
 await poll(()=>evaluate('window.__client.stagedTexts.at(-1)?.text'),value=>value==='另一个 GlobalSend 网页窗口');evidence.push({case:'cross-window-marker',trace:mixed});
 // A child trying to consume drop cannot bypass window-level acceptance.
 await evaluate("document.querySelector('.brand').addEventListener('drop',event=>event.stopPropagation(),{once:true})");
 await drag({items:[{mimeType:'text/plain',data:'子元素也可接收'}],dragOperationsMask:1},'.brand');await poll(()=>evaluate('window.__client.stagedTexts.at(-1)?.text'),value=>value==='子元素也可接收');
 const screenshot=await page('Page.captureScreenshot',{format:'jpeg',quality:72,captureBeyondViewport:false});await mkdir(join(root,'artifacts/screenshots'),{recursive:true});const shot=join(root,'artifacts/screenshots/web-drop-fixed.preview.jpg');await writeFile(shot,Buffer.from(screenshot.data,'base64'));
 assert.deepEqual(await evaluate('window.__errors'),[]);
 const report={run,profile:browserProfile,passed:true,diskFiles:3,stagedTexts:await evaluate('window.__client.stagedTexts.map(item=>item.text)'),evidence,screenshot:shot,scope:'Trusted Chromium drag/drop with actual disk files and native-format text, plus nested-element and rerender feedback. Physical Windows OLE gesture not exercised.'};
 await writeFile(join(run,'result.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({run,passed:true,diskFiles:report.diskFiles,texts:report.stagedTexts.length,screenshot:shot}));
}finally{await closePage?.().catch(()=>{});socket?.close();await closeSharedBrowser(browser);await center.close();}
