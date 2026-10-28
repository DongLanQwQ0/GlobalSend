/** Folder entries reference the original files; no archive or payload copy. */
export interface FolderPart { path:string; file?:File }
export type FolderSelection={name:string;parts:FolderPart[]};
export function completeFolderParts(name:string,parts:FolderPart[]):FolderPart[] {
  const entries=new Map<string,FolderPart>();
  entries.set(name,{path:name+'/'});
  for(const part of parts) {
    const path=part.path.replaceAll('\\','/').replace(/\/+$/,'');
    const segments=path.split('/');
    if(segments[0]!==name || segments.some(value=>!value || value==='.' || value==='..'))throw new Error('文件夹路径不完整');
    for(let i=1;i<segments.length;i++){const parent=segments.slice(0,i).join('/');entries.set(parent,{path:parent+'/'});}
    entries.set(path,part.file?{path,file:part.file}:{path:path+'/'});
  }
  if(entries.size>10000)throw new Error('文件夹最多包含 10000 项');
  return [...entries.values()].sort((a,b)=>a.path.split('/').length-b.path.split('/').length || a.path.localeCompare(b.path));
}
export async function directoryParts(handle:FileSystemDirectoryHandle,path=handle.name):Promise<FolderPart[]> {
  const parts:FolderPart[]=[{path:path+'/'}];
  for await(const child of (handle as FileSystemDirectoryHandle & {values():AsyncIterable<FileSystemHandle>}).values()) {
    if(child.kind==='directory')parts.push(...await directoryParts(child as FileSystemDirectoryHandle,path+'/'+child.name));
    else parts.push({path:path+'/'+child.name,file:await (child as FileSystemFileHandle).getFile()});
    if(parts.length>10000)throw new Error('文件夹最多包含 10000 项');
  }
  return parts;
}

interface Entry { name:string;isFile:boolean;isDirectory:boolean;file(success:(file:File)=>void,failure:(error:DOMException)=>void):void;createReader():{readEntries(success:(entries:Entry[])=>void,failure:(error:DOMException)=>void):void} }
export async function droppedFiles(transfer:DataTransfer):Promise<{files:File[];folders:{name:string;parts:FolderPart[]}[]}> {
  const files:File[]=[],folders:{name:string;parts:FolderPart[]}[]=[];
  const visit=async(entry:Entry,path:string,parts:FolderPart[])=>{
    if(entry.isFile){const file=await new Promise<File>((resolve,reject)=>entry.file(resolve,reject));parts.push({path,file});return;}
    parts.push({path:path+'/'});const reader=entry.createReader();
    for(;;){const children=await new Promise<Entry[]>((resolve,reject)=>reader.readEntries(resolve,reject));if(!children.length)break;for(const child of children)await visit(child,`${path}/${child.name}`,parts);}
  };
  const items=Array.from(transfer.items || []).filter(item=>item.kind==='file');
  // Capture entries before awaiting: the drag data store is only readable during drop.
  const listed=Array.from(transfer.files);
  const sources=items.map((item,index)=>{
    // Some native OLE/virtual file sources expose FileList but no Entry object.
    let entry:Entry|null=null;
    try{entry=item.webkitGetAsEntry?.() as unknown as Entry|null;}catch{/* FileList remains a valid source. */}
    return {entry,file:item.getAsFile() || listed[index]};
  });
  if(!sources.length)return {files:listed,folders};
  for(const source of sources){if(source.entry?.isDirectory){const parts:FolderPart[]=[];await visit(source.entry,source.entry.name,parts);folders.push({name:source.entry.name,parts});}else if(source.file)files.push(source.file);}
  files.push(...listed.slice(sources.length));
  return {files,folders};
}
