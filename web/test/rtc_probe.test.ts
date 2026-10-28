import test from 'node:test';
import assert from 'node:assert/strict';
import { RtcProbeSession, RtcProbeMonitor, RTC_PROBE_LABEL, probeNonce, probeInitiator, probeScopes, probeResultLabel, latestProbeAt } from '../src/rtc_probe.ts';
import type { RtcProbeView, RtcProbeResult } from '../../packages/protocol/src/index.ts';

const delay=(ms:number)=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(condition:()=>boolean){for(let i=0;i<100;i++){if(condition())return;await delay(5);}throw new Error('Probe fixture timed out');}
const sdp='v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=candidate:1 1 udp 10 123.1.2.3 5000 typ host\r\na=end-of-candidates\r\n';
const candidate=(address:string,kind='host')=>({candidate:`candidate:1 1 udp 10 ${address} 5000 typ ${kind}`,sdpMid:'0',sdpMLineIndex:0});
function view(scope:'lan'|'public'='lan',expires=Date.now()+2000):RtcProbeView {return {attemptId:'attempt',initiatorDeviceId:'a',responderDeviceId:'b',scope,expiresAt:new Date(expires).toISOString(),offer:{type:'offer',sdp},answer:{type:'answer',sdp},candidates:{initiator:[],responder:[]}};}
function result(probe:RtcProbeView,success=true):RtcProbeResult {return {attemptId:probe.attemptId,initiatorDeviceId:probe.initiatorDeviceId,responderDeviceId:probe.responderDeviceId,scope:probe.scope,success,elapsedMs:success?3:null,checkedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+120000).toISOString(),...(!success?{error:'PROBE_TIMEOUT'}:{})};}
test('probe scheduling uses one initiator, fixed scope priority and expiring route-only status',()=>{
  assert.equal(probeNonce({getRandomValues(bytes:any){bytes.fill(17);return bytes;}}),'11'.repeat(16));
  assert.equal(probeInitiator('a','b'),true);assert.equal(probeInitiator('b','a'),false);assert.equal(probeInitiator('a','a'),false);
  assert.deepEqual(probeScopes(['public','lan']),['lan','public']);assert.deepEqual(probeScopes(['public']),['public']);
  const lan=result(view()),publicResult=result(view('public'));
  assert.equal(probeResultLabel([publicResult,lan],'b','a'),'RTC 局域网 · 3 ms');
  assert.equal(probeResultLabel([publicResult],'b','a'),'RTC 公网 · 3 ms');
  assert.equal(probeResultLabel([{...lan,success:false}],'b','a'),'RTC 暂不可达');
  assert.equal(probeResultLabel([{...lan,expiresAt:new Date(0).toISOString()}],'b','a'),'');
  assert.equal(latestProbeAt([lan],'b','a'),Date.parse(lan.checkedAt));
});

class Channel {
  label=RTC_PROBE_LABEL;readyState='connecting';bufferedAmount=0;
  onopen:(()=>void)|null=null;onclose:(()=>void)|null=null;onerror:(()=>void)|null=null;onmessage:((event:{data:any})=>void)|null=null;
  sent:string[]=[];sending:(data:string)=>void=()=>{};
  send(data:string){this.sent.push(data);this.sending(data);}
  message(data:string){this.onmessage?.({data});}
  open(){this.readyState='open';this.onopen?.();}
  close(){this.readyState='closed';this.onclose?.();}
}
function peerFixture(initiator:boolean,options:{wrongNonce?:boolean;neverOpen?:boolean}={}) {
  const original=globalThis.RTCPeerConnection,channel=new Channel(),peers:any[]=[],configurations:any[]=[];
  channel.sending=raw=>{
    const message=JSON.parse(raw);
    if(initiator)queueMicrotask(()=>channel.message(JSON.stringify({type:'echo',nonce:options.wrongNonce?'0'.repeat(32):message.nonce})));
    else queueMicrotask(()=>channel.close());
  };
  class Peer {
    connectionState='new';onicecandidate:any;onconnectionstatechange:any;ondatachannel:any;closed=false;
    constructor(configuration:any){configurations.push(configuration);peers.push(this);}
    createDataChannel(label:string){assert.equal(label,RTC_PROBE_LABEL);return channel;}
    async createOffer(){return {type:'offer',sdp};}
    async createAnswer(){return {type:'answer',sdp};}
    async setLocalDescription(){
      for(const value of [candidate('192.168.1.3'),candidate('123.1.2.3'),candidate('123.1.2.3','relay')])this.onicecandidate?.({candidate:{toJSON:()=>({...value,usernameFragment:'not-in-schema'})}});
      if(!initiator && !options.neverOpen)queueMicrotask(()=>{channel.open();channel.message(JSON.stringify({type:'ping',nonce:'1'.repeat(32)}));});
    }
    async setRemoteDescription(description:any){assert.equal(description.sdp.includes('a=candidate:'),false);if(!initiator)this.ondatachannel?.({channel});else if(!options.neverOpen)channel.open();}
    async addIceCandidate(){}
    close(){this.closed=true;this.connectionState='closed';this.onconnectionstatechange?.();}
  }
  globalThis.RTCPeerConnection=Peer as unknown as typeof RTCPeerConnection;
  return {channel,peers,configurations,restore:()=>{globalThis.RTCPeerConnection=original;}};
}
function sessionApi(probe:RtcProbeView) {
  const calls:{path:string;body:any}[]=[];
  return {calls,api:{request:async(path:string,body:any)=>{
    calls.push({path,body});
    if(path.endsWith('/complete'))return {result:result(probe)};
    if(path.endsWith('/fail'))return {result:result(probe,false)};
    return {probe};
  }}};
}
test('initiator probes one nonce only, filters ICE and closes without file or external ICE traffic',async()=>{
  const peer=peerFixture(true),probe=view(),{api,calls}=sessionApi(probe),session=new RtcProbeSession(api as any,probe,'a',new AbortController().signal);
  try {
    const checked=await session.run();assert.equal(checked?.success,true);assert.equal(peer.channel.sent.length,1);
    const ping=JSON.parse(peer.channel.sent[0]);assert.equal(ping.type,'ping');assert.match(ping.nonce,/^[a-f0-9]{32}$/);assert.ok(peer.channel.sent[0].length<100);
    assert.deepEqual(peer.configurations,[{iceServers:[]}]);assert.equal(peer.peers[0].closed,true);
    const candidates=calls.filter(call=>call.path.endsWith('/candidate'));
    assert.equal(candidates.length,1);assert.equal(candidates[0].body.candidate.includes('192.168.1.3'),true);assert.deepEqual(Object.keys(candidates[0].body),['candidate','sdpMid','sdpMLineIndex']);
    assert.equal(calls.find(call=>call.path.endsWith('/description'))!.body.sdp.includes('a=candidate:'),false);
    assert.equal(calls.some(call=>/transfers|files|downloads/.test(call.path)),false);
  }finally{session.close();peer.restore();}
});
test('responder echoes exactly the received nonce and never reports initiator completion',async()=>{
  const peer=peerFixture(false),probe=view(),{api,calls}=sessionApi(probe),session=new RtcProbeSession(api as any,probe,'b',new AbortController().signal);
  try {
    assert.equal(await session.run(),null);assert.equal(peer.channel.sent.length,1);assert.deepEqual(JSON.parse(peer.channel.sent[0]),{type:'echo',nonce:'1'.repeat(32)});
    assert.equal(calls.some(call=>call.path.endsWith('/complete') || call.path.endsWith('/fail')),false);assert.equal(peer.peers[0].closed,true);
  }finally{session.close();peer.restore();}
});
test('nonce mismatch records failure and a short deadline closes the peer connection',async()=>{
  for(const options of [{wrongNonce:true},{neverOpen:true}]) {
    const peer=peerFixture(true,options),probe=view('lan',Date.now()+(options.neverOpen?35:2000)),{api,calls}=sessionApi(probe),session=new RtcProbeSession(api as any,probe,'a',new AbortController().signal);
    try{assert.equal((await session.run())?.success,false);assert.equal(calls.some(call=>call.path.endsWith('/fail')),true);assert.equal(peer.peers[0].closed,true);}
    finally{session.close();peer.restore();}
  }
});
test('hiding aborts a pending signaling request immediately rather than waiting for its timeout',async()=>{
  const peer=peerFixture(true),abort=new AbortController();let pending=false,requestAborted=false;
  const api={request:async(_path:string,_body:any,_method:string,signal:AbortSignal)=>{pending=true;return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>{requestAborted=true;reject(new DOMException('Stopped','AbortError'));},{once:true}));}};
  const session=new RtcProbeSession(api as any,view(),'a',abort.signal),running=session.run();
  try{await until(()=>pending);abort.abort();assert.equal(peer.peers[0].closed,true);assert.equal(await running,null);assert.equal(requestAborted,true);}
  finally{session.close();peer.restore();}
});

test('negotiated parallel monitor checks both scopes and multiple peers while LAN remains stalled',async()=>{
  const probes=new Map<string,RtcProbeView>(),results:RtcProbeResult[]=[],started:string[]=[],closed:string[]=[];
  const blocked=new Map<string,()=>void>();
  const api={request:async(path:string,body:any)=>{
    if(path.endsWith('/presence')){if(!body.foreground){probes.clear();results.length=0;}return {};}
    if(path==='/devices/me/rtc-probes')return {presence:{foreground:true,expiresAt:new Date(Date.now()+40000).toISOString()},
      peers:['b','c'].map(deviceId=>({deviceId,scopes:['lan','public'],parallelProbes:true,foregroundExpiresAt:new Date(Date.now()+40000).toISOString()})),probes:[...probes.values()],results:[...results]};
    if(path.startsWith('/devices/')){const probe={...view(body.scope),attemptId:body.attemptId,initiatorDeviceId:'a',responderDeviceId:path.split('/')[2]};probes.set(probe.attemptId,probe);return {probe};}
    if(path.startsWith('/rtc-probes/'))probes.delete(path.split('/')[2]);return {};
  }};
  const monitor=new RtcProbeMonitor({api:api as any,deviceId:'a',parallel:true,changed:()=>{},session:(probe,signal)=>({
    active:true,refresh:async()=>{},close:()=>{closed.push(probe.attemptId);},run:async()=>{
      started.push(probe.responderDeviceId+'/'+probe.scope);
      if(probe.scope==='lan')await new Promise<void>(resolve=>{blocked.set(probe.attemptId,resolve);signal.addEventListener('abort',()=>resolve(),{once:true});});
      if(signal.aborted)return null;
      const value=result(probe);probes.delete(probe.attemptId);results.push(value);return value;
    },
  })});
  monitor.setOnlinePeers(['b','c']);
  try{
    await monitor.setForeground(true);
    await until(()=>results.length===2);
    assert.deepEqual(new Set(started),new Set(['b/lan','b/public','c/lan','c/public']));
    assert.equal([...probes.values()].filter(probe=>probe.scope==='lan').length,2);
    assert.ok(results.every(value=>value.scope==='public'),'public succeeds while both LAN sessions are pending');
    assert.equal(monitor.status('b'),'RTC 检测中');
    for(const resume of blocked.values())resume();
    await until(()=>monitor.results.length===4);
    assert.equal(started.length,4,'completed scopes do not immediately repeat');
    await monitor.refreshAllPeers();await until(()=>started.length===8);
    await monitor.setForeground(false);await delay(10);
    assert.equal(monitor.results.length,0);assert.ok(closed.length>=8);
  }finally{for(const resume of blocked.values())resume();await monitor.dispose();}
});

test('parallel coordinator keeps a legacy peer serial and stops all concurrent peers on background',async()=>{
  const probes=new Map<string,RtcProbeView>(),results:RtcProbeResult[]=[],started:string[]=[],resume=new Map<string,()=>void>();
  const api={request:async(path:string,body:any)=>{
    if(path.endsWith('/presence'))return {};
    if(path==='/devices/me/rtc-probes')return {peers:[{deviceId:'b',scopes:['lan','public'],foregroundExpiresAt:new Date(Date.now()+40000).toISOString()}],probes:[...probes.values()],results:[...results]};
    const probe={...view(body.scope),attemptId:body.attemptId,initiatorDeviceId:'a',responderDeviceId:'b'};probes.set(probe.attemptId,probe);return {probe};
  }};
  const monitor=new RtcProbeMonitor({api:api as any,deviceId:'a',parallel:true,changed:()=>{},session:(probe,signal)=>({active:true,refresh:async()=>{},close:()=>{},run:async()=>{
    started.push(probe.scope);await new Promise<void>(resolve=>{resume.set(probe.scope,resolve);signal.addEventListener('abort',()=>resolve(),{once:true});});
    if(signal.aborted)return null;const value=result(probe);probes.delete(probe.attemptId);results.push(value);return value;
  }})});
  monitor.setOnlinePeers(['b']);
  try{await monitor.setForeground(true);await until(()=>started.length===1);assert.deepEqual(started,['lan']);
    resume.get('lan')!();await until(()=>started.length===2);assert.deepEqual(started,['lan','public']);
    await monitor.setForeground(false);await delay(10);assert.equal(monitor.results.length,0);
  }finally{for(const done of resume.values())done();await monitor.dispose();}
});

function monitorApi(self='a',other='b') {
  const calls:{path:string;body:any}[]=[],scopes:string[]=[];
  let results:RtcProbeResult[]=[];
  const api={request:async(path:string,body:any)=>{
    calls.push({path,body});
    if(path.endsWith('/presence')){if(!body.foreground)results=[];return {presence:{foreground:body.foreground,expiresAt:new Date(Date.now()+40000).toISOString()}};}
    if(path==='/devices/me/rtc-probes')return {presence:{foreground:true,expiresAt:new Date(Date.now()+40000).toISOString()},peers:[{deviceId:other,scopes:['public','lan'],foregroundExpiresAt:new Date(Date.now()+40000).toISOString()}],probes:[],results};
    if(path.startsWith('/devices/')){scopes.push(body.scope);return {probe:{...view(body.scope),attemptId:body.attemptId,initiatorDeviceId:self,responderDeviceId:other}};}
    return {};
  }};
  return {api,calls,scopes,save:(value:RtcProbeResult)=>{results=results.filter(old=>old.scope!==value.scope);results.push(value);}};
}
test('foreground monitor tries LAN before public once per pair and renews its presence without repeating the cycle',async()=>{
  const server=monitorApi();let concurrent=0,maxConcurrent=0;
  const monitor=new RtcProbeMonitor({api:server.api as any,deviceId:'a',changed:()=>{},session:probe=>({active:true,refresh:async()=>{},close:()=>{},run:async()=>{concurrent++;maxConcurrent=Math.max(maxConcurrent,concurrent);await delay(5);concurrent--;const value=result(probe,probe.scope==='public');server.save(value);return value;}})});
  monitor.setOnlinePeers(['b']);
  try {
    await monitor.setForeground(true);await until(()=>server.scopes.length===2 && monitor.results.some(value=>value.success));
    assert.deepEqual(server.scopes,['lan','public']);assert.equal(maxConcurrent,1);assert.equal(monitor.status('b'),'RTC 公网 · 3 ms');
    await monitor.tick();await monitor.refresh();assert.deepEqual(server.scopes,['lan','public']);assert.ok(server.calls.filter(call=>call.path.endsWith('/presence') && call.body.foreground).length>=2);
    await monitor.setForeground(false);assert.equal(monitor.status('b'),'');assert.equal(monitor.results.length,0);assert.equal(server.calls.at(-1)!.body.foreground,false);
  }finally{await monitor.dispose();}
});
test('larger device ID does not initiate and backgrounding stops the active scope without trying public',async()=>{
  const larger=monitorApi('z','a'),quiet=new RtcProbeMonitor({api:larger.api as any,deviceId:'z',changed:()=>{}});quiet.setOnlinePeers(['a']);
  try{await quiet.setForeground(true);await delay(10);assert.equal(larger.scopes.length,0);}finally{await quiet.dispose();}
  const server=monitorApi();let closed=0,started=false;
  const monitor=new RtcProbeMonitor({api:server.api as any,deviceId:'a',changed:()=>{},session:(_probe,signal)=>({active:true,refresh:async()=>{},close:()=>{closed++;},run:async()=>{started=true;return new Promise(resolve=>signal.addEventListener('abort',()=>resolve(null),{once:true}));}})});monitor.setOnlinePeers(['b']);
  try{await monitor.setForeground(true);await until(()=>started);await monitor.setForeground(false);await delay(5);assert.ok(closed>0);assert.deepEqual(server.scopes,['lan']);assert.equal(monitor.status('b'),'');}
  finally{await monitor.dispose();}
});
test('network changes invalidate cached results and publish background before a fresh foreground lease',async()=>{
  const server=monitorApi();
  const monitor=new RtcProbeMonitor({api:server.api as any,deviceId:'a',changed:()=>{},session:probe=>({active:true,refresh:async()=>{},close:()=>{},run:async()=>{const value=result(probe);server.save(value);return value;}})});monitor.setOnlinePeers(['b']);
  try {
    await monitor.setForeground(true);await until(()=>monitor.results.length===1);const count=server.calls.length;
    await monitor.networkChanged();await until(()=>server.scopes.length===2);
    assert.deepEqual(server.calls.slice(count).filter(call=>call.path.endsWith('/presence')).map(call=>call.body.foreground),[false,true]);
    monitor.removePeer('b');assert.equal(monitor.status('b'),'');assert.equal(monitor.results.length,0);
  }finally{await monitor.dispose();}
});

test('manual target refresh tests both scopes despite a fresh successful LAN cache',async()=>{
  const server=monitorApi();
  const monitor=new RtcProbeMonitor({api:server.api as any,deviceId:'a',changed:()=>{},session:probe=>({active:true,refresh:async()=>{},close:()=>{},run:async()=>{const value=result(probe);server.save(value);return value;}})});
  monitor.setOnlinePeers(['b']);
  try {
    await monitor.setForeground(true);await until(()=>monitor.results.length===1);
    await monitor.refreshPeer('b');await until(()=>monitor.results.some(value=>value.scope==='public' && value.success));
    assert.deepEqual(server.scopes,['lan','lan','public']);
    assert.ok(monitor.results.some(value=>value.scope==='public' && value.success));
  }finally{await monitor.dispose();}
});
test('a peer appearing after a signaling notification is consumed immediately, not after the next heartbeat',async()=>{
  const server=monitorApi();let started=0;
  const monitor=new RtcProbeMonitor({api:server.api as any,deviceId:'a',changed:()=>{},session:probe=>({active:true,refresh:async()=>{},close:()=>{},run:async()=>{started++;const value=result(probe);server.save(value);return value;}})});
  try{await monitor.setForeground(true);assert.equal(started,0);monitor.setOnlinePeers(['b']);await until(()=>started===1);assert.deepEqual(server.scopes,['lan']);}
  finally{await monitor.dispose();}
});


test('RTC endpoint diagnostics use the selected candidate pair and orient source toward the current device',async()=>{
  const {selectedProbeAddresses,orientedProbeAddresses}=await import('../src/rtc_probe.ts');
  const report=new Map([
    ['transport',{id:'transport',type:'transport',selectedCandidatePairId:'pair'}],
    ['pair',{id:'pair',type:'candidate-pair',state:'succeeded',localCandidateId:'local',remoteCandidateId:'remote'}],
    ['local',{id:'local',type:'local-candidate',address:'2408::1234',port:54321}],
    ['remote',{id:'remote',type:'remote-candidate',ip:'10.2.3.4',port:23456}],
    ['unused',{id:'unused',type:'candidate-pair',state:'in-progress',nominated:true,localCandidateId:'remote',remoteCandidateId:'local'}],
  ]);
  const addresses=selectedProbeAddresses(report);assert.deepEqual(addresses,{initiatorAddress:'[2408::1234]:54321',responderAddress:'10.2.3.4:23456'});
  const result={...addresses,initiatorDeviceId:'a'};
  assert.deepEqual(orientedProbeAddresses(result,'a'),{source:'[2408::1234]:54321',target:'10.2.3.4:23456'});
  assert.deepEqual(orientedProbeAddresses(result,'b'),{source:'10.2.3.4:23456',target:'[2408::1234]:54321'});
  assert.deepEqual(selectedProbeAddresses(new Map([['pair',{type:'candidate-pair',state:'failed',nominated:true}]])),{});
  assert.deepEqual(selectedProbeAddresses(new Map([['pair',{type:'candidate-pair',state:'succeeded',selected:true,localCandidateId:'redacted'}]])),{initiatorAddress:undefined,responderAddress:undefined});
});


test('RTC completion reports selected endpoint stats only when the center advertises the address contract',async()=>{
 for(const enabled of [false,true]){
  const peer=peerFixture(true),probe=view(),{api,calls}=sessionApi(probe),session=new RtcProbeSession(api as any,probe,'a',new AbortController().signal,enabled);let statsReads=0;
  peer.peers[0].getStats=async()=>{statsReads++;return new Map([
   ['pair',{id:'pair',type:'candidate-pair',state:'succeeded',selected:true,localCandidateId:'local',remoteCandidateId:'remote'}],
   ['local',{id:'local',type:'local-candidate',address:'10.1.1.1',port:123}],['remote',{id:'remote',type:'remote-candidate',address:'2408::2',port:456}],
  ]);};
  try{assert.equal((await session.run())?.success,true);const body=calls.find(call=>call.path.endsWith('/complete'))!.body;
   assert.equal(statsReads,enabled?1:0);if(enabled){assert.equal(body.initiatorAddress,'10.1.1.1:123');assert.equal(body.responderAddress,'[2408::2]:456');}else assert.deepEqual(Object.keys(body),['elapsedMs']);
  }finally{session.close();peer.restore();}
 }
});


test('RTC endpoint fallback never guesses among several successful nominated or selected pairs',async()=>{
 const {selectedProbeAddresses}=await import('../src/rtc_probe.ts');
 const endpoints=[{id:'local',type:'local-candidate',address:'10.1.1.1',port:123},{id:'remote',type:'remote-candidate',address:'10.2.2.2',port:456}];
 const first={id:'first',type:'candidate-pair',state:'succeeded',nominated:true,localCandidateId:'local',remoteCandidateId:'remote',timestamp:1};
 const second={...first,id:'second',localCandidateId:'remote',remoteCandidateId:'local',timestamp:999};
 const report=(pairs:any[])=>new Map([...endpoints,...pairs].map(value=>[value.id,value]));
 assert.deepEqual(selectedProbeAddresses(report([first,second])),{},'a newer nomination is not evidence of the used route');
 assert.deepEqual(selectedProbeAddresses(report([{...first,selected:true},{...second,selected:true}])),{},'several selected flags are ambiguous');
 assert.deepEqual(selectedProbeAddresses(report([{...first,selected:true},second])),{initiatorAddress:'10.1.1.1:123',responderAddress:'10.2.2.2:456'},'one explicit selected flag wins over other nominations');
 assert.deepEqual(selectedProbeAddresses(report([first])),{initiatorAddress:'10.1.1.1:123',responderAddress:'10.2.2.2:456'},'a single successful nomination remains usable');
});
