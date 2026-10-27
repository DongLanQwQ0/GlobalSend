import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { buildApp } from '../../server/src/server.ts';

// Real same-service HTTP/WS under deployment prefixes, the persistent shared Edge profile.
// Clipboard is replaced only inside this test page; the OS clipboard is untouched.
const root=fileURLToPath(new URL('../../',import.meta.url)),work=join(root,'artifacts/tmp/web-entry-settings');await mkdir(work,{recursive:true});
const run=await mkdtemp(join(work,'run-')),site=join(run,'site'),shots=join(root,'artifacts/screenshots');await mkdir(site,{recursive:true});await mkdir(shots,{recursive:true});
const {build}=createRequire(import.meta.url)('esbuild'),source=await readFile(join(root,'web/src/main.ts'),'utf8');
const compiled=await build({stdin:{contents:source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();'),resolveDir:join(root,'web/src'),sourcefile:'entry-acceptance.ts',loader:'ts'},bundle:true,platform:'browser',format:'esm',write:false,loader:{'.css':'empty'}});
await writeFile(join(site,'fixture.js'),compiled.outputFiles[0].text);await writeFile(join(site,'style.css'),await readFile(join(root,'web/src/style.css')));
await writeFile(join(site,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" hidden multiple><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script></html>');
async function freePort(){const server=createServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const port=server.address().port;await new Promise(resolve=>server.close(resolve));return port;}
let stage='startup-no-session';const requests=[];
async function center(name,prefix){const port=await freePort(),base=`http://127.0.0.1:${port}${prefix}`;const app=await buildApp({dataDir:join(run,name),relayDir:join(run,name,'relay'),staticDir:site,publicBaseUrl:base,diskReserve:0,production:false,log:false});app.addHook('onRequest',async req=>{requests.push({stage,center:name,method:req.method,path:new URL(req.url,base).pathname,at:Date.now()});});await app.listen({host:'127.0.0.1',port});return {app,base};}
const primary=await center('primary','/globalsend'),alternate=await center('alternate','/alternate'),profile=sharedBrowserProfile;
const browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,predicate,timeout=12000){let last;const end=Date.now()+timeout;while(Date.now()<end){last=await action();if(predicate(last))return last;await delay(35);}throw new Error('Deadline '+JSON.stringify(last));}
let socket;
try {
  const address=await poll(async()=>{try{return (await readFile(join(profile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0;const calls=new Map();socket.addEventListener('message',event=>{const reply=JSON.parse(event.data),call=calls.get(reply.id);if(call){calls.delete(reply.id);reply.error?call.reject(new Error(reply.error.message)):call.resolve(reply.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++next;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const page=(method,params)=>send(method,params,sessionId);
  const evaluate=async expression=>{const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;};
  await page('Page.enable');await page('Runtime.enable');await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  await page('Page.navigate',{url:primary.base+'/app/'});await poll(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
  const evidence=[];
  const snapshot=async name=>{await evaluate('document.fonts.ready.then(()=>true)');await delay(80);const state=await evaluate("({overflow:document.documentElement.scrollWidth>innerWidth,details:document.querySelectorAll('.onboarding details,.settings-modal details').length,passwordEyes:[...document.querySelectorAll('.password-eye')].filter(n=>n.getClientRects().length).length,copyButtons:[...document.querySelectorAll('.reader-modal [data-action=copy-reader]')].map(n=>n.textContent.trim()),serverVisible:!!document.querySelector('.settings-modal #server-url'),base:window.__client.baseUrl})");assert.equal(state.overflow,false);assert.equal(state.details,0);const shot=await page('Page.captureScreenshot',{format:'jpeg',quality:80,captureBeyondViewport:false});const path=join(shots,'web-1.0.4-'+name+'.preview.jpg');await writeFile(path,Buffer.from(shot.data,'base64'));evidence.push({name,...state,path});return state;};
  assert.equal(await evaluate('window.__client.baseUrl'),primary.base);assert.equal(await evaluate('window.__client.api.baseUrl'),primary.base);
  assert.ok(requests.some(req=>req.path==='/globalsend/api/v1/info'));assert.equal(requests.some(req=>req.path.endsWith('/devices')),false);
  assert.equal(await evaluate("document.querySelector('#device-name').closest('details')"),null);
  assert.equal(await evaluate("document.querySelector('#device-name').hasAttribute('required')"),false);
  assert.equal(await evaluate("document.querySelector('.pair-form').textContent.includes('相同密码的设备自动分为一组')"),false);
  assert.equal((await snapshot('phone-join')).passwordEyes,1);
  await evaluate("(()=>{const field=document.querySelector('#group-key');field.value='shared-entry-password';field.dispatchEvent(new Event('input',{bubbles:true}));field.setSelectionRange(2,6);document.querySelector('.password-eye').click();})()");
  assert.equal(await evaluate("document.querySelector('#group-key').type"),'text');assert.equal(await evaluate("document.querySelector('#group-key').value"),'shared-entry-password');assert.equal(await evaluate("document.querySelectorAll('[data-action=show-group-key]').length"),1);
  assert.equal(await evaluate("[...document.styleSheets].flatMap(sheet=>[...sheet.cssRules]).some(rule=>rule.selectorText?.includes('#group-key::-ms-reveal') && rule.style.display==='none')"),true);
  await evaluate("document.querySelector('.password-eye').click();window.__client.render()");assert.equal(await evaluate("document.querySelector('#group-key').type"),'password');
  stage='no-session-resume';await evaluate("window.dispatchEvent(new FocusEvent('focus'));window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}))");await delay(70);assert.equal(requests.some(req=>req.stage===stage && req.path.endsWith('/devices')),false);
  await evaluate("document.querySelector('[data-action=server-modal]').click()");assert.equal((await snapshot('phone-settings-before-join')).serverVisible,true);
  assert.equal(await evaluate("document.querySelector('#server-url').value"),primary.base);
  await evaluate("document.querySelector('[data-action=close-modal]').click()");stage='enroll';
  await evaluate("document.querySelector('#enroll-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))");await poll(()=>evaluate('window.__client.connected && window.__client.shared.loaded'),Boolean);
  const identity=await evaluate('window.__client.session.device.deviceId');assert.ok(requests.some(req=>req.path==='/globalsend/api/v1/ws'));
  await poll(()=>evaluate('!window.__client.syncing'),Boolean);
  for(const [name,expression] of [['manual-device-refresh',"document.querySelector('[title=刷新设备]').click()"],['window-focus',"window.dispatchEvent(new FocusEvent('focus'))"],['pageshow-persisted',"window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}))"]]){
    stage=name;const before=requests.length;await evaluate(expression);await poll(async()=>requests.slice(before).filter(req=>req.stage===name && req.path==='/globalsend/api/v1/devices').length,count=>count>0);await poll(()=>evaluate('!window.__client.syncing'),Boolean);
  }
  stage='remembered-startup';await page('Page.reload');await poll(()=>evaluate('!!window.__client && window.__client.connected && !window.__client.loading'),Boolean);await poll(()=>evaluate('!window.__client.syncing'),Boolean);
  assert.equal(await evaluate('window.__client.session.device.deviceId'),identity);assert.equal(await evaluate('window.__client.baseUrl'),primary.base);
  assert.ok(requests.some(req=>req.stage===stage && req.path==='/globalsend/api/v1/devices'));assert.ok(requests.some(req=>req.stage===stage && req.path==='/globalsend/api/v1/ws'));
  await evaluate('window.__client.openSettings()');await snapshot('phone-settings-connected');await evaluate("document.querySelector('[data-action=close-modal]').click()");
  stage='reader';const call=async(path,body,token)=>{const response=await fetch(primary.base+'/api/v1'+path,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body)});const value=await response.json();assert.ok(response.ok,JSON.stringify(value));return value;};
  const sender=await call('/devices/enroll',{name:'reader sender',platform:'web',groupKey:'shared-entry-password'}),text='完整正文\n'+('中文 English 123\n'.repeat(800)),eventId=randomUUID();await call('/texts',{eventId,targetDeviceId:identity,text},sender.deviceToken);
  await poll(()=>evaluate(`window.__client.events.some(event=>event.eventId==='${eventId}')`),Boolean);
  await evaluate(`window.__client.openText('${eventId}');Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>{window.__copied=text;}}});document.querySelector('#reader-text').setSelectionRange(3,7);document.querySelector('[data-action=copy-reader]').click()`);
  assert.equal(await evaluate('window.__copied'),text);assert.equal(await evaluate("document.querySelector('[data-action=select-reader]')"),null);assert.equal((await snapshot('phone-reader')).copyButtons.length,1);
  assert.equal(await evaluate("document.querySelector('[data-action=copy-reader]').textContent.trim()"),'复制');
  await evaluate("document.querySelector('[data-action=close-modal]').click()");
  const fileText='<!doctype html>\n<html lang="zh-CN"><body>完整文件正文</body></html>';
  await evaluate(`(async()=>{const c=window.__client,rules={retentionHours:24,categories:['image','video','audio','text','archive','other'],sizeRule:'any',sizeMiB:0},entry={id:'fixture/html',scope:'fixture',key:'html',name:'index.html',mimeType:'text/html',size:100,receivedAt:Date.now(),expiresAt:Date.now()+86400000};c.fileLibrary.service={list:async()=>[entry],cleanupPreferences:async()=>rules,get:async()=>new File([${JSON.stringify(fileText)}],'index.html',{type:'text/html'})};await c.openLibrary();await c.fileLibrary.preview(entry.id);document.querySelector('[data-library-action=copy]').click();})()`);
  assert.equal(await evaluate('window.__copied'),fileText);assert.equal(await evaluate("document.querySelector('[data-library-action=copy]').textContent.trim()"),'复制');await snapshot('phone-file-reader');
  await evaluate("document.querySelector('[data-library-action=back]').click();document.querySelector('.library-cleanup').open=true");await snapshot('phone-library-cleanup');
  await evaluate("document.querySelector('[data-library-action=close]').click();window.__client.openSettings()");
  stage='external-server-switch';await evaluate(`(()=>{const field=document.querySelector('#server-url');field.value=${JSON.stringify(alternate.base)};field.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#server-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));})()`);
  await poll(()=>evaluate('!!window.__client && !window.__client.loading && location.pathname.startsWith("/alternate/")'),Boolean);
  assert.equal(await evaluate('window.__client.baseUrl'),alternate.base);assert.equal(await evaluate('window.__client.api.baseUrl'),alternate.base);assert.equal(await evaluate('window.__client.session'),null);
  assert.ok(requests.some(req=>req.stage===stage && req.center==='alternate' && req.path==='/alternate/api/v1/info'));
  await evaluate("(()=>{const field=document.querySelector('#group-key');field.value='shared-elsewhere-password';field.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#enroll-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));})()");await poll(()=>evaluate('window.__client.connected'),Boolean);
  assert.ok(requests.some(req=>req.center==='alternate' && req.path==='/alternate/api/v1/ws'));
  const result={screens:evidence,sourceBase:primary.base,customBase:alternate.base,oneVisiblePasswordControl:true,deviceNameDirectAndOptional:true,directServerCard:true,wholeTextCopiedWithoutSystemClipboard:true,rememberedIdentityRestored:true,pathsSameOriginAndPrefix:true,discoveryRequests:requests.filter(req=>req.path.endsWith('/devices')),requests};
  await writeFile(join(run,'result.json'),JSON.stringify(result,null,2));console.log(JSON.stringify({run,...result}));
}finally{socket?.close();await closeSharedBrowser(browser);await primary.app.close();await alternate.app.close();}
