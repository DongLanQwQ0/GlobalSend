import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { buildApp } from '../../server/src/server.ts';

// Two ordinary tabs in the same persistent browser profile; separate in-memory clients.
const root=fileURLToPath(new URL('../../',import.meta.url));
const work=join(root,'artifacts/tmp/web-workspace-shared');await mkdir(work,{recursive:true});
const run=await mkdtemp(join(work,'run-')),site=join(run,'site');await mkdir(site,{recursive:true});
const require=createRequire(import.meta.url),{build}=require('esbuild');
const source=await readFile(join(root,'web/src/main.ts'),'utf8');
const compiled=await build({stdin:{contents:source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();'),resolveDir:join(root,'web/src'),sourcefile:'shared-acceptance.ts',loader:'ts'},bundle:true,platform:'browser',format:'esm',write:false,loader:{'.css':'empty'}});
await writeFile(join(site,'fixture.js'),compiled.outputFiles[0].text);
await writeFile(join(site,'style.css'),await readFile(join(root,'web/src/style.css')));
await writeFile(join(site,'index.html'),'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" hidden multiple><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script>');
const app=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,diskReserve:0,production:false,log:false});await app.listen({host:'127.0.0.1',port:0});
const base=`http://127.0.0.1:${app.server.address().port}`,profile=sharedBrowserProfile;
const browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,predicate,timeout=10000){let last;const end=Date.now()+timeout;while(Date.now()<end){last=await action();if(predicate(last))return last;await delay(40);}throw new Error('Deadline: '+JSON.stringify(last));}
let socket;
try {
  const address=await poll(async()=>{try{return (await readFile(join(profile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0;const calls=new Map();socket.addEventListener('message',event=>{const reply=JSON.parse(event.data),call=calls.get(reply.id);if(call){calls.delete(reply.id);reply.error?call.reject(new Error(reply.error.message)):call.resolve(reply.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++next;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  async function open(name){
    const {targetId}=await send('Target.createTarget',{url:'about:blank'});const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
    const page=(method,params)=>send(method,params,sessionId);
    const evaluate=async(expression)=>{const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;};
    await page('Page.enable');await page('Runtime.enable');await page('Page.navigate',{url:base+'/app/'});
    await poll(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
    await evaluate(`(async()=>{window.__client.rememberDevice=false;window.__client.deviceName=${JSON.stringify(name)};window.__client.groupKey='workspace-browser-acceptance';await window.__client.enroll()})()`);
    await poll(()=>evaluate('!!window.__client.connected && window.__client.shared.loaded'),Boolean);
    return {evaluate,page};
  }
  const a=await open('first browser'),b=await open('second browser');
  const type=text=>`(()=>{const input=document.querySelector('#shared-group-text');input.value=${JSON.stringify(text)};input.dispatchEvent(new Event('input',{bubbles:true}));})()`;
  await a.evaluate(type('电脑输入\n实时到达手机'));
  await poll(()=>b.evaluate('window.__client.shared.draft'),value=>value==='电脑输入\n实时到达手机');
  await b.evaluate(type('手机修改\n实时回到电脑'));
  await poll(()=>a.evaluate('window.__client.shared.draft'),value=>value==='手机修改\n实时回到电脑');
  // An unfinished IME draft must not be replaced by an incoming remote write.
  await a.evaluate("document.querySelector('#shared-group-text').dispatchEvent(new Event('compositionstart'));"+type('保留本机草稿'));
  await b.evaluate(type('另一设备新版本'));
  await poll(()=>a.evaluate('window.__client.shared.conflict'),Boolean);
  assert.equal(await a.evaluate("document.querySelector('#shared-group-text').value"),'保留本机草稿');
  await a.evaluate("document.querySelector('#shared-group-text').dispatchEvent(new Event('compositionend'));document.querySelector('[data-shared-action=mine]').click()");
  await poll(()=>b.evaluate('window.__client.shared.draft'),value=>value==='保留本机草稿');
  const state=await a.evaluate(`(async()=>({revision:window.__client.shared.document.revision,text:window.__client.shared.document.text,events:(await window.__client.api.request('/events')).events.length,transfers:(await window.__client.api.request('/transfers')).transfers.length}))()`);
  assert.equal(state.events,0);assert.equal(state.transfers,0);assert.equal(state.text,'保留本机草稿');assert.equal(state.revision,4);
  const result={twoOrdinaryTabsOnePersistentProfile:true,bidirectionalHttpWebSocketSync:true,debounceMilliseconds:400,imeDraftPreservedOnConcurrentWrite:true,explicitConflictResolution:true,...state};
  await writeFile(join(run,'result.json'),JSON.stringify(result,null,2));console.log(JSON.stringify({run,...result}));
  
} finally {socket?.close();await closeSharedBrowser(browser);await app.close();}
