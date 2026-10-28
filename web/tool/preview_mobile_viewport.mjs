import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';

// Isolated visual fixture: actual UI code and CSS, synthetic data, no hosted
// center or clipboard. Reuses the established persistent browser profile.
const require = createRequire(import.meta.url);
const { build } = require('esbuild');
const root = fileURLToPath(new URL('../../', import.meta.url));
const work = join(root, 'artifacts/tmp/web-mobile-viewport-20261028');
const screenshots = join(root, 'artifacts/screenshots');
await mkdir(work, { recursive: true }); await mkdir(screenshots, { recursive: true });
const source = await readFile(join(root, 'web/src/main.ts'), 'utf8');
const bootstrap = 'void new GlobalSend().start();';
assert.equal(source.split(bootstrap).length, 2);
const fixture = "const c = new GlobalSend();window.__preview=c;c.loading=false;c.connected=true;c.helloReceived=true;\nc.info={protocolVersion:1,instanceId:'visual-fixture',limits:{maxTextLength:100000,maxFileSize:2000000000,ttlSeconds:86400}};\nc.session={deviceToken:'synthetic-only',device:{deviceId:'self',name:'DongLan',platform:'web'},groupId:'fixture'};c.api.session=c.session;\nc.devices=[{deviceId:'phone',name:'我的手机',platform:'android',online:true},{deviceId:'ipad',name:'iPad',platform:'web',online:true}];c.target='phone';\nc.ensureRtc=async()=>{};c.ensureFolderCapability=async()=>{};c.refresh=async()=>{};c.startReadyUploads=()=>{};c.selectIncomingRelays=async()=>{};c.notifications.notify=async()=>false;\nconst now=new Date().toISOString(),expiresAt=new Date(Date.now()+3600000).toISOString();\nconst file=(id,name,type,status,size=40000)=>({fileId:id,name,mimeType:type,size,offset:0,status,sha256:'0'.repeat(64),attemptId:'a',transport:'relay'});\nc.transfers=[{transferId:'incoming',sourceDeviceId:'phone',targetDeviceId:'self',routePreference:'auto',createdAt:now,expiresAt,files:[file('photo','湖畔.png','image/png','received'),file('upload','notes.txt','text/plain','accepted',20000),file('other','project.zip','application/zip','received')]},{transferId:'outgoing',sourceDeviceId:'self',targetDeviceId:'phone',createdAt:now,expiresAt,files:[file('failed','报告.md','text/markdown','failed')]}];\nc.fileSources.set('outgoing:failed',new File(['内容'],'报告.md',{type:'text/markdown'}));c.uploadErrors.set('outgoing:failed','接收方目录暂不可写');\nconst canvas=document.createElement('canvas');canvas.width=640;canvas.height=480;const ctx=canvas.getContext('2d');const gradient=ctx.createLinearGradient(0,0,640,480);gradient.addColorStop(0,'#c8dcc5');gradient.addColorStop(.5,'#7caa96');gradient.addColorStop(1,'#1d654f');ctx.fillStyle=gradient;ctx.fillRect(0,0,640,480);ctx.fillStyle='#dce8ce';ctx.beginPath();ctx.moveTo(0,360);ctx.lineTo(260,120);ctx.lineTo(420,360);ctx.fill();ctx.fillStyle='#426e59';ctx.beginPath();ctx.moveTo(220,480);ctx.lineTo(470,160);ctx.lineTo(640,380);ctx.lineTo(640,480);ctx.fill();\nc.previews.set('incoming:photo',{kind:'image',url:canvas.toDataURL()});c.rtcLocalFiles.set('incoming:photo',new File(['image'],'湖畔.png',{type:'image/png'}));c.previews.set('incoming:upload',{kind:'text',text:'方案记录\\n\\n准备、发送、接收。\\n更少操作，内容始终在眼前。'});c.previews.set('outgoing:failed',{kind:'text',text:'项目记录\\n这里是可以直接拖动和转发的内容。'});\nc.events=[{eventId:'text',type:'text.created',cursor:1,sourceDeviceId:'phone',targetDeviceId:'self',createdAt:now,expiresAt,payload:{text:'下午三点，在图书馆见。\\n我会带上修改后的文档。'}}];c.stagedTexts=[{id:'draft',text:'新的待发送内容'}];c.render();\n";
const compiled = await build({ stdin: { contents: source.replace(bootstrap, fixture),
  resolveDir: join(root, 'web/src'), sourcefile: 'reader-visual.ts', loader: 'ts' },
  bundle: true, platform: 'browser', format: 'esm', write: false, loader: { '.css': 'empty' } });
const css = await readFile(join(root, 'web/src/style.css'));
const html = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/style.css"><div id="app"></div><input id="file-input" type="file" hidden multiple><input id="resume-file" type="file" hidden><div id="toasts"></div><script type="module" src="/fixture.js"></script></html>';
const server = createServer((request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  response.setHeader('Content-Type', path === '/fixture.js' ? 'text/javascript' : path === '/style.css' ? 'text/css' : 'text/html');
  response.end(path === '/fixture.js' ? compiled.outputFiles[0].text : path === '/style.css' ? css : html);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const profile = sharedBrowserProfile;
const edge = process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = launchSharedBrowser(edge, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--disable-background-networking', '--disable-component-update',
  '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'],
  { windowsHide: true, stdio: ['ignore', 'ignore', 'ignore'] });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
let socket;
try {
  let address;
  for (let i=0; i<100 && !address; i++) {
    try { address = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/); }
    catch { await delay(100); }
  }
  assert.ok(address, 'isolated headless browser did not start');
  socket = new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject) => { socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true}); });
  let nextId=0; const calls=new Map();
  socket.addEventListener('message',event=>{
    const reply=JSON.parse(event.data);const pending=calls.get(reply.id);if(!pending)return;
    calls.delete(reply.id);reply.error?pending.reject(new Error(reply.error.message)):pending.resolve(reply.result);
  });
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{
    const id=++nextId;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));
  });
  const target=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId:target.targetId,flatten:true});
  const page=(method,params)=>send(method,params,sessionId);
  const evaluate=async(expression)=>{
    const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
    if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));return result.result.value;
  };
  await page('Page.enable');await page('Runtime.enable');
  await page('Emulation.setDeviceMetricsOverride',{width:1024,height:768,deviceScaleFactor:1,mobile:true});
  await page('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`});
  for(let i=0;i<100;i++){if(await evaluate('Boolean(window.__preview)'))break;await delay(50);}
  assert.equal(await evaluate('Boolean(window.__preview)'),true);
  const evidence=[];
  const capture=async(name,width,height)=>{
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<760});
    await evaluate('document.fonts.ready.then(()=>true)');await delay(100);
    const state=await evaluate(`(()=>{const modal=document.querySelector('.receipt-modal'),cards=[...document.querySelectorAll('.receipt-batch-grid .content-card')];return {overflow:document.documentElement.scrollWidth>innerWidth,modal:modal?{left:modal.getBoundingClientRect().left,right:modal.getBoundingClientRect().right,bottom:modal.getBoundingClientRect().bottom}:null,cards:cards.map(card=>({width:card.getBoundingClientRect().width,height:card.getBoundingClientRect().height,metadata:!!card.querySelector('.card-source,.card-meta,time')})),scrollbar:getComputedStyle(document.querySelector('.dock-items,.history-items,.embedded-library') || document.body).scrollbarWidth};})()`);
    assert.equal(state.overflow,false);for(const card of state.cards)assert.equal(card.metadata,false);
    if(state.modal){assert.ok(state.modal.left>=0&&state.modal.right<=width);assert.ok(state.modal.bottom<=height);}
    const shot=await page('Page.captureScreenshot',{format:'jpeg',quality:82,captureBeyondViewport:false}),path=join(screenshots,`web-mobile-${name}.preview.jpg`);await writeFile(path,Buffer.from(shot.data,'base64'));evidence.push({name,path,...state});
  };
  await evaluate(String.raw`(()=>{const c=window.__preview;c.info.features={groupSharedText:true};c.fileLibrary.refresh=async()=>{};c.fileLibrary.open=async()=>{c.fileLibrary.opened=true;};c.fileLibrary.entries=[{id:'scope/f1',key:'f1',scope:'scope',name:'notes.txt',size:32,mimeType:'text/plain',receivedAt:Date.now(),expiresAt:Date.now()+86400000},{id:'scope/f2',key:'f2',scope:'scope',name:'photo.png',size:200,mimeType:'image/png',receivedAt:Date.now(),expiresAt:Date.now()+86400000}];c.fileLibrary.files.set('scope/f1',new File(['课堂笔记'],'notes.txt',{type:'text/plain'}));c.fileLibrary.files.set('scope/f2',new File(['image'],'photo.png',{type:'image/png'}));c.fileLibrary.snippets.set('scope/f1','课堂笔记\n新的内容会出现在最前面。');c.render();})()`);
  const toolbarEvidence=[];
  for(const width of [390,950])for(const view of ['receive','sent','library'])for(const selected of [false,true]){
    await page('Emulation.setDeviceMetricsOverride',{width,height:width===390?844:650,deviceScaleFactor:1,mobile:width===390});
    await evaluate(`(()=>{const c=window.__preview;c.mobileView='receive';c.contentView='${view}';c.receiveSelecting=${selected};c.sentSelecting=${selected};c.fileLibrary.opened=true;c.fileLibrary.editing=${selected};c.render();})()`);
    const toolbar=await evaluate(`(()=>{const row=document.querySelector('.dock-panel .content-toolbar'),box=row.getBoundingClientRect();return {height:box.height,top:box.top,bottom:box.bottom,wrapped:getComputedStyle(row).flexWrap,buttons:[...row.querySelectorAll('button')].map(button=>button.getBoundingClientRect().height)};})()`);
    assert.equal(toolbar.height,40);assert.equal(toolbar.wrapped,'nowrap');assert.ok(toolbar.buttons.every(height=>height===32));toolbarEvidence.push({width,view,selected,...toolbar});
    if(width===390)await capture(view+(selected?'-selected':'-normal'),390,844);
  }
  await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});await delay(60);
  await evaluate(`(()=>{const c=window.__preview;c.receiveSelecting=false;c.sentSelecting=false;c.fileLibrary.editing=false;c.setMobileView('send');c.render();document.querySelector('#shared-group-text').focus();document.querySelector('#shared-group-text').value='正在编辑的草稿';window.__focused=document.querySelector('#shared-group-text');})()`);
  await page('Emulation.setDeviceMetricsOverride',{width:390,height:430,deviceScaleFactor:1,mobile:true});await delay(120);
  const sharedKeyboard=await evaluate(`(()=>{const input=document.querySelector('#shared-group-text'),box=input.getBoundingClientRect();return {keyboard:document.documentElement.classList.contains('keyboard-open'),sameInput:input===window.__focused,focused:document.activeElement===input,value:input.value,nav:getComputedStyle(document.querySelector('.mobile-view-tabs')).display,appHeight:document.querySelector('#app').getBoundingClientRect().height,top:box.top,bottom:box.bottom,scroll:scrollY,overflow:document.documentElement.scrollWidth>innerWidth};})()`);
  assert.equal(sharedKeyboard.keyboard,true);assert.equal(sharedKeyboard.sameInput,true);assert.equal(sharedKeyboard.focused,true);assert.equal(sharedKeyboard.value,'正在编辑的草稿');assert.equal(sharedKeyboard.nav,'none');assert.equal(sharedKeyboard.appHeight,430);assert.ok(sharedKeyboard.top>=0&&sharedKeyboard.bottom<=430);assert.equal(sharedKeyboard.scroll,0);assert.equal(sharedKeyboard.overflow,false);
  await capture('shared-keyboard-frame',390,430);
  await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});await evaluate(`window.__preview.toggleEditor(true)`);await delay(50);
  await page('Emulation.setDeviceMetricsOverride',{width:390,height:430,deviceScaleFactor:1,mobile:true});await delay(100);
  const editorKeyboard=await evaluate(`(()=>{const input=document.querySelector('#send-text'),modal=document.querySelector('.editor-modal'),box=modal.getBoundingClientRect();return {top:box.top,bottom:box.bottom,height:box.height,keyboard:document.documentElement.classList.contains('keyboard-open'),focused:document.activeElement===input,inputHeight:input?.getBoundingClientRect().height};})()`);
  assert.ok(editorKeyboard.top>=0 && editorKeyboard.bottom<=430);await capture('editor-keyboard-frame',390,430);
  evidence.push({toolbarEvidence,sharedKeyboard,editorKeyboard,keyboardEvidence:'Headless visualViewport resize and focused DOM/caret behavior; not a physical Android/iPad IME acceptance.'});
  await writeFile(join(work,'evidence.json'),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence));

} finally {
  socket?.close(); await closeSharedBrowser(browser);
  await new Promise(resolve=>server.close(resolve));
}
