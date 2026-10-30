import type { TransferFile } from './model.ts';

export const isFolderRoot=(file:TransferFile)=>file.entryKind==='directory' && !!file.relativePath && !file.relativePath.includes('/');
export function folderMembers(root:TransferFile,files:TransferFile[]):TransferFile[] {
  if(!isFolderRoot(root))return [root];
  return files.filter(file=>file.fileId===root.fileId || file.relativePath?.startsWith(root.relativePath!+'/'));
}
export function folderRoot(file:TransferFile,files:TransferFile[]):TransferFile {
  const name=file.relativePath?.split('/')[0];
  return name?files.find(item=>isFolderRoot(item) && item.relativePath===name) || file:file;
}
export function summarizeFolder(root:TransferFile,members:TransferFile[],progress?:(file:TransferFile)=>number):TransferFile {
  const pending=members.filter(file=>file.status!=='received');
  const state=pending.find(file=>file.status==='failed') || pending.find(file=>file.status==='uploading') ||
    pending.find(file=>file.status==='accepted') || pending.find(file=>!['canceled','rejected','expired'].includes(file.status)) || pending[0] || root;
  return {...root,size:members.reduce((sum,file)=>sum+file.size,0),
    offset:members.reduce((sum,file)=>sum+(file.status==='received'?file.size:Math.min(file.size,Math.max(0,progress?.(file) ?? file.offset))),0),
    status:pending.length?state.status:'received',errorCode:state.errorCode,receiveFailure:state.receiveFailure};
}
/** Display roots only; the caller retains the full manifest for transfer work. */
export function folderCards(files:TransferFile[],progress?:(file:TransferFile)=>number):TransferFile[] {
  const groups=new Map<string,TransferFile[]>();
  for(const file of files)if(isFolderRoot(file))groups.set(file.relativePath!,[]);
  for(const file of files){const name=file.relativePath?.split('/')[0];if(name)groups.get(name)?.push(file);}
  return files.flatMap(file=>{
    const name=file.relativePath?.split('/')[0],members=name?groups.get(name):undefined;
    return !members?[file]:isFolderRoot(file)?[summarizeFolder(file,members,progress)]:[];
  });
}
