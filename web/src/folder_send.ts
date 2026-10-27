import type { FolderPart } from './folder.ts';
export interface OfferFile {name:string;size:number;mimeType:string;sha256:string;relativePath?:string;entryKind?:'file'|'directory'}
export const emptyFileHash='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
/** One metadata row per real directory/file; source File objects are retained. */
export async function prepareFolderSend(files:File[],parts:(file:File)=>FolderPart[]|undefined,digest:(file:File)=>Promise<string>,maxSize=Infinity) {
  const metadata:OfferFile[]=[],sources:(File|undefined)[]=[];
  const structured=files.some(file=>!!parts(file));
  const count=files.reduce((n,file)=>n+(parts(file)?.length || 1),0);
  if(count>(structured?10000:32))throw new Error(structured?'文件夹最多包含 10000 项':'一次最多选择 32 个文件');
  for(const selected of files){
    const entries=parts(selected);
    for(const entry of entries || [{path:selected.name,file:selected}]){
      const relativePath=entries?entry.path.replace(/\/$/,''):undefined;
      if(!entry.file){metadata.push({name:relativePath!.split('/').at(-1)!,size:0,mimeType:'inode/directory',sha256:emptyFileHash,relativePath,entryKind:'directory'});sources.push(undefined);continue;}
      if(entry.file.size>maxSize)throw new Error(`${entry.file.name} 超过单文件上限`);
      metadata.push({name:entry.file.name,size:entry.file.size,mimeType:entry.file.type || 'application/octet-stream',sha256:await digest(entry.file),...(relativePath?{relativePath,entryKind:'file' as const}:{})});sources.push(entry.file);
    }
  }
  if(metadata.length>(structured?10000:32))throw new Error(structured?'文件夹最多包含 10000 项':'一次最多选择 32 个文件');
  return {metadata,sources};
}
