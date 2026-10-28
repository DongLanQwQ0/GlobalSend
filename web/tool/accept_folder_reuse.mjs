import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import {build} from 'vite';
import assert from 'node:assert/strict';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../../server/src/server.ts';

const root=fileURLToPath(new URL('../../',import.meta.url)),run=join(root,'artifacts/tmp/web-folder-browser-'+Date.now());
await mkdir(run,{recursive:true});
await build({root:join(root,'web'),build:{outDir:join(run,'site'),emptyOutDir:false},plugins:[{
  name:'folder-acceptance-exports',transform(source,id){if(id.endsWith('/src/main.ts'))return source.replace('void new GlobalSend().start();',"window.__Store=RtcFileStore;window.__Library=(await import('./library')).LocalFileLibrary;");}
}]});
const center=await buildApp({dataDir:join(run,'center'),staticDir:join(run,'site'),diskReserve:0,production:false,log:false});
const base=await center.listen({host:'127.0.0.1',port:0});
let browser,socket,closePage;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,accept){const end=Date.now()+15000;let value;while(Date.now()<end){value=await action();if(accept(value))return value;await delay(50);}throw new Error('Browser acceptance timed out');}
try{
  browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
  const address=await poll(async()=>{try{return(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let sequence=0;const pending=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=pending.get(value.id);if(call){pending.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const page=(method,params={})=>send(method,params,sessionId);
  const evaluate=async expression=>{const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;};
  closePage=()=>send('Target.closeTarget',{targetId});
  await page('Page.navigate',{url:base+'/app/'});await poll(()=>evaluate('typeof window.__Store'),value=>value==='function');
  const result=await evaluate(`(async()=>{
    const Store=window.__Store,old=new Store('folder-old'),next=new Store('folder-new');await Promise.all([old.ready,next.ready]);
    const bytes=new TextEncoder().encode('真实浏览器目录复用'),digest=async bytes=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');
    const files=[{fileId:'root',name:'资料',relativePath:'资料',entryKind:'directory',size:0,sha256:await digest(new Uint8Array())},
      {fileId:'empty',name:'空目录',relativePath:'资料/空目录',entryKind:'directory',size:0,sha256:await digest(new Uint8Array())},
      {fileId:'text',name:'文字.txt',relativePath:'资料/文字.txt',entryKind:'file',mimeType:'text/plain',size:bytes.length,sha256:await digest(bytes)}];
    for(const file of files){const key='old:'+file.fileId;if(file.entryKind==='directory')await old.directory(key,file);else{await old.open(key,file,Date.now()+86400000);await old.write(key,0,bytes.buffer);await old.finish(key);await old.confirm(key);}}
    const reused=await next.reuseFolder('new',files);if(reused?.size!==3)throw new Error('Complete tree was not reused');
    const at=new Date().toISOString();await next.confirmFolderReuse([...reused.keys()],at);
    if(await reused.get('new:text').text()!=='真实浏览器目录复用')throw new Error('Original bytes differ');
    await next.dispose();const restarted=new Store('folder-new');await restarted.ready;
    if(await (await restarted.get('new:text')).text()!=='真实浏览器目录复用')throw new Error('Restart lost alias');
    const library=new window.__Library(),entries=await library.list();
    const expanded=await library.expand([restarted.scope+'/new%3Aroot']);if(expanded.length!==3 || expanded.some(value=>value.entry.receivedAt!==Date.parse(at)))throw new Error('Forward expansion lost members/timestamp');
    const app=await (await navigator.storage.getDirectory()).getDirectoryHandle('globalsend-received-v1'),scope=await app.getDirectoryHandle(restarted.scope);
    const handles=[];for await(const handle of scope.values())handles.push({name:handle.name,kind:handle.kind});if(handles.some(handle=>handle.kind==='directory'))throw new Error('Duplicate payload directory');
    await restarted.remove('new:root');const remaining=await library.list();if(remaining.length)throw new Error('Deleting reused root left library aliases');
    await old.dispose();await restarted.dispose();await library.dispose();
    return {members:3,canonicalEntries:entries.length,rootEntries:entries.filter(entry=>entry.entryKind==='directory'&&!entry.relativePath.includes('/')).length,restarted:true,expanded:expanded.length,oneTimestamp:true,duplicatePayload:false,deleted:true};
  })()`);
  assert.deepEqual(result,{members:3,canonicalEntries:3,rootEntries:1,restarted:true,expanded:3,oneTimestamp:true,duplicatePayload:false,deleted:true});
  await writeFile(join(run,'result.json'),JSON.stringify({passed:true,profile:browserProfile,...result},null,2));
  console.log(JSON.stringify({run,passed:true,...result}));
}finally{await closePage?.().catch(()=>{});socket?.close();await closeSharedBrowser(browser);await center.close();}
