import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {createServer} from 'node:net';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../../server/src/server.ts';

const root=fileURLToPath(new URL('../../',import.meta.url));
const run=join(root,'artifacts/tmp/web-ui-'+Date.now()),site=join(run,'site');await mkdir(site,{recursive:true});
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
 await evaluate("(async()=>{const c=window.__client;c.groupKey='web-ui-acceptance';await c.enroll();})()");await poll(()=>evaluate('window.__client.connected && window.__client.shared.loaded'),Boolean);
 const shots=join(root,'artifacts/screenshots/themes/web');await mkdir(shots,{recursive:true});
 const capture=async name=>{const shot=await page('Page.captureScreenshot',{format:'jpeg',quality:75,captureBeyondViewport:false});const path=join(shots,name+'.preview.jpg');await writeFile(path,Buffer.from(shot.data,'base64'));return path;};
 await evaluate(`(()=>{const c=window.__client;c.stagedTexts=[{id:'ui-draft',text:'文件和文字，点击设备即可发送。'}];c.events=['整理好的课程笔记，拖到待发送即可转发。','https://example.com/'].map((text,index)=>({eventId:'ui-text-'+index,type:'text.created',cursor:index+1,sourceDeviceId:'ui-peer',targetDeviceId:c.session.device.deviceId,createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString(),payload:{text}}));c.render();})()`);
  for(const width of [950,430]){
  await page('Emulation.setDeviceMetricsOverride',{width,height:800,deviceScaleFactor:1,mobile:width<761});
  for(const [mode,accent] of [['light','green'],['dark','blue'],['neutral','purple']]){
   await evaluate(`(()=>{const c=window.__client;c.appearance.set({mode:${JSON.stringify(mode)},accent:${JSON.stringify(accent)}});c.mobileView='receive';c.render();})()`);await delay(240);
   const result=await evaluate(`(()=>{const q=s=>document.querySelector(s),style=s=>getComputedStyle(q(s));return{mode:document.documentElement.dataset.theme,accent:document.documentElement.dataset.accent,canvas:getComputedStyle(document.documentElement).backgroundColor,panel:style('.dock-panel').backgroundColor,text:style('.card-text').color,card:style('.card-text').backgroundColor,filter:style('.content-card').filter,overflow:document.documentElement.scrollWidth>innerWidth}})()`);
   assert.equal(result.mode,mode);assert.equal(result.accent,accent);assert.equal(result.overflow,false);assert.equal(result.filter,'none');
   if(mode==='dark'){assert.equal(result.canvas,'rgb(20, 21, 22)');assert.equal(result.panel,'rgb(32, 33, 36)');assert.equal(result.text,'rgb(233, 234, 237)');}
   evidence.push({width,...result,screenshot:await capture(width+'-'+mode)});
  }
 }
 await page('Emulation.setDeviceMetricsOverride',{width:950,height:800,deviceScaleFactor:1,mobile:false});
 await evaluate(`document.querySelector('[data-action="settings"]').click()`);await delay(220);
 await evaluate(`document.querySelector('[data-appearance-mode="dark"]').click()`);await evaluate(`document.querySelector('[data-appearance-accent="rose"]').click()`);
 assert.equal(await evaluate(`document.querySelectorAll('[data-appearance-accent][aria-pressed=true]').length`),1);
 const settings=await capture('settings-dark-rose');
 await evaluate(`document.querySelector('.modal-backdrop').click()`);await delay(220);
 await evaluate(`document.querySelector('[data-action="open-editor"]').click()`);await delay(220);
 await evaluate(`(()=>{const input=document.querySelector('.editor-sheet textarea');input.value='主题切换保留草稿';input.dispatchEvent(new Event('input',{bubbles:true}));input.focus();input.setSelectionRange(3,3);window.__themeEditor=input;window.__client.appearance.set({mode:'neutral',accent:'purple'});})()`);
 const draft=await evaluate(`(()=>{const input=document.querySelector('.editor-sheet textarea');return{same:input===window.__themeEditor,text:input.value,caret:input.selectionStart}})()`);
 assert.equal(draft.same,true);assert.equal(draft.text,'主题切换保留草稿');assert.equal(draft.caret,3);
 await page('Page.reload');await poll(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
 assert.deepEqual(await evaluate('window.__client.appearance.value'),{mode:'neutral',accent:'purple'});
 const report={passed:true,profile:browserProfile,evidence,settings,draft,scope:'Actual Edge desktop/mobile surfaces, settings buttons, reload persistence, no draft remount.'};await writeFile(join(run,'result.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({passed:true,run,screenshots:shots}));
}finally{await closePage?.().catch(()=>{});socket?.close();await closeSharedBrowser(browser);await center.close();}
