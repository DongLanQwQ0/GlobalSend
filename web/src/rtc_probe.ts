import type { Api } from './api';
import { candidateAllowed, signalingCandidate, stripIce } from './rtc.ts';
import type { IceCandidate } from './rtc';
import type { RtcProbeView, RtcProbePeer, RtcProbeResult, RtcProbeSnapshot, RtcScope } from '../../packages/protocol/src/index';

export const RTC_PROBE_INTERVAL=120000;
export const RTC_PROBE_LABEL='globalsend-probe-v1';
const delay=(ms:number)=>new Promise<void>(resolve=>setTimeout(resolve,ms));
export function probeNonce(random:Pick<Crypto,'getRandomValues'>=crypto) {
  return Array.from(random.getRandomValues(new Uint8Array(16)),byte=>byte.toString(16).padStart(2,'0')).join('');
}
export function probeScopes(scopes:RtcScope[]):RtcScope[] {return (['lan','public'] as const).filter(scope=>scopes.includes(scope));}
export function probeInitiator(self:string,other:string){return self<other;}
export function probeOther(value:Pick<RtcProbeView,'initiatorDeviceId'|'responderDeviceId'>,self:string) {return value.initiatorDeviceId===self?value.responderDeviceId:value.initiatorDeviceId;}
export function latestProbeAt(results:RtcProbeResult[],self:string,peer:string) {return Math.max(-Infinity,...results.filter(result=>[result.initiatorDeviceId,result.responderDeviceId].includes(self) && probeOther(result,self)===peer).map(result=>Date.parse(result.checkedAt)));}
export function probeResultLabel(results:RtcProbeResult[],self:string,peer:string,now=Date.now()) {
  const valid=results.filter(result=>probeOther(result,self)===peer && [result.initiatorDeviceId,result.responderDeviceId].includes(self) && Date.parse(result.expiresAt)>now);
  for(const scope of ['lan','public']) {
    const result=valid.find(result=>result.scope===scope && result.success);
    if(result)return `RTC ${scope==='lan'?'局域网':'公网'}${result.elapsedMs!==null?` · ${result.elapsedMs} ms`:''}`;
  }
  return valid.length?'RTC 暂不可达':'';
}
/** Addresses of the pair which actually carried the nonce, never a guessed ICE candidate. */
export function selectedProbeAddresses(report:{forEach(callback:(value:any)=>void):void}) {
  const values:any[]=[];report.forEach(value=>values.push(value));
  const byId=new Map(values.map(value=>[value.id,value]));
  const transport=values.find(value=>value.type==='transport' && value.selectedCandidatePairId);
  const succeeded=values.filter(value=>value.type==='candidate-pair' && value.state==='succeeded');
  const selected=succeeded.filter(value=>value.selected===true),nominated=succeeded.filter(value=>value.nominated===true);
  // Several successful/nominated pairs can coexist during ICE changes. Without
  // an explicit selection or a single candidate, their timestamps prove nothing.
  const pair=transport?byId.get(transport.selectedCandidatePairId):selected.length===1?selected[0]:selected.length===0 && nominated.length===1?nominated[0]:undefined;
  if(!pair || pair.state && pair.state!=='succeeded')return {};
  const endpoint=(candidate:any)=>{
    const address=candidate?.address || candidate?.ip;
    if(typeof address!=='string' || !address)return undefined;
    const host=address.includes(':') && !address.startsWith('[')?`[${address}]`:address;
    return Number.isInteger(candidate.port) && candidate.port>0?`${host}:${candidate.port}`:host;
  };
  return {initiatorAddress:endpoint(byId.get(pair.localCandidateId)),responderAddress:endpoint(byId.get(pair.remoteCandidateId))};
}
export function orientedProbeAddresses(result:Pick<RtcProbeResult,'initiatorDeviceId'|'initiatorAddress'|'responderAddress'>,self:string){
  return result.initiatorDeviceId===self?{source:result.initiatorAddress,target:result.responderAddress}:{source:result.responderAddress,target:result.initiatorAddress};
}

type ProbeApi=Pick<Api,'request'>;
type ProbeRole='initiator'|'responder';

/** Data-only nonce echo. It never opens a file, transfer or external ICE server. */
export class RtcProbeSession {
  readonly view:RtcProbeView;
  readonly path:string;
  private api:ProbeApi;
  private role:ProbeRole;
  private signal:AbortSignal;
  private pc:RTCPeerConnection;
  private channel:RTCDataChannel|null=null;
  private rpc=new AbortController();
  private deadlineTimer:ReturnType<typeof setTimeout>;
  private externalAbort:()=>void;
  private pending:IceCandidate[]=[];
  private local:string[]=[];
  private sent=new Set<string>();
  private remote=new Set<string>();
  private candidateTail=Promise.resolve();
  private remoteDescription=false;
  private descriptionPosted=false;
  private refreshing=false;
  private failure:Error|null=null;
  private closed=false;
  private timedOut=false;
  private ended=false;
  private echoed=false;
  private gotEcho=false;
  private nonce=probeNonce();
  private pingAt:number|null=null;
  private elapsedMs=0;
  private reportAddresses=false;
  constructor(api:ProbeApi,view:RtcProbeView,self:string,signal:AbortSignal,reportAddresses=false) {
    this.reportAddresses=reportAddresses;
    this.api=api;this.view=view;this.signal=signal;this.role=view.initiatorDeviceId===self?'initiator':'responder';this.path=`/rtc-probes/${view.attemptId}`;
    this.pc=new RTCPeerConnection({iceServers:[]});
    this.externalAbort=()=>this.close();signal.addEventListener('abort',this.externalAbort,{once:true});
    this.deadlineTimer=setTimeout(()=>{this.timedOut=true;this.close();},Math.max(0,Math.min(12000,Date.parse(view.expiresAt)-Date.now())));
    this.pc.onicecandidate=event=>{
      if(!event.candidate || this.closed)return;
      const candidate=signalingCandidate(event.candidate.toJSON());this.local.push(candidate.candidate);this.pending.push(candidate);this.flushCandidates();
    };
    this.pc.onconnectionstatechange=()=>{if(['failed','closed'].includes(this.pc.connectionState) && !this.closed && !this.echoed && !this.gotEcho)this.failure=new Error('PROBE_CONNECTION_FAILED');};
    this.pc.ondatachannel=event=>{if(this.role!=='responder' || this.channel || event.channel.label!==RTC_PROBE_LABEL){event.channel.close();return;}this.attach(event.channel);};
  }
  get active(){return !this.closed;}
  private check() {
    if(this.timedOut)throw new Error('PROBE_TIMEOUT');
    if(this.closed || this.signal.aborted)throw new DOMException('探测已停止','AbortError');
    if(this.failure)throw this.failure;
  }
  private attach(channel:RTCDataChannel) {
    this.channel=channel;
    const ping=()=>{if(this.role==='initiator' && this.pingAt===null && !this.closed){this.pingAt=performance.now();channel.send(JSON.stringify({type:'ping',nonce:this.nonce}));}};
    channel.onopen=ping;
    channel.onclose=()=>{if(this.echoed || this.gotEcho)this.ended=true;else if(!this.closed)this.failure=new Error('PROBE_CHANNEL_CLOSED');};
    channel.onerror=()=>{if(!this.closed && !this.gotEcho && !this.echoed)this.failure=new Error('PROBE_CHANNEL_FAILED');};
    channel.onmessage=event=>{
      if(this.closed)return;
      try {
        if(typeof event.data!=='string' || event.data.length>256)throw new Error('PROBE_INVALID_ECHO');
        const message=JSON.parse(event.data);
        if(this.role==='responder' && message.type==='ping' && /^[a-f0-9]{32}$/.test(message.nonce) && !this.echoed) {
          this.echoed=true;channel.send(JSON.stringify({type:'echo',nonce:message.nonce}));
        } else if(this.role==='initiator' && message.type==='echo' && message.nonce===this.nonce && this.pingAt!==null) {
          this.gotEcho=true;this.elapsedMs=Math.max(0,Math.round(performance.now()-this.pingAt));
        } else throw new Error('PROBE_INVALID_ECHO');
      }catch(error){this.failure=error as Error;}
    };
    if(channel.readyState==='open')ping();
  }
  private flushCandidates() {
    if(!this.descriptionPosted || this.closed)return;
    this.candidateTail=this.candidateTail.then(async()=>{
      for(const candidate of this.pending) {
        if(this.closed)return;
        if(this.sent.has(candidate.candidate) || !candidateAllowed(candidate.candidate,this.view.scope,this.local,true))continue;
        this.sent.add(candidate.candidate);await this.api.request(this.path+'/candidate',candidate,'POST',this.rpc.signal);this.check();
      }
    }).catch(error=>{if(!this.closed)this.failure=error;});
  }
  async refresh(view?:RtcProbeView) {
    if(this.refreshing || this.closed || this.gotEcho || this.ended)return;
    this.refreshing=true;
    try {
      const probe=view || (await this.api.request<{probe:RtcProbeView}>(this.path,undefined,'GET',this.rpc.signal)).probe;this.check();
      const description=this.role==='initiator'?probe.answer:probe.offer;
      if(description && !this.remoteDescription) {
        await this.pc.setRemoteDescription({type:description.type,sdp:stripIce(description.sdp)});this.check();this.remoteDescription=true;
        if(this.role==='responder') {
          const answer=await this.pc.createAnswer();await this.pc.setLocalDescription(answer);this.check();
          await this.api.request(this.path+'/description',{type:'answer',sdp:stripIce(answer.sdp || '')},'POST',this.rpc.signal);this.check();this.descriptionPosted=true;this.flushCandidates();
        }
      }
      if(this.remoteDescription)for(const candidate of probe.candidates[this.role==='initiator'?'responder':'initiator']) {
        if(this.remote.has(candidate.candidate) || !candidateAllowed(candidate.candidate,this.view.scope,this.local))continue;
        await this.pc.addIceCandidate(candidate);this.check();this.remote.add(candidate.candidate);
      }
    } catch(error) {
      if((error as {status?:number}).status===410 && (this.echoed || this.gotEcho))this.ended=true;
      else if(!this.closed)this.failure=error as Error;
    }finally{this.refreshing=false;}
  }
  async run():Promise<RtcProbeResult|null> {
    try {
      this.check();
      if(this.role==='initiator') {
        this.attach(this.pc.createDataChannel(RTC_PROBE_LABEL,{ordered:true}));
        const offer=await this.pc.createOffer();await this.pc.setLocalDescription(offer);this.check();
        await this.api.request(this.path+'/description',{type:'offer',sdp:stripIce(offer.sdp || '')},'POST',this.rpc.signal);this.check();this.descriptionPosted=true;this.flushCandidates();
      }
      let nextRefresh=0;
      while(this.role==='initiator'?!this.gotEcho:!this.ended) {
        this.check();
        if(Date.now()>=nextRefresh){nextRefresh=Date.now()+500;await this.refresh();}
        await delay(20);
      }
      this.check();
      if(this.role==='initiator') {
        let addresses:ReturnType<typeof selectedProbeAddresses>={};
        if(this.reportAddresses && typeof this.pc.getStats==='function'){
          let timer:ReturnType<typeof setTimeout>|undefined;
          try{addresses=await Promise.race([this.pc.getStats().then(selectedProbeAddresses),new Promise<{}>(resolve=>{timer=setTimeout(()=>resolve({}),500);})]);}
          catch{/* Some browsers redact endpoint stats; the echoed path remains proven. */}
          finally{clearTimeout(timer);}
        }
        const {result}=await this.api.request<{result:RtcProbeResult}>(this.path+'/complete',{elapsedMs:this.elapsedMs,...addresses},'POST',this.rpc.signal);return result;
      }
      return null;
    } catch(error) {
      if(this.signal.aborted || this.closed && !this.timedOut)return null;
      const report=new AbortController(),timer=setTimeout(()=>report.abort(),2000);
      try{return (await this.api.request<{result:RtcProbeResult}>(this.path+'/fail',{error:this.timedOut?'PROBE_TIMEOUT':(error as Error).message},'POST',report.signal)).result;}
      catch{return null;}finally{clearTimeout(timer);}
    }finally{this.close();}
  }
  close() {
    if(this.closed)return;
    this.closed=true;clearTimeout(this.deadlineTimer);this.signal.removeEventListener('abort',this.externalAbort);this.rpc.abort();this.channel?.close();this.pc.close();
  }
}

interface MonitorOptions {
  api:ProbeApi;deviceId:string;changed:()=>void;reportAddresses?:boolean;parallel?:boolean;
  session?:(view:RtcProbeView,signal:AbortSignal)=>Pick<RtcProbeSession,'run'|'close'|'refresh'|'active'>;
}
/** Foreground-only coordinator; shared server results never change file policy. */
export class RtcProbeMonitor {
  results:RtcProbeResult[]=[];
  private options:MonitorOptions;
  private foreground=false;
  private disposed=false;
  private epoch=0;
  private life=new AbortController();
  private heartbeat:ReturnType<typeof setInterval>|null=null;
  private lastAttempt=new Map<string,number>();
  private requestedPeers=new Set<string>();
  private online=new Set<string>();
  private snapshot:RtcProbeSnapshot|null=null;
  private syncing:Promise<void>|null=null;
  private syncAgain=false;
  private leaseTail=Promise.resolve();
  private leaseAbort:AbortController|null=null;
  private leaseClosing=false;
  private running=false;
  private parallelSessions=new Map<string,NonNullable<RtcProbeMonitor['activeSession']>>();
  private creatingScopes=new Set<string>();
  private requestedScopes=new Set<string>();
  private sessions(){return [...this.parallelSessions.values(),...(this.activeSession?[this.activeSession]:[])];}
  private stopSession(active:NonNullable<RtcProbeMonitor['activeSession']>){active.abort.abort();active.value.close();this.parallelSessions.delete(active.view.attemptId);}

  private activeSession:{view:RtcProbeView;value:Pick<RtcProbeSession,'run'|'close'|'refresh'|'active'>;abort:AbortController}|null=null;
  constructor(options:MonitorOptions){this.options=options;}
  get ownCandidates(){
    return this.sessions().flatMap(({view})=>view.candidates[view.initiatorDeviceId===this.options.deviceId?'initiator':'responder'].map(candidate=>candidate.candidate));
  }
  setOnlinePeers(ids:string[]) {
    const changed=ids.length!==this.online.size || ids.some(id=>!this.online.has(id));
    this.online=new Set(ids);this.results=this.results.filter(result=>this.online.has(probeOther(result,this.options.deviceId)));
    for(const active of this.sessions())if(!this.online.has(probeOther(active.view,this.options.deviceId)))this.stopSession(active);
    if(changed && this.foreground)void this.refresh();
  }
  removePeer(id:string){
    this.online.delete(id);this.lastAttempt.delete(id);
    for(const key of this.lastAttempt.keys())if(key.startsWith(id+'/'))this.lastAttempt.delete(key);
    this.results=this.results.filter(result=>probeOther(result,this.options.deviceId)!==id);
    for(const active of this.sessions())if(probeOther(active.view,this.options.deviceId)===id)this.stopSession(active);
    this.options.changed();
  }
  status(peerId:string) {
    if(!this.foreground || !this.online.has(peerId))return '';
    if(this.sessions().some(active=>active.value.active && probeOther(active.view,this.options.deviceId)===peerId))return 'RTC 检测中';
    return probeResultLabel(this.results,this.options.deviceId,peerId);
  }
  async setForeground(value:boolean) {
    if(this.disposed && value || value===this.foreground)return;
    this.foreground=value;const epoch=++this.epoch;
    this.life.abort();this.life=new AbortController();if(!this.leaseClosing)this.leaseAbort?.abort();
    for(const active of this.sessions())this.stopSession(active);this.activeSession=null;this.requestedScopes.clear();this.snapshot=null;this.results=[];this.lastAttempt.clear();
    if(this.heartbeat!==null){clearInterval(this.heartbeat);this.heartbeat=null;}
    if(value)this.heartbeat=setInterval(()=>{void this.tick();},20000);
    this.options.changed();
    this.leaseTail=this.leaseTail.catch(()=>{}).then(async()=>{
      if(value && (epoch!==this.epoch || this.disposed))return;
      const controller=new AbortController();this.leaseAbort=controller;this.leaseClosing=!value;
      const timer=setTimeout(()=>controller.abort(),2000);
      try {
        await this.options.api.request('/devices/me/rtc-probes/presence',{foreground:value},'POST',controller.signal);
        if(value && epoch===this.epoch)await this.refresh();
      }catch{/* The next foreground heartbeat refreshes a temporarily unavailable lease. */}
      finally{clearTimeout(timer);if(this.leaseAbort===controller){this.leaseAbort=null;this.leaseClosing=false;}}
    });
    await this.leaseTail;
  }
  async tick() {
    if(!this.foreground || this.disposed)return;
    const epoch=this.epoch;
    try {
      await this.options.api.request('/devices/me/rtc-probes/presence',{foreground:true},'POST',this.life.signal);
      if(epoch===this.epoch)await this.refresh();
    }catch{/* Probe availability must not block actual transfers. */}
  }
  async changed(){if(!this.foreground)return;for(const active of this.sessions())void active.value.refresh();await this.refresh();}
  async refreshPeer(peerId:string){if(!this.online.has(peerId))return;if(this.options.parallel){for(const scope of ['lan','public'])this.requestedScopes.add(peerId+'/'+scope);}else this.requestedPeers.add(peerId);await this.refresh();}
  async refreshAllPeers(){for(const id of this.online){if(this.options.parallel){for(const scope of ['lan','public'])this.requestedScopes.add(id+'/'+scope);}else this.requestedPeers.add(id);}await this.refresh();}
  async networkChanged(canResume?:()=>boolean){const restore=this.foreground;await this.setForeground(false);if(restore && !this.disposed && (!canResume || canResume()))await this.setForeground(true);}
  async refresh() {
    if(!this.foreground || this.disposed)return;
    if(this.syncing){this.syncAgain=true;return this.syncing;}
    const epoch=this.epoch,known=new Set(this.parallelSessions.keys());
    const syncing=(async()=>{
      try {
        const snapshot=await this.options.api.request<RtcProbeSnapshot>('/devices/me/rtc-probes',undefined,'GET',this.life.signal);
        if(epoch!==this.epoch || !this.foreground)return;
        this.snapshot=snapshot;this.results=snapshot.results.filter(result=>Date.parse(result.expiresAt)>Date.now() && this.online.has(probeOther(result,this.options.deviceId)));this.options.changed();
        if(this.options.parallel){this.scheduleParallel(snapshot,epoch,known);return;}
        if(this.activeSession){const view=snapshot.probes.find(probe=>probe.attemptId===this.activeSession!.view.attemptId);if(view)void this.activeSession.value.refresh(view);return;}
        if(this.running)return;
        const incoming=snapshot.probes.find(probe=>probe.responderDeviceId===this.options.deviceId && this.online.has(probe.initiatorDeviceId));
        if(incoming){void this.respond(incoming,epoch);return;}
        if(snapshot.probes.length)return;
        const available=[...snapshot.peers].sort((a,b)=>a.deviceId.localeCompare(b.deviceId)).filter(peer=>this.online.has(peer.deviceId) && Date.parse(peer.foregroundExpiresAt)>Date.now());
        const requested=available.find(peer=>this.requestedPeers.has(peer.deviceId));
        const peer=requested || available.find(peer=>probeInitiator(this.options.deviceId,peer.deviceId) && Date.now()-Math.max(this.lastAttempt.get(peer.deviceId) ?? -Infinity,latestProbeAt(snapshot.results,this.options.deviceId,peer.deviceId))>=RTC_PROBE_INTERVAL);
        if(peer){this.requestedPeers.delete(peer.deviceId);void this.initiate(peer,epoch,!!requested);}
      }catch{/* Old centers never enable this monitor; transient errors stay local. */}
    })();
    this.syncing=syncing;
    try{await syncing;}finally{if(this.syncing===syncing){this.syncing=null;if(this.syncAgain){this.syncAgain=false;void this.refresh();}}}
  }
  private async session(view:RtcProbeView,epoch:number) {
    if(epoch!==this.epoch || !this.foreground || !this.online.has(probeOther(view,this.options.deviceId)))return null;
    const life=this.life.signal,abort=new AbortController(),cancel=()=>abort.abort();life.addEventListener('abort',cancel,{once:true});
    const value=this.options.session?.(view,abort.signal) || new RtcProbeSession(this.options.api,view,this.options.deviceId,abort.signal,this.options.reportAddresses);
    const active={view,value,abort};if(this.options.parallel)this.parallelSessions.set(view.attemptId,active);else this.activeSession=active;this.options.changed();
    try {
      const result=await value.run();
      if(result && epoch===this.epoch && this.foreground && this.online.has(probeOther(view,this.options.deviceId))){this.results=this.results.filter(old=>old.scope!==result.scope || probeOther(old,this.options.deviceId)!==probeOther(result,this.options.deviceId));this.results.push(result);}
      return result;
    } finally {
      life.removeEventListener('abort',cancel);value.close();if(this.parallelSessions.get(view.attemptId)===active)this.parallelSessions.delete(view.attemptId);if(this.activeSession===active)this.activeSession=null;this.options.changed();
    }
  }
  private scheduleParallel(snapshot:RtcProbeSnapshot,epoch:number,known:Set<string>){
    for(const id of known){const active=this.parallelSessions.get(id);if(active && !snapshot.probes.some(view=>view.attemptId===id))this.stopSession(active);}
    for(const view of snapshot.probes){
      if(!this.online.has(probeOther(view,this.options.deviceId)))continue;
      const active=this.parallelSessions.get(view.attemptId);
      if(active)void active.value.refresh(view);
      else void this.runParallel(view,epoch);
    }
    for(const peer of snapshot.peers){
      if(!this.online.has(peer.deviceId) || Date.parse(peer.foregroundExpiresAt)<=Date.now())continue;
      for(const scope of probeScopes(peer.scopes)){
        const key=peer.deviceId+'/'+scope,requested=this.requestedScopes.has(key);
        if(!requested && !probeInitiator(this.options.deviceId,peer.deviceId))continue;
        if(this.creatingScopes.has(key) || snapshot.probes.some(view=>view.scope===scope && probeOther(view,this.options.deviceId)===peer.deviceId))continue;
        const recent=snapshot.results.some(result=>result.scope===scope && probeOther(result,this.options.deviceId)===peer.deviceId && Date.parse(result.expiresAt)>Date.now());
        if(!requested && (recent || Date.now()-(this.lastAttempt.get(key)??-Infinity)<RTC_PROBE_INTERVAL))continue;
        if(!peer.parallelProbes && (this.sessions().some(active=>probeOther(active.view,this.options.deviceId)===peer.deviceId) || [...this.creatingScopes].some(value=>value.startsWith(peer.deviceId+'/'))))break;
        void this.initiateScope(peer,scope,epoch);
      }
    }
  }
  private async runParallel(view:RtcProbeView,epoch:number){
    if(this.parallelSessions.has(view.attemptId))return;
    try{await this.session(view,epoch);}catch{/* This scope's failure does not stop other checks. */}
    finally{if(epoch===this.epoch && this.foreground)void this.refresh();}
  }
  private async initiateScope(peer:RtcProbePeer,scope:RtcScope,epoch:number){
    const key=peer.deviceId+'/'+scope;
    this.creatingScopes.add(key);this.requestedScopes.delete(key);this.lastAttempt.set(key,Date.now());
    let created=false;
    try{
      const attemptId=probeNonce(),controller=new AbortController(),cancel=()=>controller.abort(),life=this.life.signal;
      life.addEventListener('abort',cancel,{once:true});if(life.aborted)controller.abort();
      const timer=setTimeout(cancel,1000);
      let probe:RtcProbeView;
      try{({probe}=await this.options.api.request<{probe:RtcProbeView}>(`/devices/${peer.deviceId}/rtc-probes`,{attemptId,scope},'POST',controller.signal));}
      finally{clearTimeout(timer);life.removeEventListener('abort',cancel);}
      if(epoch!==this.epoch || !this.foreground || !this.online.has(peer.deviceId)){void this.options.api.request(`/rtc-probes/${attemptId}`,undefined,'DELETE').catch(()=>{});return;}
      created=true;await this.runParallel(probe,epoch);
    }catch{this.lastAttempt.delete(key);}
    finally{this.creatingScopes.delete(key);if(created && epoch===this.epoch && this.foreground)void this.refresh();}
  }
  private async respond(view:RtcProbeView,epoch:number) {
    this.running=true;
    try{await this.session(view,epoch);}finally{this.running=false;if(epoch===this.epoch)void this.refresh();}
  }
  private async initiate(peer:RtcProbePeer,epoch:number,allScopes=false) {
    this.running=true;
    try {
      for(const scope of probeScopes(peer.scopes)) {
        if(epoch!==this.epoch || !this.foreground || !this.online.has(peer.deviceId))return;
        const attemptId=probeNonce();
        const {probe}=await this.options.api.request<{probe:RtcProbeView}>(`/devices/${peer.deviceId}/rtc-probes`,{attemptId,scope},'POST',this.life.signal);
        if(epoch!==this.epoch || !this.foreground || !this.online.has(peer.deviceId)){void this.options.api.request(`/rtc-probes/${attemptId}`,undefined,'DELETE').catch(()=>{});return;}
        this.lastAttempt.set(peer.deviceId,Date.now());
        const result=await this.session(probe,epoch);
        if(result?.success && !allScopes)return;
      }
    }catch{/* Peer foreground/busy changes are reconciled by the next notification. */}
    finally{this.running=false;if(epoch===this.epoch)void this.refresh();}
  }
  async dispose(){if(this.disposed)return this.leaseTail;this.disposed=true;await this.setForeground(false);await this.leaseTail;}
}
