import type { RoutePreference } from '../../packages/protocol/src/index';
import type { OfferFile } from './folder_send.ts';

export interface StagedText {id:string;text:string;target?:string}
export interface QueueOffer {
  transferId:string;targetDeviceId:string;routePreference:RoutePreference;
  files:(OfferFile & {fileId:string})[];
}
export interface TargetProgress {
  state:'queued'|'sending'|'sent'|'failed';
  textIds:string[];nextText:number;offer:QueueOffer|null;filesSent:boolean;
}

/** One confirmed snapshot, shared by every selected recipient and by retries. */
export class SendBatch {
  readonly files:File[];
  readonly texts:{id:string;text:string}[];
  readonly targets=new Map<string,TargetProgress>();
  metadata:Omit<QueueOffer['files'][number],'fileId'>[]|null=null;
  sources:(File|undefined)[]=[];
  constructor(files:File[],texts:StagedText[],readonly route:RoutePreference) {
    this.files=[...files];this.texts=texts.map(({id,text})=>({id,text}));
  }
  matches(files:File[],texts:StagedText[]) {
    return files.length===this.files.length && files.every((file,index)=>file===this.files[index]) &&
      texts.length===this.texts.length && texts.every((text,index)=>text.id===this.texts[index].id && text.text===this.texts[index].text);
  }
  target(id:string) {
    let target=this.targets.get(id);
    if(!target){target={state:'queued',textIds:this.texts.map(()=>crypto.randomUUID()),nextText:0,offer:null,filesSent:false};this.targets.set(id,target);}
    return target;
  }
  get complete(){return this.targets.size>0 && [...this.targets.values()].every(target=>target.state==='sent');}
}
