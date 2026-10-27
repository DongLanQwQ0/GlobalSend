import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {mkdir,mkdtemp,readFile,writeFile,readdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {dirname,join} from 'node:path';
import {buildApp} from '../../server/src/server.ts';

// Production monitors/PC adapters + a project-local center. No existing product
// process, current browser tab, phone, global network/firewall or STUN/TURN.
const root=fileURLToPath(new URL('../../',import.meta.url));
const webInitiates=process.argv.includes('--web-initiates');
const temporary=join(root,'artifacts/tmp/rtc-reachability-interop');
await mkdir(temporary,{recursive:true});
const run=await mkdtemp(join(temporary,'run-'));
const require=createRequire(new URL('../package.json',import.meta.url));
const ControlSocket=createRequire(new URL('../../server/package.json',import.meta.url))('ws');
const {build}=await import(pathToFileURL(require.resolve('vite')).href);
const site=join(run,'site');
await build({configFile:false,root:join(root,'web'),base:'/app/',logLevel:'warn',build:{outDir:site,emptyOutDir:true,rollupOptions:{input:join(root,'web/tool/rtc_reachability_fixture.html')}}});
await writeFile(join(site,'index.html'),await readFile(join(site,'tool/rtc_reachability_fixture.html')));
const app=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,production:false,diskReserve:0,log:false});
await app.listen({host:'127.0.0.1',port:0});
const base=`http://127.0.0.1:${app.server.address().port}`;
const executable=join(root,'client/build/rtc-reachability-probe/build/windows/x64/runner/Release/rtc_reachability_probe.exe');
const native=spawn(executable,[run],{cwd:dirname(executable),windowsHide:true,stdio:'ignore'});
let nativeFailure;native.on('error',error=>{nativeFailure=error;});
let nativeUrl,browser,socket,evaluate,pump;
const sockets=[];
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,predicate,timeout=30000){const end=Date.now()+timeout;let v;while(Date.now()<end){v=await action();if(predicate(v))return v;await delay(60);}throw new Error('Deadline '+JSON.stringify(v));}
async function call(path,body,token,method=body===undefined?'GET':'POST'){
  const r=await fetch(base+'/api/v1'+path,{method,headers:{...(token?{Authorization:`Bearer ${token}`} : {}),...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});
  const v=await r.json();if(!r.ok)throw new Error(`${path} ${r.status} ${JSON.stringify(v)}`);return v;
}
async function control(path,body){const r=await fetch(nativeUrl+path,body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const v=await r.json();if(!r.ok)throw new Error(JSON.stringify(v));return v;}
try {
  await poll(async()=>{if(nativeFailure)throw nativeFailure;try{return nativeUrl=JSON.parse(await readFile(join(run,'control.json'),'utf8')).url;}catch{if(native.exitCode!==null)throw new Error(await readFile(join(run,'startup-error.txt'),'utf8').catch(()=>String(native.exitCode)));}},Boolean,25000);
  const group=randomUUID()+randomUUID();
  const web=await call('/devices/enroll',{name:'isolated browser reachability',platform:'web',groupKey:group});
  let win;
  for(let i=0;i<100;i++){win=await call('/devices/enroll',{name:'isolated Windows reachability',platform:'windows',groupKey:group});if((win.device.deviceId<web.device.deviceId)!==webInitiates)break;}
  assert.ok((win.device.deviceId<web.device.deviceId)!==webInitiates,'Fixture needs the selected deterministic initiator');
  let forward=true;
  for(const device of [win,web]){
    const {ticket}=await call('/session/ws-ticket',{},device.deviceToken);
    const ws=new ControlSocket(base.replace('http:','ws:')+'/api/v1/ws?ticket='+ticket,{origin:base});sockets.push(ws);
    await new Promise((resolve,reject)=>{ws.on('message',data=>{const event=JSON.parse(String(data));if(event.type==='hello')resolve();if(event.type==='rtc.probes.changed' && forward){if(device===win)void control('/refresh',{}).catch(()=>{});else if(evaluate)void evaluate('void fixture.refresh()').catch(()=>{});}});ws.once('error',reject);});
    await call('/devices/me/rtc',{scopes:['lan','public']},device.deviceToken);
  }
  const beforeTransfers=await call('/transfers',undefined,win.deviceToken),beforeEvents=await call('/events',undefined,win.deviceToken);
  await control('/configure',{base,token:win.deviceToken,deviceId:win.device.deviceId});
  const profile=sharedBrowserProfile;
  browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update','--disable-extensions','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
  const address=await poll(async()=>{try{return(await readFile(join(profile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean,20000);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0;const pending=new Map();
  socket.addEventListener('message',event=>{const r=JSON.parse(event.data),p=pending.get(r.id);if(p){pending.delete(r.id);r.error?p.reject(new Error(r.error.message)):p.resolve(r.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const page=(method,params)=>send(method,params,sessionId);
  evaluate=async expression=>{const r=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
  await page('Runtime.enable');await page('Page.enable');await page('Page.navigate',{url:base+'/app/'});
  await poll(()=>evaluate("typeof fixture==='object'"),Boolean,15000);
  await evaluate(`fixture.configure(${JSON.stringify(web)},${JSON.stringify([win.device.deviceId])})`);
  const devices=[{deviceId:web.device.deviceId,online:true,platform:'web',rtc:{scopes:['lan','public']}}];
  await control('/presence',{online:true,foreground:true,devices});
  pump=setInterval(()=>{if(forward){void control('/refresh',{}).catch(()=>{});void evaluate('void fixture.refresh()').catch(()=>{});}},700);
  const success=await poll(async()=>({native:await control('/state'),web:await evaluate('fixture.state()')}),v=>v.native.results.some(r=>r.scope==='lan'&&r.success)&&v.web.results.some(r=>r.scope==='lan'&&r.success),30000);
  assert.ok(success.native.created>=1);assert.ok(success.web.created>=1);
  console.log('Real LAN nonce/echo PASS',JSON.stringify(success));
  // Finish/close the diagnostic public phase too; no persistent idle PC.
  const settled=await poll(async()=>({native:await control('/state'),web:await evaluate('fixture.state()')}),v=>!v.native.session&&v.native.created===v.native.closed&&v.web.created===v.web.closed,30000);
  assert.ok(settled.native.channelsClosed>=1);
  // A fresh foreground network epoch creates a new real PC. Withhold the
  // browser notification so Windows remains negotiating, then hide it.
  let hidden,offline;
  if(!webInitiates){
  forward=false;
  await control('/invalidate',{});
  const active=await poll(()=>control('/state'),v=>v.created>v.closed,10000);
  await control('/presence',{online:true,foreground:false,devices});
  hidden=await poll(()=>control('/state'),v=>!v.active&&!v.session&&v.created===v.closed,10000);
  assert.deepEqual(hidden.results,[]);
  const hiddenCenter=await call('/devices/me/rtc-probes',undefined,win.deviceToken);
  assert.equal(hiddenCenter.presence.foreground,false);assert.deepEqual(hiddenCenter.probes,[]);assert.deepEqual(hiddenCenter.results,[]);
  console.log('Foreground=false cancels and releases pending PC PASS');
  await control('/presence',{online:true,foreground:true,devices});
  await poll(()=>control('/state'),v=>v.created>v.closed,10000);
  sockets[0].terminate();
  await control('/presence',{online:false,foreground:true,devices:[]});
  offline=await poll(()=>control('/state'),v=>!v.active&&!v.session&&v.created===v.closed,10000);
  await poll(()=>call('/devices/me/rtc-probes',undefined,web.deviceToken),v=>v.probes.length===0&&v.results.length===0,10000);
  }
  assert.deepEqual(await call('/transfers',undefined,web.deviceToken),beforeTransfers);
  assert.deepEqual(await call('/events',undefined,win.deviceToken),beforeEvents);
  assert.deepEqual(await readdir(join(run,'relay')),[]);
  const evidence={scope:'actual Windows/browser LAN host candidates',initiator:webInitiates?'browser':'windows',nonceEcho:true,noExternalIce:true,foregroundCancelled:!webInitiates,offlineCancelled:!webInitiates,transferSideEffects:0,fileRelayBytes:0,settled,hidden,offline};
  await writeFile(join(run,'result.json'),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify({passed:true,evidence:join(run,'result.json')}));
  await evaluate('fixture.close()');
}finally{
  clearInterval(pump);if(nativeUrl)await control('/shutdown',{}).catch(()=>{});socket?.close();await closeSharedBrowser(browser);if(native.exitCode===null)native.kill();for(const ws of sockets)ws.terminate();await app.close();
}
