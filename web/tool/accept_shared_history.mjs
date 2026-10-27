import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,mkdtemp} from 'node:fs/promises';
import {createServer} from 'node:net';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {randomUUID,createHash} from 'node:crypto';
import {buildApp} from '../../server/src/server.ts';

// The real UI, local center and the persistent shared Edge profile.
// Clipboard writes stay in a page-only mock. No user browser or device is used.
const root=fileURLToPath(new URL('../../',import.meta.url));
const acceptVersion=process.env.GLOBALSEND_ACCEPT_VERSION || 'shared-history';
const ipOnly=process.env.GLOBALSEND_ACCEPT_IP_ONLY==='1';
const work=join(root,`artifacts/tmp/web-ui-${acceptVersion}`),shots=join(root,'artifacts/screenshots');
await mkdir(work,{recursive:true});await mkdir(shots,{recursive:true});
const run=await mkdtemp(join(work,'run-')),site=join(run,'site'),profile=sharedBrowserProfile;await mkdir(site,{recursive:true});
const {build}=createRequire(import.meta.url)('esbuild'),source=await readFile(join(root,'web/src/main.ts'),'utf8');
const compiled=await build({stdin:{contents:source.replace('void new GlobalSend().start();','const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();'),resolveDir:join(root,'web/src'),sourcefile:'ui-acceptance.ts',loader:'ts'},bundle:true,platform:'browser',format:'esm',write:false,loader:{'.css':'empty'}});
await writeFile(join(site,'fixture.js'),compiled.outputFiles[0].text);await writeFile(join(site,'style.css'),await readFile(join(root,'web/src/style.css')));
await writeFile(join(site,'index.html'),'<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" hidden multiple><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script></html>');
const portServer=createServer();await new Promise(resolve=>portServer.listen(0,'127.0.0.1',resolve));const port=portServer.address().port;await new Promise(resolve=>portServer.close(resolve));
const base=`http://127.0.0.1:${port}/globalsend`,center=await buildApp({dataDir:join(run,'center'),relayDir:join(run,'relay'),staticDir:site,publicBaseUrl:base,diskReserve:0,production:false,log:false});
const requests=[];center.addHook('onRequest',async req=>{requests.push({method:req.method,path:new URL(req.url,base).pathname});});await center.listen({host:'127.0.0.1',port});
const browser=launchSharedBrowser(process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',['--headless=new','--disable-gpu','--no-first-run','--no-default-browser-check','--disable-extensions','--disable-background-networking','--disable-component-update','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{windowsHide:true,stdio:'ignore',env:{...process.env,TEMP:work,TMP:work}});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function poll(action,predicate,timeout=15000){let last;const end=Date.now()+timeout;while(Date.now()<end){last=await action();if(predicate(last))return last;await delay(30);}throw new Error('Deadline: '+JSON.stringify(last));}
async function call(path,body,token,method=body===undefined?'GET':'POST'){
  const response=await fetch(base+'/api/v1'+path,{method,headers:{...(body===undefined?{}:{'content-type':Buffer.isBuffer(body)?'application/octet-stream':'application/json'}),...(token?{authorization:'Bearer '+token}:{})},body:body===undefined?undefined:Buffer.isBuffer(body)?body:JSON.stringify(body)});
  const value=await response.json();assert.ok(response.ok,JSON.stringify({path,status:response.status,value}));return value;
}
const peerSockets=[];let socket,closeTestPage;
try {
  const address=await poll(async()=>{try{return (await readFile(join(profile,'DevToolsActivePort'),'utf8')).trim().split(/\r?\n/);}catch{}},Boolean);
  socket=new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);await new Promise((resolve,reject)=>{socket.addEventListener('open',resolve,{once:true});socket.addEventListener('error',reject,{once:true});});
  let next=0;const protocolEvents=[];const calls=new Map();socket.addEventListener('message',event=>{const value=JSON.parse(event.data),pending=calls.get(value.id);if(value.method)protocolEvents.push(value);if(pending){calls.delete(value.id);value.error?pending.reject(new Error(value.error.message)):pending.resolve(value.result);}});
  const send=(method,params={},sessionId)=>new Promise((resolve,reject)=>{const id=++next;calls.set(id,{resolve,reject});socket.send(JSON.stringify({id,method,params,...(sessionId?{sessionId}:{})}));});
  const {targetId}=await send('Target.createTarget',{url:'about:blank'}),{sessionId}=await send('Target.attachToTarget',{targetId,flatten:true});
  const page=(method,params)=>send(method,params,sessionId);
  const evaluate=async expression=>{const value=await page('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});if(value.exceptionDetails)throw new Error(JSON.stringify(value.exceptionDetails));return value.result.value;};
  closeTestPage=async()=>{await evaluate("(()=>{const c=window.__client;if(!c)return;c.stagedTexts=[];c.pendingTexts=[];c.pendingOffer=null;c.libraryForward=null;c.shared.dirty=false;c.busy=false;for(const view of c.textViews.values()){view.draft=view.savedText;view.busy=false;}})()");return send('Target.closeTarget',{targetId});};
  await page('Page.enable');await page('Runtime.enable');await page('Emulation.setFocusEmulationEnabled',{enabled:true});
  const systemReducedMotion=await evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches");
  await page('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
  await page('Emulation.setDeviceMetricsOverride',{width:950,height:619,deviceScaleFactor:1,mobile:false});await page('Page.navigate',{url:base+'/app/'});
  await poll(()=>evaluate('!!window.__client && !window.__client.loading'),Boolean);



  const checks={};
  async function click(selector){
    const p=await evaluate("(()=>{const node=document.querySelector("+JSON.stringify(selector)+");node.scrollIntoView({block:'nearest'});const r=node.getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()");
    for(const type of ['mousePressed','mouseReleased'])await page('Input.dispatchMouseEvent',{type,...p,button:'left',buttons:type==='mousePressed'?1:0,clickCount:1});
    await delay(70);
  }
  async function key(key,code,modifiers=0){
    await page('Input.dispatchKeyEvent',{type:'keyDown',key,code,modifiers});
    await page('Input.dispatchKeyEvent',{type:'keyUp',key,code,modifiers});
    await delay(40);
  }
  await evaluate("(async()=>{const c=window.__client;c.groupKey='shared-history-browser';await c.enroll();Object.defineProperty(navigator,'clipboard',{configurable:true,value:{read:async()=>[],writeText:async t=>window.__copied=t}});})()");
  await poll(()=>evaluate('window.__client.connected && window.__client.shared.loaded'),Boolean);
  await evaluate("window.__client.refresh=async()=>{};document.querySelector('#shared-group-text').focus()");
  if(!ipOnly){
  await page('Input.insertText',{text:'共同编辑 ABC'});
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'共同编辑 ABC');
  await poll(()=>evaluate("!window.__client.shared.dirty && !window.__client.shared.saving"),Boolean);
  assert.equal(await evaluate("document.querySelector('[data-shared-action=undo]').disabled"),false);
  await key('z','KeyZ',2);
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'');
  await key('z','KeyZ',10);
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'共同编辑 ABC');
  await click('[data-shared-action=undo]');
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'');
  await click('[data-shared-action=redo]');
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'共同编辑 ABC');
  assert.equal(await evaluate("document.activeElement.id"),'shared-group-text');
  await poll(()=>evaluate("!window.__client.shared.dirty && !window.__client.shared.saving"),Boolean);
  checks.actualKeysAndButtonsRetainCaretAndSync=true;
  const peer=await call('/devices/enroll',{name:'共享编辑测试端',platform:'web',groupKey:'shared-history-browser'});
  await call('/group/shared-text',{text:'另一设备正文',baseRevision:await evaluate('window.__client.shared.document.revision'),mutationId:randomUUID()},peer.deviceToken,'PUT');
  await poll(()=>evaluate("document.querySelector('#shared-group-text').value"),value=>value==='另一设备正文');
  assert.equal(await evaluate("document.querySelector('[data-shared-action=undo]').disabled"),false);
  await evaluate("document.querySelector('#shared-group-text').focus()");
  await key('z','KeyZ',2);
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'共同编辑 ABC');
  await poll(()=>evaluate("!window.__client.shared.dirty && !window.__client.shared.saving"),Boolean);
  assert.equal((await call('/group/shared-text',undefined,peer.deviceToken)).text,'共同编辑 ABC');
  await key('z','KeyZ',2);
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'');
  await poll(()=>evaluate("!window.__client.shared.dirty && !window.__client.shared.saving"),Boolean);
  await key('z','KeyZ',10);
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'共同编辑 ABC');
  await poll(()=>evaluate("!window.__client.shared.dirty && !window.__client.shared.saving"),Boolean);
  await key('z','KeyZ',10);
  assert.equal(await evaluate("document.querySelector('#shared-group-text').value"),'另一设备正文');
  await poll(()=>evaluate("!window.__client.shared.dirty && !window.__client.shared.saving"),Boolean);
  assert.equal((await call('/group/shared-text',undefined,peer.deviceToken)).text,'另一设备正文');
  checks.remoteAndEarlierLocalEditsRemainUndoableAndRedoableAcrossSavedACKs=true;
  }

  assert.equal(await evaluate('window.__client.mobileView'),'send');
  await evaluate("document.querySelector('#shared-group-text').blur();window.__client.stagedTexts=Array.from({length:8},(_,i)=>({id:'row-'+i,text:'待发送 '+(i+1)}));window.__client.render()");
  for(const mobile of [false,true]){
    await page('Emulation.setDeviceMetricsOverride',{width:mobile?390:950,height:mobile?844:619,deviceScaleFactor:1,mobile});
    const layout=await evaluate(`(()=>{const nodes=[...document.querySelectorAll('.staged-item')],a=nodes[0].getBoundingClientRect(),b=nodes[1].getBoundingClientRect(),q=document.querySelector('.staged-list'),send=document.querySelector('#mobile-send-tab'),receive=document.querySelector('#mobile-receive-tab');return{height:q.offsetHeight,square:Math.abs(a.width-a.height)<1,row:a.top===b.top,overflow:q.scrollWidth>q.clientWidth,left:!${mobile}||send.getBoundingClientRect().left<receive.getBoundingClientRect().left,label:receive.textContent,selected:send.getAttribute('aria-selected'),windowOverflow:document.documentElement.scrollWidth>innerWidth};})()`);
    assert.deepEqual(layout,{height:148,square:true,row:true,overflow:true,left:true,label:'接收',selected:'true',windowOverflow:false});
    const p=await evaluate("(()=>{const r=document.querySelector('.staged-list').getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()");
    await evaluate("document.querySelector('.staged-list').scrollLeft=0");
    await page('Input.dispatchMouseEvent',{type:'mouseWheel',...p,deltaX:0,deltaY:550});await delay(200);
    assert.ok(await evaluate("document.querySelector('.staged-list').scrollLeft>0"));
    const shot=await page('Page.captureScreenshot',{format:'jpeg',quality:78,captureBeyondViewport:false});
    await writeFile(join(shots,acceptVersion+'-queue-'+(mobile?'phone':'desktop')+'.raw.jpg'),Buffer.from(shot.data,'base64'));
    if(mobile){await click('#mobile-receive-tab');assert.equal(await evaluate('window.__client.mobileView'),'receive');await click('#mobile-send-tab');assert.equal(await evaluate('window.__client.stagedTexts.length'),8);}
  }
  checks.sendLeftReceiveRightDefaultSendAndOneRowQueue=true;
  await page('Emulation.setDeviceMetricsOverride',{width:950,height:619,deviceScaleFactor:1,mobile:false});

  await evaluate(`(()=>{
    const c=window.__client;window.__actualPeer=window.RTCPeerConnection;
    window.RTCPeerConnection=class {
      createDataChannel(){} async createOffer(){return {type:'offer',sdp:''};}
      async setLocalDescription(){for(const candidate of window.__menuCandidates)this.onicecandidate({candidate:{candidate}});this.onicecandidate({candidate:null});}close(){}
    };
    window.__menuCandidates=['candidate:1 1 udp 1 10.2.0.3 1234 typ host','candidate:2 1 udp 1 1.2.3.4 1234 typ srflx','candidate:3 1 udp 1 fd00::3 1234 typ host','candidate:4 1 udp 1 2001:db8::3 1234 typ host','candidate:5 1 udp 1 hidden.local 1234 typ host','candidate:6 1 udp 1 127.0.0.1 1234 typ host','candidate:7 1 udp 1 ::1 1234 typ host','candidate:8 1 udp 1 ::ffff:127.0.0.2 1234 typ host'];
    c.devices=[{...c.session.device,peer:{candidates:['https://10.2.0.3:8787']}},{deviceId:'different-device',name:'其它设备',platform:'android',online:true,peer:{candidates:['https://10.99.99.99:8787']}}];
    c.stagedTexts=[{id:'kept-draft',text:'保留的待发'}];c.text='未确认草稿';c.render();
  })()`);
  await click('[data-action=ip-addresses]');
  await poll(()=>evaluate('window.__client.ipLoading'),value=>!value);
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('.ip-address-source>h3'),node=>node.textContent)"),['浏览器本机','公网映射','已发布地址']);
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('.ip-address-group h4'),node=>node.textContent)"),['IPv4 内网','IPv6 内网','IPv6 公网','IPv4 公网','IPv4 内网']);
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('[data-stage-ip]'),node=>node.dataset.stageIp)"),['10.2.0.3','fd00::3','2001:db8::3','1.2.3.4','10.2.0.3']);
  const ipShot=await page('Page.captureScreenshot',{format:'jpeg',quality:82,captureBeyondViewport:false});
  await writeFile(join(shots,acceptVersion+'-ip-menu-desktop.raw.jpg'),Buffer.from(ipShot.data,'base64'));
  await click('[data-stage-ip="2001:db8::3"]');
  assert.deepEqual(await evaluate('window.__client.stagedTexts.map(item=>item.text)'),['保留的待发','2001:db8::3']);
  assert.equal(await evaluate('window.__client.text'),'未确认草稿');assert.equal(await evaluate('window.__client.modal'),null);
  await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  await click('[data-action=ip-addresses]');await poll(()=>evaluate('window.__client.ipLoading'),value=>!value);
  assert.equal(await evaluate('document.documentElement.scrollWidth>innerWidth'),false);
  const ipMobile=await page('Page.captureScreenshot',{format:'jpeg',quality:82,captureBeyondViewport:false});
  await writeFile(join(shots,acceptVersion+'-ip-menu-phone.raw.jpg'),Buffer.from(ipMobile.data,'base64'));
  await key('Escape','Escape');assert.equal(await evaluate('window.__client.modal'),null);
  assert.equal(await evaluate("document.activeElement.matches('[data-action=ip-addresses]')"),true);
  await evaluate("window.__menuCandidates=[];window.__client.devices=[{...window.__client.session.device,peer:null}]");
  await click('[data-action=ip-addresses]');await poll(()=>evaluate('window.__client.ipLoading'),value=>!value);
  assert.equal(await evaluate('document.querySelectorAll("[data-stage-ip]").length'),0);
  assert.match(await evaluate("document.querySelector('.ip-address-list').textContent"),/浏览器未提供可用 IP 地址/);
  await page('Input.dispatchMouseEvent',{type:'mousePressed',x:4,y:4,button:'left',buttons:1,clickCount:1});
  await page('Input.dispatchMouseEvent',{type:'mouseReleased',x:4,y:4,button:'left',buttons:0,clickCount:1});
  assert.equal(await evaluate('window.__client.modal'),null);
  await evaluate('window.RTCPeerConnection=window.__actualPeer');
  await click('[data-action=ip-addresses]');await poll(()=>evaluate('window.__client.ipLoading'),value=>!value);
  const actualHostGroups=await evaluate('window.__client.ipSources');
  assert.equal(await evaluate("Array.from(document.querySelectorAll('[data-stage-ip]'),node=>node.dataset.stageIp).some(value=>/\\.local$/i.test(value))"),false);
  await key('Escape','Escape');
  await page('Emulation.setDeviceMetricsOverride',{width:950,height:619,deviceScaleFactor:1,mobile:false});
  checks.realTitleIpMenuGroupsOwnAddressesAndStagesSelectedText=true;
  checks.mobileIpMenuFitsAndEmptyStateEscAndBackdropClose=true;
  checks.standardBrowserHostGatheringCompletesWithoutAddressFabrication=true;

  if(!ipOnly){
  await evaluate("(()=>{document.querySelector('#shared-group-text').blur();const c=window.__client,me=c.session.device.deviceId,now=new Date().toISOString(),expiresAt=new Date(Date.now()+86400000).toISOString();c.events=[['sent-a',me,'other','发出 A'],['sent-b',me,'other','发出 B'],['incoming','other',me,'保留收到的内容']].map(([eventId,sourceDeviceId,targetDeviceId,text],i)=>({eventId,type:'text.created',cursor:i+1,sourceDeviceId,targetDeviceId,createdAt:now,expiresAt,payload:{text}}));c.contentView='sent';c.shared.dirty=false;c.render();})()");
  await click('[data-action=sent-multi-select]');
  await click('[data-action=sent-select-all]');
  assert.equal(await evaluate('window.__client.sentSelected.size'),2);
  await click('[data-sent-key=sent-b] .card-text-lines');
  assert.equal(await evaluate('window.__client.sentSelected.size'),1);
  assert.equal(await evaluate('window.__client.modal'),null);
  const shot=await page('Page.captureScreenshot',{format:'jpeg',quality:82,captureBeyondViewport:false});
  await writeFile(join(shots,'ip-undo-sent-desktop.raw.jpg'),Buffer.from(shot.data,'base64'));
  await click('[data-action=sent-delete-selected]');
  assert.deepEqual(await evaluate("window.__client.displayTexts(true).map(x=>x.eventId)"),['sent-b']);
  assert.deepEqual(await evaluate("window.__client.receivedTexts().map(x=>x.eventId)"),['incoming']);
  checks.realWholeCardSentSelectAllAndDelete=true;
  await click('[data-content-view=receive]');
  assert.equal(await evaluate('window.__client.selected.size'),0);
  await evaluate("document.querySelector('#shared-group-text').blur()");
  const before=await evaluate("({queue:window.__client.stagedTexts.length,view:window.__client.contentView,toasts:document.querySelector('#toasts').textContent})");
  await click('[data-action=clipboard]');
  assert.deepEqual(await evaluate("({queue:window.__client.stagedTexts.length,view:window.__client.contentView,toasts:document.querySelector('#toasts').textContent})"),before);
  checks.emptyClipboardNoErrorOrNavigation=true;
  await page('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  await evaluate("window.__client.setMobileView('receive');window.__client.contentView='sent';window.__client.render()");
  await click('[data-action=sent-multi-select]');
  assert.equal(await evaluate("document.documentElement.scrollWidth>innerWidth"),false);
  const mobile=await page('Page.captureScreenshot',{format:'jpeg',quality:82,captureBeyondViewport:false});
  await writeFile(join(shots,'ip-undo-sent-phone.raw.jpg'),Buffer.from(mobile.data,'base64'));
  }
  await writeFile(join(run,'result.json'),JSON.stringify({checks,actualHostGroups,profile,run},null,2));
  console.log(JSON.stringify({checks,actualHostGroups,profile,run}));
}finally{await closeTestPage?.().catch(()=>{});for(const peer of peerSockets)peer.close();socket?.close();await closeSharedBrowser(browser);await center.close();}

