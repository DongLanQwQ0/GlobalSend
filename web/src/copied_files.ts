import type { CopiedFileOffer, CopiedFilePull } from '../../packages/protocol/src/index.ts';

type Request = <T>(path:string, body?:unknown, method?:string)=>Promise<T>;
export interface CopiedReference {
  id:string; offer:CopiedFileOffer; item:CopiedFileOffer['items'][number];
  state:CopiedFilePull['state']|'received'|''; error:string; localKey?:string; completedAtMillis:number;
}

/** Receiver-only references. Bytes and receipts stay in the existing transfer pipeline. */
export class CopiedFilesReceiver {
  offers:CopiedFileOffer[]=[];
  error='';
  private received=new Map<string,{key:string;completedAtMillis:number}>();
  remember(source:string,context:{offerId:string;itemId:string},key:string,completedAtMillis=Date.now()){const id=`copied:${source}:${context.offerId}:${context.itemId}`,previous=this.received.get(id);if(previous?.key===key || previous && previous.completedAtMillis>completedAtMillis)return;this.received.set(id,{key,completedAtMillis});this.changed();}
  reconcile(local:(key:string)=>boolean){for(const [id,{key}] of this.received)if(!local(key)){this.received.delete(id);for(const [request,pull] of this.pulls)if(id===`copied:${pull.sourceDeviceId}:${pull.offerId}:${pull.itemIds[0]}`)this.pulls.delete(request);}}
  private pulls=new Map<string,CopiedFilePull>();
  private dismissed=new Set<string>();
  private epoch=0;
  private refreshWork:Promise<void>|null=null;
  private refreshAgain=false;
  private request:Request;
  private changed:()=>void;
  private newId:()=>string;
  constructor(request:Request,changed:()=>void,newId=()=>crypto.randomUUID()){this.request=request;this.changed=changed;this.newId=newId;}
  reset(){this.epoch++;this.offers=[];this.error='';this.pulls.clear();this.dismissed.clear();this.refreshWork=null;this.refreshAgain=false;}
  get references():CopiedReference[]{return this.offers.flatMap(offer=>offer.items.map((item):CopiedReference=>{
    const id=`copied:${offer.sourceDeviceId}:${offer.offerId}:${item.id}`;
    const pull=[...this.pulls.values()].filter(value=>value.sourceDeviceId===offer.sourceDeviceId && value.offerId===offer.offerId && value.itemIds.includes(item.id)).at(-1);
    const local=this.received.get(id);
    return {id,offer,item,localKey:local?.key,completedAtMillis:local?.completedAtMillis || 0,state:local?'received':pull?.state==='sent'?'sending':pull?.state || '',error:pull?.error || ''};
  })).filter(value=>!this.dismissed.has(value.id)).sort((a,b)=>b.completedAtMillis-a.completedAtMillis);}
  dismiss(id:string){this.dismissed.add(id);this.changed();}
  async refresh():Promise<void>{
    if(this.refreshWork){this.refreshAgain=true;return this.refreshWork;}
    const epoch=this.epoch;
    const work=(async()=>{
      do {
        this.refreshAgain=false;
        try {
          const {offers}=await this.request<{offers:CopiedFileOffer[]}>('/clipboard/files');
          if(epoch!==this.epoch)return;
          this.offers=offers;this.error='';
          const active=new Set(offers.map(offer=>`${offer.sourceDeviceId}/${offer.offerId}`));
          for(const [id,pull] of this.pulls)if(!active.has(`${pull.sourceDeviceId}/${pull.offerId}`))this.pulls.delete(id);
          await Promise.all([...this.pulls.values()].filter(pull=>pull.state==='pending' || pull.state==='sending').map(async pull=>{
            try{
              const latest=await this.request<CopiedFilePull>(`/clipboard/files/pulls/${encodeURIComponent(pull.requestId)}`);
              if(epoch===this.epoch)this.receive(latest);
            }catch(error){if(epoch===this.epoch && this.pulls.get(pull.requestId)===pull)this.receive({...pull,state:'failed',error:error instanceof Error?error.message:'拉取状态更新失败'});}
          }));
          if(epoch!==this.epoch)return;
        }catch(error){if(epoch!==this.epoch)return;this.error=error instanceof Error?error.message:'文件引用刷新失败';}
        this.changed();
      }while(epoch===this.epoch && this.refreshAgain);
    })();
    this.refreshWork=work;
    try{await work;}finally{if(this.refreshWork===work)this.refreshWork=null;}
  }
  receive(pull:CopiedFilePull){
    if(!this.offers.some(offer=>offer.sourceDeviceId===pull.sourceDeviceId && offer.offerId===pull.offerId))return;
    const old=this.pulls.get(pull.requestId);
    if(old && (old.state==='sent' || old.state==='failed'))return;
    this.pulls.set(pull.requestId,pull);this.changed();
  }
  async pull(id:string){
    const reference=this.references.find(value=>value.id===id);
    if(!reference || reference.state==='pending' || reference.state==='sending' || reference.state==='received')return;
    const epoch=this.epoch,requestId=this.newId(),{offer,item}=reference;
    const pending:CopiedFilePull={requestId,offerId:offer.offerId,sourceDeviceId:offer.sourceDeviceId,targetDeviceId:'',groupId:offer.groupId,itemIds:[item.id],state:'pending'};
    this.pulls.set(requestId,pending);this.changed();
    try{
      const result=await this.request<CopiedFilePull>(`/clipboard/files/${encodeURIComponent(offer.sourceDeviceId)}/pull`,{requestId,offerId:offer.offerId,itemIds:[item.id]});
      if(epoch===this.epoch && this.pulls.get(requestId)===pending)this.receive(result);
    }catch(error){if(epoch===this.epoch && this.pulls.get(requestId)===pending)this.receive({...pending,state:'failed',error:error instanceof Error?error.message:'拉取失败'});}
  }
}
