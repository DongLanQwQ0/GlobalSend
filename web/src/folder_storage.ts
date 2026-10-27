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
  async base(destinationId='opfs'):Promise<Directory>{
    if(destinationId==='opfs')return await this.scope.getDirectoryHandle('received',{create:true}) as Directory;
    const handle=await destinationSetting(destinationId) as PermissionHandle|undefined;
    if(!handle || await handle.queryPermission({mode:'readwrite'})!=='granted')throw Object.assign(new Error('请重新授权接收目录'),{name:'NotAllowedError'});
    return handle;
  }
  async roots(){return json(this.scope,'folder-roots.json');}
  async saveRoots(roots:Record<string,{name:string;destinationId:string}>){await saveJson(this.scope,'folder-roots.json',roots);}
  async reserveName(name:string,destinationId:string){
    const base=await this.base(destinationId),dot=name.lastIndexOf('.');
    const stem=dot>0?name.slice(0,dot):name,extension=dot>0?name.slice(dot):'';
    let candidate=name,index=0;
    for(;;){
      try{await base.getFileHandle(candidate);}
      catch(error){if(missing(error))return candidate;if((error as Error).name!=='TypeMismatchError')throw error;}
      candidate=`${stem} (${++index})${extension}`;
    }
  }
  async allocateFile(name:string,destinationId?:string):Promise<StoredLocation>{
    const destination=destinationId ?? (await receivingDestination()).id;
    return {storagePath:await this.reserveName(name,destination),destinationId:destination};
  }
  async allocate(transferId:string,relativePath:string):Promise<StoredLocation>{
    const destination=await receivingDestination();
    const parts=pathSegments(relativePath),root=parts[0],key=JSON.stringify([destination.id,transferId,root]);
    const roots=await json(this.scope,'folder-roots.json');
    const legacy=roots[JSON.stringify([transferId,root])];
    let reserved=roots[key] || (legacy?.destinationId===destination.id?legacy:undefined);
    if(!reserved){
      const name=await this.reserveName(root,destination.id);
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
  async remove(location:StoredLocation,cleanParents=false){
    try{const {parent,name}=await this.parent(location);await parent.removeEntry(name);}
    catch(error){if(missing(error))return;if(location.entryKind==='directory' && ['InvalidModificationError','NoModificationAllowedError'].includes((error as Error).name))return;throw error;}
    // Nested parents may have been made implicitly by a file receive rather
    // than recorded as separate directory entries. Remove them only if empty.
    if(!cleanParents)return;
    const parts=pathSegments(location.storagePath!);
    for(let depth=parts.length-1;depth>0;depth--){
      const parentLocation={...location,storagePath:parts.slice(0,depth).join('/')};
      try{const {parent,name}=await this.parent(parentLocation);await parent.removeEntry(name);}
      catch(error){if(missing(error))continue;if(['InvalidModificationError','NoModificationAllowedError'].includes((error as Error).name))break;throw error;}
    }
  }
}
