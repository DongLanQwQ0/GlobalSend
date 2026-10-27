import test from 'node:test';
import assert from 'node:assert/strict';
import { candidateAllowed, stripIce, RtcFileChannel, signalingCandidate } from '../src/rtc.ts';
import type { RtcView } from '../src/rtc.ts';

const candidate=(address:string,kind='host')=>`candidate:1 1 udp 2122260223 ${address} 52112 typ ${kind} generation 0`;
test('browser ICE toJSON projects only the three center signaling fields',()=>{
  const value=signalingCandidate({candidate:candidate('192.168.1.3'),sdpMid:'0',sdpMLineIndex:0,usernameFragment:'browser-ufrag'});
  assert.deepEqual(Object.keys(value),['candidate','sdpMid','sdpMLineIndex']);
  assert.equal(value.sdpMLineIndex,0);
  assert.deepEqual(signalingCandidate({candidate:'candidate:1'}),{candidate:'candidate:1',sdpMid:null,sdpMLineIndex:null});
});
test('RTC keeps LAN candidates separate from public and TURN candidates',()=>{
  for(const address of ['192.168.1.3','10.1.2.3','172.16.8.9','fd23::45','fe80::27','unique-peer.local']) {
    assert.equal(candidateAllowed(candidate(address),'lan'),true,address);
    assert.equal(candidateAllowed(candidate(address),'public'),false,address);
  }
  for(const address of ['123.207.180.163','2408:1234:5678:abcd::2']) {
    assert.equal(candidateAllowed(candidate(address),'lan'),false,address);
    assert.equal(candidateAllowed(candidate(address),'public'),true,address);
    assert.equal(candidateAllowed(candidate(address,'relay'),'public'),false,address);
  }
  assert.equal(candidateAllowed(candidate('123.207.180.163','srflx'),'lan'),false);
  assert.equal(candidateAllowed(candidate('123.207.180.163','srflx'),'public'),true);
  assert.equal(candidateAllowed(candidate('0.0.0.0'),'public'),false);
  assert.equal(candidateAllowed(candidate('239.1.2.3'),'public'),false);
  assert.equal(candidateAllowed(candidate('not-an-address'),'lan'),false);
});
test('global IPv6 is a LAN candidate only on a matching local /64',()=>{
  const local=[candidate('2408:1234:5678:abcd::1')];
  assert.equal(candidateAllowed(candidate('2408:1234:5678:abcd::2'),'lan',local),true);
  assert.equal(candidateAllowed(candidate('2408:1234:5678:abce::2'),'lan',local),false);
  assert.equal(candidateAllowed(candidate('2408:1234:5678:abcd::1'),'lan',[],true),true);
  assert.equal(candidateAllowed(candidate('2408:1234:5678:abcd::2','srflx'),'lan',local),false);
});
test('deprecated site-local IPv6 remains LAN-only and multicast is not a connection candidate',()=>{
  for(const address of ['fec0::1','feff::12']) {
    assert.equal(candidateAllowed(candidate(address),'lan'),true,address);
    assert.equal(candidateAllowed(candidate(address),'public'),false,address);
  }
  assert.equal(candidateAllowed(candidate('ff02::1'),'lan'),false);
  assert.equal(candidateAllowed(candidate('ff02::1'),'public'),false);
});
test('SDP has no embedded candidates that could bypass the selected route',()=>{
  const sdp='v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=ice-ufrag:session\r\na=candidate:1 1 UDP 10 123.207.180.163 999 typ host\r\na=end-of-candidates\r\na=fingerprint:sha-256 ABC\r\n';
  const stripped=stripIce(sdp);
  assert.equal(stripped.includes('candidate:'),false);
  assert.equal(stripped.includes('end-of-candidates'),false);
  assert.ok(stripped.includes('a=ice-ufrag:session'));
  assert.ok(stripped.includes('a=fingerprint:sha-256 ABC'));
});

const delay=(ms:number)=>new Promise(resolve=>setTimeout(resolve,ms));
const view=(offset=0):RtcView=>({transferId:'t',fileId:'f',attemptId:'attempt',scope:'lan',offset,state:'negotiating',expiresAt:new Date(Date.now()+60000).toISOString(),sourceDeviceId:'source',targetDeviceId:'target',offer:{type:'offer',sdp:'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'},answer:{type:'answer',sdp:'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'},candidates:{source:[],target:[]}});

class Channel {
  label='globalsend-file-v1';readyState='open';binaryType='arraybuffer';bufferedAmount=0;bufferedAmountLowThreshold=0;
  onmessage:((event:{data:any})=>void)|null=null;onopen:(()=>void)|null=null;onclose:(()=>void)|null=null;onerror:(()=>void)|null=null;
  sent:((data:any)=>void)=()=>{};
  send(data:any){this.sent(data);}
  message(data:any){this.onmessage?.({data});}
  close(){this.readyState='closed';this.onclose?.();}
}
function installPeer(channel:Channel,source:boolean,onClose=()=>{}) {
  const original=globalThis.RTCPeerConnection;
  class Peer {
    connectionState='connected';onicecandidate:any;onconnectionstatechange:any;ondatachannel:any;
    createDataChannel(){return channel;}
    async createOffer(){return view().offer;}
    async createAnswer(){return view().answer;}
    async setLocalDescription(){}
    async setRemoteDescription(){if(source){this.ondatachannel({channel});queueMicrotask(()=>channel.message(JSON.stringify({type:'ready',offset:12345,size:1048599})));}else channel.onopen?.();}
    async addIceCandidate(){}
    close(){this.connectionState='closed';onClose();this.onconnectionstatechange?.();}
  }
  globalThis.RTCPeerConnection=Peer as unknown as typeof RTCPeerConnection;
  return ()=>{globalThis.RTCPeerConnection=original;};
}
test('RTC source resumes and never has more than 512 KiB of uncommitted bytes',async()=>{
  const data=Uint8Array.from({length:1048599},(_,index)=>index%251),file=new File([data],'source.bin');
  const channel=new Channel(),restore=installPeer(channel,true);
  let received=12345,committed=12345,maxUncommitted=0,finalProgress=0;
  channel.sent=data=>{
    if(typeof data==='string') {
      const end=JSON.parse(data);assert.equal(end.type,'end');assert.equal(received,file.size);
      channel.message(JSON.stringify({type:'complete',size:file.size}));return;
    }
    const bytes=new Uint8Array(data);assert.ok(bytes.length<=16384);
    for(let i=0;i<bytes.length;i++)assert.equal(bytes[i],(received+i)%251);
    received+=bytes.length;maxUncommitted=Math.max(maxUncommitted,received-committed);
    const offset=received;
    setTimeout(()=>{committed=offset;channel.message(JSON.stringify({type:'ack',offset}));},20);
  };
  const api={request:async()=>({rtc:view(12345)})};
  const transport=new RtcFileChannel(api as any,view(12345),'source',[],new AbortController().signal);
  try {
    await transport.send(file,offset=>{finalProgress=offset;});
    assert.equal(finalProgress,file.size);assert.equal(received,file.size);assert.equal(committed,file.size);
    assert.ok(maxUncommitted<=524288);assert.ok(maxUncommitted>16384,'window must not degrade into stop-and-wait');
  } finally {await transport.close();restore();}
});
test('cancel waits for the active disk write and does not write another queued RTC chunk',async()=>{
  const channel=new Channel(),restore=installPeer(channel,false),abort=new AbortController();
  let release:(()=>void)|undefined,writes=0,closed=false;
  const writeStarted=new Promise<void>(resolve=>{
    channel.sent=raw=>{if(JSON.parse(raw).type==='ready'){channel.message(new Uint8Array(16384).buffer);channel.message(new Uint8Array(16384).buffer);resolve();}};
  });
  const transport=new RtcFileChannel({request:async()=>({rtc:view()})} as any,view(),'target',[],abort.signal);
  const receiving=transport.receive(32768,async()=>{writes++;await new Promise<void>(resolve=>{release=resolve;});return 16384;},async()=>{}).then(()=>null,error=>error);
  try {
    await writeStarted;await delay(0);abort.abort();
    const closing=transport.close().then(()=>{closed=true;});await delay(20);
    assert.equal(writes,1);assert.equal(closed,false);
    release!();await closing;assert.equal(closed,true);assert.equal(writes,1);
    assert.equal((await receiving)?.name,'AbortError');
  } finally {release?.();await transport.close();restore();}
});


test('canceling an ICE attempt aborts its outstanding description HTTP request and closes the peer connection',async()=>{
  const channel=new Channel();channel.readyState='connecting';let peerClosed=false,signal:AbortSignal|undefined;
  const restore=installPeer(channel,false,()=>{peerClosed=true;}),abort=new AbortController();let posted!:()=>void;
  const started=new Promise<void>(resolve=>posted=resolve);
  const api={request:async(path:string,_body:unknown,_method:string,requestSignal:AbortSignal)=>{assert.match(path,/\/description$/);signal=requestSignal;posted();return new Promise((_,reject)=>requestSignal.addEventListener('abort',()=>reject(new DOMException('aborted','AbortError')),{once:true}));}};
  const transport=new RtcFileChannel(api as any,view(),'target',[],abort.signal);
  const receiving=transport.receive(4,async()=>4,async()=>{}).then(()=>null,error=>error);
  try{await started;abort.abort();assert.equal((await receiving)?.name,'AbortError');assert.equal(signal?.aborted,true);assert.equal(peerClosed,true);assert.equal(channel.readyState,'closed');}
  finally{await transport.close();restore();}
});
