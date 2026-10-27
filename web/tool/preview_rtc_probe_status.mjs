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
const work = join(root, 'artifacts/tmp/web-rtc-probe-visual');
const screenshots = join(root, 'artifacts/screenshots');
await mkdir(work, { recursive: true }); await mkdir(screenshots, { recursive: true });
const source = await readFile(join(root, 'web/src/main.ts'), 'utf8');
const bootstrap = 'void new GlobalSend().start();';
assert.equal(source.split(bootstrap).length, 2);
const fixture = `
const c=new GlobalSend();c.loading=false;c.connected=true;c.helloReceived=true;
c.info={protocolVersion:1,instanceId:'visual-fixture',features:{rtcProbes:true},limits:{maxTextLength:100000,maxFileSize:2000000000,ttlSeconds:86400}};
c.session={deviceToken:'synthetic-only',device:{deviceId:'self',name:'Windows 电脑',platform:'web'},groupId:'fixture'};c.api.session=c.session;
c.devices=[{deviceId:'phone',name:'我的手机',platform:'android',online:true},{deviceId:'ipad',name:'iPad',platform:'web',online:true}];c.target='phone';
c.rtcProbes={status:peer=>peer==='phone'?'RTC 局域网 · 3 ms':'RTC 公网 · 21 ms'};
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
  for(const [width,height,mode,name] of [[1365,900,'workspace','desktop-status'],[390,844,'workspace','phone-status'],[390,844,'settings','phone-settings']]){
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:true});
    await evaluate("window.__preview.modal=null;window.__preview.mobileView='send';window.__preview.render()");
    if(mode==='settings')await evaluate('window.__preview.openSettings()');
    await evaluate('document.fonts.ready.then(()=>true)');await delay(100);
    const state=await evaluate(`(()=>({overflow:document.documentElement.scrollWidth>innerWidth,status:[...document.querySelectorAll('.rtc-probe-status')].map(n=>n.textContent),note:document.querySelector('.target-note')?.textContent}))()`);
    assert.equal(state.overflow,false);assert.equal(state.note,'RTC 局域网 · 3 ms');assert.ok(state.status.includes('RTC 公网 · 21 ms'));
    const shot=await page('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
    const path=join(screenshots,`web-rtc-probe-${name}.png`);await writeFile(path,Buffer.from(shot.data,'base64'));evidence.push({name,...state,path});
  }
  await writeFile(join(work,'evidence.json'),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence));
  
} finally {
  socket?.close(); await closeSharedBrowser(browser);
  await new Promise(resolve=>server.close(resolve));
}
