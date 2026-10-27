import {existsSync,mkdirSync,readdirSync,readFileSync,statSync,openSync,closeSync,ftruncateSync,writeSync,fsyncSync,unlinkSync,rmdirSync} from 'node:fs';
import {join,basename} from 'node:path';
import {runInNewContext} from 'node:vm';

const error=(name:string)=>Object.assign(new Error(name),{name});
function actualError(e:any){if(e.code==='ENOENT')throw error('NotFoundError');if(e.code==='ENOTEMPTY')throw error('InvalidModificationError');throw e;}
export class DiskFile {
  kind='file';name:string;path:string;external:boolean;
  constructor(path:string,external=false){this.path=path;this.external=external;this.name=basename(path);}
  async getFile(){try{return new File([readFileSync(this.path)],this.name,{lastModified:statSync(this.path).mtimeMs});}catch(e){return actualError(e);}}
  async createSyncAccessHandle(){
    if(this.external)throw new Error('External handles must use createWritable');
    const fd=openSync(this.path,'r+');
    return {getSize:()=>statSync(this.path).size,truncate:(size:number)=>ftruncateSync(fd,size),write:(bytes:Uint8Array,{at}:{at:number})=>writeSync(fd,bytes,0,bytes.length,at),flush:()=>fsyncSync(fd),close:()=>closeSync(fd)};
  }
  async createWritable({keepExistingData=false}={}){
    const fd=openSync(this.path,keepExistingData?'r+':'w');let cursor=0,closed=false;
    const write=async(value:any)=>{const bytes=value?.type==='write'?value.data:value;const at=value?.type==='write'?value.position:cursor;writeSync(fd,bytes,0,bytes.length,at);cursor=at+bytes.length;};
    const close=async()=>{if(!closed){fsyncSync(fd);closeSync(fd);closed=true;}};
    const stream=new WritableStream({write,close,abort:close}) as any;
    Object.assign(stream,{write,close,abort:close,truncate:async(size:number)=>ftruncateSync(fd,size)});return stream;
  }
}
export class DiskDirectory {
  kind='directory';name:string;path:string;external:boolean;
  constructor(path:string,external=false){this.path=path;this.external=external;this.name=basename(path);mkdirSync(path,{recursive:true});}
  async queryPermission(){return 'granted';}
  async isSameEntry(other:DiskDirectory){return this.path===other.path;}
  async getDirectoryHandle(name:string,{create=false}={}){
    const path=join(this.path,name);if(!existsSync(path)){if(!create)throw error('NotFoundError');mkdirSync(path);}
    if(!statSync(path).isDirectory())throw error('TypeMismatchError');return new DiskDirectory(path,this.external);
  }
  async getFileHandle(name:string,{create=false}={}){
    const path=join(this.path,name);if(!existsSync(path)){if(!create)throw error('NotFoundError');closeSync(openSync(path,'wx'));}
    if(statSync(path).isDirectory())throw error('TypeMismatchError');return new DiskFile(path,this.external);
  }
  async *values(){for(const name of readdirSync(this.path)){const path=join(this.path,name);yield statSync(path).isDirectory()?new DiskDirectory(path,this.external):new DiskFile(path,this.external);}}
  async removeEntry(name:string){try{const path=join(this.path,name);statSync(path).isDirectory()?rmdirSync(path):unlinkSync(path);}catch(e){actualError(e);}}
}
export function indexedDBFixture(){
  const values=new Map<string,unknown>();
  const db={close(){},createObjectStore(){},transaction(){const tx:any={objectStore:()=>({get(key:string){const request:any={};queueMicrotask(()=>{request.result=values.get(key);request.onsuccess?.();tx.oncomplete?.();});return request;},put(value:unknown,key:string){const request:any={};queueMicrotask(()=>{values.set(key,value);request.result=key;request.onsuccess?.();tx.oncomplete?.();});return request;}})};return tx;}};
  return {open(){const request:any={};queueMicrotask(()=>{request.result=db;request.onsuccess?.();});return request;}};
}
export function diskWorkerFactory(code:string,root:DiskDirectory,indexedDB=indexedDBFixture()){
  return class Worker {
    onmessage:((event:any)=>void)|null=null;onerror:any=null;closed=false;
    private context:any;
    constructor(_url:unknown,_options?:unknown){
      const self={postMessage:(message:unknown)=>queueMicrotask(()=>{if(!this.closed)this.onmessage?.({data:message});})};
      this.context={self,navigator:{storage:{getDirectory:async()=>root}},indexedDB,TextEncoder,TextDecoder,Uint8Array,Map,Set,JSON,Error,Infinity,Promise,Number,String,Date,decodeURIComponent,encodeURIComponent};
      runInNewContext(code,this.context);
    }
    postMessage(message:unknown){this.context.self.onmessage({data:message});}
    terminate(){this.closed=true;}
  };
}
