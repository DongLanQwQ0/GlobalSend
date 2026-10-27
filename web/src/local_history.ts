import type { Transfer, WireEvent } from './model';

export interface LocalHistoryScope {
  scope:string;deviceId:string;events:WireEvent[];transfers:Transfer[];
  names:Record<string,string>;receivedAt:Record<string,string>;hidden:Record<string,number>;
}
/** One local user's content; authentication remains in the active session. */
export class LocalHistory {
  scopes:LocalHistoryScope[]=[];
  private write:(value:string)=>void;
  constructor(read:()=>string|null,write:(value:string)=>void){
    this.write=write;
    const stored=read();if(stored){try{this.scopes=JSON.parse(stored).scopes || [];}catch{/* Preserve the live session if an old snapshot is incomplete. */}}
  }
  remember(value:LocalHistoryScope){
    const previous=this.scopes.find(scope=>scope.scope===value.scope),hidden={...previous?.hidden,...value.hidden};
    const events=[...new Map([...(previous?.events || []),...value.events].map(event=>[event.eventId,event])).values()].filter(event=>!(hidden['text:'+event.eventId]>Date.now()));
    const transfers=[...new Map([...(previous?.transfers || []),...value.transfers].map(transfer=>[transfer.transferId,transfer])).values()];
    const snapshot:LocalHistoryScope={scope:value.scope,deviceId:value.deviceId,events,transfers,names:{...previous?.names,...value.names},receivedAt:{...previous?.receivedAt,...value.receivedAt},hidden};
    this.scopes=[...this.scopes.filter(scope=>scope.scope!==value.scope),JSON.parse(JSON.stringify(snapshot))];this.save();
  }
  save(){this.write(JSON.stringify({format:1,scopes:this.scopes}));}
  event(id:string){for(const scope of this.scopes){const event=scope.events.find(event=>event.eventId===id);if(event)return {event,scope};}}
  transfer(id:string){for(const scope of this.scopes){const transfer=scope.transfers.find(transfer=>transfer.transferId===id);if(transfer)return {transfer,scope};}}
  removeText(id:string){for(const scope of this.scopes)scope.events=scope.events.filter(event=>event.eventId!==id && event.payload.sourceEventId!==id);this.save();}
  removeFile(transferId:string,fileId:string){for(const scope of this.scopes)for(const transfer of scope.transfers)if(transfer.transferId===transferId)transfer.files=transfer.files.filter(file=>file.fileId!==fileId);this.save();}
}
