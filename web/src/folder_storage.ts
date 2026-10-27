export type StoredLocation={storagePath?:string;destinationId?:string;entryKind?:'file'|'directory';relativePath?:string;transferId?:string};
type Directory=FileSystemDirectoryHandle & {values():AsyncIterable<FileSystemHandle>};
type PermissionHandle=Directory & {queryPermission(options:{mode:string}):Promise<string>};
type SyncFile=FileSystemFileHandle & {createSyncAccessHandle():Promise<{truncate(n:number):void|Promise<void>;write(b:Uint8Array,o:{at:number}):number|Promise<number>;flush():void|Promise<void>;close():void|Promise<void>}>};
const missing=(error:unknown)=>(error as Error).name==='NotFoundError';
export function pathSegments(path:string){const parts=path.replace(/\/$/,'').split('/');if(parts.some(value=>!value || value==='.' || value==='..'))throw new Error('文件夹路径不完整');return parts;}
async function database() {
  return new Promise<IDBDatabase>((resolve,reject)=>{const open=indexedDB.open('globalsend-receive-destinations-v1',1);open.onupgradeneeded=()=>open.result.createObjectStore('handles');open.onsuccess=()=>resolve(open.result);open.onerror=()=>reject(open.error);});
}
export async function destinationSetting(key:string,value?:unknown,write=false):Promise<any> {
  if(typeof indexedDB==='undefined'){if(write)throw new Error('浏览器不能记住所选目录');return undefined;}
  const db=await database();
  try{return await new Promise((resolve,reject)=>{const tx=db.transaction('handles',write?'readwrite':'readonly'),store=tx.objectStore('handles'),request=write?store.put(value,key):store.get(key);let result:unknown;request.onsuccess=()=>result=request.result;tx.oncomplete=()=>resolve(write?value:result);tx.onerror=()=>reject(tx.error);});}
  finally{db.close();}
}
export async function receivingDestination(){const id=await destinationSetting('current');const handle=id?await destinationSetting(id):undefined;return {id:id || 'opfs',name:handle?.name || '浏览器文件库',handle};}
async function json(directory:Directory,name:string){try{return JSON.parse(await (await (await directory.getFileHandle(name)).getFile()).text());}catch(error){if(missing(error))return {};throw error;}}
async function saveJson(directory:Directory,name:string,data:unknown){const file=await directory.getFileHandle(name,{create:true}) as SyncFile,access=await file.createSyncAccessHandle();try{const bytes=new TextEncoder().encode(JSON.stringify(data));await access.truncate(0);await access.write(bytes,{at:0});await access.flush();}finally{await access.close();}}
export class FolderStorage {
  constructor(private scope:Directory){}
  private async base(destinationId='opfs'):Promise<Directory>{
    if(destinationId==='opfs')return await this.scope.getDirectoryHandle('received',{create:true}) as Directory;
    const handle=await destinationSetting(destinationId) as PermissionHandle|undefined;
    if(!handle || await handle.queryPermission({mode:'readwrite'})!=='granted')throw Object.assign(new Error('请重新授权接收目录'),{name:'NotAllowedError'});
    return handle;
  }
  async allocate(transferId:string,relativePath:string):Promise<StoredLocation>{
    const parts=pathSegments(relativePath),root=parts[0],key=JSON.stringify([transferId,root]);
    const roots=await json(this.scope,'folder-roots.json');
    let reserved=roots[key];
    if(!reserved){
      const destination=await receivingDestination(),base=await this.base(destination.id);
      let name=root,index=0;
      for(;;){try{await base.getDirectoryHandle(name);name=`${root} (${++index})`;}catch(error){if(missing(error))break;if((error as Error).name==='TypeMismatchError'){name=`${root} (${++index})`;continue;}throw error;}}
      reserved={name,destinationId:destination.id};roots[key]=reserved;
      // Persist the reservation before creating bytes; re-opening this transfer
      // reuses exactly this root, including an interrupted zero-byte directory.
      await saveJson(this.scope,'folder-roots.json',roots);
    }
    return {storagePath:[reserved.name,...parts.slice(1)].join('/'),destinationId:reserved.destinationId,relativePath,transferId};
  }
  async parent(location:StoredLocation,create=false){const parts=pathSegments(location.storagePath!);let parent=await this.base(location.destinationId);for(const part of parts.slice(0,-1))parent=await parent.getDirectoryHandle(part,{create}) as Directory;return {parent,name:parts.at(-1)!};}
  async directory(location:StoredLocation){const {parent,name}=await this.parent(location,true);await parent.getDirectoryHandle(name,{create:true});}
  async file(location:StoredLocation,create=false){const {parent,name}=await this.parent(location,create);return parent.getFileHandle(name,{create});}
  async remove(location:StoredLocation){
    try{const {parent,name}=await this.parent(location);await parent.removeEntry(name);}
    catch(error){if(missing(error))return;if(location.entryKind==='directory' && ['InvalidModificationError','NoModificationAllowedError'].includes((error as Error).name))return;throw error;}
  }
}
