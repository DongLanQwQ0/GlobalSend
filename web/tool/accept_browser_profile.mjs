import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {randomUUID} from 'node:crypto';
import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';

// Only a local fixture origin is touched. The same normal profile is reopened,
// with a sentinel proving persistent site storage survives normal shutdown.
const root=fileURLToPath(new URL('../../',import.meta.url));
const reports=join(root,'artifacts/reports');await mkdir(reports,{recursive:true});
const server=createServer((_req,res)=>{res.setHeader('content-type','text/html');res.end('<!doctype html><title>Profile continuity</title>');});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin=`http://127.0.0.1:${server.address().port}`;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let browser,socket;
async function open(){
  browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',[
    '--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking',
    '--disable-component-update','--disable-extensions','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'
  ],{windowsHide:true,stdio:'ignore'});
  let address;
  for(let retry=0;retry<100;retry++){
    try {address=(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);break;}
    catch(error){if(error.code!=='ENOENT')throw error;await delay(30);}
  }
  assert.ok(address,'shared browser endpoint');
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let id=0;const pending=new Map();
  socket.addEventListener('message',event=>{const data=JSON.parse(event.data),call=pending.get(data.id);if(!call)return;pending.delete(data.id);data.error?call.reject(new Error(data.error.message)):call.resolve(data.result);});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const callId=++id;pending.set(callId,{resolve,reject});socket.send(JSON.stringify({id:callId,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:origin}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const evaluate=async expression=>{const value=await send('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true},sessionId);if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
  for(let retry=0;retry<100;retry++){if(await evaluate(`location.origin===${JSON.stringify(origin)}`))return {evaluate,send,targetId};await delay(20);}
  throw new Error('fixture origin did not load');
}
try {
  let page=await open();const marker=randomUUID();
  await page.evaluate(`localStorage.setItem('globalsend-profile-continuity',${JSON.stringify(marker)})`);
  await page.evaluate(`document.cookie='globalsend_profile_continuity=${marker}; Max-Age=3600; SameSite=Lax'`);
  const contender=spawn(process.execPath,['--input-type=module','-e',"await import('./web/tool/browser_profile.mjs')"],{cwd:root,windowsHide:true,stdio:['ignore','pipe','pipe']});
  let conflict='';contender.stderr.on('data',value=>conflict+=value);
  const conflictExit=await new Promise(resolve=>contender.once('exit',resolve));
  assert.notEqual(conflictExit,0);assert.match(conflict,/固定浏览器配置正在使用/);
  await page.send('Target.closeTarget',{targetId:page.targetId});socket.close();await closeSharedBrowser(browser);
  page=await open();
  assert.equal(await page.evaluate("localStorage.getItem('globalsend-profile-continuity')"),marker);
  assert.equal(await page.evaluate(`document.cookie.includes('globalsend_profile_continuity=${marker}')`),true);
  await page.send('Target.closeTarget',{targetId:page.targetId});
  const result={profile:browserProfile,sameProfileReopened:true,localStoragePreserved:true,persistentCookiePreserved:true,concurrentRunnerRejected:true,normalBrowserCloseWaited:true};
  await writeFile(join(reports,'browser-profile-continuity-1.0.10.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
} finally {socket?.close();await closeSharedBrowser(browser);await new Promise(resolve=>server.close(resolve));}
