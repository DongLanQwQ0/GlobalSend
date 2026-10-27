import type { LocalFileEntry } from './library.ts';
/** Explicit export only. Receiving to a chosen directory already writes there. */
export async function exportFolderEntries(entries:{entry:LocalFileEntry;file:File|null}[],destination:FileSystemDirectoryHandle){
  const roots=new Map<string,string>();
  for(const {entry} of entries){
    const root=(entry.relativePath || entry.name).split('/')[0];if(roots.has(root))continue;
    let name=root,index=0;
    for(;;){try{await destination.getDirectoryHandle(name);name=`${root} (${++index})`;}catch(error){if((error as Error).name==='NotFoundError')break;if((error as Error).name==='TypeMismatchError'){name=`${root} (${++index})`;continue;}throw error;}}
    roots.set(root,name);
  }
  for(const {entry,file} of entries){
    const parts=(entry.relativePath || entry.name).split('/');parts[0]=roots.get(parts[0])!;
    let parent=destination;
    const dirs=entry.entryKind==='directory'?parts:parts.slice(0,-1);
    for(const part of dirs)parent=await parent.getDirectoryHandle(part,{create:true});
    if(entry.entryKind==='directory')continue;
    if(!file)throw new Error('本机文件已不存在');
    const handle=await parent.getFileHandle(parts.at(-1)!,{create:true}),writer=await handle.createWritable();
    try{await file.stream().pipeTo(writer);}catch(error){await writer.abort().catch(()=>{});throw error;}
  }
}
