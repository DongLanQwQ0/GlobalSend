import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile, readdir, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { buildApp } from '../../server/src/server.ts';

// Actual production transports + local center; no product process, current tab,
// phone, user data, global firewall/network change or external STUN/TURN.
const root=fileURLToPath(new URL('../../',import.meta.url));
const temporary=join(root,'artifacts/tmp/rtc-production-interop');
await mkdir(temporary,{recursive:true});
const run=await mkdtemp(join(temporary,'run-'));
const require=createRequire(new URL('../package.json',import.meta.url));
const ControlSocket=createRequire(new URL('../../server/package.json',import.meta.url))('ws');
const {build}=await import(pathToFileURL(require.resolve('vite')).href);
const site=join(run,'site');
await build({configFile:false,root:join(root,'web'),base:'/app/',logLevel:'warn',
  build:{outDir:site,emptyOutDir:true,rollupOptions:{input:join(root,'web/tool/rtc_native_fixture.html')}}});
await writeFile(join(site,'index.html'),await readFile(join(site,'tool/rtc_native_fixture.html')));
const app=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,production:false,diskReserve:0,log:false});
await app.listen({host:'127.0.0.1',port:0});
const base=`http://127.0.0.1:${app.server.address().port}`;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const executable=join(root,'client/build/rtc-transfer-probe/build/windows/x64/runner/Release/rtc_transfer_probe.exe');
const externalNative=process.env.GLOBALSEND_RTC_NATIVE_URL;
const native=externalNative?null:spawn(executable,[run],{cwd:dirname(executable),windowsHide:true,stdio:'ignore'});
let nativeFailure;native?.on('error',error=>{nativeFailure=error;});
let browser,socket,nativeUrl=externalNative,evaluate,page;const controlSockets=[];
const results=[],offered=[];
async function poll(action,predicate,timeout=45000) {
  const until=Date.now()+timeout;let value;
  while(Date.now()<until){value=await action();if(predicate(value))return value;await delay(100);}
  throw new Error('Fixture deadline: '+JSON.stringify(value));
}
async function call(path,body,token,method=body===undefined?'GET':'POST') {
  const response=await fetch(base+'/api/v1'+path,{method,headers:{...(token?{Authorization:'Bearer '+token}:{}),...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});
  const value=await response.json();if(!response.ok)throw new Error(`${path} ${response.status}: ${JSON.stringify(value)}`);return value;
}
async function control(path,body) {
  const response=await fetch(nativeUrl+path,body===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const value=await response.json();if(!response.ok)throw new Error('Native fixture: '+JSON.stringify(value));return value;
}
try {
  if(native)await poll(async()=>{
    if(nativeFailure)throw nativeFailure;
    try{return nativeUrl=JSON.parse(await readFile(join(run,'control.json'),'utf8')).url;}
    catch(error){if(native.exitCode!==null)throw new Error('Native fixture exited: '+await readFile(join(run,'startup-error.txt'),'utf8').catch(()=>native.exitCode));}
  },Boolean,20000);
  else await poll(()=>control('/state'),value=>value.state==='idle',20000);
  const key=randomUUID()+randomUUID();
  const win=await call('/devices/enroll',{name:externalNative?'synthetic Android JNI':'synthetic Windows',platform:externalNative?'android':'windows',groupKey:key});
  const web=await call('/devices/enroll',{name:'synthetic browser',platform:'web',groupKey:key});
  // Discovery now belongs only to online group members. Model each fixture's
  // normal control connection before advertising either transport capability.
  for(const device of [win,web]){
    const {ticket}=await call('/session/ws-ticket',{},device.deviceToken);
    const ws=new ControlSocket(base.replace('http:','ws:')+'/api/v1/ws?ticket='+ticket,{origin:base});
    const hello=new Promise((resolve,reject)=>{
      ws.on('message',data=>{if(JSON.parse(String(data)).type==='hello')resolve();});
      ws.once('error',reject);
    });
    controlSockets.push(ws);await hello;
  }
  await call('/devices/me/rtc',{scopes:['lan','public']},win.deviceToken);
  // Emulator guest reaches this host's random-port center through its alias.
  await control('/configure',{base:externalNative?base.replace('127.0.0.1','10.0.2.2'):base,token:win.deviceToken});
  const profile=sharedBrowserProfile;
  browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    ['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update',
      '--disable-extensions','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
  let browserFailure;browser.on('error',error=>{browserFailure=error;});
  const address=await poll(async()=>{
    if(browserFailure)throw browserFailure;
    try{return(await readFile(join(profile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}
  },Boolean,20000);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0;const pending=new Map();
  socket.addEventListener('message',event=>{const r=JSON.parse(event.data),p=pending.get(r.id);if(p){pending.delete(r.id);r.error?p.reject(new Error(r.error.message)):p.resolve(r.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  page=(method,params)=>send(method,params,sessionId);
  evaluate=async(expression)=>{
    const r=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
    if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;
  };
  await page('Runtime.enable');await page('Page.enable');
  await page('Page.navigate',{url:base+'/app/'});
  await poll(()=>evaluate("typeof fixture==='object'"),Boolean,15000);
  await evaluate(`fixture.configure(${JSON.stringify(web)})`);
  const size=process.argv.includes('--empty')?0:1048576+731,offset=size===0?0:12345;
  const bytes=Buffer.alloc(size);for(let i=0;i<size;i++)bytes[i]=i%251;
  const hash=createHash('sha256').update(bytes).digest('hex');
  const offer=async(source,target,name)=>{
    const transferId=randomUUID(),fileId=randomUUID();
    const {transfer}=await call('/transfers',{transferId,targetDeviceId:target.device.deviceId,routePreference:'lan',files:[{fileId,name,size,mimeType:'application/octet-stream',sha256:hash}]},source.deviceToken);
    const accepted=await call(`/transfers/${transferId}/accept`,{fileIds:[fileId]},target.deviceToken);
    offered.push({transferId,fileId,token:source.deviceToken});
    return accepted.transfer || transfer;
  };
  const terminal=async()=>{
    const [n,w]=await Promise.all([control('/state'),evaluate('fixture.state()')]);
    if(n.state==='failed' || w.state==='failed')throw new Error('Transport failed '+JSON.stringify({native:n,web:w}));
    return {native:n,web:w};
  };
  // Resume an existing native partial, not a second destination.
  await control('/prepare',{size,offset});
  const inbound=await offer(web,win,'browser-to-native.bin');
  const route=t=>`/transfers/${t.transferId}/files/${t.files[0].fileId}`;
  await control('/receive',{fileRoute:route(inbound),attemptId:randomUUID(),scope:'lan',size});
  const attempt=await poll(async()=>{
    const {transfer}=await call('/transfers/'+inbound.transferId,undefined,web.deviceToken);
    if(!transfer.files[0].rtc)return null;
    return(await call(`${route(inbound)}/rtc/${transfer.files[0].rtc.attemptId}`,undefined,web.deviceToken)).rtc;
  },Boolean);
  assert.equal(attempt.offset,offset);
  await evaluate(`fixture.send(${JSON.stringify(inbound)},${JSON.stringify(attempt)})`);
  const first=await poll(terminal,v=>v.native.state==='done'&&v.web.state==='done');
  if(externalNative)assert.equal(first.native.destinationHash,hash);
  else {const saved=await readFile(first.native.destination);assert.deepEqual(saved,bytes);}
  assert.equal(first.web.startedOffset,offset);assert.equal(first.native.progress,size);
  await call(route(inbound)+'/received',{transport:'direct'},win.deviceToken);
  results.push({direction:'browser-to-native',bytes:size,resumedOffset:offset,verified:true});
  // Reverse direction receives incrementally into the real OPFS worker.
  await control('/prepare',{size,offset:0});
  const outbound=await offer(win,web,'native-to-browser.bin');
  await evaluate(`fixture.receive(${JSON.stringify(outbound)},${offset})`);
  const reverse=await poll(async()=>{
    const {transfer}=await call('/transfers/'+outbound.transferId,undefined,win.deviceToken);
    if(!transfer.files[0].rtc)return null;
    return(await call(`${route(outbound)}/rtc/${transfer.files[0].rtc.attemptId}`,undefined,win.deviceToken)).rtc;
  },Boolean);
  assert.equal(reverse.offset,offset);
  await control('/send',{fileRoute:route(outbound),attempt:reverse,size});
  const second=await poll(terminal,v=>v.native.state==='done'&&v.web.state==='done');
  assert.equal(second.web.receivedHash,hash);assert.equal(second.web.progress,size);
  results.push({direction:'native-to-browser-opfs',bytes:size,resumedOffset:second.web.startedOffset,verified:true});
  for(const transfer of [inbound,outbound]) {
    const snapshot=(await call('/transfers/'+transfer.transferId,undefined,win.deviceToken)).transfer.files[0];
    assert.equal(snapshot.status,'received');assert.equal(snapshot.transport,'direct');assert.equal(snapshot.offset,0);
  }
  let relayBytes=0;for(const name of await readdir(join(run,'relay')))relayBytes+=(await stat(join(run,'relay',name))).size;
  assert.equal(relayBytes,0);
  await writeFile(join(run,'result.json'),JSON.stringify({results,relayBytes,nativePlatform:externalNative?'android-emulator-jni':'windows',externalIceServers:0,scope:externalNative?'emulated Android network to host browser':'actual local host candidates',dataOnlySdpEnforcedByCenter:true},null,2));
  console.log(JSON.stringify({results,relayBytes,evidence:join(run,'result.json')}));
  await evaluate('fixture.close()');
  
} catch(error) {
  const diagnostics=[];
  for(const item of offered){
    const snapshot=await call('/transfers/'+item.transferId,undefined,item.token).catch(()=>null);
    const file=snapshot?.transfer.files[0];
    const rtc=file?.rtc?await call(`/transfers/${item.transferId}/files/${item.fileId}/rtc/${file.rtc.attemptId}`,undefined,item.token).catch(()=>null):null;
    diagnostics.push({transferId:item.transferId,file,rtc});
  }
  await writeFile(join(run,'failure.json'),JSON.stringify({error:String(error),native:await control('/state').catch(()=>null),diagnostics},null,2));
  console.error('Failure evidence:',join(run,'failure.json'));
  throw error;
} finally {
  if(nativeUrl)await control('/close',{}).catch(()=>{});
  socket?.close();await closeSharedBrowser(browser);
  await delay(300);if(native?.exitCode===null)native.kill();
  for(const ws of controlSockets)ws.terminate();
  await app.close();
}
