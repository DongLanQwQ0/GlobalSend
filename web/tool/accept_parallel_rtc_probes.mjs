import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../../server/src/server.ts';

// Three real browser contexts, production monitor + RTCPeerConnection + center.
// Uses the one established profile; no native install, device or public traffic.
const root=fileURLToPath(new URL('../../',import.meta.url));
const run=join(root,'artifacts/tmp/parallel-rtc-'+Date.now()),site=join(run,'site');await mkdir(site,{recursive:true});
const {build}=createRequire(import.meta.url)('esbuild');
const output=await build({entryPoints:[join(root,'web/tool/rtc_reachability_fixture.ts')],bundle:true,platform:'browser',format:'esm',write:false});
await writeFile(join(site,'fixture.js'),output.outputFiles[0].text);
await writeFile(join(site,'index.html'),'<!doctype html><html><meta charset="utf-8"><script type="module" src="./fixture.js"></script></html>');
const app=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,diskReserve:0,production:false,log:false});
await app.listen({host:'127.0.0.1',port:0});const base=`http://127.0.0.1:${app.server.address().port}`;
const ControlSocket=createRequire(new URL('../../server/package.json',import.meta.url))('ws');
const controls=[],pages=new Map();let browser,socket,send;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,accept,timeout=18000){let value;const end=Date.now()+timeout;while(Date.now()<end){value=await action();if(accept(value))return value;await delay(50);}throw new Error('Deadline '+JSON.stringify(value));}
async function call(path,body,token){const r=await fetch(base+'/api/v1'+path,{method:body===undefined?'GET':'POST',headers:{connection:'close',...(token?{authorization:`Bearer ${token}`} : {}),...(body===undefined?{}:{'content-type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});const v=await r.json();assert.equal(r.ok,true,`${path}: ${r.status}`);return v;}
try{
  const group='parallel-rtc-'+Date.now(),devices=[];
  for(let i=0;i<3;i++){
    const device=await call('/devices/enroll',{name:'isolated parallel browser '+i,platform:'web',groupKey:group});devices.push(device);
    const {ticket}=await call('/session/ws-ticket',{},device.deviceToken);
    const ws=new ControlSocket(base.replace('http:','ws:')+'/api/v1/ws?ticket='+ticket,{origin:base});controls.push(ws);
    await new Promise((resolve,reject)=>{ws.on('message',data=>{const message=JSON.parse(String(data));if(message.type==='hello')resolve();if(message.type==='rtc.probes.changed')void pages.get(device.device.deviceId)?.evaluate('void fixture.refresh()').catch(()=>{});});ws.once('error',reject);});
    await call('/devices/me/rtc',{scopes:['lan','public'],parallelProbes:true},device.deviceToken);
  }
  const before=await call('/transfers',undefined,devices[0].deviceToken);
  browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
  const address=await poll(async()=>{try{return (await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let sequence=0;const pending=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),p=pending.get(value.id);if(p){pending.delete(value.id);value.error?p.reject(new Error(value.error.message)):p.resolve(value.result);}});
  send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  for(const device of devices){
    const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
    const page=(method,params={})=>send(method,params,sessionId);
    const evaluate=async expression=>{const value=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
    pages.set(device.device.deviceId,{targetId,evaluate});await page('Page.navigate',{url:base+'/app/'});await poll(()=>evaluate('typeof fixture === "object"'),Boolean);
  }
  const started=Date.now();
  await Promise.all(devices.map(device=>pages.get(device.device.deviceId).evaluate(`fixture.configure(${JSON.stringify(device)},${JSON.stringify(devices.filter(d=>d!==device).map(d=>d.device.deviceId))},true)`)));
  const states=()=>Promise.all([...pages.values()].map(page=>page.evaluate('fixture.state()')));
  const startedAll=await poll(states,rows=>rows.every(row=>row.created>=4));
  const simultaneous=(await call('/devices/me/rtc-probes',undefined,devices[0].deviceToken)).probes;
  const ready=await poll(states,rows=>rows.every(row=>row.results.filter(result=>result.scope==='lan'&&result.success).length===2));
  const lanReadyMs=Date.now()-started;
  assert.deepEqual(await call('/transfers',undefined,devices[0].deviceToken),before);
  await Promise.all([...pages.values()].map(page=>page.evaluate('fixture.close()')));
  const closed=await poll(states,rows=>rows.every(row=>row.created===row.closed));
  const report={passed:true,profile:browserProfile,startedAll,observedConcurrentProbes:simultaneous.length,lanReadyMs,ready,closed,scope:'Three real same-machine browser contexts; real nonce/echo and lifecycle. Not physical network/phone/iPad reachability.'};
  await writeFile(join(run,'result.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({passed:true,run,lanReadyMs,created:closed.map(row=>row.created),closed:closed.map(row=>row.closed)}));
}catch(error){await writeFile(join(run,'failure.txt'),String(error));throw error;}
finally{
  for(const page of pages.values()){await page.evaluate('fixture.close()').catch(()=>{});await send?.('Target.closeTarget',{targetId:page.targetId}).catch(()=>{});}
  socket?.close();if(browser)await closeSharedBrowser(browser);
  await Promise.all(controls.map(ws=>new Promise(resolve=>{if(ws.readyState===ControlSocket.CLOSED)return resolve();ws.once('close',resolve);ws.close();})));
  await app.close();
}
