import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import assert from 'node:assert/strict';

// A hidden, synthetic interop check. No product instance, device, media track,
// user browser profile, external STUN server or firewall setting is used.
const root = fileURLToPath(new URL('../../', import.meta.url));
const parent = join(root, 'artifacts/tmp/rtc-native-probe');
await mkdir(parent, { recursive: true });
const run = await mkdtemp(join(parent, 'run-'));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const executable = join(root, 'client/build/rtc-probe/build/windows/x64/runner/Release/rtc_probe.exe');
const native = spawn(executable, [run], { cwd: join(executable, '..'), windowsHide: true, stdio: 'ignore' });
let nativeFailure;
native.on('error', error => { nativeFailure=error; });
let browser, socket, server, nativeUrl;
try {
  for (let i=0;i<150 && !nativeUrl;i++) {
    if(nativeFailure)throw nativeFailure;
    try { nativeUrl=JSON.parse(await readFile(join(run,'control.json'),'utf8')).url; }
    catch { if(native.exitCode!==null)throw new Error(`Native probe exited: ${await readFile(join(run,'startup-error.txt'),'utf8').catch(()=>native.exitCode)}`);await delay(100); }
  }
  assert.ok(nativeUrl,'native data-channel factory did not become ready');
  const html=`<!doctype html><html><meta charset="utf-8"><script>
  window.runProbe=async()=>{
    const native=(path,body)=>fetch('/native'+path,body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:{}).then(async r=>{const data=await r.json();if(!r.ok)throw new Error(JSON.stringify(data));return data;});
    const pc=new RTCPeerConnection({iceServers:[]});
    const dc=pc.createDataChannel('globalsend-probe',{ordered:true});dc.binaryType='arraybuffer';
    const local=[],errors=[];let nativeReady=false,remoteCount=0,echoed=0,text='',opened=false;
    pc.onicecandidate=e=>{if(e.candidate){local.push(e.candidate.toJSON());if(nativeReady)void native('/candidate',e.candidate.toJSON()).catch(e=>errors.push(String(e)));}};
    dc.onopen=()=>opened=true;
    dc.onmessage=e=>{if(typeof e.data==='string'){text=e.data;return;}const bytes=new Uint8Array(e.data);for(let i=0;i<bytes.length;i++)if(bytes[i]!==((echoed+i)%251)){errors.push('Echo byte mismatch');break;}echoed+=bytes.length;};
    const offer=await pc.createOffer();await pc.setLocalDescription(offer);
    const answer=await native('/offer',{sdp:offer.sdp,type:offer.type});await pc.setRemoteDescription(answer);
    for(const candidate of local)await native('/candidate',candidate);nativeReady=true;
    // Let native ICE initiate checks before delivering its candidates back.
    await new Promise(resolve=>setTimeout(resolve,200));
    const deadline=Date.now()+20000;
    while(!opened && Date.now()<deadline){
      const state=await native('/state');for(const candidate of state.candidates.slice(remoteCount))await pc.addIceCandidate(candidate);remoteCount=state.candidates.length;
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    if(!opened)throw new Error('Data channel did not open: '+JSON.stringify({connection:pc.connectionState,ice:pc.iceConnectionState,local:local.map(c=>c.candidate.split(' ')[7]),remoteCount,native:await native('/state')}));
    const greeting='浏览器 ↔ Windows：仅数据通道';dc.send(greeting);
    const total=262157;
    for(let offset=0;offset<total;offset+=16384){const bytes=new Uint8Array(Math.min(16384,total-offset));for(let i=0;i<bytes.length;i++)bytes[i]=(offset+i)%251;dc.send(bytes);}
    const end=Date.now()+15000;while((echoed!==total || text!=='native:'+greeting) && Date.now()<end)await new Promise(resolve=>setTimeout(resolve,20));
    const state=await native('/state'),stats=await pc.getStats();let selected;
    for(const report of stats.values())if(report.type==='transport' && report.selectedCandidatePairId)selected=stats.get(report.selectedCandidatePairId);
    if(!selected)for(const report of stats.values())if(report.type==='candidate-pair' && report.nominated && report.state==='succeeded')selected=report;
    const localCandidate=selected&&stats.get(selected.localCandidateId),remoteCandidate=selected&&stats.get(selected.remoteCandidateId);
    const result={sentBytes:total,echoedBytes:echoed,nativeReceivedBytes:state.receivedBytes,textRoundTrip:text==='native:'+greeting,
      errors:[...errors,...state.errors],connection:pc.connectionState,localCandidateType:localCandidate?.candidateType,remoteCandidateType:remoteCandidate?.candidateType,
      protocol:localCandidate?.protocol,mediaTracks:pc.getSenders().filter(s=>s.track).length};
    dc.close();pc.close();return result;
  };
  </script></html>`;
  server=createServer(async(req,res)=>{
    try {
      if(req.url.startsWith('/native/')){
        const chunks=[];for await(const chunk of req)chunks.push(chunk);
        const response=await fetch(nativeUrl+req.url.slice(7),{method:req.method,...(req.method==='POST'?{headers:{'Content-Type':'application/json'},body:Buffer.concat(chunks)}:{})});
        res.statusCode=response.status;res.setHeader('Content-Type','application/json');res.end(await response.text());
      } else {res.setHeader('Content-Type','text/html; charset=utf-8');res.end(html);}
    } catch(error){res.statusCode=500;res.end(JSON.stringify({error:String(error)}));}
  });
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const profile=sharedBrowserProfile;
  browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER||'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    ['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update',
      '--disable-extensions','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
  let browserFailure;browser.on('error',e=>{browserFailure=e;});
  let address;for(let i=0;i<150 && !address;i++){if(browserFailure)throw browserFailure;try{address=(await readFile(join(profile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{await delay(100);}}
  assert.ok(address,'isolated browser did not start');
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let id=0;const pending=new Map();
  socket.addEventListener('message',e=>{const r=JSON.parse(e.data),p=pending.get(r.id);if(p){pending.delete(r.id);r.error?p.reject(new Error(r.error.message)):p.resolve(r.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});socket.send(JSON.stringify({id:n,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const page=(method,params)=>send(method,params,sessionId);
  const evaluate=async(expression)=>{const r=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
  await page('Runtime.enable');await page('Page.enable');
  await page('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`});
  for(let i=0;i<100;i++){if(await evaluate("typeof runProbe==='function'"))break;await delay(50);}
  const result=await evaluate('runProbe()');
  await writeFile(join(run,'result.json'),JSON.stringify(result,null,2));
  assert.equal(result.echoedBytes,result.sentBytes);assert.equal(result.nativeReceivedBytes,result.sentBytes);
  assert.equal(result.textRoundTrip,true);assert.deepEqual(result.errors,[]);assert.equal(result.mediaTracks,0);
  assert.equal(result.localCandidateType,'host');assert.equal(result.remoteCandidateType,'host');
  console.log(JSON.stringify({result,evidence:join(run,'result.json')}));
  
} finally {
  if(nativeUrl)await fetch(nativeUrl+'/close',{method:'POST',body:'{}'}).catch(()=>{});
  socket?.close();await closeSharedBrowser(browser);
  await delay(300);if(native.exitCode===null)native.kill();
  if(server)await new Promise(resolve=>server.close(resolve));
}
