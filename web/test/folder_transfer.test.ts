import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdir,mkdtemp} from 'node:fs/promises';
import {existsSync,readFileSync,readdirSync,statSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {runInNewContext} from 'node:vm';
import {webcrypto,createHash} from 'node:crypto';
import {parseHTML} from 'linkedom';
import {buildApp} from '../../server/src/server.ts';
import {DiskDirectory,diskWorkerFactory,indexedDBFixture} from './helpers/disk_opfs.ts';
// Compile the actual export helper too: its streaming writer must preserve
// empty directories, not download a ZIP or flatten leaf names.

const require=createRequire(import.meta.url),{build}=require('esbuild');
const workerCode=(await build({entryPoints:[fileURLToPath(new URL('../src/rtc_storage.worker.ts',import.meta.url))],bundle:true,format:'iife',write:false,platform:'browser',logLevel:'silent'})).outputFiles[0].text;
const mainSource=await readFile(new URL('../src/main.ts',import.meta.url),'utf8');
const mainCode=(await build({stdin:{contents:mainSource.replace('void new GlobalSend().start();','export {GlobalSend};'),resolveDir:fileURLToPath(new URL('../src/',import.meta.url)),loader:'ts'},bundle:true,format:'cjs',write:false,platform:'browser',loader:{'.css':'empty'},define:{'import.meta.url':'"https://fixture.invalid/main.ts"'},logLevel:'silent'})).outputFiles[0].text;
const page=await readFile(new URL('../index.html',import.meta.url),'utf8');
const hash=(bytes:string|Uint8Array)=>createHash('sha256').update(bytes).digest('hex');
async function drained(c:any){for(let i=0;i<1000;i++){if(!c.rtcReceives.size && !c.selectingRelays.size)return;await new Promise(resolve=>setTimeout(resolve,5));}throw new Error('receiver queue did not drain');}

function controller(root:DiskDirectory,base:string,session:any,info:any,idb=indexedDBFixture(),fetcher=fetch){
  const {document}=parseHTML(page).window;
  const storage=new Map<string,string>(),exports:any={};
  const local={getItem:(key:string)=>storage.get(key) || null,setItem:(key:string,value:string)=>storage.set(key,value)};
  const Worker=diskWorkerFactory(workerCode,root,idb);
  const context:any={exports,module:{exports},crypto:webcrypto,fetch:fetcher,Intl,URL,Error,DOMException,AbortController,TextEncoder,TextDecoder,File,Blob,Uint8Array,Worker,KeyframeEffect:class {},setTimeout,clearTimeout,
    navigator:{userAgent:'Fixture',storage:{getDirectory:async()=>root}},location:{origin:base,pathname:'/app/',protocol:'http:'},document,
    window:{innerWidth:950,setTimeout,clearTimeout,setInterval:()=>0,addEventListener(){}},sessionStorage:local,localStorage:local};
  runInNewContext(mainCode,context);
  const c=new context.module.exports.GlobalSend();c.render=()=>{};c.toast=()=>{};c.refresh=async()=>{};c.paintProgress=()=>{};
  c.loading=false;c.connected=true;c.helloReceived=true;c.session=session;c.api.session=session;c.info=info;
  return c;
}
async function call(base:string,session:any,path:string,body?:unknown,method=body===undefined?'GET':'POST'){
  const binary=body instanceof Uint8Array;
  const response=await fetch(base+'/api/v1'+path,{method,headers:{...(session?{authorization:'Bearer '+session.deviceToken}:{}),...(body!==undefined?{'content-type':binary?'application/octet-stream':'application/json'}:{})},body:body===undefined?undefined:binary?body:JSON.stringify(body)});
  const value=await response.json();assert.ok(response.ok,JSON.stringify(value));return value;
}
function filesUnder(path:string):string[]{return readdirSync(path).flatMap(name=>{const child=join(path,name);return statSync(child).isDirectory()?filesUnder(child):[child];});}

test('real Web controller + production OPFS worker + real center transfer a 70-file tree, restart Range resume, and reforward references',async()=>{
  const artifacts=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));await mkdir(artifacts,{recursive:true});const dir=await mkdtemp(join(artifacts,'web-folder-center-'));
  const center=await buildApp({dataDir:join(dir,'center'),log:false,diskReserve:0,webEnabled:false});
  const base=await center.listen({host:'127.0.0.1',port:0});
  const workers:any[]=[];
  try{
    const senderSession=await call(base,null,'/devices/enroll',{name:'Web sender',platform:'web',groupKey:'web-folder-production-test'});
    const receiverSession=await call(base,null,'/devices/enroll',{name:'Web receiver',platform:'web',groupKey:'web-folder-production-test'});
    const info=await call(base,null,'/info'),idb=indexedDBFixture(),receiverRoot=new DiskDirectory(join(dir,'receiver-opfs'));
    const sender=controller(new DiskDirectory(join(dir,'sender-opfs')),base,senderSession,info),receiver=controller(receiverRoot,base,receiverSession,info,idb);
    workers.push(sender,receiver);await sender.ensureFolderCapability();await receiver.ensureFolderCapability();
    sender.devices=[{...receiverSession.device,online:true,folderTransfer:true}];receiver.devices=[{...senderSession.device,online:true,folderTransfer:true}];
    const parts:any[]=[{path:'资料/'},{path:'资料/空目录/'}];
    for(let i=0;i<70;i++)parts.push({path:`资料/sub/note${i}.txt`,file:new File([`正文-${i}`],`note${i}.txt`,{type:'text/plain'})});
    const resumeBytes=new TextEncoder().encode('重新启动后，从第三个字节继续接收。');parts.push({path:'资料/sub/resume.txt',file:new File([resumeBytes],'resume.txt',{type:'text/plain'})});
    await sender.addFolders([{name:'资料',parts}]);const selection=sender.picked[0];
    assert.equal(selection.name,'资料');assert.equal(selection.type,'inode/directory');assert.equal(sender.folderParts.get(selection).find((p:any)=>p.path==='资料/sub/note0.txt').file,parts[2].file);
    await sender.sendQueue([receiverSession.device.deviceId]);let transfer=sender.transfers[0];assert.ok(transfer);
    assert.equal(transfer.files.length,74);assert.equal(transfer.files.some((file:any)=>file.name.endsWith('.zip')),false);
    await sender.stageReceivedFile(`${transfer.transferId}:${transfer.files.find((file:any)=>file.relativePath==='资料').fileId}`);
    assert.equal(sender.folderParts.get(sender.picked[0]).length,74,'sent directory cards retain source references for another send');sender.picked=[];
    receiver.transfers=[transfer];await receiver.acceptFiles(transfer,transfer.files.map((file:any)=>file.fileId),true);transfer=receiver.transfers[0];
    for(const file of transfer.files.filter((file:any)=>file.entryKind==='directory'))await receiver.receiveDirectory(transfer,file);
    await drained(receiver);
    const dirs=(await call(base,receiverSession,`/transfers/${transfer.transferId}`)).transfer.files.filter((file:any)=>file.entryKind==='directory');
    assert.ok(dirs.every((file:any)=>file.status==='received'));
    for(const file of transfer.files.filter((file:any)=>file.entryKind!=='directory')){
      const source=sender.fileSources.get(`${transfer.transferId}:${file.fileId}`) as File;
      await call(base,senderSession,`/transfers/${transfer.transferId}/files/${file.fileId}/chunks?offset=0`,new Uint8Array(await source.arrayBuffer()),'PUT');
      await call(base,senderSession,`/transfers/${transfer.transferId}/files/${file.fileId}/complete`,{});
    }
    transfer=(await call(base,receiverSession,`/transfers/${transfer.transferId}`)).transfer;receiver.transfers=[transfer];
    const resumeFile=transfer.files.find((file:any)=>file.name==='resume.txt'),key=`${transfer.transferId}:${resumeFile.fileId}`;
    const store=await receiver.ensureFileStore();await store.open(key,resumeFile,Date.now()+86400000);await store.write(key,0,resumeBytes.slice(0,3).buffer);await store.close(key);receiver.generation++;receiver.connected=false;await store.dispose();receiver.rtcStore=null;
    const requests:any[]=[];
    const restarted=controller(receiverRoot,base,receiverSession,info,idb,async(url:any,options:any)=>{requests.push({url:String(url),range:options?.headers?.Range});return fetch(url,options);});workers.push(restarted);
    restarted.devices=receiver.devices;restarted.transfers=[transfer];await restarted.ensureFolderCapability();
    for(const file of transfer.files.filter((file:any)=>file.entryKind!=='directory'))await restarted.receiveStructuredRelay(transfer,file);
    await drained(restarted);
    assert.equal(restarted.uploadErrors.size,0,[...restarted.uploadErrors].join(','));
    assert.ok(requests.some(request=>request.range==='bytes=3-'));
    const scope=(await restarted.ensureFileStore()).scope,received=join(receiverRoot.path,'globalsend-received-v1',scope,'received');
    assert.ok(existsSync(join(received,'资料','空目录')));assert.deepEqual(readFileSync(join(received,'资料','sub','resume.txt')),Buffer.from(resumeBytes));
    assert.equal(filesUnder(join(received,'资料')).length,71);assert.equal(readdirSync(received).length,1,'same transfer reused its reserved root across worker restart');
    assert.equal(filesUnder(join(receiverRoot.path,'globalsend-received-v1',scope)).filter(path=>path.endsWith('.data')).length,0,'folder payloads are real files, not encoded .data blobs');
    const completed=(await call(base,receiverSession,`/transfers/${transfer.transferId}`)).transfer;assert.ok(completed.files.every((file:any)=>file.status==='received'));
    await restarted.openLibrary();const rootEntry=restarted.fileLibrary.entries.find((entry:any)=>entry.relativePath==='资料');assert.ok(rootEntry);
    const expanded=await restarted.fileLibrary.service.expand([rootEntry.id]);assert.equal(expanded.length,74);assert.equal(expanded.filter((item:any)=>item.entry.entryKind==='directory').length,3);
    await assert.rejects(restarted.download(transfer.transferId,transfer.files.find((file:any)=>file.relativePath==='资料').fileId),/不能导出目录/);
    const exportCode=(await build({entryPoints:[fileURLToPath(new URL('../src/folder_export.ts',import.meta.url))],bundle:true,format:'cjs',write:false,platform:'browser',logLevel:'silent'})).outputFiles[0].text;
    const exported:any={exports:{}};runInNewContext(exportCode,{module:exported,exports:exported.exports,Error,Map});
    const exportRoot=new DiskDirectory(join(dir,'explicit-export'),true);await exported.exports.exportFolderEntries(expanded,exportRoot);
    assert.ok(existsSync(join(exportRoot.path,'资料','空目录')));assert.equal(filesUnder(join(exportRoot.path,'资料')).length,71);
    const recordedTime=rootEntry.receivedAt;await restarted.fileLibrary.preview(rootEntry.id);assert.equal(restarted.fileLibrary.previewFile.paths.length,74);
    await restarted.stageLibraryEntry(rootEntry);assert.equal(restarted.picked.length,1);assert.equal(restarted.folderParts.get(restarted.picked[0]).length,74);
    await restarted.forwardLibraryFiles([rootEntry],senderSession.device.deviceId);const forwarded=restarted.transfers[0];
    assert.equal(forwarded.files.length,74);assert.deepEqual(forwarded.files.map((file:any)=>file.relativePath).sort(),transfer.files.map((file:any)=>file.relativePath).sort());
    assert.ok(forwarded.files.every((file:any)=>file.entryKind==='directory' || restarted.fileSources.get(`${forwarded.transferId}:${file.fileId}`) instanceof File));
    assert.equal(rootEntry.receivedAt,recordedTime);
    const activeStore=await restarted.ensureFileStore();await activeStore.directory('different-transfer:root',{...transfer.files[0],relativePath:'资料',name:'资料',entryKind:'directory'});
    assert.ok(existsSync(join(received,'资料 (1)')),'a different transfer gets a distinct root rather than overwriting the first');
    await sender.addFolders([{name:'完全空',parts:[]}]);await sender.sendQueue([receiverSession.device.deviceId]);const empty=sender.transfers[0];assert.equal(empty.files.length,1);
    restarted.transfers=[empty,...restarted.transfers];await restarted.acceptFiles(empty,[empty.files[0].fileId],true);await restarted.receiveDirectory(restarted.transfers[0],restarted.transfers[0].files[0]);await drained(restarted);
    assert.ok(existsSync(join(received,'完全空')));assert.equal((await call(base,receiverSession,`/transfers/${empty.transferId}`)).transfer.files[0].status,'received');
    // Directory removal owns only received entries, not files subsequently
    // created by the user in the same root. Never recursive-delete the root.
    writeFileSync(join(received,'资料','keep-user.txt'),'user');await restarted.fileLibrary.service.remove(rootEntry.id);
    assert.equal(readFileSync(join(received,'资料','keep-user.txt'),'utf8'),'user');assert.equal(existsSync(join(received,'资料','sub','resume.txt')),false);
    await mkdir(join(dir,'proof'),{recursive:true});writeFileSync(join(dir,'proof','summary.json'),JSON.stringify({entries:74,realFiles:71,emptyDirectory:true,resumedRange:'bytes=3-',reforwardedEntries:forwarded.files.length,keptUserFile:true},null,2));
    console.log('folder proof:',dir);
  }finally{for(const c of workers){await c.rtcStore?.dispose();if(c.fileLibrary.service)await c.fileLibrary.service.dispose();}await center.close();}
});

test('chosen File System Access directory receives bytes directly and keeps its root reservation on restart',async()=>{
  const artifacts=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));await mkdir(artifacts,{recursive:true});const dir=await mkdtemp(join(artifacts,'web-folder-external-'));
  const root=new DiskDirectory(join(dir,'opfs')),external=new DiskDirectory(join(dir,'chosen-directory'),true),idb=indexedDBFixture();
  await external.getDirectoryHandle('项目',{create:true});
  const session={deviceToken:'fixture',device:{deviceId:'one',name:'fixture'},groupId:'group'},info={instanceId:'fixture',features:{folderTransfer:true},limits:{maxFileSize:10000}};
  const c=controller(root,'http://127.0.0.1:1',session,info,idb);let store=await c.ensureFileStore();await store.setDestination(external as any);
  const directory:any={fileId:'root',name:'项目',size:0,sha256:hash(''),entryKind:'directory',relativePath:'项目'};
  const file:any={fileId:'text',name:'文字.txt',size:6,sha256:hash('abcdef'),entryKind:'file',relativePath:'项目/sub/文字.txt'};
  await store.directory('transfer:root',directory);await store.open('transfer:text',file,Date.now()+86400000);await store.write('transfer:text',0,new TextEncoder().encode('abc').buffer);await store.close('transfer:text');await store.dispose();c.rtcStore=null;
  store=await c.ensureFileStore();assert.equal(await store.open('transfer:text',file,Date.now()+86400000),3);await store.write('transfer:text',3,new TextEncoder().encode('def').buffer);const saved=await store.finish('transfer:text');await store.confirm('transfer:text');
  assert.equal(await saved.text(),'abcdef');assert.equal(readFileSync(join(external.path,'项目 (1)','sub','文字.txt'),'utf8'),'abcdef');
  assert.equal(existsSync(join(root.path,'globalsend-received-v1',store.scope,'received','项目 (1)','sub','文字.txt')),false,'no second OPFS payload copy');
  const scopeFiles=filesUnder(join(root.path,'globalsend-received-v1',store.scope));assert.ok(scopeFiles.every(path=>path.endsWith('.json')));
  assert.equal((await store.destination()).name,'chosen-directory');assert.equal(readdirSync(external.path).length,2);
  await store.dispose();console.log('external directory proof:',dir);
});
