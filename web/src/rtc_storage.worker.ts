// OPFS uses a dedicated worker so Safari can stream into one file without a
// second permanent copy or a file-sized in-memory Blob.
import { sha256 } from '@noble/hashes/sha2.js';
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
type Metadata = StoredLocation & {key:string;name:string;mimeType?:string;size:number;sha256?:string;receivedAt?:number;expires:number;complete:boolean;alias?:{scope:string;key:string}};
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
async function canonical(meta:Metadata,target:Directory){
  if(!meta.alias)return {meta,target};
  target=await appDirectory.getDirectoryHandle(meta.alias.scope) as Directory;
  meta=JSON.parse(await (await (await target.getFileHandle(`${keyName(meta.alias.key)}.json`)).getFile()).text()) as Metadata;
  return {meta,target};
}
async function dataFile(meta:Metadata,target:Directory=directory){
  ({meta,target}=await canonical(meta,target));
  if(meta.entryKind==='directory'){const folder=new FolderStorage(target);const {parent,name}=await folder.parent(meta);await parent.getDirectoryHandle(name);return null;}
  return (await dataHandle(meta,target)).getFile();
}
async function removeData(meta:Metadata,target:Directory=directory,cleanParents=false){
  if(meta.alias)return;
  if(meta.storagePath)await new FolderStorage(target).remove(meta,cleanParents);
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
  else await removeLibraryFile(directory,key);
}
async function cleanup() {
  const rules=await cleanupPreferences();
  const expired:Metadata[]=[];
  for await(const handle of directory.values()) {
    if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
    const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
    if(meta.complete && !meta.alias && cleanupDue({name:meta.name,size:meta.size,receivedAt:meta.receivedAt ?? meta.expires-86400000},rules) && !opened.has(meta.key))expired.push(meta);
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
  let meta=JSON.parse(await (await (await target.getFileHandle(`${keyName(key)}.json`)).getFile()).text()) as Metadata;
  const source=await canonical(meta,target);if(meta.alias)meta={...meta,receivedAt:source.meta.receivedAt,expires:source.meta.expires};
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
  const owner=await canonical(meta,target);
  // Every delivery references one physical file. Deleting it removes the
  // aliases too, rather than leaving cards pointing at a deleted source.
  for await(const scope of appDirectory.values()){
    if(scope.kind!=='directory')continue;
    const aliases=scope as Directory;
    for await(const handle of aliases.values()){
      if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
      const link=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
      if(link.alias?.scope===owner.target.name && link.alias.key===owner.meta.key)await aliases.removeEntry(handle.name);
    }
  }
  await removeData(owner.meta,owner.target);await owner.target.removeEntry(keyName(owner.meta.key)+'.json');
}
async function removeOwned(meta:Metadata,target:Directory){
  const owned:Metadata[]=[meta];
  if(meta.entryKind==='directory')for await(const handle of target.values()){
    if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
    const child=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
    if(child.key!==meta.key && child.transferId===meta.transferId && child.relativePath?.startsWith(meta.relativePath!+'/'))owned.push(child);
  }
  owned.sort((a,b)=>(a.entryKind==='directory'?1:0)-(b.entryKind==='directory'?1:0) || (b.relativePath?.split('/').length || 0)-(a.relativePath?.split('/').length || 0));
  for(const child of owned){if(target===directory)await close(child.key);await removeLibraryFile(target,child.key);}
}
type MoveEntry={scope:string;old:Metadata;next:Metadata};
type Migration={phase:'copying'|'commit';destinationId:string;entries:MoveEntry[]};
const migrationName='destination-migration.json';
async function writeMigration(value:Migration){
  const handle=await appDirectory.getFileHandle(migrationName,{create:true}) as Handle,access=await handle.createSyncAccessHandle();
  try{const bytes=new TextEncoder().encode(JSON.stringify(value));await access.truncate(0);await access.write(bytes,{at:0});await access.flush();}finally{await access.close();}
}
async function migrationRecord():Promise<Migration|undefined>{
  try{return JSON.parse(await (await (await appDirectory.getFileHandle(migrationName)).getFile()).text());}
  catch(error){if((error as Error).name==='NotFoundError')return undefined;throw error;}
}
function deepestFirst(entries:MoveEntry[],side:'old'|'next'){
  return [...entries].sort((a,b)=>(a[side].entryKind==='directory'?1:0)-(b[side].entryKind==='directory'?1:0) || (b[side].storagePath?.split('/').length || 0)-(a[side].storagePath?.split('/').length || 0));
}
async function finishMigration(record:Migration){
  if(record.phase==='copying'){
    // A cancelled copy has not changed any source metadata or the selected
    // destination. Remove only entries created by this migration, never a tree.
    for(const entry of deepestFirst(record.entries,'next'))await removeData(entry.next,await appDirectory.getDirectoryHandle(entry.scope) as Directory,true);
  }else{
    for(const entry of record.entries){
      const target=await appDirectory.getDirectoryHandle(entry.scope) as Directory;
      await metadata(entry.next,target);
      if(entry.next.relativePath){
        const folder=new FolderStorage(target),roots=await folder.roots(),root=entry.next.relativePath.split('/')[0];
        roots[JSON.stringify([record.destinationId,entry.next.transferId,root])]={name:entry.next.storagePath!.split('/')[0],destinationId:record.destinationId};
        await folder.saveRoots(roots);
      }
    }
    await destinationSetting('current',record.destinationId==='opfs'?'':record.destinationId,true);
    // References now name durable new bytes. If an old directory temporarily
    // loses permission, keep the journal so the next attempt can finish moving.
    try{for(const entry of deepestFirst(record.entries,'old'))await removeData(entry.old,await appDirectory.getDirectoryHandle(entry.scope) as Directory,true);}
    catch{return true;}
  }
  await appDirectory.removeEntry(migrationName);return false;
}
async function changeDestination(data:{id?:string;handle?:FileSystemDirectoryHandle}){
  if(opened.size)throw new Error('请等待当前接收完成后再更改目录');
  const pending=await migrationRecord();
  if(pending && await finishMigration(pending))throw new Error('上次迁移已保存，原目录尚未清理，请重新授权原目录后重试');
  const current=await receivingDestination();
  const sameHandle=data.handle && current.handle && await current.handle.isSameEntry(data.handle);
  const destinationId=data.handle?(sameHandle?current.id:data.id!):'opfs';
  if(data.handle)await destinationSetting(destinationId,data.handle,true);
  const record:Migration={phase:'copying',destinationId,entries:[]};
  await writeMigration(record);
  const relocated:{scope:string;key:string}[]=[];
  try{
    for await(const scopeHandle of appDirectory.values()){
      if(scopeHandle.kind!=='directory')continue;
      const target=scopeHandle as Directory,folder=new FolderStorage(target),roots=new Map<string,string>();
      const metas:Metadata[]=[];
      for await(const handle of target.values()){
        if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
        const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
        if(!meta.alias && typeof meta.key==='string' && handle.name===`${keyName(meta.key)}.json`)metas.push(meta);
      }
      // Parents precede their files, including intentionally empty directories.
      metas.sort((a,b)=>(a.relativePath?.split('/').length || 0)-(b.relativePath?.split('/').length || 0));
      for(const old of metas){
        if(!old.storagePath && destinationId==='opfs')continue;
        if(old.storagePath && await (await folder.base(old.destinationId)).isSameEntry(await folder.base(destinationId)))continue;
        let file:File|null;
        try{file=await dataFile(old,target);}catch(error){if((error as Error).name==='NotFoundError')continue;throw error;}
        let location:StoredLocation;
        if(old.relativePath){
          const parts=old.relativePath.split('/'),key=JSON.stringify([old.transferId,parts[0]]);
          let root=roots.get(key);
          if(!root){root=await folder.reserveName(parts[0],destinationId);roots.set(key,root);}
          location={storagePath:[root,...parts.slice(1)].join('/'),destinationId};
        }else location=await folder.allocateFile(old.name,destinationId);
        const next={...old,...location};
        record.entries.push({scope:scopeHandle.name,old,next});await writeMigration(record);
        if(old.entryKind==='directory')await folder.directory(next);
        else{
          const handle=await folder.file(next,true),access=await accessFile(handle,destinationId!=='opfs');
          try{
            await access.truncate(0);
            for(let offset=0;offset<file!.size;offset+=262144){const bytes=new Uint8Array(await file!.slice(offset,offset+262144).arrayBuffer());if(await access.write(bytes,{at:offset})!==bytes.length)throw new Error('迁移空间不足');}
            await access.flush();
          }finally{await access.close();}
          if((await handle.getFile()).size!==file!.size)throw new Error('文件迁移未完成');
        }
        relocated.push({scope:scopeHandle.name,key:old.key});
      }
    }
  }catch(error){await finishMigration(record);throw error;}
  record.phase='commit';await writeMigration(record);
  const cleanupPending=await finishMigration(record),{id,name}=await receivingDestination();
  return {id,name,moved:record.entries.length,cleanupPending,relocated};
}
async function reuseFolder(incoming:Metadata[]) {
  const offeredRoot=incoming.find(meta=>meta.entryKind==='directory' && meta.relativePath && !meta.relativePath.includes('/'));
  if(!offeredRoot || new Set(incoming.map(meta=>meta.key)).size!==incoming.length)return {};
  const suffix=(meta:Metadata)=>meta.relativePath===offeredRoot.relativePath?'':meta.relativePath?.startsWith(offeredRoot.relativePath!+'/')?meta.relativePath.slice(offeredRoot.relativePath!.length+1):undefined;
  const wanted=new Map(incoming.map(meta=>[suffix(meta),meta]));
  if(wanted.has(undefined) || wanted.size!==incoming.length)return {};
  const rules=await cleanupPreferences(),kind=(meta:Metadata)=>meta.entryKind==='directory'?'directory':'file';
  for await(const scope of appDirectory.values()){
    if(scope.kind!=='directory')continue;
    const target=scope as Directory,records:Metadata[]=[];
    for await(const handle of target.values()){
      if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
      const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
      if(!meta.alias && meta.complete && meta.relativePath)records.push(meta);
    }
    for(const root of records.filter(meta=>meta.entryKind==='directory' && !meta.relativePath!.includes('/'))){
      const members=records.filter(meta=>meta.transferId===root.transferId && (meta.key===root.key || meta.relativePath!.startsWith(root.relativePath!+'/')));
      if(members.length!==incoming.length || !root.storagePath)continue;
      const indexed=new Map(members.map(meta=>[meta.key===root.key?'':meta.relativePath!.slice(root.relativePath!.length+1),meta]));
      if(indexed.size!==wanted.size || [...indexed].some(([path,meta])=>{
        const file=wanted.get(path);
        return !file || kind(meta)!==kind(file) || meta.storagePath!==root.storagePath+(path?'/'+path:'') || meta.destinationId!==root.destinationId ||
          cleanupDue({...meta,receivedAt:meta.receivedAt ?? meta.expires-86400000},rules) || kind(meta)==='file' && (meta.size!==file.size || meta.sha256!==file.sha256);
      }))continue;
      // Compare the real tree, including empty directories and user-added files.
      // Matching metadata from separate old roots must never assemble a folder.
      const actual=new Map<string,File|null>();
      try {
        const {parent,name}=await new FolderStorage(target).parent(root);
        const visit=async(folder:Directory,prefix:string)=>{
          actual.set(prefix,null);
          for await(const handle of folder.values()){
            const path=prefix?prefix+'/'+handle.name:handle.name;
            if(handle.kind==='directory')await visit(handle as Directory,path);
            else actual.set(path,await (handle as FileSystemFileHandle).getFile());
          }
        };
        await visit(await parent.getDirectoryHandle(name) as Directory,'');
      }catch(error){if(['NotFoundError','NotAllowedError'].includes((error as Error).name))continue;throw error;}
      if(actual.size!==wanted.size)continue;
      let matches=true;
      for(const [path,meta] of wanted){
        if(!actual.has(path!)){matches=false;break;}
        const file=actual.get(path!)!;
        if(meta.entryKind==='directory'){if(file!==null){matches=false;break;}continue;}
        if(!file || file.size!==meta.size){matches=false;break;}
        const digest=sha256.create();
        for(let offset=0;offset<file.size;offset+=1048576)digest.update(new Uint8Array(await file.slice(offset,offset+1048576).arrayBuffer()));
        if(Array.from(digest.digest(),byte=>byte.toString(16).padStart(2,'0')).join('')!==meta.sha256){matches=false;break;}
      }
      if(!matches)continue;
      const now=Date.now(),files=[];
      for(const [path,meta] of wanted){
        const owner=indexed.get(path!)!;owner.receivedAt=now;owner.expires=now+86400000;await metadata(owner,target);
        const alias:Metadata={...meta,complete:true,receivedAt:now,expires:owner.expires,alias:{scope:scope.name,key:owner.key}};
        if(target.name!==directory.name || owner.key!==alias.key)await metadata(alias);
        files.push({key:meta.key,file:actual.get(path!),meta:{...alias,expires:cleanupMatches(owner,rules)?now+rules.retentionHours*3600000:Infinity}});
      }
      return {files};
    }
  }
  return {};
}

async function execute(command:string,data:any):Promise<unknown> {
  switch(command) {
    case 'init': {
      const root=await navigator.storage.getDirectory();
      appDirectory=await root.getDirectoryHandle('globalsend-received-v1',{create:true}) as Directory;
      const migration=await migrationRecord();if(migration)await finishMigration(migration);
      if(data.scope){directory=await appDirectory.getDirectoryHandle(data.scope,{create:true}) as Directory;await cleanup();}
      return {};
    }
    case 'destination-get': {const {id,name}=await receivingDestination();return {id,name};}
    case 'destination-set': return changeDestination(data);
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
      const location=previous?{storagePath:previous.storagePath,destinationId:previous.destinationId,relativePath:previous.relativePath,transferId:previous.transferId}:data.relativePath?await new FolderStorage(directory).allocate(data.transferId,data.relativePath):(await receivingDestination()).id==='opfs'?{}:await new FolderStorage(directory).allocateFile(data.name);
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
      let meta=await readMeta(data.key);
      const source=await canonical(meta,directory);
      if(meta.alias)meta={...meta,receivedAt:source.meta.receivedAt,expires:source.meta.expires};
      const rules=await cleanupPreferences(),receivedAt=meta.receivedAt ?? meta.expires-86400000;
      if(!meta.complete || cleanupDue({...meta,receivedAt},rules))return {};
      return {file:await dataFile(meta),directory:meta.entryKind==='directory',meta:{...meta,expires:cleanupMatches(meta,rules)?receivedAt+rules.retentionHours*3600000:Infinity}};
    }
    case 'reuse-folder': return reuseFolder(data.files);
    case 'confirm-folder-reuse': {
      const receivedAt=Date.parse(data.receivedAt),rules=await cleanupPreferences(),files=[];
      for(const key of data.keys as string[]){
        const {meta,target}=await canonical(await readMeta(key),directory);
        meta.receivedAt=receivedAt;meta.expires=receivedAt+86400000;await metadata(meta,target);
        files.push({key,expires:cleanupMatches(meta,rules)?receivedAt+rules.retentionHours*3600000:Infinity});
      }
      return {files};
    }
    case 'reuse': {
      if(data.relativePath || data.entryKind==='directory')return {};
      // Look up only committed local bytes. A relay-ready/download history is
      // not proof that the browser still owns a saved file.
      for await(const scope of appDirectory.values()){
        if(scope.kind!=='directory')continue;
        const target=scope as Directory;
        for await(const handle of target.values()){
          if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
          const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
          if(meta.alias || !meta.complete || meta.relativePath || meta.entryKind==='directory' || meta.sha256!==data.sha256 || meta.size!==data.size)continue;
          if(cleanupDue({name:meta.name,size:meta.size,receivedAt:meta.receivedAt ?? meta.expires-86400000},await cleanupPreferences()))continue;
          let file:File;try{file=(await dataFile(meta,target))!;}catch(error){if((error as Error).name==='NotFoundError')continue;throw error;}
          if(file.size!==data.size)continue;
          const hash=sha256.create();
          for(let offset=0;offset<file.size;offset+=1048576)hash.update(new Uint8Array(await file.slice(offset,offset+1048576).arrayBuffer()));
          if(Array.from(hash.digest(),byte=>byte.toString(16).padStart(2,'0')).join('')!==data.sha256)continue;
          const now=Date.now();meta.receivedAt=now;meta.expires=now+86400000;await metadata(meta,target);
          const alias:Metadata={...data,complete:true,receivedAt:now,expires:meta.expires,alias:{scope:scope.name,key:meta.key}};
          if(target.name!==directory.name || meta.key!==data.key)await metadata(alias);
          const rules=await cleanupPreferences();return {file,receivedAt:now,expires:cleanupMatches(meta,rules)?now+rules.retentionHours*3600000:Infinity};
        }
      }
      return {};
    }
    case 'unlink-reuse': {
      try{const meta=await readMeta(data.key);if(meta.alias)await directory.removeEntry(keyName(data.key)+'.json');}
      catch(error){if((error as Error).name!=='NotFoundError')throw error;}
      return {};
    }
    case 'close': await close(data.key);return {};
    case 'remove': await remove(data.key);return {};
    case 'cleanup': await cleanup();return {};
    case 'library-list': {
      const rules=await cleanupPreferences();
      const entries=[],aliases:{scope:string;key:string;alias:{scope:string;key:string}}[]=[];
      for await(const scopeHandle of appDirectory.values()) {
        if(scopeHandle.kind!=='directory')continue;
        const target=scopeHandle as Directory;
        const expired:Metadata[]=[];
        for await(const handle of target.values()) {
          if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
          const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
          if(meta.alias){aliases.push({scope:scopeHandle.name,key:meta.key,alias:meta.alias});continue;}
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
      for(const entry of entries)(entry as typeof entry & {aliases:string[]}).aliases=aliases.filter(value=>value.alias.scope===entry.scope && value.alias.key===entry.key).map(value=>value.key);
      return {entries};
    }
    case 'library-references': {
      const wanted=new Set<string>(data.keys),entries=[];
      for await(const scope of appDirectory.values()){
        if(scope.kind!=='directory')continue;
        const target=scope as Directory;
        for await(const handle of target.values()){
          if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
          const meta=JSON.parse(await (await (handle as FileSystemFileHandle).getFile()).text()) as Metadata;
          if(!wanted.has(meta.key) || !meta.complete)continue;
          try{
            const saved=await libraryFile(`${scope.name}/${keyName(meta.key)}`);
            entries.push({entry:libraryEntry(scope.name,saved.meta,saved.file,await cleanupPreferences()),file:saved.file});
          }catch(error){if((error as Error).name!=='NotFoundError' && (error as Error).message!=='文件已清理')throw error;}
        }
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
          const saved=await libraryFile(`${scope}/${keyName(child.key)}`);
          const entry=libraryEntry(scope,saved.meta,saved.file,await cleanupPreferences());expanded.set(entry.id,{entry,file:saved.file});
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
    try{
      // The library and receiving session each own a worker. A destination move
      // must not race a library cleanup or another worker's startup recovery.
      const result=navigator.locks?await navigator.locks.request('globalsend-received-storage',()=>execute(command,data)):await execute(command,data);
      self.postMessage({id,result});
    }
    catch(error){self.postMessage({id,error:(error as Error).message,name:(error as Error).name});}
  });
};
export {};
