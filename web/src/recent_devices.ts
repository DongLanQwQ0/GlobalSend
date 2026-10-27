import type { Device } from './model';

/** Kept only for the current discovery session; offline is never probe-online. */
export class RecentDevices {
  static readonly graceMs=30000;
  deadlines=new Map<string,number>();
  available(device:Device,now=Date.now()) { return !device.revoked && (device.online || (this.deadlines.get(device.deviceId) || 0)>now); }
  merge(previous:Device[],snapshot:Device[],now=Date.now()):Device[] {
    const old=new Map(previous.map(device=>[device.deviceId,device])),incoming=new Map(snapshot.map(device=>[device.deviceId,device])),result:Device[]=[];
    for(const id of new Set([...incoming.keys(),...old.keys()])) {
      const next=incoming.get(id),before=old.get(id);
      if(next?.revoked){this.deadlines.delete(id);continue;}
      if(next?.online){this.deadlines.delete(id);result.push({...next});continue;}
      if(before?.online && !this.deadlines.has(id))this.deadlines.set(id,now+RecentDevices.graceMs);
      if((this.deadlines.get(id) || 0)>now && before)result.push({...before,...next,online:false,peer:next?.peer ?? before.peer,rtc:next?.rtc ?? before.rtc});
      else {this.deadlines.delete(id);if(next)result.push({...next,peer:null,rtc:null});}
    }
    return result;
  }
  clear(){this.deadlines.clear();}
}
