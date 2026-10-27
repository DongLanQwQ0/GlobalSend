import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';
import assert from 'node:assert/strict';

// Isolated visual fixture: actual UI code and CSS, synthetic data, no hosted
// center or user browser profile. Does not invoke the system clipboard.
const require = createRequire(import.meta.url);
const { build } = require('esbuild');
const root = fileURLToPath(new URL('../../', import.meta.url));
const work = join(root, 'artifacts/tmp/web-library-visual');
const screenshots = join(root, 'artifacts/screenshots');
await mkdir(work, { recursive: true }); await mkdir(screenshots, { recursive: true });
const source = await readFile(join(root, 'web/src/main.ts'), 'utf8');
const bootstrap = 'void new GlobalSend().start();';
assert.equal(source.split(bootstrap).length, 2);
const fixture = `
(async()=>{
const c = new GlobalSend();c.loading=false;c.connected=true;
c.info={protocolVersion:1,instanceId:'visual-fixture',features:{rtcDataChannels:true},limits:{maxTextLength:100000,maxFileSize:2000000000,ttlSeconds:86400}};
c.session={deviceToken:'synthetic-only',device:{deviceId:'self',name:'我的 iPad',platform:'web'},groupId:'fixture'};c.api.session=c.session;
c.devices=[{deviceId:'phone',name:'我的手机',platform:'android',online:true}];c.target='phone';
const canvas=document.createElement('canvas');canvas.width=560;canvas.height=350;const ctx=canvas.getContext('2d');
const gradient=ctx.createLinearGradient(0,0,560,350);gradient.addColorStop(0,'#f1eacb');gradient.addColorStop(1,'#d5e3cc');ctx.fillStyle=gradient;ctx.fillRect(0,0,560,350);ctx.fillStyle='#f6f4dd';ctx.beginPath();ctx.arc(400,95,48,0,Math.PI*2);ctx.fill();ctx.fillStyle='#b9cbb0';ctx.beginPath();ctx.moveTo(0,240);ctx.lineTo(165,100);ctx.lineTo(360,350);ctx.lineTo(0,350);ctx.closePath();ctx.fill();ctx.fillStyle='#729c7c';ctx.beginPath();ctx.moveTo(110,350);ctx.lineTo(375,150);ctx.lineTo(560,290);ctx.lineTo(560,350);ctx.closePath();ctx.fill();ctx.fillStyle='#365f50';ctx.beginPath();ctx.moveTo(0,320);ctx.quadraticCurveTo(210,195,560,350);ctx.lineTo(0,350);ctx.fill();
const image=new File([await new Promise(resolve=>canvas.toBlob(resolve,'image/png'))],'湖边散步.png',{type:'image/png'});
const notes='周末出行计划\\n\\n周六早上八点出发，先去湖边散步，再找一家安静的咖啡馆。\\n\\n需要带上：相机、充电器、雨伞和水。\\n\\n会合地点：图书馆南门。\\n时间有变化时在群里通知。';
const entries=[['image',image.name,image.size,'image/png'],['notes','出行计划.txt',new Blob([notes]).size,'text/plain'],['archive','项目设计源文件.zip',73400320,'application/zip'],['photo','山间一日 · 原图.png',image.size,'image/png'],['report','10月会议纪要与工作安排.pdf',362568,'application/pdf'],['config','服务器配置.json',1248,'application/json']].map((item,index)=>({id:'scope-'+(index%2)+'/'+item[0],scope:'scope-'+(index%2),key:item[0],name:item[1],size:item[2],mimeType:item[3],sha256:'a'.repeat(64),receivedAt:Date.now()-index*3600000,expiresAt:Date.now()+86400000-index*3600000}));
const rules={retentionHours:24,categories:['image','video','audio','text','archive','other'],sizeRule:'any',sizeMiB:0};
c.fileLibrary.service={list:async()=>entries,cleanupPreferences:async()=>rules,get:async(id)=>{const entry=entries.find(e=>e.id===id);return entry.mimeType.startsWith('image/')?new File([image],entry.name,{type:entry.mimeType}):new File([id.endsWith('notes')?notes:'{\\n  "name": "GlobalSend"\\n}'],entry.name,{type:entry.mimeType});},rename:async(id,name)=>{const entry=entries.find(e=>e.id===id);entry.name=name;return entry;},remove:async()=>{},setCleanupPreferences:async(value)=>Object.assign(rules,value)};
c.render();await c.openLibrary();window.__preview=c;
})();
`;
const compiled = await build({ stdin: { contents: source.replace(bootstrap, fixture),
  resolveDir: join(root, 'web/src'), sourcefile: 'reader-visual.ts', loader: 'ts' },
  bundle: true, platform: 'browser', format: 'iife', write: false, loader: { '.css': 'empty' } });
const css = await readFile(join(root, 'web/src/style.css'));
const html = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="/style.css"><div id="app"></div><input id="file-input" type="file" hidden multiple><input id="resume-file" type="file" hidden><div id="toasts"></div><script src="/fixture.js"></script></html>';
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
  for(const [width,height,mode,name] of [[1024,768,'grid','tablet-grid'],[390,844,'grid','phone-grid'],[390,844,'edit','phone-edit'],[390,844,'text','phone-text'],[1024,768,'image','tablet-image'],[390,844,'cleanup','phone-cleanup']]){
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:true});
    if(mode==='grid')await evaluate('window.__preview.fileLibrary.closePreview();window.__preview.fileLibrary.editing=false;window.__preview.render();');
    if(mode==='edit')await evaluate("window.__preview.fileLibrary.enterEdit('scope-0/image');window.__preview.fileLibrary.selected.add('scope-1/notes');window.__preview.render();");
    if(mode==='text')await evaluate("window.__preview.fileLibrary.preview('scope-1/notes')");
    if(mode==='image')await evaluate("window.__preview.fileLibrary.preview('scope-0/image')");
    if(mode==='cleanup')await evaluate("(()=>{const c=window.__preview;c.fileLibrary.closePreview();c.fileLibrary.editing=false;c.fileLibrary.retentionValue='6';c.fileLibrary.retentionUnit='hours';c.fileLibrary.cleanupDraft.categories=['image','text'];c.fileLibrary.cleanupDraft.sizeRule='greater';c.fileLibrary.cleanupDraft.sizeMiB=10;c.fileLibrary.cleanupDirty=true;c.render();document.querySelector('.library-cleanup').open=true;document.querySelector('.file-library-modal').scrollTop=99999;})()");
    await evaluate('document.fonts.ready.then(()=>true)');await delay(130);
    const state=await evaluate(`(()=>{const modal=document.querySelector('.file-library-modal').getBoundingClientRect(),grid=document.querySelector('.library-grid');return {columns:grid?getComputedStyle(grid).gridTemplateColumns.split(' ').length:null,modal:{left:modal.left,right:modal.right,top:modal.top,bottom:modal.bottom},width:innerWidth,height:innerHeight,overflow:document.documentElement.scrollWidth>innerWidth}})()`);
    assert.equal(state.overflow,false);assert.ok(state.modal.left>=0 && state.modal.right<=width && state.modal.bottom<=height);
    if(mode==='grid')assert.equal(state.columns,2);
    if(mode==='text')assert.equal(await evaluate("document.querySelector('#library-text').readOnly"),true);
    if(mode==='image')assert.equal(await evaluate("document.querySelector('.library-image-preview img').naturalWidth"),560);
    const shot=await page('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
    const path=join(screenshots,`web-library-${name}.png`);await writeFile(path,Buffer.from(shot.data,'base64'));
    evidence.push({name,...state,path});
  }
  await writeFile(join(work,'evidence.json'),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence));
  
} finally {
  socket?.close(); await closeSharedBrowser(browser);
  await new Promise(resolve=>server.close(resolve));
}
