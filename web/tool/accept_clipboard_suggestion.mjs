import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {createServer} from 'node:net';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../../server/src/server.ts';

const root=fileURLToPath(new URL('../../',import.meta.url));
const run=join(root,'artifacts/tmp/clipboard79/browser'),site=join(run,'site');await mkdir(site,{recursive:true});
const {build}=createRequire(import.meta.url)('esbuild');
const source=await readFile(join(root,'web/src/main.ts'),'utf8');
const output=await build({stdin:{contents:source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();'),resolveDir:join(root,'web/src'),sourcefile:'clipboard-acceptance.ts',loader:'ts'},bundle:true,platform:'browser',format:'esm',write:false,loader:{'.css':'empty'}});
await writeFile(join(site,'fixture.js'),output.outputFiles[0].text);
await writeFile(join(site,'style.css'),await readFile(join(root,'web/src/style.css')));
await writeFile(join(site,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" multiple hidden><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script></html>');
const reserve=createServer();await new Promise(resolve=>reserve.listen(0,'127.0.0.1',resolve));const port=reserve.address().port;await new Promise(resolve=>reserve.close(resolve));
const base=`http://127.0.0.1:${port}/globalsend`;
const center=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,publicBaseUrl:base,diskReserve:0,production:false,log:false});await center.listen({host:'127.0.0.1',port});
const browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(action,accept){const end=Date.now()+15000;while(Date.now()<end){const value=await action();if(accept(value))return value;await delay(50);}throw new Error('Browser condition timed out');}
let socket,page,targetId,send;
try {
  const endpoint=await until(async()=>{try{return(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{return null;}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${endpoint[0]}${endpoint[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let sequence=0;const calls=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=calls.get(value.id);if(call){calls.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}});
  send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++sequence;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  ({targetId}=await send('Target.createTarget',{url:'about:blank'}));const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});page=(method,params={})=>send(method,params,sessionId);
  const evaluate=async expression=>{const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;};
  await page('Page.enable');await page('Runtime.enable');
  // Synthetic clipboard transport: never read or replace the user's clipboard.
  await page('Page.addScriptToEvaluateOnNewDocument',{source:`window.__clipboardType='text/plain';window.__clipboardLoads=0;Object.defineProperty(navigator,'permissions',{value:{query:async()=>({state:'granted'})}});Object.defineProperty(navigator,'clipboard',{value:{read:async()=>[{types:[window.__clipboardType],getType:async()=>{window.__clipboardLoads++;return new Blob(['synthetic clipboard'],{type:'text/plain'});}}],writeText:async()=>{}}});`});
  await page('Emulation.setDeviceMetricsOverride',{width:950,height:650,deviceScaleFactor:1,mobile:false});
  await page('Page.navigate',{url:base+'/app/'});await until(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
  await evaluate("(async()=>{const c=window.__client;c.groupKey='clipboard79-fixture';await c.enroll();await c.refreshClipboardSuggestion();})()");
  await until(()=>evaluate("!!document.querySelector('.clipboard-suggestion')"),Boolean);
  assert.equal(await evaluate('window.__clipboardLoads'),0);
  assert.equal(await evaluate("!!document.querySelector('.staged-list > .clipboard-suggestion') && !document.querySelector('.queue-heading .clipboard-suggestion')"),true);
  assert.equal(await evaluate('window.__client.stagedTexts.length+window.__client.picked.length'),0);
  assert.equal(await evaluate("document.querySelector('.queue-heading .count')"),null);
  for(const [width,height] of [[950,650],[390,844]]) {
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<500});await delay(150);
    assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);
    assert.equal(await evaluate("(()=>{const r=document.querySelector('.clipboard-suggestion').getBoundingClientRect();return Math.abs(r.width-r.height)<2})()"),true);
    const capture=await page('Page.captureScreenshot',{format:'jpeg',quality:82});await writeFile(join(run,`clipboard-${width}.jpg`),Buffer.from(capture.data,'base64'));
  }
  const click=async selector=>{const point=await evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);await page('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...point});await page('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...point});};
  await click('.clipboard-suggestion [data-action="clipboard"]');await until(()=>evaluate('window.__client.stagedTexts.length'),value=>value===1);
  assert.equal(await evaluate('window.__client.stagedTexts[0].text'),'synthetic clipboard');assert.equal(await evaluate('window.__clipboardLoads'),1);
  assert.equal(await evaluate("!!document.querySelector('.clipboard-suggestion')"),false);
  await evaluate("(async()=>{dispatchEvent(new Event('blur'));await window.__client.refreshClipboardSuggestion();})()");
  await click('[data-action="dismiss-clipboard-suggestion"]');assert.equal(await evaluate("!!document.querySelector('.clipboard-suggestion')"),false);
  assert.equal(await evaluate('window.__clipboardLoads'),1);
  await writeFile(join(run,'result.json'),JSON.stringify({unconfirmedCardInsideQueue:true,excludedFromPendingCount:true,metadataDoesNotLoadContent:true,tapStagesWithoutSending:true,dismissDoesNotRead:true,desktopAndMobileFit:true,userClipboardUntouched:true,browserProfile},null,2));
  await evaluate('(()=>{const c=window.__client;c.stagedTexts=[];c.picked=[];c.shared.dirty=false;c.busy=false;})()');
  console.log('PASS: browser clipboard suggestion, explicit import, dismissal, desktop/mobile render; synthetic clipboard only');
} finally {
  if(send && targetId)await send('Target.closeTarget',{targetId}).catch(()=>{});
  socket?.close();await closeSharedBrowser(browser);await center.close();
}
