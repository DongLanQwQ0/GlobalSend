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
const work = join(root, 'artifacts/tmp/web-workspace-redesign');
const screenshots = join(root, 'artifacts/screenshots');
await mkdir(work, { recursive: true }); await mkdir(screenshots, { recursive: true });
const source = await readFile(join(root, 'web/src/main.ts'), 'utf8');
const bootstrap = 'void new GlobalSend().start();';
assert.equal(source.split(bootstrap).length, 2);
const fixture = `
const c=new GlobalSend();c.loading=false;c.connected=true;c.helloReceived=true;
c.info={protocolVersion:1,instanceId:'workspace-fixture',features:{groupSharedText:true},limits:{maxTextLength:100000,maxFileSize:2000000000,ttlSeconds:86400}};
c.session={deviceToken:'synthetic-only',device:{deviceId:'self',name:'冬岚的电脑',platform:'web'},groupId:'fixture'};c.api.session=c.session;
c.devices=Array.from({length:12},(_,i)=>({deviceId:'peer-'+i,name:['我的手机','iPad','MacBook','客厅电脑'][i%4]+(i>3?' '+i:''),platform:['android','web','windows','windows'][i%4],online:true}));c.target='peer-0';
c.shared.receive({text:'周末出行\\n周六 10:00 在图书馆见。',revision:1,updatedAt:'',updatedBy:'peer-0'});
const canvas=document.createElement('canvas');canvas.width=640;canvas.height=400;const ctx=canvas.getContext('2d');const gradient=ctx.createLinearGradient(0,0,640,400);gradient.addColorStop(0,'#90c6bd');gradient.addColorStop(1,'#f7e9b7');ctx.fillStyle=gradient;ctx.fillRect(0,0,640,400);ctx.fillStyle='#4f8b76';ctx.beginPath();ctx.moveTo(0,280);ctx.quadraticCurveTo(150,80,330,270);ctx.quadraticCurveTo(470,160,640,270);ctx.lineTo(640,400);ctx.lineTo(0,400);ctx.fill();ctx.fillStyle='#316955';ctx.beginPath();ctx.moveTo(0,350);ctx.quadraticCurveTo(290,190,640,330);ctx.lineTo(640,400);ctx.lineTo(0,400);ctx.fill();
const blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/png')),image=new File([blob],'山间漫步.png',{type:'image/png'}),htmlFile=new File(['<!doctype html>\\n<html lang="zh-CN">\\n  <head><title>我的页面</title></head>\\n  <body>\\n    <h1>Hello, GlobalSend</h1>\\n    <p>一个简单的页面。</p>\\n  </body>\\n</html>'],'index.html',{type:'text/html'});
c.picked=[image,htmlFile,...Array.from({length:10},(_,i)=>new File(['备忘内容'],'会议记录 '+(i+1)+'.txt',{type:'text/plain'}))];c.stagedTexts=[{id:'staged-text',text:'这周的设计稿已更新，请查收附件。'}];
const now=new Date().toISOString(),expires=new Date(Date.now()+86400000).toISOString();
c.events=[{eventId:'received-text',type:'text.created',cursor:1,sourceDeviceId:'peer-0',targetDeviceId:'self',createdAt:now,expiresAt:expires,payload:{text:'这是一条来自手机的消息。\\n下午见，记得带上电脑。'}},{eventId:'sent-text',type:'text.created',cursor:2,sourceDeviceId:'self',targetDeviceId:'peer-0',createdAt:now,expiresAt:expires,payload:{text:'收到，文件已经发给你了。'}}];
c.transfers=[{transferId:'fixture',sourceDeviceId:'peer-0',targetDeviceId:'self',createdAt:now,expiresAt:expires,routePreference:'auto',files:[{fileId:'image',name:image.name,size:image.size,mimeType:'image/png',sha256:'a'.repeat(64),offset:image.size,status:'received',transport:'direct'},{fileId:'html',name:htmlFile.name,size:htmlFile.size,mimeType:'text/html',sha256:'b'.repeat(64),offset:htmlFile.size,status:'received',transport:'direct'},{fileId:'archive',name:'课程资料.zip',size:2641200,mimeType:'application/zip',sha256:'c'.repeat(64),offset:2641200,status:'received',transport:'direct'}]}];
c.rtcLocalFiles.set('fixture:image',image);c.rtcLocalFiles.set('fixture:html',htmlFile);
c.rtcFileExpiry.set('fixture:image',Date.now()+86400000);c.rtcFileExpiry.set('fixture:html',Date.now()+86400000);
c.render();c.installWindowDrop();window.__preview=c;
`;
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
  const evidence=[],receiptOnly=process.argv.includes('--receipt-phone');
  const sizes=receiptOnly?[[390,844,'receive','phone-receive-receipt-labels']]:[[1200,800,'send','desktop'],[1000,720,'send','desktop-compact'],[390,844,'send','phone-send'],[390,844,'receive','phone-receive']];
  for(const [width,height,view,name] of sizes){
    await page('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:true});
    await evaluate("window.__preview.setMobileView('"+view+"');window.__preview.render();window.scrollTo(0,0);document.documentElement.scrollTop=0;document.body.scrollTop=0");
    await evaluate('document.fonts.ready.then(()=>true)');await delay(150);
    const state=await evaluate(`(()=>{const box=s=>{const n=document.querySelector(s);if(!n)return null;const r=n.getBoundingClientRect();return {top:r.top,bottom:r.bottom,left:r.left,right:r.right,height:r.height,client:n.clientHeight,scroll:n.scrollHeight,display:getComputedStyle(n).display};};return {overflow:document.documentElement.scrollWidth>innerWidth,pageHeight:document.documentElement.scrollHeight,queue:box('.staged-list'),devices:box('.target-devices'),shared:box('.shared-note'),send:box('#send-panel'),receive:box('#receive-panel'),grid:getComputedStyle(document.querySelector('.receive-grid')).gridTemplateColumns,cards:document.querySelectorAll('.receive-grid>.content-card').length,loadedImages:[...document.querySelectorAll('.content-preview>img')].filter(n=>n.complete && n.naturalWidth>0).length,buttons:[...document.querySelectorAll('.compose-action')].map(n=>n.textContent.trim())};})()`);
    assert.equal(state.overflow,false,JSON.stringify(state));assert.equal(state.pageHeight,height,JSON.stringify(state));assert.deepEqual(state.buttons,['文本','剪贴板','已发送','文件库']);assert.equal(state.cards,4);assert.ok(state.loadedImages>=2);
    if(receiptOnly){
      const labels=await evaluate("[...document.querySelectorAll('#receive-panel .card-info')].map(n=>({label:n.textContent,time:n.querySelector('time').textContent,width:n.clientWidth,scroll:n.scrollWidth,timeWidth:n.querySelector('time').getBoundingClientRect().width,cardWidth:n.closest('.content-card').clientWidth,wrap:getComputedStyle(n).flexWrap}))");
      for(const label of labels){assert.ok(label.scroll<=label.width,JSON.stringify(label));assert.ok(label.timeWidth<=label.width,JSON.stringify(label));}
      assert.ok(labels.some(label=>label.time.startsWith('邀请 ')));assert.ok(labels.some(label=>label.time.startsWith('消息 ')));state.receiptLabelWidths=labels;
      const typography=await evaluate("[...document.querySelectorAll('#receive-panel .card-info,#receive-panel .card-source,#receive-panel .card-status,#receive-panel .card-name,#receive-panel .card-text')].map(n=>({className:n.className,size:parseFloat(getComputedStyle(n).fontSize)}))");
      for(const node of typography)assert.ok(node.size>=((node.className==='card-name' || node.className==='card-text')?14:12),JSON.stringify(node));state.cardTypography=typography;
      const reachable=await evaluate("(()=>{const n=document.querySelector('#receive-panel .dock-items');n.scrollTop=n.scrollHeight;const cards=[...n.querySelectorAll('.content-card')],last=cards.at(-1).getBoundingClientRect(),box=n.getBoundingClientRect();const result={count:cards.length,containerOverflow:getComputedStyle(n).overflowY,scrollTop:n.scrollTop,lastBottom:last.bottom,containerBottom:box.bottom,columns:getComputedStyle(n.querySelector('.receive-grid')).gridTemplateColumns};n.scrollTop=0;return result})()");
      assert.equal(reachable.count,4);assert.equal(reachable.containerOverflow,'auto');assert.ok(reachable.lastBottom<=reachable.containerBottom+1);assert.equal(reachable.columns.trim().split(/\s+/).length,2);state.cardsAccessible=reachable;
    }
    if(width>760 || view==='send'){assert.ok(state.queue.height>=70,JSON.stringify(state));assert.ok(state.queue.scroll>state.queue.client);assert.ok(state.devices.scroll>state.devices.client);assert.ok(state.shared.bottom<=height,JSON.stringify(state));}
    if(width<=760)assert.equal((view==='send'?state.receive:state.send).display,'none');
    const shot=await page('Page.captureScreenshot',{format:'jpeg',quality:80,captureBeyondViewport:false});const path=join(screenshots,'web-workspace-'+name+'.preview.jpg');await writeFile(path,Buffer.from(shot.data,'base64'));evidence.push({name,...state,path});
  }
  if(!receiptOnly){
  await page('Emulation.setDeviceMetricsOverride',{width:1200,height:800,deviceScaleFactor:1,mobile:true});
  // Text is staged, not sent from the editor. Queue/device scroll positions survive presence repaint.
  await evaluate("window.__preview.setMobileView('send');window.__preview.render();document.querySelector('.staged-list').scrollTop=90;document.querySelector('.target-devices').scrollTop=50;window.__preview.render()");
  assert.equal(await evaluate("document.querySelector('.staged-list').scrollTop"),90);
  assert.equal(await evaluate("document.querySelector('.target-devices').scrollTop"),50);
  await evaluate("document.querySelector('[data-action=open-editor]').click();const input=document.querySelector('#send-text');input.value='待发送文本';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('[data-action=stage-text]').click()");
  assert.equal(await evaluate("window.__preview.stagedTexts.at(-1).text"),'待发送文本');assert.equal(await evaluate('window.__preview.modal'),null);
  // Full-window text drop uses the header, far outside the old drop control.
  await evaluate("const transfer=new DataTransfer();transfer.setData('text/plain','窗口任意区域拖入');document.querySelector('.topbar').dispatchEvent(new DragEvent('dragenter',{dataTransfer:transfer,bubbles:true,cancelable:true}));window.__dropData=transfer");
  assert.equal(await evaluate("document.querySelector('#window-drop').classList.contains('visible')"),true);
  const dragshot=await page('Page.captureScreenshot',{format:'jpeg',quality:80,captureBeyondViewport:false});await writeFile(join(screenshots,'web-workspace-drop.preview.jpg'),Buffer.from(dragshot.data,'base64'));
  await evaluate("document.querySelector('.topbar').dispatchEvent(new DragEvent('drop',{dataTransfer:window.__dropData,bubbles:true,cancelable:true}))");await delay(20);
  assert.equal(await evaluate("window.__preview.stagedTexts.at(-1).text"),'窗口任意区域拖入');
  assert.equal(await evaluate("document.querySelector('#window-drop').classList.contains('visible')"),false);
  await evaluate("document.querySelector('[data-action=history]').click()");assert.equal(await evaluate("document.querySelectorAll('.history-modal [data-read=sent-text]').length"),1);
  await evaluate("document.querySelector('.history-modal [data-read=sent-text]').click()");assert.equal(await evaluate("document.querySelector('#reader-text').readOnly"),false);
  await evaluate("document.querySelector('[data-action=close-modal]').click();window.__preview.setMobileView('receive');document.querySelector('[data-preview-file=\"fixture:html\"]').click()");
  assert.ok((await evaluate("document.querySelector('.large-file-preview').textContent")).includes('<!doctype html>'));
  await evaluate("document.querySelector('[data-action=close-modal]').click();document.querySelector('[data-action=settings]').click()");
  const settingShot=await page('Page.captureScreenshot',{format:'jpeg',quality:80,captureBeyondViewport:false});await writeFile(join(screenshots,'web-workspace-settings.preview.jpg'),Buffer.from(settingShot.data,'base64'));
  evidence.push({interactions:{textStaged:true,queueAndDeviceScrollPreserved:true,wholeWindowDrop:true,sentHistoryEdit:true,htmlPreview:true}});
  }
  await writeFile(join(work,receiptOnly?'receipt-labels-evidence.json':'evidence.json'),JSON.stringify(evidence,null,2));console.log(JSON.stringify(evidence));
  
} finally {
  socket?.close(); await closeSharedBrowser(browser);
  await new Promise(resolve=>server.close(resolve));
}
