import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../../server/src/server.ts';

const root=fileURLToPath(new URL('../../',import.meta.url));
const run=join(root,'artifacts/tmp/platform-guides102/browser'),site=join(run,'site');
await mkdir(site,{recursive:true});
const {build}=createRequire(import.meta.url)('esbuild');
const source=await readFile(join(root,'web/src/main.ts'),'utf8');
const js=await build({stdin:{contents:source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;await c.start();'),resolveDir:join(root,'web/src'),sourcefile:'guide-acceptance.ts',loader:'ts'},bundle:true,platform:'browser',format:'esm',write:false,loader:{'.css':'empty'}});
const css=await build({entryPoints:[join(root,'web/src/style.css')],bundle:true,write:false});
await writeFile(join(site,'fixture.js'),js.outputFiles[0].text);
await writeFile(join(site,'style.css'),css.outputFiles[0].text);
await writeFile(join(site,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" multiple hidden><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script></html>');
const center=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,diskReserve:0,production:false,log:false});
const base=await center.listen({host:'127.0.0.1',port:0});
let browser,socket,closePage;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(action,accept){const end=Date.now()+15000;while(Date.now()<end){const value=await action();if(accept(value))return value;await delay(50);}throw new Error('Browser condition timed out');}
try {
  browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
  const address=await until(async()=>{try{return(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{return null;}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let sequence=0;const calls=new Map();
  socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=calls.get(value.id);if(call){calls.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++sequence;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  closePage=()=>send('Target.closeTarget',{targetId});
  const page=(method,params={})=>send(method,params,sessionId);
  const evaluate=async expression=>{const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;};
  const click=async selector=>{await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);};
  await page('Page.enable');await page('Page.navigate',{url:base+'/app/'});
  await until(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
  await evaluate('window.__client.openSettings()');
  await click('[data-action="user-guide"]');
  assert.equal(await evaluate('document.querySelector("#user-guide-title").textContent'),'使用指南');
  await click('[data-guide-topic="3"]');
  assert.equal(await evaluate('document.querySelector(".user-guide-section h3").textContent'),'通知与移动浏览');
  for(const [width,height,mode] of [[950,650,'dark'],[390,844,'light']]){
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<500});
    await evaluate(`window.__client.appearance.set({mode:'${mode}',accent:'purple'})`);await delay(220);
    assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);
    assert.equal(await evaluate('(()=>{const r=document.querySelector(".user-guide-modal").getBoundingClientRect();return r.left>=0 && r.right<=innerWidth && r.top>=0 && r.bottom<=innerHeight})()'),true);
    const capture=await page('Page.captureScreenshot',{format:'jpeg',quality:84});await writeFile(join(run,`web-${width}.jpg`),Buffer.from(capture.data,'base64'));
  }
  await page('Input.dispatchKeyEvent',{type:'keyDown',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await page('Input.dispatchKeyEvent',{type:'keyUp',key:'Escape',code:'Escape',windowsVirtualKeyCode:27});
  await until(()=>evaluate('window.__client.modal'),value=>value===null);
  await evaluate('window.__client.openSettings()');await click('[data-action="user-guide"]');await delay(200);
  await evaluate('document.querySelector(".modal-backdrop").click()');
  await until(()=>evaluate('window.__client.modal'),value=>value===null);
  await writeFile(join(run,'result.json'),JSON.stringify({settingsEntry:true,topicChanges:true,desktopAndMobileFit:true,escapeCloses:true,outsideClickCloses:true,existingModalAnimations:true,browserProfile},null,2));
  console.log('PASS: guide settings entry, topic selection, desktop/mobile render, Escape and outside dismissal');
} finally {
  try{await closePage?.();}finally{socket?.close();await closeSharedBrowser(browser);await center.close();}
}
