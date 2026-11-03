/** One persistent local ledger; retries reuse their original protocol identity. */
export class DeviceUsage {
  private operations = new Map<string, Set<string>>();
  private readonly write:(value:string)=>void;
  constructor(read:()=>string|null=()=>null, write:(value:string)=>void=()=>{}) {
    this.write=write;
    const data=read();
    if(data)for(const [device,operations] of Object.entries(JSON.parse(data) as Record<string,string[]>))this.operations.set(device,new Set(operations));
  }
  record(device:string,operation:string) {
    let entries=this.operations.get(device);if(!entries)this.operations.set(device,entries=new Set());
    if(entries.has(operation))return false;
    entries.add(operation);this.write(JSON.stringify(Object.fromEntries([...this.operations].map(([id,set])=>[id,[...set]]))));return true;
  }
  rank<T extends {deviceId:string}>(devices:readonly T[]):T[] {
    const unique=new Map(devices.map(device=>[device.deviceId,device]));
    const order=new Map([...unique.keys()].map((id,index)=>[id,index]));
    return [...unique.values()].sort((a,b)=>(this.operations.get(b.deviceId)?.size || 0)-(this.operations.get(a.deviceId)?.size || 0) || order.get(a.deviceId)!-order.get(b.deviceId)!);
  }
}
// Match the app's existing persistence behavior in private/restricted browsers.
const key='globalsend.deviceUsage';
export const deviceUsage=new DeviceUsage(
  ()=>{try{return globalThis.localStorage?.getItem(key) ?? null;}catch{return null;}},
  value=>{try{globalThis.localStorage?.setItem(key,value);}catch{/* Keep the live session usable. */}},
);
export function recordAcceptedDeviceSend(path:string,method:string,body:unknown,usage=deviceUsage) {
  if(method!=='POST' || (path!=='/texts' && path!=='/transfers') || !body || typeof body!=='object')return;
  const value=body as Record<string,unknown>;
  if(value.clipboard!==undefined || value.copiedFile!==undefined)return;
  const target=value.targetDeviceId,operation=path==='/texts'?value.eventId:value.transferId;
  if(typeof target==='string' && typeof operation==='string')usage.record(target,`${path}:${operation}`);
}
