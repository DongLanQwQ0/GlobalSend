import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import {build} from 'vite';
import assert from 'node:assert/strict';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {buildApp} from '../../server/src/server.ts';

const root=fileURLToPath(new URL('../../',import.meta.url)),run=join(root,'artifacts/tmp/copied-files-browser');
await mkdir(run,{recursive:true});
await build({root:join(root,'web'),build:{outDir:join(run,'site'),emptyOutDir:false},plugins:[{
  name:'copied-file-acceptance',transform(source,id){if(id.endsWith('/src/main.ts'))return source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();');}
}]});
const center=await buildApp({dataDir:join(run,'center'),staticDir:join(run,'site'),diskReserve:0,production:false,log:false});
const base=await center.listen({host:'127.0.0.1',port:0});
const SourceSocket=createRequire(new URL('../../server/package.json',import.meta.url))('ws');
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(action,accept){const end=Date.now()+20000;let value;while(Date.now()<end){value=await action();if(accept(value))return value;await delay(40);}throw new Error('Timed out: '+JSON.stringify(value));}
async function call(method,path,body,token){const response=await fetch(base+'/api/v1'+path,{method,headers:{...(token?{authorization:'Bearer '+token}:{}),...(body===undefined?{}:{'content-type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});const data=await response.json();assert.ok(response.ok,JSON.stringify(data));return data;}
let browser,socket,sourceSocket,closePage,sourceFailure,sourceJobs=[];
try{
  const source=await call('POST','/devices/enroll',{name:'Copied source',platform:'windows',groupKey:'copied-reference-browser'});
  const unselected=await call('POST','/devices/enroll',{name:'Unselected',platform:'android',groupKey:'copied-reference-browser'});
  const {ticket}=await call('POST','/session/ws-ticket',{},source.deviceToken);
  sourceSocket=new SourceSocket(base.replace('http:','ws:')+'/api/v1/ws?ticket='+ticket,{origin:base});
  await new Promise((resolve,reject)=>{sourceSocket.once('open',resolve);sourceSocket.once('error',reject);});
  browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
  const address=await until(async()=>{try{return(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let sequence=0;const pending=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=pending.get(value.id);if(call){pending.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  closePage=()=>send('Target.closeTarget',{targetId});const page=(method,params={})=>send(method,params,sessionId);
  const evaluate=async expression=>{const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;};
  await page('Emulation.setDeviceMetricsOverride',{width:950,height:650,deviceScaleFactor:1,mobile:false});
  await page('Page.navigate',{url:base+'/app/'});await until(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);
  await evaluate("(async()=>{const c=window.__client;c.groupKey='copied-reference-browser';await c.enroll();})()");
  await until(()=>evaluate('window.__client.connected'),Boolean);
  const receiver=await evaluate('window.__client.session');
  await evaluate("(()=>{const c=window.__client;c.stagedTexts=[{id:'draft',text:'Keep my draft'}];c.appearance.set({mode:'dark'});c.render();})()");
  const bytes=Buffer.from('A copied file pulled through the ordinary transfer pipeline.','utf8');
  let pulls=0;
  sourceSocket.on('message',raw=>{
    const message=JSON.parse(String(raw));if(message.type!=='clipboard.files.pull')return;
    const job=(async()=>{
      pulls++;const resultPath=`/clipboard/files/pulls/${message.targetDeviceId}/${message.requestId}`;
      await call('PUT',resultPath,{state:'sending'},source.deviceToken);
      const transferId='copied-transfer-'+message.requestId;
      await call('POST','/transfers',{transferId,targetDeviceId:message.targetDeviceId,routePreference:'relay',files:[{fileId:'file',name:'copied-note.txt',size:bytes.length,mimeType:'text/plain',sha256:createHash('sha256').update(bytes).digest('hex')}]},source.deviceToken);
      await call('PUT',resultPath,{state:'sent'},source.deviceToken);
      await until(()=>call('GET','/transfers/'+transferId,undefined,source.deviceToken),value=>value.transfer.files[0].status!=='offered');
      const uploaded=await fetch(`${base}/api/v1/transfers/${transferId}/files/file/chunks?offset=0`,{method:'PUT',headers:{authorization:'Bearer '+source.deviceToken,'content-type':'application/octet-stream'},body:bytes});assert.ok(uploaded.ok,await uploaded.text());
      await call('POST',`/transfers/${transferId}/files/file/complete`,{},source.deviceToken);
    })().catch(error=>sourceFailure=error);sourceJobs.push(job);
  });
  await call('PUT','/clipboard/files',{offerId:'batch',targetDeviceIds:[receiver.device.deviceId],items:[{id:'file',name:'copied-note.txt',kind:'file',size:bytes.length},{id:'folder',name:'Course files',kind:'directory'}]},source.deviceToken);
  await until(()=>evaluate("document.querySelectorAll('[data-copied-reference]').length"),value=>value===2);
  assert.equal((await call('GET','/transfers',undefined,source.deviceToken)).transfers.length,0);assert.equal(pulls,0);
  assert.equal((await call('GET','/clipboard/files',undefined,unselected.deviceToken)).offers.length,0);
  for(const width of [950,390]){
    await page('Emulation.setDeviceMetricsOverride',{width,height:width===950?650:844,deviceScaleFactor:1,mobile:width<500});await delay(150);
    assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);
    const capture=await page('Page.captureScreenshot',{format:'jpeg',quality:84});await writeFile(join(run,`references-${width}.jpg`),Buffer.from(capture.data,'base64'));
  }
  const selector='[data-action="pull-copied-file"]';
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'center'})`);
  const point=await evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  await page('Input.dispatchMouseEvent',{type:'mousePressed',button:'left',clickCount:1,...point});await page('Input.dispatchMouseEvent',{type:'mouseReleased',button:'left',clickCount:1,...point});
  try {await until(()=>evaluate("(()=>{const c=window.__client;return [...c.rtcLocalFiles.values()].some(file=>file.name==='copied-note.txt')})()"),Boolean);}
  catch(error){await writeFile(join(run,'failure.json'),JSON.stringify({pulls,sourceFailure:sourceFailure?.stack,client:await evaluate("(()=>{const c=window.__client;return {references:c.copiedFiles.references,transfers:c.transfers,errors:[...c.uploadErrors],accepting:[...c.accepting],rtcUnavailable:c.rtcUnavailable,toasts:document.querySelector('#toasts')?.textContent}})()")},null,2));throw error;}
  if(sourceFailure)throw sourceFailure;
  assert.equal(pulls,1);assert.deepEqual(await evaluate('window.__client.stagedTexts'),[{id:'draft',text:'Keep my draft'}]);
  const saved=await evaluate("(async()=>{const c=window.__client;return await [...c.rtcLocalFiles.values()].find(file=>file.name==='copied-note.txt').text()})()");assert.equal(saved,bytes.toString());
  await evaluate("(()=>{const c=window.__client;c.closeModal();c.copiedFiles.dismiss(c.copiedFiles.references[1].id)})()");
  assert.equal(await evaluate('window.__client.copiedFiles.references.length'),1);
  await call('DELETE','/clipboard/files',undefined,source.deviceToken);
  await until(()=>evaluate('window.__client.copiedFiles.references.length'),value=>value===0);
  await writeFile(join(run,'result.json'),JSON.stringify({passed:true,explicitTarget:true,noPretransfer:true,onePull:true,ordinaryTransferSavedExactBytes:true,draftPreserved:true,folderSingleReference:true,withdrawal:true,viewports:[950,390],browserProfile},null,2));
  await evaluate("(async()=>{const c=window.__client;const store=c.rtcStore;for(const key of c.rtcLocalFiles.keys())await store.remove(key);c.stagedTexts=[];c.signOut();})()");
  console.log('PASS: designated reference -> explicit click -> ordinary transfer -> browser local file; no pretransfer or draft mutation');
}finally{
  await Promise.all(sourceJobs);sourceSocket?.close();await closePage?.().catch(()=>{});socket?.close();await closeSharedBrowser(browser);await center.close();
}
