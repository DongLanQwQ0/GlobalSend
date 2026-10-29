import type { RtcScope } from './rtc';

/** One connection decision. File IO after a successful handshake has no deadline. */
export class DirectConnectionBudget {
  private deadline:number;
  readonly automatic:boolean;
  private clock:()=>number;
  constructor(automatic:boolean,clock=Date.now){this.automatic=automatic;this.clock=clock;this.deadline=clock()+(automatic?1000:15000);}
  remaining(){return Math.max(0,this.deadline-this.clock());}
  window(scopesLeft:number,preferred=false,latencyMs=0){const remaining=this.remaining();return !this.automatic?remaining:preferred?Math.min(3000,Math.max(1000,latencyMs*4+100)):scopesLeft<=1?remaining:Math.max(1,Math.floor(remaining*.5));}
  resumeAfterDisconnect(){this.deadline=this.clock()+(this.automatic?1000:15000);}
}

/** Actual cancellation reaches both signaling fetches and the peer connection. */
export class ConnectAttempt {
  readonly controller=new AbortController();
  readonly signal=this.controller.signal;
  timedOut=false;connected=false;
  private timer:ReturnType<typeof setTimeout>;
  private abort=()=>this.controller.abort();
  private parent:AbortSignal;
  constructor(parent:AbortSignal,milliseconds:number){
    this.parent=parent;
    parent.addEventListener('abort',this.abort,{once:true});if(parent.aborted)this.abort();
    this.timer=setTimeout(()=>{this.timedOut=true;this.controller.abort();},Math.max(0,milliseconds));
  }
  opened(){this.connected=true;clearTimeout(this.timer);}
  async wait<T>(work:Promise<T>):Promise<T>{
    if(this.signal.aborted)throw new DOMException('连接尝试已停止','AbortError');
    let stop!:()=>void;
    const canceled=new Promise<never>((_,reject)=>{stop=()=>reject(new DOMException('连接尝试已停止','AbortError'));this.signal.addEventListener('abort',stop,{once:true});});
    try{return await Promise.race([work,canceled]);}finally{this.signal.removeEventListener('abort',stop);}
  }
  dispose(){clearTimeout(this.timer);this.parent.removeEventListener('abort',this.abort);this.controller.abort();}
}

export function preferredScopes(scopes:RtcScope[],results:{scope:RtcScope;success:boolean;expiresAt:string;initiatorDeviceId:string;responderDeviceId:string}[],self:string,peer:string,now=Date.now()):RtcScope[]{
  const valid=results.filter(result=>Date.parse(result.expiresAt)>now && [result.initiatorDeviceId,result.responderDeviceId].includes(self) && [result.initiatorDeviceId,result.responderDeviceId].includes(peer));
  const lan=valid.find(result=>result.scope==='lan' && result.success),publicPath=valid.find(result=>result.scope==='public' && result.success);
  // Positive LAN remains first. A positive public result may bypass a *known*
  // failed LAN probe, but an untested LAN still receives its own attempt.
  if(!lan && publicPath && valid.some(result=>result.scope==='lan' && !result.success))return [...scopes].sort((a,b)=>Number(b==='public')-Number(a==='public'));
  return scopes;
}

export function verifiedScopeLatency(results:{scope:RtcScope;success:boolean;expiresAt:string;initiatorDeviceId:string;responderDeviceId:string;elapsedMs?:number|null}[],self:string,peer:string,scope:RtcScope,now=Date.now()):number|undefined {
  const values=results.filter(result=>result.scope===scope && result.success && Date.parse(result.expiresAt)>now &&
    [result.initiatorDeviceId,result.responderDeviceId].includes(self) && [result.initiatorDeviceId,result.responderDeviceId].includes(peer));
  return values.length?Math.min(...values.map(value=>value.elapsedMs??0)):undefined;
}
