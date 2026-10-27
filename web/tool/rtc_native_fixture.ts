import { Api } from '../src/api';
import { RtcFileChannel, RtcFileStore } from '../src/rtc';
import { digestFile } from '../src/files';
import type { Session, Transfer } from '../src/model';
import type { RtcView } from '../src/rtc';

// Synthetic consumer of the same channel and disk-backed store used by the UI.
let api:Api, store:RtcFileStore, channel:RtcFileChannel|null=null;
let state='idle',error='',progress=0,receivedHash='',startedOffset=0;
let pending:Promise<void>|null=null;
const controller=new AbortController();
const pattern=(start:number,length:number)=>Uint8Array.from({length},(_,i)=>(start+i)%251);
function run(action:()=>Promise<void>) {
  if(state==='running')throw new Error('Fixture is already running');
  state='running';error='';progress=0;receivedHash='';
  pending=action().then(()=>{state='done';}).catch(failure=>{state='failed';error=String(failure.stack || failure);});
}
const fixture={
  async configure(session:Session) {
    api=new Api(location.origin,session);store=new RtcFileStore('synthetic-native-interop:'+session.device.deviceId);await store.ready;
    await api.request('/devices/me/rtc',{scopes:['lan','public']});
  },
  receive(transfer:Transfer,offset:number) {
    run(async()=>{
      const file=transfer.files[0],key=transfer.transferId+':'+file.fileId;
      let committed=await store.open(key,file,Date.parse(transfer.expiresAt));
      if(offset && !committed)committed=await store.write(key,0,pattern(0,offset).buffer);
      startedOffset=committed;progress=committed;
      const {rtc}=await api.request<{rtc:RtcView}>(`/transfers/${transfer.transferId}/files/${file.fileId}/rtc`,{attemptId:crypto.randomUUID(),scope:'lan',offset:committed});
      channel=new RtcFileChannel(api,rtc,'target',[],controller.signal);
      try {
        await channel.receive(file.size,async bytes=>{
          committed=await store.write(key,committed,bytes);progress=committed;return committed;
        },async()=>{
          const saved=await store.finish(key);receivedHash=await digestFile(saved);
          if(saved.size!==file.size || receivedHash!==file.sha256)throw new Error('Disk file integrity mismatch');
        });
        await api.request(`/transfers/${transfer.transferId}/files/${file.fileId}/received`,{transport:'direct'});
        await store.confirm(key);
      } finally {await channel.close();await store.close(key);channel=null;}
    });
  },
  send(transfer:Transfer,rtc:RtcView) {
    run(async()=>{
      const file=transfer.files[0],parts:Uint8Array<ArrayBuffer>[]=[];
      for(let offset=0;offset<file.size;offset+=16384)parts.push(pattern(offset,Math.min(16384,file.size-offset)));
      const source=new File(parts,file.name,{type:file.mimeType});
      startedOffset=rtc.offset;
      channel=new RtcFileChannel(api,rtc,'source',[],controller.signal);
      try {await channel.send(source,count=>progress=count);}
      finally {await channel.close();channel=null;}
    });
  },
  state:()=>({state,error,progress,receivedHash,startedOffset}),
  async close() {controller.abort();await channel?.close();await pending;await store?.dispose();},
};
Object.assign(window,{fixture});
