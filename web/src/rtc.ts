import type { Api } from './api';
import type { TransferFile } from './model';
import { OpfsStorage } from './storage.ts';

export type RtcScope = 'lan'|'public';
export interface IceCandidate {candidate:string;sdpMid:string|null;sdpMLineIndex:number|null}
export const signalingCandidate=(value:RTCIceCandidateInit):IceCandidate=>({candidate:value.candidate || '',sdpMid:value.sdpMid ?? null,sdpMLineIndex:value.sdpMLineIndex ?? null});
export interface RtcView {
  transferId:string;fileId:string;attemptId:string;scope:RtcScope;offset:number;
  state:'negotiating'|'streaming'|'failed';expiresAt:string;error?:string;
  sourceDeviceId:string;targetDeviceId:string;
  offer:RTCSessionDescriptionInit|null;answer:RTCSessionDescriptionInit|null;
  candidates:{source:IceCandidate[];target:IceCandidate[]};
}
const sleep=(ms:number)=>new Promise<void>(resolve=>setTimeout(resolve,ms));
const aborted=()=>new DOMException('已停止直连','AbortError');
export const rtcSupported=()=>typeof RTCPeerConnection!=='undefined';
export const rtcStorageSupported=()=>rtcSupported() && typeof Worker!=='undefined' && typeof navigator.storage?.getDirectory==='function';
export function stripIce(sdp:string) {
  return sdp.split(/\r?\n/).filter(line=>!line.startsWith('a=candidate:') && line!=='a=end-of-candidates').join('\r\n');
}
function ipv6Prefix(address:string) {
  address=address.toLowerCase().split('%')[0];
  if(!/^[0-9a-f:]+$/.test(address) || !address.includes(':'))return null;
  const parts=address.split('::');if(parts.length>2)return null;
  const left=parts[0]?parts[0].split(':'):[],right=parts[1]?parts[1].split(':'):[];
  const groups=parts.length===2?[...left,...Array(Math.max(0,8-left.length-right.length)).fill('0'),...right]:left;
  return groups.length===8?groups.slice(0,4).map(part=>part.padStart(4,'0')).join(':'):null;
}
function addressKind(address:string):'lan'|'public'|'invalid' {
  address=address.toLowerCase();
  if(address.endsWith('.local'))return 'lan';
  const v4=/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(address);
  if(v4) {
    const [a,b,c,d]=v4.slice(1).map(Number);
    if([a,b,c,d].some(n=>n>255) || a===0 || a>=224)return 'invalid';
    return a===10 || a===127 || a===169&&b===254 || a===172&&b>=16&&b<=31 || a===192&&b===168 || a===100&&b>=64&&b<=127?'lan':'public';
  }
  if(!ipv6Prefix(address) || address==='::')return 'invalid';
  // ULA, link-local and deprecated site-local addresses remain LAN-only.
  if(address==='::1' || /^(fc|fd|fe[89a-f])/.test(address))return 'lan';
  return /^2|^3/.test(address)?'public':'invalid';
}
export function candidateAllowed(candidate:string,scope:RtcScope,localCandidates:string[]=[],own=false) {
  const parts=candidate.trim().split(/\s+/),address=parts[4],kind=parts[7];
  if(!address || !['host','srflx','prflx'].includes(kind) || !['udp','tcp'].includes(parts[2]?.toLowerCase()))return false;
  const location=addressKind(address);
  if(scope==='public')return location==='public';
  if(kind!=='host')return false;
  if(location==='lan')return true;
  const prefix=ipv6Prefix(address);
  return !!prefix && location==='public' && (own || localCandidates.some(value=>ipv6Prefix(value.split(/\s+/)[4] || '')===prefix));
}

export class RtcFileStore {
  private storage:OpfsStorage;
  private expiries=new Map<string,number>();
  private receivedTimes=new Map<string,string>();
  readonly ready:Promise<void>;
  constructor(scope:string) {
    this.storage=new OpfsStorage(scope);this.ready=this.storage.ready;
  }
  private call<T=any>(command:string,data:unknown,transfer:Transferable[]=[]):Promise<T> {
    return this.storage.call<T>(command,data,transfer);
  }
  async open(key:string,file:TransferFile,expires:number) {await this.ready;return (await this.call('open',{key,name:file.name,mimeType:file.mimeType,size:file.size,sha256:file.sha256,expires,relativePath:file.relativePath,entryKind:file.entryKind,transferId:key.split(':')[0]})).offset as number;}
  async directory(key:string,file:TransferFile){const {meta}=await this.call('directory',{key,name:file.name,size:0,mimeType:'inode/directory',relativePath:file.relativePath,transferId:key.split(':')[0],expires:Date.now()+86400000});this.receivedTimes.set(key,new Date(meta.receivedAt).toISOString());return meta;}
  async destination(){return this.call<{id:string;name:string}>('destination-get',{});}
  async setDestination(handle?:FileSystemDirectoryHandle){return this.call<{id:string;name:string;moved:number;cleanupPending:boolean;relocated?:{scope:string;key:string}[]}>('destination-set',handle?{handle,id:crypto.randomUUID()}:{});}
  async write(key:string,offset:number,bytes:ArrayBuffer) {return (await this.call('write',{key,offset,bytes},[bytes])).offset as number;}
  async finish(key:string) {return (await this.call('finish',{key})).file as File;}
  async confirm(key:string) {const result=await this.call('confirm',{key});this.expiries.set(key,result.expires);if(result.receivedAt)this.receivedTimes.set(key,new Date(result.receivedAt).toISOString());}
  async get(key:string) {
    await this.ready;
    try{const result=await this.call('get',{key});if(result.file || result.directory){this.expiries.set(key,result.meta.expires);if(result.meta.receivedAt)this.receivedTimes.set(key,new Date(result.meta.receivedAt).toISOString());return new File(result.file?[result.file]:[],result.meta.name,{type:result.meta.mimeType || '',lastModified:result.file?.lastModified || result.meta.receivedAt});}return undefined;}
    catch(error){if((error as Error).name==='NotFoundError')return undefined;throw error;}
  }
  get scope(){return this.storage.scopeName;}
  expiry(key:string) {return this.expiries.get(key) || 0;}
  receivedAt(key:string){return this.receivedTimes.get(key);}
  async reuse(key:string,file:TransferFile) {
    const result=await this.call<{file?:File;receivedAt?:number;expires?:number}>('reuse',{key,name:file.name,mimeType:file.mimeType,size:file.size,sha256:file.sha256,relativePath:file.relativePath,entryKind:file.entryKind,transferId:key.split(':')[0]});
    if(result.file){this.expiries.set(key,result.expires!);this.receivedTimes.set(key,new Date(result.receivedAt!).toISOString());return new File([result.file],file.name,{type:file.mimeType,lastModified:result.file.lastModified});}
    return undefined;
  }
  async unlinkReuse(key:string){await this.call('unlink-reuse',{key});this.expiries.delete(key);this.receivedTimes.delete(key);}
  async close(key:string) {await this.ready;await this.call('close',{key});}
  async remove(key:string) {await this.ready;await this.call('remove',{key});}
  async cleanup() {await this.ready;await this.call('cleanup',{});}
  async dispose() {await this.storage.dispose();}
}

/** One accepted file, one authenticated signaling attempt, one reliable channel. */
export class RtcFileChannel {
  private pc:RTCPeerConnection;
  private channel:RTCDataChannel|null=null;
  private stopped=false;
  private closing:Promise<void>|null=null;
  private failure:Error|null=null;
  private localCandidates:string[]=[];
  private pendingCandidates:IceCandidate[]=[];
  private sentCandidates=new Set<string>();
  private remoteCandidates=new Set<string>();
  private remoteDescription=false;
  private active=false;
  private refreshing=false;
  private lastProgress=Date.now();
  private opened=false;
  private readyMessage:{offset:number;size:number}|null=null;
  private acked=0;
  private completed=false;
  private endReceived=false;
  private queue=Promise.resolve();
  private receiving=false;
  private receiveOffset=0;
  private onBytes:((bytes:ArrayBuffer)=>Promise<number>)|null=null;
  private bytesSize=0;
  private abortListener:()=>void;
  readonly path:string;
  private api:Api;
  readonly view:RtcView;
  private role:'source'|'target';
  private signal:AbortSignal;
  private rpc=new AbortController();
  private connection:{opened?:()=>void;deadline?:number};
  get ownCandidates(){return [...this.localCandidates];}
  constructor(api:Api,view:RtcView,role:'source'|'target',iceServers:RTCIceServer[],signal:AbortSignal,connection:{opened?:()=>void;deadline?:number}={}) {
    this.connection=connection;
    this.api=api;this.view=view;this.role=role;this.signal=signal;
    this.path=`/transfers/${view.transferId}/files/${view.fileId}/rtc/${view.attemptId}`;
    // TURN is intentionally not a hidden large-file relay. Existing HTTPS relay
    // remains the visible, consent-aware last route.
    this.pc=new RTCPeerConnection({iceServers:iceServers.map(server=>({urls:(Array.isArray(server.urls)?server.urls:[server.urls]).filter(url=>/^stuns?:/i.test(url))})).filter(server=>server.urls.length),iceTransportPolicy:'all'});
    this.abortListener=()=>{void this.close();};signal.addEventListener('abort',this.abortListener,{once:true});
    this.pc.onicecandidate=event=>{
      if(!event.candidate || this.stopped || this.completed)return;
      const candidate=signalingCandidate(event.candidate.toJSON());
      this.localCandidates.push(candidate.candidate);this.pendingCandidates.push(candidate);
      void this.flushCandidates().catch(error=>this.fail(error));
    };
    this.pc.onconnectionstatechange=()=>{
      if(['failed','closed'].includes(this.pc.connectionState))void this.queue.then(()=>{if(!this.stopped && !this.completed)this.fail(new Error('直连已断开'));});
    };
    this.pc.ondatachannel=event=>{if(role!=='source' || this.channel || event.channel.label!=='globalsend-file-v1'){event.channel.close();return;}this.attach(event.channel);};
  }
  private check() {
    if(this.signal.aborted || this.stopped)throw aborted();
    if(this.failure)throw this.failure;
    if(Date.now()-this.lastProgress>45000)throw new Error('直连传输超时');
  }
  private fail(error:unknown) {if(!this.failure)this.failure=error instanceof Error?error:new Error(String(error));}
  private attach(channel:RTCDataChannel) {
    this.channel=channel;channel.binaryType='arraybuffer';channel.bufferedAmountLowThreshold=65536;
    this.opened=channel.readyState==='open';if(this.opened)this.connection.opened?.();
    channel.onopen=()=>{this.opened=true;this.lastProgress=Date.now();this.connection.opened?.();};
    channel.onclose=()=>{void this.queue.then(()=>{if(!this.completed && !this.stopped)this.fail(new Error('直连已关闭'));});};
    channel.onerror=()=>this.fail(new Error('直连数据通道失败'));
    channel.onmessage=event=>{
      this.queue=this.queue.then(async()=>{
        this.check();this.lastProgress=Date.now();
        if(typeof event.data==='string') {
          const message=JSON.parse(event.data);
          if(this.role==='source' && message.type==='ready') {
            if(message.offset!==this.view.offset || message.size!==this.bytesSize)throw new Error('直连文件位置不匹配');
            this.readyMessage=message;this.acked=message.offset;
          } else if(this.role==='source' && message.type==='ack') {
            if(!Number.isSafeInteger(message.offset) || message.offset<this.acked || message.offset>this.bytesSize)throw new Error('直连确认位置不匹配');
            this.acked=message.offset;
          } else if(this.role==='source' && message.type==='complete') {
            if(message.size!==this.bytesSize || this.acked!==this.bytesSize)throw new Error('直连确认不完整');
            this.completed=true;
          } else if(this.role==='target' && message.type==='end') {
            if(message.size!==this.bytesSize || this.receiveOffset!==this.bytesSize)throw new Error('直连文件不完整');
            this.endReceived=true;
          } else throw new Error('直连数据顺序不匹配');
        } else {
          if(!this.receiving || !this.onBytes || this.endReceived || !(event.data instanceof ArrayBuffer) || event.data.byteLength>16384 || this.receiveOffset+event.data.byteLength>this.bytesSize)throw new Error('直连文件数据不匹配');
          this.receiveOffset=await this.onBytes(event.data);
          if(this.stopped || this.signal.aborted)return;
          channel.send(JSON.stringify({type:'ack',offset:this.receiveOffset}));
        }
      }).catch(error=>this.fail(error));
    };
  }
  private async flushCandidates() {
    if(!this.active || this.stopped || this.completed)return;
    for(const candidate of this.pendingCandidates) {
      if(this.sentCandidates.has(candidate.candidate) || !candidateAllowed(candidate.candidate,this.view.scope,this.localCandidates,true))continue;
      this.sentCandidates.add(candidate.candidate);
      await this.api.request(this.path+'/candidate',candidate,'POST',this.rpc.signal);this.check();
    }
  }
  async refresh() {
    if(this.refreshing || this.stopped || this.completed)return;
    this.refreshing=true;
    try {
      const {rtc}=await this.api.request<{rtc:RtcView}>(this.path,undefined,'GET',this.rpc.signal);if(this.completed || this.stopped)return;this.check();
      if(rtc.state==='failed')throw new Error(rtc.error || '对方已停止直连');
      const description=this.role==='source'?rtc.offer:rtc.answer;
      if(description && !this.remoteDescription) {
        await this.pc.setRemoteDescription({type:description.type,sdp:stripIce(description.sdp || '')});this.check();this.remoteDescription=true;
        if(this.role==='source') {
          const answer=await this.pc.createAnswer();await this.pc.setLocalDescription(answer);this.check();
          await this.api.request(this.path+'/description',{type:'answer',sdp:stripIce(answer.sdp || '')},'POST',this.rpc.signal);this.check();this.active=true;await this.flushCandidates();
        }
      }
      if(this.remoteDescription)for(const candidate of rtc.candidates[this.role==='source'?'target':'source']) {
        if(this.remoteCandidates.has(candidate.candidate) || !candidateAllowed(candidate.candidate,this.view.scope,this.localCandidates))continue;
        await this.pc.addIceCandidate(candidate);this.check();this.remoteCandidates.add(candidate.candidate);
      }
    } catch(error){if(!this.completed && !this.stopped)this.fail(error);}
    finally{this.refreshing=false;}
  }
  private async negotiate() {
    this.check();
    if(this.role==='target') {
      this.attach(this.pc.createDataChannel('globalsend-file-v1',{ordered:true}));
      const offer=await this.pc.createOffer();await this.pc.setLocalDescription(offer);this.check();
      await this.api.request(this.path+'/description',{type:'offer',sdp:stripIce(offer.sdp || '')},'POST',this.rpc.signal);this.check();this.active=true;await this.flushCandidates();
    }
    const deadline=this.connection.deadline ?? Date.now()+15000;
    while(!this.opened) {
      this.check();if(Date.now()>deadline)throw new Error(this.view.scope==='lan'?'局域网不可达':'公网直连不可达');
      await this.refresh();await sleep(100);
    }
  }
  async send(file:File,onProgress:(offset:number)=>void) {
    this.bytesSize=file.size;
    await this.negotiate();
    while(!this.readyMessage){this.check();await sleep(20);}
    let offset=this.view.offset;
    while(offset<file.size) {
      this.check();
      if(offset-this.acked>=524288 || this.channel!.bufferedAmount>=524288){onProgress(this.acked);await sleep(10);continue;}
      const bytes=await file.slice(offset,Math.min(file.size,offset+16384)).arrayBuffer();this.check();
      this.channel!.send(bytes);offset+=bytes.byteLength;onProgress(this.acked);
    }
    while(this.acked<file.size){this.check();onProgress(this.acked);await sleep(10);}
    this.channel!.send(JSON.stringify({type:'end',size:file.size}));
    while(!this.completed){this.check();await sleep(20);}
    onProgress(file.size);
  }
  async receive(size:number,write:(bytes:ArrayBuffer)=>Promise<number>,finish:()=>Promise<void>) {
    this.bytesSize=size;this.receiveOffset=this.view.offset;this.onBytes=write;this.receiving=true;
    await this.negotiate();await this.api.request(this.path+'/started',{},'POST',this.rpc.signal);this.check();
    this.channel!.send(JSON.stringify({type:'ready',offset:this.view.offset,size}));
    while(!this.endReceived){this.check();await sleep(20);}
    await this.queue;this.check();
    this.channel!.send(JSON.stringify({type:'complete',size}));this.completed=true;
    // Allow SCTP to commit the final control message before close.
    while(this.channel!.bufferedAmount>0){this.check();await sleep(10);}
    const grace=Date.now()+1000;
    while(this.channel!.readyState!=='closed' && Date.now()<grace){this.check();await sleep(10);}
    // complete acknowledges durable bytes, not final integrity or center receipt.
    // A large disk-backed hash can legitimately outlast the channel idle timer.
    if(this.signal.aborted || this.stopped)throw aborted();
    await finish();
    if(this.signal.aborted || this.stopped)throw aborted();
  }
  async close() {
    if(this.closing)return this.closing;
    this.stopped=true;this.rpc.abort();this.signal.removeEventListener('abort',this.abortListener);
    this.channel?.close();this.pc.close();
    this.closing=(async()=>{await this.queue;})();return this.closing;
  }
}
