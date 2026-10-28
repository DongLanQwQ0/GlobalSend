import { OpfsStorage } from './storage.ts';
import { validateCleanup } from './cleanup.ts';
import type { CleanupPreferences } from './cleanup';

export interface LocalFileEntry {
  id:string;scope:string;key:string;name:string;mimeType:string;size:number;
  sha256?:string;receivedAt:number;expiresAt:number;aliases?:string[];
  entryKind?:'file'|'directory';relativePath?:string;storagePath?:string;transferId?:string;
}
export type LibrarySort='received'|'oldest'|'name'|'size';
/** The current origin's saved files, independent of center/group credentials. */
export class LocalFileLibrary {
  private storage=new OpfsStorage();
  async list():Promise<LocalFileEntry[]> {return (await this.storage.call('library-list',{})).entries;}
  async references(keys:string[]):Promise<{entry:LocalFileEntry;file:File|null}[]> {return (await this.storage.call('library-references',{keys})).entries;}
  async get(id:string):Promise<File> {const {file,entry}=await this.storage.call('library-get',{id});return new File(file?[file]:[],entry.name,{type:entry.mimeType,lastModified:file?.lastModified || entry.receivedAt});}
  async expand(ids:string[]):Promise<{entry:LocalFileEntry;file:File|null}[]> {return (await this.storage.call('library-expand',{ids})).entries;}
  async rename(id:string,name:string):Promise<LocalFileEntry> {return (await this.storage.call('library-rename',{id,name:validateLocalName(name)})).entry;}
  async remove(id:string):Promise<void> {await this.storage.call('library-remove',{id});}
  async cleanupPreferences():Promise<CleanupPreferences> {return (await this.storage.call('library-preferences',{})).cleanup;}
  async setCleanupPreferences(value:CleanupPreferences):Promise<CleanupPreferences> {return (await this.storage.call('library-preferences',{value:validateCleanup(value)})).cleanup;}
  async dispose() {await this.storage.dispose();}
}
export function validateLocalName(value:string) {
  const name=value.trim();
  if(!name || name.length>255 || /[\x00-\x1f\\/]/.test(name) || name==='.' || name==='..')throw new Error('请输入有效文件名');
  return name;
}
export function sortLocalFiles(entries:LocalFileEntry[],sort:LibrarySort) {
  return [...entries].sort((a,b)=>sort==='name'?a.name.localeCompare(b.name,'zh-CN',{numeric:true}):sort==='size'?b.size-a.size || b.receivedAt-a.receivedAt:sort==='oldest'?a.receivedAt-b.receivedAt:b.receivedAt-a.receivedAt);
}
export function filePreviewKind(entry:Pick<LocalFileEntry,'name'|'mimeType'>):'image'|'text'|'file' {
  const extension=entry.name.split('.').pop()?.toLowerCase() || '';
  // SVG stays text: previewing arbitrary SVG as active document is unnecessary.
  if(/^image\/(?!svg)/i.test(entry.mimeType) || /^(png|jpe?g|webp|gif|avif|bmp|ico)$/.test(extension))return 'image';
  if(/^text\//i.test(entry.mimeType) || /(?:json|xml|javascript|yaml)/i.test(entry.mimeType) || /^(txt|md|markdown|log|csv|tsv|json|xml|yaml|yml|toml|ini|conf|config|html?|css|scss|js|jsx|ts|tsx|dart|py|java|c|h|cpp|hpp|rs|go|sh|bat|ps1|sql|svg)$/.test(extension))return 'text';
  return 'file';
}
export async function readLocalText(file:Blob) {
  const limit=8*1024*1024,bytes=new Uint8Array(await file.slice(0,limit).arrayBuffer());
  const truncated=file.size>limit;
  let encoding='utf-8',start=0;
  if(bytes[0]===255 && bytes[1]===254){encoding='utf-16le';start=2;}
  else if(bytes[0]===254 && bytes[1]===255){encoding='utf-16be';start=2;}
  else if(bytes[0]===239 && bytes[1]===187 && bytes[2]===191)start=3;
  else {
    const sample=bytes.subarray(0,Math.min(256,bytes.length));
    const zeros=sample.reduce((count,value,index)=>{if(value===0)count[index%2]++;return count;},[0,0]);
    if(zeros[1]>sample.length/5 && zeros[0]<sample.length/20)encoding='utf-16le';
    else if(zeros[0]>sample.length/5 && zeros[1]<sample.length/20)encoding='utf-16be';
  }
  let text:string;
  try{text=new TextDecoder(encoding,{fatal:true}).decode(bytes.subarray(start),{stream:truncated});}
  catch {encoding='gb18030';text=new TextDecoder(encoding).decode(bytes.subarray(start),{stream:truncated});}
  return {text,encoding,truncated};
}
