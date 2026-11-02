import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { browserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import { features } from '../../docs/experience/catalog.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const run = join(root,'artifacts/tmp/experience-atlas');
const visualOnly = process.argv.includes('--visual-only');
const reportPath = join(run,visualOnly ? 'visual-result.json' : 'result.json');
await mkdir(run,{recursive:true});
const html = await readFile(join(root,'web/public/experience/index.html'));
const server = createServer((req,res)=>{
  if (req.url === '/' || req.url === '/experience/') { res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'}); res.end(html); }
  else { res.writeHead(req.url === '/favicon.ico' ? 204 : 404); res.end(); }
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base=`http://127.0.0.1:${server.address().port}`;
const delay = ms => new Promise(resolve=>setTimeout(resolve,ms));
async function until(action,accept) {
  const deadline=Date.now()+12000;
  while(Date.now()<deadline) { const value=await action(); if(accept(value)) return value; await delay(50); }
  throw new Error('Browser condition timed out');
}
let browser,socket,closePage;
const report={browserProfile,baseline:'1.0.89+114',mode:visualOnly?'render':'acceptance',checks:[],screenshots:[],realDevicesOperated:false};
try {
  browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',[
    '--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions',
    '--disable-background-networking','--disable-component-update','--remote-debugging-port=0',
    `--user-data-dir=${browserProfile}`,'about:blank'
  ],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
  const address=await until(async()=>{
    try{return(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{return null;}
  },Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let sequence=0; const calls=new Map(),exceptions=[];
  socket.addEventListener('message',event=>{
    const value=JSON.parse(event.data),call=calls.get(value.id);
    if(call){calls.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}
    if(value.method==='Runtime.exceptionThrown') exceptions.push(value.params.exceptionDetails);
  });
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{
    const id=++sequence;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));
  });
  const {targetId}=await send('Target.createTarget',{url:'about:blank'});
  const {sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  closePage=()=>send('Target.closeTarget',{targetId});
  const page=(method,params={})=>send(method,params,sessionId);
  const evaluate=async expression=>{
    const result=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
    if(result.exceptionDetails)throw new Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  const click=selector=>evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  const key=async(key,code=key)=>{
    const windowsVirtualKeyCode = {Escape:27,ArrowRight:39,ArrowLeft:37,'/':191}[key];
    await page('Input.dispatchKeyEvent',{type:'keyDown',key,code,windowsVirtualKeyCode});
    await page('Input.dispatchKeyEvent',{type:'keyUp',key,code,windowsVirtualKeyCode});
  };
  const capture=async name=>{
    await until(()=>evaluate('document.getAnimations().every(animation=>animation.playState!=="running")'),Boolean);
    const result=await page('Page.captureScreenshot',{format:'jpeg',quality:84});
    await writeFile(join(run,name),Buffer.from(result.data,'base64'));report.screenshots.push(name);
  };
  const check=(name,actual,expected=true)=>{assert.deepEqual(actual,expected,name);report.checks.push(name);};
  await page('Page.enable'); await page('Runtime.enable');
  await page('Emulation.setDeviceMetricsOverride',{width:1440,height:1050,deviceScaleFactor:1,mobile:false});
  await page('Page.navigate',{url:base+'/experience/'});
  await until(()=>evaluate('document.querySelectorAll(".feature-card").length'),value=>value===features.length);
  if (visualOnly) {
    for (const [selector,name] of [['#modules','module-roles-desktop.jpg'],['#layout','desktop-layout.jpg'],['#catalog','desktop-catalog.jpg'],['#decisions','desktop-recommendations.jpg']]) {
      await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({behavior:'instant'})`);
      await capture(name);
    }
    await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
    await click('[data-platform=android]');
    await evaluate('document.querySelector("#layout").scrollIntoView({behavior:"instant"})');
    await capture('android-layout-390.jpg');
    check('final mobile diagram keeps four add actions on one row',await evaluate('new Set([...document.querySelectorAll(".phone .mock-split button")].map(node=>Math.round(node.getBoundingClientRect().top))).size'),1);
  } else {
  check('five platform selectors',await evaluate('document.querySelectorAll("[data-platform]").length'),5);
  check('initial Windows and proposed layout',await evaluate('document.querySelector("[data-platform=windows]").getAttribute("aria-selected")==="true" && document.querySelector("[data-mode=proposed]").getAttribute("aria-pressed")==="true"'));
  await capture('desktop-overview.jpg');
  check('three modules have distinct responsibilities',await evaluate('[...document.querySelectorAll(".module-purpose")].map(node=>node.textContent)'),['完整工作台','跨应用中转站','后台到件入口']);
  await evaluate('document.querySelector("#modules").scrollIntoView()');
  await capture('module-roles-desktop.jpg');
  await click('[data-module=windows-receiver] summary');
  check('module lifecycle states close does not delete or interrupt',await evaluate('document.querySelector("[data-module=windows-receiver] details").open && document.querySelector("[data-module=windows-receiver] dd").textContent.includes("不删除正式收件")'));
  await click('[data-module=windows-receiver] summary');
  await evaluate('document.querySelector("#layout").scrollIntoView()');
  await capture('desktop-layout.jpg');
  await click('[data-mode=current]');
  check('current map removes proposed device automation shortcut',await evaluate('!document.querySelector("#workspace").textContent.includes("设备自动化")'));
  await click('[data-mode=proposed]');
  check('proposed map has nearby device automation',await evaluate('document.querySelector("#workspace").textContent.includes("设备自动化")'));
  await click('.feature-card[data-feature=clipboard]');
  check('dialog enters with animation',await evaluate('getComputedStyle(document.querySelector("dialog")).animationName'), 'modal-in');
  check('dialog identifies Windows source and limitations',await evaluate('document.querySelector("#detail-body").textContent.includes("自动监听来源目前仅Windows") && document.querySelector("#detail-body").textContent.includes("8192")'));
  await capture('clipboard-detail.jpg');
  await key('Escape');await until(()=>evaluate('document.querySelector("dialog").open'),value=>!value);
  check('Esc closes modal',true);
  await click('.feature-card[data-feature=dock]');await delay(240);
  await page('Input.dispatchMouseEvent',{type:'mousePressed',x:5,y:5,button:'left',clickCount:1});
  await page('Input.dispatchMouseEvent',{type:'mouseReleased',x:5,y:5,button:'left',clickCount:1});
  await until(()=>evaluate('document.querySelector("dialog").open'),value=>!value);
  check('real backdrop click closes modal',true);
  for (const id of ['android','ios','ipados','web']) {
    await click(`[data-platform=${id}]`);
    check(`${id}: all feature descriptions remain available`,await evaluate('document.querySelectorAll(".feature-card").length'),features.length);
    await click('.feature-card[data-feature=clipboard]');
    const text=await evaluate('document.querySelector(".detail-platform").textContent');
    check(`${id}: clipboard policy correct`,id==='android'?text.includes('图片不写'):id==='ios'?text.includes('不写图片'):id==='ipados'?text.includes('图片写入'):text.includes('Android/iPhone'));
    await click('#close-detail');await until(()=>evaluate('document.querySelector("dialog").open'),value=>!value);
  }
  await click('[data-platform=web]');await click('#only-supported');
  check('Web capability filter excludes native dock and on-demand',await evaluate('!document.querySelector(".feature-card[data-feature=dock]") && !document.querySelector(".feature-card[data-feature=on-demand]")'));
  await click('#only-supported');await click('[data-group=shared]');
  check('shared group contains only shared features',await evaluate('[...document.querySelectorAll(".feature-card")].map(n=>n.dataset.feature)'),['shared-text','clipboard','references','on-demand','dock']);
  await evaluate('document.querySelector("#search").value="没有这个功能xyz";document.querySelector("#search").dispatchEvent(new Event("input",{bubbles:true}))');
  check('empty result state',await evaluate('!document.querySelector("#empty").hidden && document.querySelectorAll(".feature-card").length===0'));
  await click('#reset-filter');check('clear filter restores full list',await evaluate('document.querySelectorAll(".feature-card").length'),features.length);
  await evaluate('document.querySelector("#catalog-platform").value="ipados";document.querySelector("#catalog-platform").dispatchEvent(new Event("change",{bubbles:true}))');
  check('nearby platform filter reuses global selection',await evaluate('document.querySelector("[data-platform=ipados]").getAttribute("aria-selected")==="true" && document.querySelector("#platform-intro").textContent.includes("iPadOS")'));
  await click('[data-journey=copy]');
  check('copy scenario distinguishes three mechanisms',await evaluate('document.querySelector("#journey-body").textContent.includes("持续同步") && document.querySelector("#journey-body").textContent.includes("需要时才拉取")'));
  await click('details.comparison>summary');check('comparison opens',await evaluate('document.querySelector("details.comparison").open'));
  for(const [width,height] of [[950,650],[768,1024],[390,844],[320,740]]) {
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width<600});
    for(const id of ['windows','android','ios','ipados','web']) {
      await click(`[data-platform=${id}]`);
      check(`${id} at ${width}: no document overflow`,await evaluate('document.documentElement.scrollWidth<=innerWidth'));
    }
    if(width===390){
      await click('[data-platform=android]');await evaluate('document.querySelector("#layout").scrollIntoView()');await delay(250);await capture('android-layout-390.jpg');
      await click('.feature-card[data-feature=dock]');await delay(250);
      check('mobile dialog stays inside viewport',await evaluate('(()=>{let r=document.querySelector("dialog").getBoundingClientRect();return r.left>=0 && r.right<=innerWidth && r.top>=0 && r.bottom<=innerHeight})()'));
      await capture('mobile-detail-390.jpg');await key('Escape');await until(()=>evaluate('document.querySelector("dialog").open'),value=>!value);
    }
  }
  await page('Emulation.setDeviceMetricsOverride',{width:1440,height:1050,deviceScaleFactor:1,mobile:false});
  await click('[data-platform=windows]');
  await evaluate('document.querySelector("[data-platform=windows]").focus()');await key('ArrowRight');
  check('keyboard platform navigation',await evaluate('document.querySelector("[data-platform=android]").getAttribute("aria-selected")==="true"'));
  await evaluate('document.activeElement.blur()');await key('/','Slash');
  check('slash focuses search',await evaluate('document.activeElement.id'), 'search');
  await evaluate('document.activeElement.blur()');
  await page('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  await click('.feature-card[data-feature=dock]');
  check('reduced motion honors preference',await evaluate('getComputedStyle(document.querySelector("dialog")).animationName'), 'none');
  await click('#close-detail');check('reduced motion closes without animation timer',await evaluate('!document.querySelector("dialog").open'));
  await page('Page.navigate',{url:new URL('../../web/public/experience/index.html',import.meta.url).href});
  await until(()=>evaluate('document.querySelectorAll(".feature-card").length'),value=>value===features.length);
  check('standalone file works offline without HTTP imports',await evaluate('location.protocol==="file:" && document.querySelectorAll("script[src],link[rel=stylesheet]").length===0'));
  await click('[data-platform=ipados]');await click('.feature-card[data-feature=on-demand]');
  check('offline page interactions work',await evaluate('document.querySelector("dialog").open && document.querySelector("#detail-title").textContent==="按需拖放"'));
  await click('#close-detail');await until(()=>evaluate('document.querySelector("dialog").open'),value=>!value);
  check('no runtime exceptions',exceptions,[]);
  }
  report.result='passed';
  await writeFile(reportPath,JSON.stringify(report,null,2));
  console.log(JSON.stringify(report,null,2));
} catch(error) {
  report.result='failed';report.error=error.stack;
  await writeFile(reportPath,JSON.stringify(report,null,2));
  throw error;
} finally {
  await closePage?.().catch(()=>{});
  socket?.close();
  await closeSharedBrowser(browser);
  await new Promise(resolve=>server.close(resolve));
}
