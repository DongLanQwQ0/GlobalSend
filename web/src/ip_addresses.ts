export const IP_GROUPS = ['IPv4 内网','IPv4 公网','IPv6 内网','IPv6 公网'] as const;
export interface IpGroup {label:typeof IP_GROUPS[number];addresses:string[]}
export interface IpSource {label:string;groups:IpGroup[]}

/** Parse literal addresses only: no DNS lookup and no other-device discovery. */
export function literalIp(value:string):{address:string;group:number}|null {
  let raw=value.trim();
  if (/^(?:a=)?candidate:/i.test(raw)) {
    const parts=raw.replace(/^a=/,'').split(/\s+/);
    if(!['host','srflx','prflx'].includes(parts[7]))return null;
    raw=parts[4] || '';
  } else if(raw.includes('://'))raw=raw.split('://')[1].split(/[/?#]/)[0];
  if(raw.includes('@'))return null;
  if(raw.startsWith('[')) {
    const match=/^\[([^\]]+)\](?::\d+)?$/.exec(raw);if(!match)return null;raw=match[1];
  } else if(/^\d+\.\d+\.\d+\.\d+:\d+$/.test(raw))raw=raw.slice(0,raw.lastIndexOf(':'));
  const v4=/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(raw);
  const privateV4=([a,b]:number[])=>a===10 || a===169&&b===254 || a===172&&b>=16&&b<=31 || a===192&&b===168 || a===100&&b>=64&&b<=127 || a===198&&(b===18||b===19);
  if(v4) {
    const parts=v4.slice(1).map(Number);
    if(parts.some(n=>n>255) || parts[0]===0 || parts[0]===127 || parts[0]>=224)return null;
    return {address:parts.join('.'),group:privateV4(parts)?0:1};
  }
  const scoped=raw.replace(/%25(?=[a-zA-Z0-9_.-]+$)/,'%').split('%');
  if(scoped.length>2 || scoped[1]!==undefined && !/^[a-zA-Z0-9_.-]+$/.test(scoped[1]))return null;
  if(!scoped[0].includes(':'))return null;
  let address:string;
  try {address=new URL('http://['+scoped[0]+']/').hostname.slice(1,-1);}catch{return null;}
  if(address==='::' || address==='::1' || address.startsWith('ff'))return null;
  let local=/^(fc|fd|fe[89a-f])/.test(address);
  const mapped=/^::ffff:([0-9a-f]+):([0-9a-f]+)$/.exec(address);
  if(mapped){const hi=parseInt(mapped[1],16),lo=parseInt(mapped[2],16);if(hi>>8===127 || hi>>8===0 || hi>>8>=224)return null;local=privateV4([hi>>8,hi&255,lo>>8,lo&255]);}
  return {address:address+(scoped[1]?'%'+scoped[1]:''),group:local?2:3};
}

export function groupIpAddresses(values:Iterable<string>):IpGroup[] {
  const groups=IP_GROUPS.map(label=>({label,addresses:new Set<string>()}));
  for(const value of values){const parsed=literalIp(value);if(parsed)groups[parsed.group].addresses.add(parsed.address);}
  return groups.filter(group=>group.addresses.size).map(group=>({label:group.label,addresses:[...group.addresses].sort((a,b)=>a.localeCompare(b,'en',{numeric:true}))}));
}

/** Browser ICE exposes candidate origins, not OS adapter or VPN-owner names. */
export function groupIpSources(values:Iterable<string>):IpSource[] {
  const sources=new Map<string,string[]>();
  for(const value of values){
    const parsed=literalIp(value);if(!parsed)continue;
    const candidate=/^(?:a=)?candidate:/i.test(value.trim());
    const type=candidate?value.trim().replace(/^a=/,'').split(/\s+/)[7]:'';
    const label=type==='host'?'浏览器本机':type==='srflx'||type==='prflx'?'公网映射':'已发布地址';
    if(!sources.has(label))sources.set(label,[]);
    sources.get(label)!.push(parsed.address);
  }
  return ['浏览器本机','公网映射','已发布地址'].filter(label=>sources.has(label)).map(label=>({label,groups:groupIpAddresses(sources.get(label)!)}));
}

/** Standard host ICE gathering; no STUN/TURN service or privacy-policy changes. */
export async function browserHostCandidates(signal:AbortSignal):Promise<string[]> {
  if(typeof RTCPeerConnection==='undefined' || signal.aborted)return [];
  const peer=new RTCPeerConnection({iceServers:[]}),values:string[]=[];
  try {
    return await new Promise<string[]>((resolve,reject)=>{
      let finished=false;
      const finish=()=>{if(finished)return;finished=true;clearTimeout(timer);signal.removeEventListener('abort',finish);resolve(values);};
      const timer=setTimeout(finish,1200);
      signal.addEventListener('abort',finish,{once:true});
      peer.onicecandidate=event=>{if(event.candidate)values.push(event.candidate.candidate);else finish();};
      peer.createDataChannel('local-addresses');
      void peer.createOffer().then(offer=>{if(!signal.aborted && !finished)return peer.setLocalDescription(offer);}).catch(error=>{
        if(finished)return;finished=true;clearTimeout(timer);signal.removeEventListener('abort',finish);reject(error);
      });
    });
  } finally {peer.close();}
}
