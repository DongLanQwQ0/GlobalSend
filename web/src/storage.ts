/** RPC for the single-writer OPFS worker; no file payload is retained here. */
export class OpfsStorage {
  private worker:Worker;
  private counter=0;
  private pending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void}>();
  readonly ready:Promise<void>;
  scopeName:string|null=null;
  constructor(scope?:string) {
    this.worker=new Worker(new URL('./rtc_storage.worker.ts',import.meta.url),{type:'module'});
    this.worker.onmessage=event=>{
      const waiter=this.pending.get(event.data.id);if(!waiter)return;this.pending.delete(event.data.id);
      event.data.error?waiter.reject(Object.assign(new Error(event.data.error),{name:event.data.name})):waiter.resolve(event.data.result);
    };
    this.worker.onerror=event=>{for(const waiter of this.pending.values())waiter.reject(new Error(event.message || '本机文件存储不可用'));this.pending.clear();};
    this.ready=(async()=>{
      let name:string|undefined;
      if(scope!==undefined) {
        const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(scope));
        name=Array.from(new Uint8Array(hash),byte=>byte.toString(16).padStart(2,'0')).join('');
      }
      this.scopeName=name ?? null;
      await this.request('init',{scope:name});
    })();
  }
  private request<T=any>(command:string,data:unknown,transfer:Transferable[]=[]):Promise<T> {
    const id=++this.counter;
    return new Promise((resolve,reject)=>{this.pending.set(id,{resolve,reject});this.worker.postMessage({id,command,data},transfer);});
  }
  async call<T=any>(command:string,data:unknown,transfer:Transferable[]=[]):Promise<T> {await this.ready;return this.request(command,data,transfer);}
  async dispose() {try{await this.call('shutdown',{});}finally{this.worker.terminate();}}
}
export const localStorageSupported=()=>typeof Worker!=='undefined' && typeof navigator.storage?.getDirectory==='function';
