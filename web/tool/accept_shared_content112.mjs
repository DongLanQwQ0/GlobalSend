import {browserProfile,launchSharedBrowser,closeSharedBrowser} from './browser_profile.mjs';
import {build} from 'esbuild';
import {createServer} from 'node:http';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import assert from 'node:assert/strict';

const root=fileURLToPath(new URL('../../',import.meta.url));
const run=join(root,'artifacts/tmp/receive-reference112-render');await mkdir(run,{recursive:true});
await build({entryPoints:[join(root,'web/src/style.css')],bundle:true,outfile:join(run,'style.css'),logLevel:'silent'});
const source=(await readFile(join(root,'web/src/main.ts'),'utf8')).replace('void new GlobalSend().start();','');
await build({stdin:{loader:'ts',resolveDir:join(root,'web/src'),contents:source+`
const c=new GlobalSend();c.loading=false;c.connected=true;c.helloReceived=true;
c.session={deviceToken:'fixture',device:{deviceId:'self',name:'Web',platform:'web'},groupId:'group'};
c.info={features:{groupSharedText:true},limits:{maxFileSize:100000,maxTextLength:100000}};
c.api.request=async()=>({offers:[],transfers:[],events:[],devices:[]});
c.clipboard.receive({id:'slot',source:'PC',at:'2099-01-01',text:'最新剪贴板内容。可复制、拖出，或主动加入待发送。'});
c.copiedFiles.offers=[{sourceDeviceId:'PC',sourceName:'DongLan',offerId:'offer',groupId:'group',createdAt:'2099-01-01',items:[{id:'folder',name:'课程资料',kind:'directory'}]}];
c.devices=[{deviceId:'PC',name:'DongLan',platform:'windows',online:true}];
window.__errors=[];addEventListener('error',event=>window.__errors.push(event.message));window.__view=c;c.render();
`},bundle:true,format:'esm',outfile:join(run,'fixture.js'),loader:{'.css':'empty'},logLevel:'silent'});
await writeFile(join(run,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="./style.css"><main id="app" style="max-width:880px;margin:auto"></main><script type="module" src="./fixture.js"></script></html>');
const allowed=new Map([['/','index.html'],['/index.html','index.html'],['/fixture.js','fixture.js'],['/style.css','style.css'],['/test-image.png','test-image.png']]);
const server=createServer(async(req,res)=>{const file=allowed.get(new URL(req.url,'http://localhost').pathname);if(!file){res.writeHead(404).end();return;}res.setHeader('content-type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':file.endsWith('.png')?'image/png':'text/html');res.end(await readFile(join(run,file)));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const base=`http://127.0.0.1:${server.address().port}`;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(action,accept){const end=Date.now()+15000;let value;while(Date.now()<end){value=await action();if(accept(value))return value;await wait(40);}throw new Error('Timeout: '+JSON.stringify(value));}
let browser,socket,closePage;
try {
  browser=launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${browserProfile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:run,TMP:run}});
  const address=await until(async()=>{try{return(await readFile(join(browserProfile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let id=0;const pending=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),call=pending.get(value.id);if(call){pending.delete(value.id);value.error?call.reject(new Error(value.error.message)):call.resolve(value.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});socket.send(JSON.stringify({id:n,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});const page=(method,params={})=>send(method,params,sessionId);closePage=()=>send('Target.closeTarget',{targetId});
  const evaluate=async expression=>{const value=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
  await page('Page.navigate',{url:base});await until(()=>evaluate('!!window.__view && !!document.querySelector(".clipboard-slot-card")'),Boolean);
  const states=[];
  for(const width of [950,390]){
    await page('Emulation.setDeviceMetricsOverride',{width,height:width===950?650:844,deviceScaleFactor:1,mobile:width<500});await wait(60);
    const state=await evaluate(`(()=>{const list=document.querySelector('.copied-file-list'),slot=document.querySelector('.clipboard-slot-card'),ref=document.querySelector('[data-copied-reference]'),r=slot.getBoundingClientRect();return {width:r.width,height:r.height,slotParent:slot.parentElement===list,referenceParent:ref.parentElement===list,count:document.querySelectorAll('.clipboard-slot-card').length,overflow:document.documentElement.scrollWidth>innerWidth,copy:!!slot.querySelector('[data-action="copy-clipboard-slot"]'),stage:!!slot.querySelector('[data-action="stage-clipboard-slot"]'),drag:slot.draggable};})()`);
    assert.ok(Math.abs(state.width-state.height)<1);assert.equal(Math.round(state.width),124);assert.ok(state.slotParent && state.referenceParent && state.copy && state.stage && state.drag);assert.equal(state.overflow,false);states.push({viewport:width,...state});
    const image=await page('Page.captureScreenshot',{format:'jpeg',quality:85});await writeFile(join(run,`shared-content-${width}.jpg`),Buffer.from(image.data,'base64'));
  }
  assert.deepEqual(await evaluate('window.__errors'),[]);await writeFile(join(run,'browser-result.json'),JSON.stringify({passed:true,browserProfile,states},null,2));console.log('PASS shared singleton slot/reference square surfaces at 950 and 390, actions and real drag source present, no page overflow');
} finally {await closePage?.().catch(()=>{});socket?.close();await closeSharedBrowser(browser);await new Promise(resolve=>server.close(resolve));}
