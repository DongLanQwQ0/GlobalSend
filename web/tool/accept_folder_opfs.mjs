import { browserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import { createServer } from 'node:net';
import { build } from 'vite';
import { buildApp } from '../../server/src/server.ts';

// The only source transform exposes the real controller. Vite still emits the
// production storage worker and its imports; no worker, payload or OPFS mocks.
const root=fileURLToPath(new URL('../../',import.meta.url));
const parent=join(root,'artifacts/tmp/folder-opfs-browser');await mkdir(parent,{recursive:true});
const run=await mkdtemp(join(parent,'run-')),site=join(run,'site');
await build({root:join(root,'web'),configFile:join(root,'web/vite.config.ts'),logLevel:'warn',plugins:[{
 name:'expose-fixture-controller',enforce:'pre',transform(code,id){
  if(id.replaceAll('\\','/').endsWith('/web/src/main.ts')){
   assert.ok(code.includes('void new GlobalSend().start();'));
   return code.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;void c.start();');
  }
 }}],build:{outDir:site,emptyOutDir:true}});
const assets=await readdir(join(site,'assets'));assert.ok(assets.some(name=>name.startsWith('rtc_storage.worker-')));
const reservation=createServer();await new Promise(resolve=>reservation.listen(0,'127.0.0.1',resolve));
const port=reservation.address().port;await new Promise(resolve=>reservation.close(resolve));
const base=`http://127.0.0.1:${port}/globalsend`,group='folder-opfs-browser-synthetic';
const center=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,publicBaseUrl:base,diskReserve:0,production:false,log:false});
await center.listen({host:'127.0.0.1',port});
const browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',[
 '--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],
 {windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:parent,TMP:parent}});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,accept,timeout=20000){const end=Date.now()+timeout;let value;while(Date.now()<end){value=await action();if(accept(value))return value;await delay(50);}throw new Error('Deadline: '+JSON.stringify(value));}
const hash=data=>createHash('sha256').update(data).digest('hex');
async function call(method,path,body,token){const response=await fetch(base+'/api/v1'+path,{method,headers:{...(token?{authorization:'Bearer '+token}:{}),...(body!==undefined?{'content-type':Buffer.isBuffer(body)?'application/octet-stream':'application/json'}:{})},...(body!==undefined?{body:Buffer.isBuffer(body)?body:JSON.stringify(body)}:{})});const value=await response.json();assert.ok(response.ok,JSON.stringify({path,status:response.status,value}));return value;}
let socket,sourceSocket,closePage;
const report={run,profile:browserProfile,base,assets,checks:[],errors:[]};
try{
 const address=await poll(async()=>{try{return (await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
 socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
 let sequence=0;const pending=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=pending.get(value.id);if(call){pending.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}if(value.method==='Runtime.exceptionThrown')report.errors.push(value.params.exceptionDetails);});
 const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
 const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
 const page=(method,params={})=>send(method,params,sessionId);
 const evaluate=async expression=>{const value=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
 closePage=()=>send('Target.closeTarget',{targetId});
 await page('Page.enable');await page('Runtime.enable');await page('Emulation.setFocusEmulationEnabled',{enabled:true});await page('Page.navigate',{url:base+'/app/'});
 await poll(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
 await evaluate(`(async()=>{const c=window.__client;c.deviceName='OPFS browser receiver';c.groupKey=${JSON.stringify(group)};await c.enroll();})()`);
 await poll(()=>evaluate('window.__client.connected && window.__client.folderRegisteredScope'),Boolean);
 const receiver=await evaluate('window.__client.session.device.deviceId');
 const source=await call('POST','/devices/enroll',{name:'Synthetic HTTP sender',platform:'windows',groupKey:group});
 const {ticket}=await call('POST','/session/ws-ticket',{},source.deviceToken);
 sourceSocket=new WebSocket(`ws://127.0.0.1:${port}/globalsend/api/v1/ws?ticket=${ticket}`);
 await new Promise((resolve,reject)=>{sourceSocket.addEventListener('open',resolve,{once:true});sourceSocket.addEventListener('error',reject,{once:true});});
 const transferId='browser-folder-proof',empty=hash(Buffer.alloc(0));
 const payloads={'a.txt':Buffer.from('实际浏览器 OPFS 正文\n'),'b.bin':Buffer.from([0,1,2,3,254,255])};
 const directory=(fileId,name,relativePath)=>({fileId,name,relativePath,entryKind:'directory',size:0,mimeType:'inode/directory',sha256:empty});
 const files=[directory('root','资料','资料'),directory('sub','子目录','资料/子目录'),directory('empty','空目录','资料/空目录'),
  ...Object.entries(payloads).map(([name,data],index)=>({fileId:`f${index}`,name,relativePath:`资料/${index?'':'子目录/'}${name}`,entryKind:'file',size:data.length,mimeType:index?'application/octet-stream':'text/plain',sha256:hash(data)}))];
 await call('POST','/transfers',{transferId,targetDeviceId:receiver,routePreference:'relay',files},source.deviceToken);
 await poll(()=>call('GET',`/transfers/${transferId}`,undefined,source.deviceToken),value=>value.transfer.files.every(file=>file.status==='accepted'||file.status==='received'));
 for(const file of files.filter(file=>file.entryKind==='file')){
  const path=`/transfers/${transferId}/files/${file.fileId}`;
  await call('PUT',path+'/chunks?offset=0',payloads[file.name],source.deviceToken);await call('POST',path+'/complete',{},source.deviceToken);
 }
 const received=await poll(()=>call('GET',`/transfers/${transferId}`,undefined,source.deviceToken),value=>value.transfer.files.every(file=>file.status==='received'));
 report.checks.push({name:'HTTP offer auto-accept, relay download and ACK',files:received.transfer.files.map(({fileId,status,entryKind,relativePath,offset})=>({fileId,status,entryKind,relativePath,offset}))});
 const inspect=`(async()=>{const c=window.__client,store=await c.ensureFileStore(),root=await navigator.storage.getDirectory(),app=await root.getDirectoryHandle('globalsend-received-v1'),scope=await app.getDirectoryHandle(store.scope),received=await scope.getDirectoryHandle('received');async function visit(dir,p=''){const list=[];for await(const h of dir.values()){const path=p+h.name;list.push(h.kind==='directory'?{path,kind:h.kind}:{path,kind:h.kind,bytes:Array.from(new Uint8Array(await(await h.getFile()).arrayBuffer()))});if(h.kind==='directory')list.push(...await visit(h,path+'/'));}return list;}const metadata=[];for await(const h of scope.values())if(h.kind==='file'&&h.name.endsWith('.json'))metadata.push({name:h.name,data:JSON.parse(await(await h.getFile()).text())});return {scope:store.scope,tree:(await visit(received)).sort((a,b)=>a.path.localeCompare(b.path)),metadata,keys:[...c.rtcLocalFiles.keys()],errors:[...c.uploadErrors.entries()]};})()`;
 const before=await evaluate(inspect);
 assert.deepEqual(before.errors,[]);assert.equal(before.tree.length,5);
 assert.ok(before.tree.some(item=>item.path==='资料/空目录'&&item.kind==='directory'));
 for(const file of files.filter(file=>file.entryKind==='file'))assert.deepEqual(before.tree.find(item=>item.path===file.relativePath)?.bytes,[...payloads[file.name]]);
 assert.equal(before.tree.some(item=>/\.zip$/i.test(item.path)),false);assert.equal(before.metadata.filter(item=>item.data.complete).length,5);
 report.checks.push({name:'actual OPFS tree and bytes',...before});
 assert.equal(await evaluate('window.__client.displayTransfers(false)[0].files.length'),1);
 assert.equal(await evaluate('window.__client.receiptBatch.size'),1);
 assert.equal(await evaluate("document.querySelectorAll('.dock-items .file-card').length"),1);
 await evaluate("if(window.__client.modal==='receipt')window.__client.closeModal()");await delay(260);
 await page('Emulation.setDeviceMetricsOverride',{width:950,height:650,deviceScaleFactor:1,mobile:false});
 await delay(100);
 const picture=await page('Page.captureScreenshot',{format:'jpeg',quality:82});await writeFile(join(run,'folder-card.jpg'),Buffer.from(picture.data,'base64'));
 report.checks.push({name:'one folder card and one receipt for a nested tree',screenshot:join(run,'folder-card.jpg')});
 report.workerRuntime=await evaluate('({nativeWorker:window.__client.rtcStore.storage.worker instanceof Worker,scope:window.__client.rtcStore.scope})');
 assert.equal(report.workerRuntime.nativeWorker,true);
 await page('Page.reload',{ignoreCache:true});await poll(()=>evaluate('!!window.__client && !window.__client.loading && window.__client.connected'),Boolean);
 const after=await evaluate(inspect);assert.deepEqual(after.tree,before.tree);assert.equal(after.scope,before.scope);
 for(const file of files)assert.ok(after.metadata.some(item=>item.data.key===transferId+':'+file.fileId&&item.data.complete));
 report.checks.push({name:'fresh page/worker reload preserves physical tree and bytes',...after});
 report.status='passed';report.fsa='No OS directory picker or authorization was invoked; real selected-directory FSA remains a separate acceptance gap.';
 await writeFile(join(run,'result.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,run,checks:report.checks.map(check=>check.name),workerRuntime:report.workerRuntime,profile:browserProfile}));
}catch(error){report.status='failed';report.failure=String(error.stack||error);await writeFile(join(run,'result.json'),JSON.stringify(report,null,2));throw error;}
finally{await closePage?.().catch(()=>{});socket?.close();sourceSocket?.close();await closeSharedBrowser(browser);await center.close();}
