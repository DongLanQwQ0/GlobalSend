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
const work = join(root, 'artifacts/tmp/web-reader-visual');
const screenshots = join(root, 'artifacts/screenshots');
await mkdir(work, { recursive: true }); await mkdir(screenshots, { recursive: true });
const source = await readFile(join(root, 'web/src/main.ts'), 'utf8');
const bootstrap = 'void new GlobalSend().start();';
assert.equal(source.split(bootstrap).length, 2);
const fixture = `
const c = new GlobalSend();
c.loading=false; c.connected=true;
c.info={protocolVersion:1,instanceId:'visual-fixture',limits:{maxTextLength:100000,maxFileSize:2000000000,ttlSeconds:86400}};
c.session={deviceToken:'synthetic-only',device:{deviceId:'self',name:'我的 iPad',platform:'web'},groupId:'fixture'}; c.api.session=c.session;
c.devices=[{deviceId:'phone',name:'我的手机',platform:'android',online:true}]; c.target='phone';
const event=(eventId,outgoing,text,cursor)=>({eventId,type:'text.created',cursor,sourceDeviceId:outgoing?'self':'phone',targetDeviceId:outgoing?'phone':'self',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString(),payload:{text}});
c.events=[event('incoming',false,'周末出行计划\\n\\n周六早上八点出发，先去湖边散步，再找一家安静的咖啡馆。\\n\\n需要带上：相机、充电器、雨伞和水。\\n\\n收到的文字可以完整查看、选择和复制，不会意外改动。',1),event('sent',true,'明天下午三点，在图书馆门口见。\\n如果下雨，就改在一楼大厅。',2)];
c.api.request=async(path,body,method)=>{if(!path.startsWith('/texts/') || method!=='PATCH')throw new Error('Unexpected fixture request');const original=c.events.find(e=>e.eventId===decodeURIComponent(path.slice(7)));return {event:{...original,eventId:'fixture-update',type:'text.updated',cursor:3,payload:{sourceEventId:original.eventId,text:body.text,editedAt:new Date().toISOString()}}};};
c.render();window.__preview=c;
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
  for(const [width,height,eventId,name] of [[1024,768,'incoming','ipad-received'],[390,844,'sent','phone-sent']]){
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:true});
    await evaluate(`window.__preview.openText('${eventId}');document.fonts.ready.then(()=>true)`);await delay(100);
    const state=await evaluate(`(()=>{const field=document.querySelector('#reader-text'),modal=document.querySelector('.reader-modal').getBoundingClientRect();return {readOnly:field.readOnly,fontSize:getComputedStyle(field).fontSize,modal:{left:modal.left,right:modal.right,top:modal.top,bottom:modal.bottom},width:innerWidth,height:innerHeight,overflow:document.documentElement.scrollWidth>innerWidth}})()`);
    assert.equal(state.readOnly,eventId==='incoming');assert.equal(state.overflow,false);
    assert.ok(state.modal.left>=0 && state.modal.right<=state.width && state.modal.bottom<=state.height);
    if(eventId==='sent'){
      await evaluate(`(()=>{const field=document.querySelector('#reader-text');field.value='明天下午四点，在图书馆门口见。\\n时间已更新，不会另发一条消息。';field.dispatchEvent(new Event('input',{bubbles:true}));return window.__preview.saveViewedText();})()`);
      assert.equal(await evaluate("document.querySelector('#reader-status').textContent"),'已保存');
    }
    const shot=await page('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
    const path=join(screenshots,`web-reader-${name}.png`);await writeFile(path,Buffer.from(shot.data,'base64'));
    evidence.push({name,...state,path});
  }
  await writeFile(join(work,'evidence.json'),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence));
  
} finally {
  socket?.close(); await closeSharedBrowser(browser);
  await new Promise(resolve=>server.close(resolve));
}
