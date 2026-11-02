export interface ClipboardSlotValue {
  id:string; scope?:string; source:string; at:string; text?:string; key?:string; name?:string; mimeType?:string; file?:File;
}
/** Transport data is not a receipt. There is exactly one receiver slot. */
export class ClipboardSlot {
  value:ClipboardSlotValue|null=null;
  enabled=true;
  private write:(value:string)=>void;
  constructor(read:()=>string|null,write:(value:string)=>void){
    this.write=write;
    try{const saved=JSON.parse(read() || '{}');this.enabled=saved.enabled!==false;this.value=saved.value || null;}catch{/* A fresh slot needs no migration. */}
  }
  private save(){const value=this.value?{...this.value,file:undefined}:null;this.write(JSON.stringify({enabled:this.enabled,value}));}
  receive(value:ClipboardSlotValue){if(!this.enabled || this.value && (this.value.id===value.id || this.value.at>value.at))return false;this.value=value;this.save();return true;}
  setEnabled(value:boolean){this.enabled=value;this.save();}
  clear(){this.value=null;this.save();}
  get current(){return this.enabled?this.value:null;}
}
