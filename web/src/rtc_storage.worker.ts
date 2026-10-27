// OPFS uses a dedicated worker so Safari can stream into one file without a
// second permanent copy or a file-sized in-memory Blob.
import { cleanupDue, cleanupMatches, defaultCleanup, validateCleanup } from './cleanup';
import type { CleanupPreferences } from './cleanup';
import { FolderStorage, destinationSetting, receivingDestination } from './folder_storage';
import type { StoredLocation } from './folder_storage';
interface Access {
  getSize(): number|Promise<number>;
  truncate(size: number): void|Promise<void>;
  write(bytes: Uint8Array, options: {at:number}): number|Promise<number>;
  flush(): void|Promise<void>;
  close(): void|Promise<void>;
}
type Handle = FileSystemFileHandle & {createSyncAccessHandle():Promise<Access>};
type Directory = FileSystemDirectoryHandle & {values():AsyncIterable<FileSystemHandle>};
type Metadata = StoredLocation & {key:string;name:string;mimeType?:string;size:number;sha256?:string;receivedAt?:number;expires:number;complete:boolean};
let appDirectory:Directory;
let directory: Directory;
const opened = new Map<string,{access:Access;handle:Handle;offset:number;meta:Metadata}>();
const keyName = (key:string) => encodeURIComponent(key);
async function metadata(meta:Metadata,target:Directory=directory) {
  const handle=await target.getFileHandle(`${keyName(meta.key)}.json`,{create:true}) as Handle;
  const access=await handle.createSyncAccessHandle();
  try {const data=new TextEncoder().encode(JSON.stringify(meta));await access.truncate(0);await access.write(data,{at:0});await access.flush();}
  finally {await access.close();}
}
async function readMeta(key:string) {
  const handle=await directory.getFileHandle(`${keyName(key)}.json`);
  return JSON.parse(await (await handle.getFile()).text()) as Metadata;
}
async function accessFile(handle:FileSystemFileHandle,external=false):Promise<Access>{
  if(!external && typeof (handle as Handle).createSyncAccessHandle==='function')return (handle as Handle).createSyncAccessHandle();
  // External File System Access handles support writable streams, not OPFS
  // sync handles. Commit each chunk so a browser restart can resume its prefix.
  let writer=await handle.createWritable({keepExistingData:true}),size=(await handle.getFile()).size;
  return {getSize:()=>size,truncate:async n=>{await writer.truncate(n);size=n;},write:async(bytes,{at})=>{await writer.write({type:'write',position:at,data:bytes as Uint8Array<ArrayBuffer>});size=Math.max(size,at+bytes.length);return bytes.length;},flush:async()=>{await writer.close();writer=await handle.createWritable({keepExistingData:true});},close:()=>writer.close()};
}
async function dataHandle(meta:Metadata,target:Directory=directory,create=false){return meta.storagePath?new FolderStorage(target).file(meta,create):target.getFileHandle(`${keyName(meta.key)}.data`,{create});}
async function dataFile(meta:Metadata,target:Directory=directory){
  if(meta.entryKind==='directory'){const folder=new FolderStorage(target);const {parent,name}=await folder.parent(meta);await parent.getDirectoryHandle(name);return null;}
  return (await dataHandle(meta,target)).getFile();
}
async function removeData(meta:Metadata,target:Directory=directory){
  if(meta.storagePath)await new FolderStorage(target).remove(meta);
  else await target.removeEntry(keyName(meta.key)+'.data').catch(error=>{if(error.name!=='NotFoundError')throw error;});
}
async function close(key:string) {
  const entry=opened.get(key);if(!entry)return;
  await entry.access.flush();await entry.access.close();opened.delete(key);
}
async function remove(key:string,cascade=true) {
  await close(key);
  let meta:Metadata;try{meta=await readMeta(key);}catch(error){if((error as Error).name==='NotFoundError')return;throw error;}
  if(cascade && meta.entryKind==='directory')await removeOwned(meta,directory);
  else {await removeData(meta);await directory.removeEntry(keyName(key)+'.json');}
}
async function cleanup() {
  const rules=await cleanupPreferences();
  const expired:Metadata[]=[];
  for await(const handle of directory.values()) {
    if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
    const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
    if(meta.complete && cleanupDue({name:meta.name,size:meta.size,receivedAt:meta.receivedAt ?? meta.expires-86400000},rules) && !opened.has(meta.key))expired.push(meta);
  }
  expired.sort((a,b)=>(a.entryKind==='directory'?1:0)-(b.entryKind==='directory'?1:0) || (b.relativePath?.split('/').length || 0)-(a.relativePath?.split('/').length || 0));
  for(const meta of expired)await remove(meta.key,false).catch(error=>{if(error.name!=='NotAllowedError')throw error;});
}
async function cleanupPreferences():Promise<CleanupPreferences> {
  try{return JSON.parse(await (await (await appDirectory.getFileHandle('cleanup-preferences.json')).getFile()).text());}
  catch(error){if((error as Error).name==='NotFoundError')return defaultCleanup();throw error;}
}
async function writeCleanup(value:CleanupPreferences) {
  const handle=await appDirectory.getFileHandle('cleanup-preferences.json',{create:true}) as Handle,access=await handle.createSyncAccessHandle();
  try{const bytes=new TextEncoder().encode(JSON.stringify(value));await access.truncate(0);await access.write(bytes,{at:0});await access.flush();}
  finally{await access.close();}
}
function libraryParts(id:string) {
  const slash=id.indexOf('/');
  if(slash<1)throw new Error('本机文件不存在');
  return {scope:id.slice(0,slash),key:decodeURIComponent(id.slice(slash+1))};
}
async function libraryFile(id:string) {
  const {scope,key}=libraryParts(id);
  const target=await appDirectory.getDirectoryHandle(scope) as Directory;
  const meta=JSON.parse(await (await (await target.getFileHandle(`${keyName(key)}.json`)).getFile()).text()) as Metadata;
  if(!meta.complete || cleanupDue({name:meta.name,size:meta.size,receivedAt:meta.receivedAt ?? meta.expires-86400000},await cleanupPreferences()))throw new Error('文件已清理');
  const file=await dataFile(meta,target);
  return {target,meta,file,scope,key};
}
function libraryEntry(scope:string,meta:Metadata,file:File|null,rules:CleanupPreferences=defaultCleanup()) {
  return {id:`${scope}/${keyName(meta.key)}`,scope,key:meta.key,name:meta.name,mimeType:meta.mimeType || file?.type || '',size:file?.size ?? 0,
    entryKind:meta.entryKind || 'file',relativePath:meta.relativePath,storagePath:meta.storagePath,transferId:meta.transferId,
    ...(meta.sha256?{sha256:meta.sha256}:{}),receivedAt:meta.receivedAt ?? Math.min(file?.lastModified ?? meta.expires-86400000,meta.expires-86400000),expiresAt:(meta.receivedAt ?? meta.expires-86400000)+rules.retentionHours*3600000};
}
async function removeLibraryFile(target:Directory,key:string) {
  const meta=JSON.parse(await (await (await target.getFileHandle(keyName(key)+'.json')).getFile()).text()) as Metadata;
  await removeData(meta,target);await target.removeEntry(keyName(key)+'.json');
}
async function removeOwned(meta:Metadata,target:Directory){
  const owned:Metadata[]=[meta];
  if(meta.entryKind==='directory')for await(const handle of target.values()){
    if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
    const child=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
    if(child.key!==meta.key && child.transferId===meta.transferId && child.relativePath?.startsWith(meta.relativePath!+'/'))owned.push(child);
  }
  owned.sort((a,b)=>(a.entryKind==='directory'?1:0)-(b.entryKind==='directory'?1:0) || (b.storagePath?.split('/').length || 0)-(a.storagePath?.split('/').length || 0));
  for(const child of owned){if(target===directory)await close(child.key);await removeLibraryFile(target,child.key);}
}
async function execute(command:string,data:any):Promise<unknown> {
  switch(command) {
    case 'init': {
      const root=await navigator.storage.getDirectory();
      appDirectory=await root.getDirectoryHandle('globalsend-received-v1',{create:true}) as Directory;
      if(data.scope){directory=await appDirectory.getDirectoryHandle(data.scope,{create:true}) as Directory;await cleanup();}
      return {};
    }
    case 'destination-get': {const {id,name}=await receivingDestination();return {id,name};}
    case 'destination-set': {
      if(data.handle){await destinationSetting(data.id,data.handle,true);await destinationSetting('current',data.id,true);}
      else await destinationSetting('current','',true);
      const {id,name}=await receivingDestination();return {id,name};
    }
    case 'directory': {
      let previous:Metadata|undefined;try{previous=await readMeta(data.key);}catch(error){if(!((error as Error).name==='NotFoundError'))throw error;}
      const location=previous?.storagePath?{storagePath:previous.storagePath,destinationId:previous.destinationId,relativePath:previous.relativePath,transferId:previous.transferId}:await new FolderStorage(directory).allocate(data.transferId,data.relativePath);
      const meta={...data,...location,entryKind:'directory',complete:true,receivedAt:previous?.receivedAt || Date.now()} as Metadata;
      meta.expires=meta.receivedAt!+86400000;await new FolderStorage(directory).directory(meta);await metadata(meta);return {meta};
    }
    case 'open': {
      await close(data.key);
      let previous:Metadata|undefined;
      try{previous=await readMeta(data.key);}catch(error){if((error as Error).name!=='NotFoundError')throw error;}
      const location=previous?.storagePath?{storagePath:previous.storagePath,destinationId:previous.destinationId,relativePath:previous.relativePath,transferId:previous.transferId}:data.relativePath?await new FolderStorage(directory).allocate(data.transferId,data.relativePath):{};
      const meta={...data,...location,complete:false} as Metadata;
      const handle=await dataHandle(meta,directory,true) as Handle;
      const access=await accessFile(handle,!!meta.destinationId && meta.destinationId!=='opfs');
      if(!previous || previous.sha256!==data.sha256 || previous.size!==data.size || await access.getSize()>data.size)await access.truncate(0);
      const offset=await access.getSize();
      opened.set(data.key,{handle,access,offset,meta});await metadata(meta);return {offset};
    }
    case 'write': {
      const entry=opened.get(data.key);if(!entry)throw new Error('接收文件已关闭');
      const bytes=new Uint8Array(data.bytes);
      if(data.offset!==entry.offset || entry.offset+bytes.length>entry.meta.size)throw new Error('文件接收位置不匹配');
      if(await entry.access.write(bytes,{at:entry.offset})!==bytes.length)throw new Error('接收空间不足');
      await entry.access.flush();entry.offset+=bytes.length;return {offset:entry.offset};
    }
    case 'finish': {
      const entry=opened.get(data.key);if(!entry || entry.offset!==entry.meta.size)throw new Error('接收文件不完整');
      await close(data.key);return {file:await entry.handle.getFile()};
    }
    case 'confirm': {
      const meta=await readMeta(data.key);meta.complete=true;meta.receivedAt ||= Date.now();meta.expires=meta.receivedAt+86400000;await metadata(meta);const rules=await cleanupPreferences();return {receivedAt:meta.receivedAt,expires:cleanupMatches(meta,rules)?meta.receivedAt+rules.retentionHours*3600000:Infinity};
    }
    case 'get': {
      const meta=await readMeta(data.key);
      const rules=await cleanupPreferences(),receivedAt=meta.receivedAt ?? meta.expires-86400000;
      if(!meta.complete || cleanupDue({...meta,receivedAt},rules))return {};
      return {file:await dataFile(meta),directory:meta.entryKind==='directory',meta:{...meta,expires:cleanupMatches(meta,rules)?receivedAt+rules.retentionHours*3600000:Infinity}};
    }
    case 'close': await close(data.key);return {};
    case 'remove': await remove(data.key);return {};
    case 'cleanup': await cleanup();return {};
    case 'library-list': {
      const rules=await cleanupPreferences();
      const entries=[];
      for await(const scopeHandle of appDirectory.values()) {
        if(scopeHandle.kind!=='directory')continue;
        const target=scopeHandle as Directory;
        const expired:Metadata[]=[];
        for await(const handle of target.values()) {
          if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
          const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
          if(!meta.complete)continue;
          if(cleanupDue({name:meta.name,size:meta.size,receivedAt:meta.receivedAt ?? meta.expires-86400000},rules)) {
            // An active receiver may own this file in a second worker. Leave a
            // locked file alone; its receiving session owns the in-progress lease.
            expired.push(meta);
            continue;
          }
          try {
            const file=await dataFile(meta,target);
            entries.push(libraryEntry(scopeHandle.name,meta,file,rules));
          }catch(error){if((error as Error).name!=='NotFoundError')throw error;}
        }
        expired.sort((a,b)=>(a.entryKind==='directory'?1:0)-(b.entryKind==='directory'?1:0) || (b.relativePath?.split('/').length || 0)-(a.relativePath?.split('/').length || 0));
        for(const meta of expired)await removeLibraryFile(target,meta.key).catch(error=>{if(!['NoModificationAllowedError','NotAllowedError'].includes(error.name))throw error;});
      }
      return {entries};
    }
    case 'library-preferences': {
      if(data.value)await writeCleanup(validateCleanup(data.value));
      return {cleanup:await cleanupPreferences()};
    }
    case 'library-get': {
      const {file,meta,scope}=await libraryFile(data.id);return {file,entry:libraryEntry(scope,meta,file,await cleanupPreferences())};
    }
    case 'library-expand': {
      const expanded=new Map<string,unknown>();
      for(const id of data.ids as string[]) {
        const {target,meta,scope}=await libraryFile(id);
        for await(const handle of target.values()) {
          if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
          const child=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
          if(!child.complete || child.key!==meta.key && !(meta.entryKind==='directory' && child.transferId===meta.transferId && child.relativePath?.startsWith(meta.relativePath!+'/')))continue;
          const file=await dataFile(child,target);const entry=libraryEntry(scope,child,file,await cleanupPreferences());expanded.set(entry.id,{entry,file});
        }
      }
      return {entries:[...expanded.values()]};
    }
    case 'library-rename': {
      const {target,meta,file,scope}=await libraryFile(data.id);
      const name=String(data.name).trim();
      if(!name || name.length>255 || /[\x00-\x1f\\/]/.test(name) || name==='.' || name==='..')throw new Error('请输入有效文件名');
      if(meta.relativePath){
        const previous=meta.relativePath,next=[...previous.split('/').slice(0,-1),name].join('/');
        if(meta.entryKind==='directory')for await(const handle of target.values()){
          if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
          const child=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
          if(child.key!==meta.key && child.transferId===meta.transferId && child.relativePath?.startsWith(previous+'/')){child.relativePath=next+child.relativePath.slice(previous.length);await metadata(child,target);}
        }
        meta.relativePath=next;
      }
      meta.name=name;await metadata(meta,target);return {entry:libraryEntry(scope,meta,file,await cleanupPreferences())};
    }
    case 'library-remove': {
      const {scope,key}=libraryParts(data.id),target=await appDirectory.getDirectoryHandle(scope) as Directory;
      const meta=JSON.parse(await (await (await target.getFileHandle(`${keyName(key)}.json`)).getFile()).text()) as Metadata;
      if(!meta.complete)throw new Error('文件仍在接收中');
      await removeOwned(meta,target);return {};
    }
    case 'shutdown': for(const key of [...opened.keys()])await close(key);return {};
    default: throw new Error('未知接收文件操作');
  }
}
// Serialize all writes and close operations. Cancellation cannot release a file
// while an earlier queued write still owns it.
let queue=Promise.resolve();
self.onmessage=event=>{
  const {id,command,data}=event.data;
  queue=queue.then(async()=>{
    try{self.postMessage({id,result:await execute(command,data)});}
    catch(error){self.postMessage({id,error:(error as Error).message,name:(error as Error).name});}
  });
};
export {};
