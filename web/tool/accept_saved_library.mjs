import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { buildApp } from '../../server/src/server.ts';

// Real UI + real OPFS, persistent browser profile, isolated center and synthetic content.
// The fixture only exposes the normal controller and seeds disk-backed files.
const root=fileURLToPath(new URL('../../',import.meta.url));
const temporary=join(root,'artifacts/tmp/web-library-acceptance');
await mkdir(temporary,{recursive:true});
const run=await mkdtemp(join(temporary,'run-'));
const require=createRequire(new URL('../package.json',import.meta.url));
const ServerWebSocket=createRequire(new URL('../../server/package.json',import.meta.url))('ws');
const {build}=await import(pathToFileURL(require.resolve('vite')).href);
const sourcePath=resolve(root,'web/src/main.ts').replaceAll('\\','/');
const bootstrap='void new GlobalSend().start();';
const fixture=`
const fixtureController=new GlobalSend();
Object.assign(window,{__controller:fixtureController,__clipboardText:null});
Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async text=>{window.__clipboardText=text;}}});
window.__seedFile=async({scope,key,name,mimeType,text,picture,expired})=>{
  let file;
  if(picture){
    const canvas=document.createElement('canvas');canvas.width=240;canvas.height=160;
    const ctx=canvas.getContext('2d');ctx.fillStyle='#e4eee4';ctx.fillRect(0,0,240,160);
    ctx.fillStyle='#176e55';ctx.beginPath();ctx.arc(120,80,45,0,Math.PI*2);ctx.fill();
    const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png'));
    file=new File([blob],name,{type:'image/png'});
  }else file=new File([text],name,{type:mimeType});
  const metadata={fileId:key,name:file.name,size:file.size,mimeType:file.type,sha256:await digestFile(file),status:'received',offset:0,attemptId:'fixture',errorCode:null};
  const store=new RtcFileStore(scope);await store.ready;
  try{
    let offset=await store.open(key,metadata,expired?Date.now()-1000:Date.now()+86400000);
    if(offset<file.size)await store.write(key,offset,await file.slice(offset).arrayBuffer());
    await store.finish(key);await store.confirm(key);
  }finally{await store.dispose();}
  return {size:file.size,name:file.name};
};
window.__openDiskLibrary=async()=>{window.__diskLibrary=new FixtureLibrary();return window.__diskLibrary.list();};
window.__ageFixtureFile=async(name)=>{
  const root=await navigator.storage.getDirectory(),app=await root.getDirectoryHandle('globalsend-received-v1');
  for await(const scope of app.values())if(scope.kind==='directory')for await(const handle of scope.values()){
    if(handle.kind!=='file' || !handle.name.endsWith('.json'))continue;
    const meta=JSON.parse(await(await handle.getFile()).text());if(meta.name!==name)continue;
    meta.receivedAt=Date.now()-2*3600000;
    const writer=await handle.createWritable();await writer.write(JSON.stringify(meta));await writer.close();return;
  }
  throw new Error('Missing synthetic metadata');
};
void fixtureController.start();
`;
await build({configFile:false,root:join(root,'web'),base:'/app/',logLevel:'warn',
  plugins:[{name:'expose-synthetic-library-consumer',transform(code,id){
    if(id.split('?')[0].replaceAll('\\','/')!==sourcePath)return;
    assert.equal(code.split(bootstrap).length,2,'main bootstrap changed');
    return "import { LocalFileLibrary as FixtureLibrary } from './library';\n"+code.replace(bootstrap,fixture);
  }}],build:{outDir:join(run,'site'),emptyOutDir:true}});
const app=await buildApp({dataDir:join(run,'center'),staticDir:join(run,'site'),production:false,diskReserve:0,log:false});
await app.listen({host:'127.0.0.1',port:0});
const base=`http://127.0.0.1:${app.server.address().port}`;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  ['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-background-networking','--disable-component-update',
    '--disable-extensions','--remote-debugging-port=0',`--user-data-dir=${sharedBrowserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore'});
let browserFailure;browser.on('error',error=>{browserFailure=error;});
let socket;const peerSockets=[];
async function poll(action,condition,timeout=15000){
  let value;const end=Date.now()+timeout;
  while(Date.now()<end){value=await action();if(condition(value))return value;await delay(80);}
  throw new Error('Library acceptance deadline: '+JSON.stringify(value));
}
try{
  const address=await poll(async()=>{
    if(browserFailure)throw browserFailure;
    try{return(await readFile(join(sharedBrowserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}
  },Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0;const pending=new Map();
  socket.addEventListener('message',event=>{const r=JSON.parse(event.data),p=pending.get(r.id);if(p){pending.delete(r.id);r.error?p.reject(new Error(r.error.message)):p.resolve(r.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const page=(method,params)=>send(method,params,sessionId);
  const evaluate=async(expression)=>{
    const r=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
    if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;
  };
  await page('Runtime.enable');await page('Page.enable');
  const downloads=join(run,'downloads');await mkdir(downloads);
  await send('Browser.setDownloadBehavior',{behavior:'allow',downloadPath:downloads});
  await page('Emulation.setDeviceMetricsOverride',{width:1024,height:768,deviceScaleFactor:1,mobile:true});
  await page('Page.navigate',{url:base+'/app/'});
  await poll(()=>evaluate('!!window.__controller && !window.__controller.loading'),Boolean);
  const text='接收文件预览\n\n中文内容保持完整。\n第二行可复制。';
  await evaluate(`__seedFile(${JSON.stringify({scope:'synthetic-A',key:'original-text',name:'会议记录.txt',mimeType:'text/plain',text})})`);
  await delay(25);
  await evaluate(`__seedFile(${JSON.stringify({scope:'synthetic-B',key:'original-picture',name:'测试图片.png',mimeType:'image/png',picture:true})})`);
  const disk=await evaluate('__openDiskLibrary()');
  assert.equal(disk.length,2);
  assert.deepEqual(disk.map(entry=>entry.name).sort(),['会议记录.txt','测试图片.png'].sort());
  const textEntry=disk.find(entry=>entry.name==='会议记录.txt'),imageEntry=disk.find(entry=>entry.name==='测试图片.png');
  const click=selector=>evaluate(`(()=>{const node=document.querySelector(${JSON.stringify(selector)});if(!node)throw new Error('Missing UI control: '+${JSON.stringify(selector)});node.click();})()`);
  const clickCard=id=>evaluate(`(()=>{const node=[...document.querySelectorAll('[data-library-id]')].find(node=>node.dataset.libraryId===${JSON.stringify(id)});if(!node)throw new Error('Missing saved-file card');node.click();})()`);
  await click('[data-action="library"]');
  await poll(()=>evaluate("document.querySelectorAll('.library-card').length"),count=>count===2);
  assert.equal(await evaluate("document.querySelector('.library-card-name').textContent"),'测试图片.png');
  const layouts=[];
  for(const [width,height] of [[1024,768],[390,844]]){
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:true});
    const layout=await evaluate(`(()=>{const grid=document.querySelector('.library-grid');return {width:innerWidth,overflow:document.documentElement.scrollWidth>innerWidth,columns:getComputedStyle(grid).gridTemplateColumns.split(' ').length};})()`);
    assert.equal(layout.overflow,false);assert.equal(layout.columns,2);layouts.push(layout);
  }
  await clickCard(textEntry.id);
  await poll(()=>evaluate("document.querySelector('#library-text')?.value"),value=>value===text);
  assert.equal(await evaluate("document.querySelector('#library-text').readOnly"),true);
  await click('[data-library-action="copy"]');
  assert.equal(await evaluate('__clipboardText'),text);
  await click('[data-library-action="download"]');
  await poll(()=>readdir(downloads),files=>files.includes('会议记录.txt'));
  assert.equal(await readFile(join(downloads,'会议记录.txt'),'utf8'),text);
  await click('[data-library-action="back"]');
  await click('[data-library-action="edit"]');await clickCard(textEntry.id);
  await click('[data-library-action="rename"]');
  await evaluate(`(()=>{const input=document.querySelector('#library-rename-name');input.value='A-会议记录.txt';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#library-rename-form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));})()`);
  await poll(()=>evaluate("[...document.querySelectorAll('.library-card-name')].map(node=>node.textContent)"),names=>names.includes('A-会议记录.txt'));
  const renamed=await evaluate(`(async()=>{const file=await __diskLibrary.get(${JSON.stringify(textEntry.id)});return {name:file.name,type:file.type,text:await file.text()};})()`);
  assert.deepEqual(renamed,{name:'A-会议记录.txt',type:'text/plain',text});
  await click('[data-library-action="edit"]');
  await evaluate(`(()=>{const field=document.querySelector('[data-library-sort]');field.value='oldest';field.dispatchEvent(new Event('change',{bubbles:true}));})()`);
  assert.equal(await evaluate("document.querySelector('.library-card-name').textContent"),'A-会议记录.txt');
  await clickCard(imageEntry.id);
  await poll(()=>evaluate("document.querySelector('.library-image-preview img')?.naturalWidth"),width=>width===240);
  await click('[data-library-action="back"]');
  // Long press selects the entire card, not a tiny auxiliary button.
  await evaluate(`(()=>{const node=[...document.querySelectorAll('[data-library-id]')].find(node=>node.dataset.libraryId===${JSON.stringify(imageEntry.id)});node.dispatchEvent(new PointerEvent('pointerdown',{clientX:30,clientY:30,bubbles:true}));})()`);
  await poll(()=>evaluate(`__controller.fileLibrary.editing && __controller.fileLibrary.selected.has(${JSON.stringify(imageEntry.id)})`),Boolean);
  assert.equal(await evaluate("document.querySelector('[data-library-action=forward]')"),null,'signed-out library cannot forward');
  await click('[data-library-action="edit"]');
  await click('[data-library-action="close"]');
  const call=async(path,body,token)=>{
    const response=await fetch(base+'/api/v1'+path,{method:body===undefined?'GET':'POST',headers:{...(token?{Authorization:'Bearer '+token}:{}),...(body===undefined?{}:{'Content-Type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})});
    const result=await response.json();if(!response.ok)throw new Error(path+': '+JSON.stringify(result));return result;
  };
  const joinGroup=async(groupKey,peerName)=>{
    await evaluate(`(async()=>{const c=__controller;c.groupKey=${JSON.stringify(groupKey)};c.deviceName='独立文件库测试';await c.enroll();c.modal=null;c.render();if(!c.session)throw new Error(c.pairError);})()`);
    const peer=await call('/devices/enroll',{groupKey,name:peerName,platform:'windows'});
    const {ticket}=await call('/session/ws-ticket',{},peer.deviceToken);
    const ws=new ServerWebSocket(base.replace('http:','ws:')+'/api/v1/ws?ticket='+ticket,{origin:base});
    await new Promise((resolve,reject)=>{ws.once('open',resolve);ws.once('error',reject);});peerSockets.push(ws);
    await poll(()=>evaluate(`__controller.devices.some(device=>device.deviceId===${JSON.stringify(peer.device.deviceId)} && device.online)`),Boolean);
    return peer;
  };
  const firstPeer=await joinGroup(randomUUID()+randomUUID(),'旧组在线设备');
  await evaluate('__controller.signOut()');
  await click('[data-action="library"]');
  await poll(()=>evaluate("document.querySelectorAll('.library-card').length"),count=>count===2);
  await click('[data-library-action="close"]');
  const secondPeer=await joinGroup(randomUUID()+randomUUID(),'当前组在线设备');
  assert.equal(await evaluate(`__controller.devices.some(device=>device.deviceId===${JSON.stringify(firstPeer.device.deviceId)})`),false);
  assert.equal((await call('/transfers',undefined,secondPeer.deviceToken)).transfers.length,0,'joining a group must not forward old files');
  await click('[data-action="library"]');
  await poll(()=>evaluate("document.querySelectorAll('.library-card').length"),count=>count===2);
  await click('[data-library-action="edit"]');await clickCard(textEntry.id);
  const targets=await evaluate("[...document.querySelector('[data-library-target]').options].map(option=>({value:option.value,text:option.textContent}))");
  assert.deepEqual(targets,[{value:secondPeer.device.deviceId,text:'当前组在线设备'}]);
  await click('[data-library-action="forward"]');
  const forwarded=await poll(()=>call('/transfers',undefined,secondPeer.deviceToken),result=>result.transfers.length===1);
  assert.equal(forwarded.transfers[0].files.length,1);
  assert.equal(forwarded.transfers[0].files[0].name,'A-会议记录.txt');
  assert.equal(forwarded.transfers[0].files[0].size,new TextEncoder().encode(text).length);
  assert.equal((await call('/transfers',undefined,firstPeer.deviceToken)).transfers.length,0);
  await poll(()=>evaluate('__controller.fileLibrary.busy'),busy=>!busy);
  await click('[data-library-action="close"]');
  await evaluate(`__seedFile(${JSON.stringify({scope:'synthetic-A',key:'fresh-text',name:'新文件.txt',mimeType:'text/plain',text:'刚接收，不应被删除'})})`);
  await evaluate(`__ageFixtureFile('A-会议记录.txt')`);await evaluate(`__ageFixtureFile('测试图片.png')`);
  const policy={retentionHours:1,categories:['image'],sizeRule:'greater',sizeMiB:1};
  await evaluate(`__diskLibrary.setCleanupPreferences(${JSON.stringify(policy)})`);
  assert.equal((await evaluate('__diskLibrary.list()')).length,3,'size-excluded image must survive');
  await evaluate(`__diskLibrary.setCleanupPreferences(${JSON.stringify({...policy,sizeRule:'smaller'})})`);
  const afterImageCleanup=await evaluate('__diskLibrary.list()');
  assert.deepEqual(afterImageCleanup.map(entry=>entry.name).sort(),['A-会议记录.txt','新文件.txt'].sort());
  await evaluate(`__diskLibrary.setCleanupPreferences(${JSON.stringify({...policy,categories:['text'],sizeRule:'any'})})`);
  const retained=await evaluate('__diskLibrary.list()');
  assert.deepEqual(retained.map(entry=>entry.name),['新文件.txt']);
  assert.equal(await readFile(join(downloads,'会议记录.txt'),'utf8'),text,'OPFS cleanup must not delete downloaded copies');
  await click('[data-action="library"]');
  await poll(()=>evaluate("document.querySelectorAll('.library-card').length"),count=>count===1);
  await click('[data-library-action="edit"]');await clickCard(retained[0].id);
  await click('[data-library-action="delete"]');
  await poll(()=>evaluate("document.querySelectorAll('.library-card').length"),count=>count===0);
  assert.equal((await evaluate('__diskLibrary.list()')).length,0);
  assert.equal(await readFile(join(downloads,'会议记录.txt'),'utf8'),text);
  const evidence={crossScopeEntries:disk.map(({name,size,scope})=>({name,size,scope})),layouts,readOnlyText:true,copyAction:true,downloadedText:true,renamePreservesBytes:true,imageDecoded:true,longPressCard:true,signedOutLibrary:true,explicitCurrentGroupForward:true,oldGroupNotSent:true,retentionCategorySizeCleanup:true,downloadSurvivesCleanup:true,explicitDeleteLastFile:true,clipboardIsSynthetic:true};
  await writeFile(join(run,'result.json'),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify({evidence:join(run,'result.json'),result:evidence}));
  await evaluate('__diskLibrary.dispose()');
  
}finally{
  for(const ws of peerSockets)ws.terminate();
  socket?.close();await closeSharedBrowser(browser);await app.close();
}
