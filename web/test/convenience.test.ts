import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import { webcrypto } from 'node:crypto';
import { parseHTML } from 'linkedom';
import type { Transfer } from '../src/model.ts';

// Vite already supplies esbuild. Exercise the actual controller in memory,
// without starting the hosted page, changing an IAB tab, or writing a bundle.
const require = createRequire(import.meta.url);
const { build } = require('esbuild');
const source = await readFile(new URL('../src/main.ts',import.meta.url),'utf8');
const bootstrap = 'void new GlobalSend().start();';
const pageTemplate = await readFile(new URL('../index.html',import.meta.url),'utf8');
assert.equal(source.split(bootstrap).length,2,'one browser bootstrap must remain identifiable');
const result = await build({
  stdin:{contents:source.replace(bootstrap,'export { GlobalSend, ApiError };'),resolveDir:fileURLToPath(new URL('../src/',import.meta.url)),sourcefile:'main.ts',loader:'ts'},
  bundle:true,platform:'browser',format:'cjs',write:false,loader:{'.css':'empty'},logLevel:'silent',
});

function deferred<T>(){let resolve!:(value:T)=>void;const promise=new Promise<T>(done=>resolve=done);return {promise,resolve};}

test('incoming receipt keeps its window and file card through connecting, progress, ready and received',()=>{
  const {c,document,render}=fixture();c.render=render;const t=transfer('live-receipt','offered');t.files[0].name='photo.png';t.files[0].mimeType='image/png';c.transfers=[t];
  c.noticeFile(t,t.files[0]);const modal=document.querySelector('.receipt-modal'),card=document.querySelector('[data-receipt-id="live-receipt:file-live-receipt"]');
  assert.match(card!.textContent!,/等待接收/);assert.ok(card!.querySelector('[data-accept]'));
  c.setFile(t.transferId,{...t.files[0],status:'accepted'});assert.equal(document.querySelector('.receipt-modal'),modal);assert.equal(document.querySelector('[data-receipt-id="live-receipt:file-live-receipt"]'),card);
  assert.ok(card!.querySelector('[data-pause]'));c.paintProgress('live-receipt:file-live-receipt',2,4);
  assert.equal(card!.querySelector<HTMLElement>('[data-transfer-progress]')!.style.width,'50%');assert.match(card!.querySelector('[data-transfer-bytes]')!.textContent!,/2 B \/ 4 B/);
  c.previews.set('live-receipt:file-live-receipt',{kind:'image',url:'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=='});
  c.rtcLocalFiles.set('live-receipt:file-live-receipt',new File(['img'],'photo.png',{type:'image/png'}));
  c.setFile(t.transferId,{...t.files[0],status:'received',offset:4});assert.equal(document.querySelector('.receipt-modal'),modal);assert.equal(document.querySelector('[data-receipt-id="live-receipt:file-live-receipt"]'),card);
  assert.ok(card!.querySelector('img'));assert.equal(card!.querySelector('.card-meta,.card-source,.card-name,.image-card-footer'),null);assert.equal((modal as HTMLElement).style.animation,'none');
  c.closeModal();c.noticeFile(t,{...t.files[0],status:'received'});assert.equal(c.modal,null);
});

test('preview-first text and image cards remove metadata but keep copy and menus, other files keep their name',()=>{
  const {c,document}=fixture();const text=textEvent('clean-text',false,'只保留内容');c.events=[text];
  document.querySelector('#app')!.innerHTML=c.dockHtml();const card=document.querySelector('.text-card')!;
  assert.equal(card.querySelector('.card-footer,.card-meta,.card-source,time'),null);assert.ok(card.querySelector('[data-copy]'));assert.ok(card.querySelector('[data-card-menu]'));
  const t=transfer('plain-file','received');t.files[0].name='archive.unknown';c.transfers=[t];document.querySelector('#app')!.innerHTML=c.fileHtml(t,t.files[0],false);
  assert.equal(document.querySelector('.card-name')!.textContent,'archive.unknown');assert.ok(document.querySelector('.content-preview svg'));assert.equal(document.querySelector('.card-meta,.card-source,time'),null);
});

test('backdrop clicks close settings and connection but clicks inside content do not',()=>{
  const {c,document,render,context,Event}=fixture();c.render=render;(context as any).window.setTimeout=(finish:()=>void)=>{finish();return 1;};
  for(const action of ['settings','connection']){
    render();document.querySelector<HTMLElement>('[data-action="'+action+'"]')!.click();assert.equal(c.modal,'settings');
    document.querySelector('.settings-modal')!.dispatchEvent(new Event('click',{bubbles:true}));assert.equal(c.modal,'settings');
    document.querySelector('.modal-backdrop')!.dispatchEvent(new Event('click',{bubbles:true}));assert.equal(c.modal,null);
  }
});

test('failed send tools affect only actual failures and retry the same file offers with their existing prefix',async()=>{
  const {c,document,render}=fixture();c.render=render;c.session.device.deviceId='sender';c.devices.push({deviceId:'target',name:'Target',platform:'windows',online:true});
  const failed=transfer('bad','failed','auto','relay'),directory=transfer('dir-bad','failed','auto','relay'),normal=transfer('good','accepted','auto','relay'),running=transfer('busy','uploading','auto','relay'),waiting=transfer('waiting','accepted','auto','relay');
  for(const t of [failed,directory,normal,running,waiting]){t.targetDeviceId='target';t.files[0].offset=2;t.files[0].attemptId='same-attempt';c.fileSources.set(t.transferId+':'+t.files[0].fileId,new File(['data'],t.files[0].name));}
  directory.files[0].receiveFailure=true;c.transfers=[failed,directory,normal,running,waiting];c.uploads.set('busy:file-busy',new AbortController());c.uploadErrors.set('waiting:file-waiting','等待设备上线');
  c.render();assert.equal(document.querySelectorAll('.failed-send-item').length,2);assert.equal(document.querySelectorAll('.failed-send-item .failed-card-retry').length,2);
  assert.ok(document.querySelector('[data-action="clear-failed-sends"]'));assert.ok(document.querySelector('[data-action="retry-failed-sends"]'));
  c.startReadyUploads=()=>{};c.selectIncomingRelays=async()=>{};const calls:any[]=[];c.api.request=async(path:string,body:any)=>{calls.push({path,body});const t=path.includes('/dir-bad/')?directory:failed;return {file:{...t.files[0],status:'uploading',receiveFailure:false}};};
  await c.retryFailedSends();assert.equal(calls.length,2);assert.ok(calls.some(item=>item.path.endsWith('/receive-retry')));assert.ok(calls.some(item=>item.path.endsWith('/retry')));assert.ok(calls.every(item=>!item.path.endsWith('/transfers')));
  assert.equal(c.transfers[0].files[0].offset,2);assert.equal(c.transfers[1].files[0].attemptId,'same-attempt');assert.equal(c.fileSources.has('good:file-good'),true);assert.equal(c.uploads.get('busy:file-busy').signal.aborted,false);
  failed.files[0].status='failed';directory.files[0].status='failed';const original=c.fileSources.get('bad:file-bad');c.clearFailedSends();assert.equal(await original.text(),'data');assert.equal(c.fileSources.has('bad:file-bad'),false);assert.equal(c.fileSources.has('good:file-good'),true);assert.equal(c.fileSources.has('busy:file-busy'),true);assert.equal(document.querySelector('[data-action="clear-failed-sends"]'),null);
});

test('receipt error uses an upper close icon and separate primary retry with secondary cancel',()=>{
  const {c,document,render}=fixture();c.render=render;const t=transfer('receipt-failed','offered');c.transfers=[t];c.noticeFile(t,t.files[0]);
  c.setFile(t.transferId,{...t.files[0],status:'failed',receiveFailure:true,errorCode:'目录不可写'});const modal=document.querySelector('.receipt-modal')!;
  assert.ok(modal.querySelector('.modal-header [data-action="close-modal"]'));assert.equal(modal.querySelector('.receipt-actions [data-action="close-modal"]'),null);
  assert.ok(modal.querySelector('.transfer-retry.primary'));assert.equal(modal.querySelector('.transfer-cancel')!.textContent,'取消传输');assert.match(modal.querySelector('.receipt-error-detail')!.textContent!,/目录不可写/);
});

test('notifications bridge uses file arrival identity, ready says downloadable, shared edits remain quiet',()=>{
  const {c}=fixture(),notices:any[]=[];c.notifications.notify=async(value:any)=>{notices.push(value);return true;};const t=transfer('notify','offered');c.transfers=[t];
  c.noticeFile(t,t.files[0]);c.setFile(t.transferId,{...t.files[0],status:'uploading'});c.setFile(t.transferId,{...t.files[0],status:'ready'});
  assert.ok(notices.every(value=>value.id==='notify:file-notify'&&value.revision==='file'));assert.equal(notices[0].phase,'incoming');assert.match(notices.at(-1).body,/文件可下载$/);assert.equal(notices.at(-1).phase,'ready');
  const count=notices.length;c.noticeEvents([{...textEvent('quiet',false,'shared'),type:'group.shared.updated'}]);assert.equal(notices.length,count);
});

test('Escape first exits selection on receive, history, files and devices without leaving the current page',()=>{
  for(const mode of ['receive','sent','library','devices']){
    const {c,document,render,Event}=fixture();c.render=render;c.installWindowDrop();c.contentView=mode==='devices'?'receive':mode;c.mobileView=mode==='devices'?'send':'receive';
    if(mode==='receive'){c.receiveSelecting=true;c.selected.add('one');}if(mode==='sent'){c.sentSelecting=true;c.sentSelected.add('one');}if(mode==='library'){c.fileLibrary.opened=true;c.fileLibrary.editing=true;c.fileLibrary.selected.add('one');}if(mode==='devices'){c.multiSend=true;c.selectedTargets.add('sender');}
    render();const beforeView=c.contentView,beforeMobile=c.mobileView,event=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(event,{key:'Escape',isComposing:false});document.dispatchEvent(event);
    assert.equal(event.defaultPrevented,true);assert.equal(c.contentView,beforeView);assert.equal(c.mobileView,beforeMobile);assert.equal(c.receiveSelecting || c.sentSelecting || c.fileLibrary.editing || c.multiSend,false);
  }
});

test('Escape closes a top modal before touching the underlying selection',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.installWindowDrop();c.events=[textEvent('one',false,'保留的选择')];c.receiveSelecting=true;c.selected.add('one');
  c.showReceipt({id:'topmost',version:'1',source:'sender',title:'文本',text:'正文'});const event=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(event,{key:'Escape',isComposing:false});document.dispatchEvent(event);
  assert.equal(c.modal,null);assert.equal(c.receiveSelecting,true);assert.equal(c.selected.size,1);
});

function fixture() {
  class Socket {
    static CONNECTING=0;
    static OPEN=1;
    readyState=0;
    onopen?: ()=>void;
    onmessage?: (message:{data:string})=>void;
    onclose?: ()=>void;
    close() { this.readyState=3;this.onclose?.(); }
    send() {}
  }
  const {document,Event,HTMLTextAreaElement}=parseHTML(pageTemplate).window;
  // linkedom supplies the real node/event lifecycle but no visual selection
  // engine. Model the standard textarea selection API for cursor assertions.
  HTMLTextAreaElement.prototype.setSelectionRange=function(start:number,end:number,direction='none'){
    this.selectionStart=start;this.selectionEnd=end;this.selectionDirection=direction;
  };
  HTMLTextAreaElement.prototype.select=function(){this.setSelectionRange(0,this.value.length);};
  const persistent = new Map<string,string>(), session = new Map<string,string>();
  const store = (data: Map<string,string>) => ({getItem:(key: string)=>data.get(key) ?? null,setItem:(key: string,value: string)=>data.set(key,value)});
  const exports: Record<string,any> = {};
  const context = {
    module:{exports},exports,crypto:webcrypto,Intl,URL,Error,DOMException,AbortController,WebSocket:Socket,TextDecoder,TextEncoder,File,Blob,
    setTimeout:()=>1,clearTimeout:()=>{},
    location:{origin:'https://send.example',pathname:'/team/app/',protocol:'https:'},
    navigator:{userAgent:'Browser',maxTouchPoints:0},
    document,
    window:{setInterval:()=>1,setTimeout:()=>1,addEventListener:()=>{}},
    sessionStorage:store(session),localStorage:store(persistent),
  };
  runInNewContext(result.outputFiles[0].text,context);
  const c = new context.module.exports.GlobalSend();
  const render=c.render.bind(c);
  const refresh=c.refresh.bind(c),connect=c.connect.bind(c);
  c.render=()=>{};c.toast=()=>{};c.refresh=async()=>{};c.connect=()=>{};
  c.info={protocolVersion:1,instanceId:'instance',limits:{maxFileSize:100000,ttlSeconds:86400}};
  c.loading=false;c.connected=true;c.helloReceived=true;
  c.devices=[{deviceId:'sender',name:'发送设备',platform:'android',online:true}];
  c.session={deviceToken:'token',device:{deviceId:'receiver',name:'Browser',platform:'web'},groupId:'group-one'};
  c.api.session=c.session;
  return {c,persistent,session,document:context.document,render,refresh,connect,Event,ApiError:context.module.exports.ApiError,context};
}

function transfer(id: string,status='offered',routePreference: Transfer['routePreference']='auto',transport: string|null=null): any {
  return {transferId:id,sourceDeviceId:'sender',targetDeviceId:'receiver',routePreference,
    createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),
    files:[{fileId:`file-${id}`,name:'sample.txt',size:4,sha256:'a'.repeat(64),offset:0,status,transport}]};
}
test('hosted Web opens its own center automatically and enrolls with a device name without either form field',async()=>{
  const {context,document}=fixture();
  (context as any).location={origin:'https://123.207.180.163',pathname:'/globalsend/app/',protocol:'https:'};
  (context as any).navigator={userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',maxTouchPoints:0};
  const c=new context.module.exports.GlobalSend();c.render=()=>{};c.toast=()=>{};c.refresh=async()=>{};c.connect=()=>{};
  const calls:any[]=[];
  c.api.request=async(path:string,body:any)=>{calls.push({base:c.api.baseUrl,path,body});if(path==='/info')return {protocolVersion:1,instanceId:'public',limits:{maxTextLength:100000},features:{}};return {deviceToken:'new-token',device:{deviceId:'new-device',name:body.name,platform:'web'},groupId:'new-group'};};
  await c.start();assert.equal(calls[0].base,'https://123.207.180.163/globalsend');assert.equal(calls[0].path,'/info');assert.equal(c.deviceName,'Windows 电脑');
  document.querySelector('#app')!.innerHTML=c.onboarding();
  assert.equal(document.querySelector('.center-address'),null);assert.equal(document.querySelector('#server-url'),null);
  const name=document.querySelector('#device-name')!;assert.equal(name.hasAttribute('required'),false);assert.equal(name.closest('details'),null);
  assert.equal(document.querySelectorAll('[data-action="show-group-key"]').length,1);assert.doesNotMatch(c.onboarding(),/相同密码的设备自动分为一组|<summary>高级/);
  assert.equal(document.querySelector('#enroll-form')!.querySelectorAll('[required]').length,1);
  c.deviceName='';c.groupKey='shared-group-key-for-test';await c.enroll();
  assert.equal(calls[1].path,'/devices/enroll');assert.equal(calls[1].body.name,'Windows 电脑');assert.equal(calls[1].body.groupKey,'shared-group-key-for-test');
});
test('automatic naming never overwrites a manual enrollment draft or an existing registered device name',async()=>{
  const {c,render,context}=fixture();c.session=null;c.api.session=null;c.deviceName='我手动写的名称';c.groupKey='shared-group-key-for-test';
  (context as any).navigator={userAgent:'Mozilla/5.0 (Linux; Android 15)',maxTouchPoints:5};
  render();render();assert.equal(c.deviceName,'我手动写的名称');
  let body:any;c.api.request=async(_path:string,value:any)=>{body=value;return {deviceToken:'token',device:{deviceId:'device',name:value.name,platform:'web'},groupId:'group'};};
  await c.enroll();assert.equal(body.name,'我手动写的名称');assert.equal(c.session.device.name,'我手动写的名称');
  c.deviceName='自动建议不应用';c.session.device.name='已登记的自定义名称';c.saveSession();render();
  assert.equal(c.session.device.name,'已登记的自定义名称');assert.match(c.workspace(),/已登记的自定义名称/);
});
test('an existing device can explicitly apply its automatic name without changing identity',async()=>{
  const {c,context,render,document,Event}=fixture();
  (context as any).navigator={userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',maxTouchPoints:0};
  c.session.device.name='Web 实机验收';const identity=c.session.device.deviceId;let request:any;
  c.api.request=async(path:string,body:any,method:string)=>{request={path,body,method};return {device:{...c.session.device,name:body.name}};};
  c.openSettings();render();assert.equal(c.session.device.name,'Web 实机验收');
  document.querySelector('[data-action="auto-device-name"]')!.dispatchEvent(new Event('click'));
  for(let i=0;i<5;i++)await Promise.resolve();
  assert.equal(request.path,'/devices/me');assert.equal(request.method,'PATCH');assert.equal(request.body.name,'Windows 电脑');assert.equal(c.session.device.deviceId,identity);assert.equal(c.session.device.name,'Windows 电脑');
});
test('custom server navigation is directly available in settings and never forwards the current credential',()=>{
  const {c,render,document,context}=fixture();c.openSettings();render();
  const details=document.querySelector('[data-server-settings]')!;
  assert.equal(details.tagName,'SECTION');assert.equal(details.closest('details'),null);assert.equal(document.querySelector('#server-url')!.hasAttribute('required'),false);
  let destination='';(context as any).location.assign=(url:string)=>{destination=url;};
  c.serverDraft='https://another.example/team';c.changeServer();assert.equal(destination,'https://another.example/team/app/');
  assert.doesNotMatch(destination,/token|deviceToken|authorization/i);
});
test('ten-character group password enrolls directly with no generated password or new-group confirmation',async()=>{
  const {c,document}=fixture();c.session=null;c.api.session=null;c.info.enrollment={allowGroupCreation:false,minGroupKeyLength:10};
  document.querySelector('#app')!.innerHTML=c.onboarding();
  const password=document.querySelector<HTMLInputElement>('#group-key')!;
  assert.equal(password.getAttribute('minlength'),'10');assert.equal(password.getAttribute('type'),'password');
  assert.doesNotMatch(c.onboarding(),/组密钥|生成密钥|邀请码|配对|引导|pair-mode|pair-secret/);
  let calls=0,body:any;c.api.request=async(_path:string,value:any)=>{calls++;body=value;return {deviceToken:'saved-token',device:{deviceId:'same-device',name:value.name,platform:'web'},groupId:'same-group',createdGroup:true};};
  c.groupKey='123456789';await c.enroll();assert.equal(calls,0);assert.match(c.pairError,/10/);
  c.groupKey='1234567890';await c.enroll();assert.equal(calls,1);assert.equal(body.groupKey,'1234567890');
  assert.equal(Object.keys(body).sort().join(','),'groupKey,name,platform');assert.equal(c.session.groupId,'same-group');assert.equal(c.groupKey,'');
  assert.equal(c.groupNotice,undefined);assert.doesNotMatch(c.workspace(),/1234567890|保存密码|保存密钥|已创建新组/);
});
test('RTC publication starts only after hello and reconnect immediately republishes without re-enrollment',async()=>{
  const {c,context,connect}=fixture();Object.defineProperty(c,'rtcEnabled',{value:true});
  c.connected=false;c.helloReceived=false;c.rtcStore={ready:Promise.resolve(),cleanup:async()=>{}};
  const requests:string[]=[];(context as any).fetch=async(url:string)=>{requests.push(url);return {ok:true,json:async()=>({})};};
  c.api.request=async()=>({ticket:'ticket'});await c.ensureRtc();assert.equal(requests.length,0);
  connect();await new Promise(resolve=>setImmediate(resolve));const socket=c.ws;socket.onopen();
  await c.ensureRtc();assert.equal(requests.length,0);
  socket.onmessage({data:JSON.stringify({type:'hello',deviceId:'receiver',protocolVersion:1})});await new Promise(resolve=>setImmediate(resolve));
  assert.equal(requests.filter(path=>path.endsWith('/devices/me/rtc')).length,1);
  c.scheduleReconnect=()=>{};socket.onclose();assert.equal(c.rtcRegisteredAt,0);
  connect();await new Promise(resolve=>setImmediate(resolve));c.ws.onmessage({data:JSON.stringify({type:'hello',deviceId:'receiver',protocolVersion:1})});await new Promise(resolve=>setImmediate(resolve));
  assert.equal(requests.filter(path=>path.endsWith('/devices/me/rtc')).length,2);
  assert.equal(c.session.deviceToken,'token');assert.equal(requests.some(path=>path.includes('/enroll')),false);
});
test('offline presence retains last addresses for grace, stops live RTC, and rejects an older HTTP snapshot',async()=>{
  const {c,connect,refresh}=fixture(),t=transfer('active','accepted','auto','direct');c.transfers=[t];
  const peer={deviceId:'sender',name:'手机',platform:'android',online:true,peer:{candidates:['https://[2408::1]:8788'],expiresAt:new Date(Date.now()+1800000).toISOString()},rtc:{scopes:['lan','public'],expiresAt:new Date(Date.now()+1800000).toISOString()}};
  c.devices=[peer];c.deviceNames.set('sender','手机');c.target='sender';
  const receive=new AbortController(),send=new AbortController(),key='active:file-active';let closed=0;
  c.rtcReceives.set(key,receive);c.uploads.set(key,send);c.rtcAttempts.set(key,'rtc-old');c.rtcChannels.set(key,{view:{sourceDeviceId:'sender',targetDeviceId:'receiver'},close:async()=>{closed++;}});
  c.rtcLocalFiles.set('retained',new File(['saved'],'保留文件.txt'));c.events=[{eventId:'kept-history',type:'text.created',cursor:1,sourceDeviceId:'sender',targetDeviceId:'receiver',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),payload:{text:'保留历史'}}];
  c.api.request=async()=>({ticket:'ticket'});connect();await new Promise(resolve=>setImmediate(resolve));
  let finish:((value:unknown)=>void)|undefined;
  c.api.request=async(path:string)=>path==='/devices'?new Promise(resolve=>{finish=resolve;}):path==='/transfers'?{transfers:[t]}:{events:[],cursor:0,hasMore:false};
  const pending=refresh();await Promise.resolve();c.ws.onmessage({data:JSON.stringify({type:'presence',deviceId:'sender',online:false})});
  assert.deepEqual(c.device('sender').peer,peer.peer);assert.deepEqual(c.device('sender').rtc,peer.rtc);assert.equal(c.devices.length,1);assert.equal(c.device('sender').online,false);assert.equal(c.isOnlinePeer('sender'),false);assert.equal(c.target,'sender');assert.equal(receive.signal.aborted,true);assert.equal(send.signal.aborted,true);assert.equal(closed,1);
  finish!({devices:[{deviceId:'sender',name:'stale snapshot',online:true,peer:{candidates:['https://old-ip'],expiresAt:new Date(Date.now()+1800000).toISOString()}}]});await pending;
  assert.equal(c.devices.length,1);assert.equal(c.device('sender').online,false);assert.equal(c.rtcLocalFiles.has('retained'),true);assert.equal(c.events[0].eventId,'kept-history');assert.equal(c.deviceLabel('sender'),'手机');
});
test('probe status is informational and foreground visibility gates it without changing manual file routing',()=>{
  const {c,document}=fixture();c.info.features={rtcProbes:true};Object.defineProperty(c,'rtcEnabled',{value:true});c.rtcRegisteredAt=Date.now();
  const active:boolean[]=[];c.rtcProbes={setOnlinePeers:()=>{},setForeground:(value:boolean)=>{active.push(value);return Promise.resolve();},status:()=> 'RTC 局域网 · 3 ms'};c.rtcProbeScope=c.dockKey;
  Object.defineProperty(document,'visibilityState',{value:'visible',configurable:true});c.routePreference='public';c.target='sender';c.text='保留草稿';
  c.syncProbeMonitor();assert.equal(active.at(-1),true);assert.match(c.deviceInner(c.devices[0]),/RTC 局域网 · 3 ms/);assert.equal(c.targetExplanation(),'RTC 局域网 · 3 ms');
  Object.defineProperty(document,'visibilityState',{value:'hidden',configurable:true});c.syncProbeMonitor();assert.equal(active.at(-1),false);
  assert.equal(c.routePreference,'public');assert.equal(c.text,'保留草稿');
});
test('probe caller cancellation aborts the actual HTTP request without turning it into a connection warning',async()=>{
  const {c,context}=fixture(),abort=new AbortController();let cancelled=false;
  (context as any).fetch=async(_url:string,options:any)=>new Promise((_resolve,reject)=>options.signal.addEventListener('abort',()=>{cancelled=true;reject(new DOMException('Stopped','AbortError'));},{once:true}));
  const request=c.api.request('/rtc-probes/probe',undefined,'GET',abort.signal);abort.abort();
  await assert.rejects(request,(error:any)=>error.name==='AbortError');assert.equal(cancelled,true);
});

test('remember device restores token on a new page; disabling remember clears the persistent token',async()=>{
  const {c,persistent,session}=fixture();
  c.saveSession();
  const key=c.key+':session';
  assert.equal(JSON.parse(persistent.get(key)!).deviceToken,'token');
  c.session=null;c.api.session=null;
  c.api.request=async()=>c.info;
  await c.start();
  assert.equal(c.session.deviceToken,'token');
  c.rememberDevice=false;c.saveSession();
  assert.equal(persistent.get(key),'');
  assert.equal(JSON.parse(session.get(key)!).deviceToken,'token');
  c.signOut();
  assert.equal(session.get(key),'');assert.equal(persistent.get(key),'');
});

test('auto receive preferences are isolated by center instance, device and group',()=>{
  const {c}=fixture();
  c.setAutoAccept(false);
  const original=c.session;
  for(const change of [
    ()=>{c.session={...original,groupId:'other'};},
    ()=>{c.session={...original,device:{...original.device,deviceId:'other'}};},
    ()=>{c.session=original;c.info={...c.info,instanceId:'other'};},
    ()=>{c.info={...c.info,instanceId:'instance'};c.baseUrl='https://other.example';},
  ]){change();c.loadPreferences();assert.equal(c.autoAccept,true);}
  c.baseUrl='https://send.example/team';c.session=original;c.loadPreferences();
  assert.equal(c.autoAccept,false);
});

test('auto receive accepts only current active group offers, not native-only or terminal items',async()=>{
  const {c}=fixture();
  c.transfers=[transfer('auto'),transfer('relay','offered','relay'),transfer('lan','offered','lan'),transfer('public','offered','public'),transfer('canceled','canceled'),transfer('rejected','rejected'),{...transfer('expired'),expiresAt:new Date(0).toISOString()},{...transfer('other'),targetDeviceId:'another-device'}];
  const requests: string[]=[];
  c.api.request=async(path: string)=>{
    requests.push(path);const t=c.transfers.find((item:any)=>path.includes(item.transferId+'/accept'));
    return {transfer:{...t,files:t.files.map((file:any)=>({...file,status:'accepted'}))}};
  };
  await c.acceptIncoming();await c.acceptIncoming();
  assert.deepEqual(requests,['/transfers/auto/accept','/transfers/relay/accept']);
  c.autoAccept=false;c.transfers=[transfer('manual')];await c.acceptIncoming();
  assert.equal(requests.length,2);
});

test('concurrent refresh notifications cannot accept the same offer twice',async()=>{
  const {c}=fixture();c.transfers=[transfer('one')];
  let finish: ((value:unknown)=>void)|undefined,calls=0;
  c.api.request=()=>{calls++;return new Promise(resolve=>{finish=resolve;});};
  const first=c.acceptIncoming();await c.acceptIncoming();
  assert.equal(calls,1);
  finish!({transfer:transfer('one','accepted')});await first;
  assert.equal(c.accepting.size,0);
});

test('accepted files restore relay selection; native routes and canceled files never request relay',async()=>{
  const {c}=fixture();
  c.transfers=[transfer('restore','accepted'),transfer('relay','accepted','relay','relay'),transfer('lan','accepted','lan'),transfer('public','accepted','public'),transfer('canceled','canceled')];
  const calls:string[]=[];
  c.api.request=async(path:string)=>{calls.push(path);return {file:{...c.transfers[0].files[0],transport:'relay'}};};
  await c.selectIncomingRelays();await c.selectIncomingRelays();
  assert.deepEqual(calls,['/transfers/restore/files/file-restore/relay']);
});

test('RTC offers select direct negotiation before relay and manual route constraints remain intact',async()=>{
  const {c}=fixture();
  c.transfers=[transfer('auto-rtc','accepted'),transfer('lan-rtc','accepted','lan'),transfer('public-rtc','accepted','public'),transfer('explicit-relay','accepted','relay')];
  c.rtcPeer=(t:any)=>t.routePreference!=='relay';
  const direct:string[]=[],relay:string[]=[];
  c.receiveRtc=async(t:any)=>{direct.push(t.transferId);};
  c.api.request=async(path:string)=>{relay.push(path);return {file:{...c.transfers[3].files[0],transport:'relay'}};};
  await c.selectIncomingRelays();
  assert.deepEqual(direct,['auto-rtc','lan-rtc','public-rtc']);
  assert.deepEqual(relay,['/transfers/explicit-relay/files/file-explicit-relay/relay']);
  assert.equal(c.requiresNative(c.transfers[1]),false);
});

test('an already accepted large file cannot silently fall back to relay after capabilities disappear',async()=>{
  const {c}=fixture();const t=transfer('large','accepted');t.files[0].size=c.autoAcceptMaxBytes+1;c.transfers=[t];
  const calls:string[]=[];
  c.api.request=async(path:string)=>{calls.push(path);return {file:{...t.files[0],transport:'relay'}};};
  await c.selectIncomingRelays();
  assert.equal(calls.length,0);assert.equal(c.uploadErrors.get('large:file-large'),'使用中继需确认');
  c.rtcStore={remove:async()=>{}};
  await c.allowRelay('large','file-large');
  assert.deepEqual(calls,['/transfers/large/files/file-large/relay']);
  assert.equal(c.relayConfirmed.has('large:file-large'),true);
});

test('RTC source waits for receiver attempt and never starts a competing relay upload',()=>{
  const {c}=fixture();Object.defineProperty(c,'rtcEnabled',{value:true});
  const t=transfer('direct-source','accepted');t.sourceDeviceId='receiver';t.targetDeviceId='target';
  t.files[0].transport='direct';t.files[0].rtc={attemptId:'rtc-one',state:'negotiating'};
  c.transfers=[t];c.fileSources.set('direct-source:file-direct-source',{});
  const direct:string[]=[],relay:string[]=[];
  c.sendRtc=async(_t:any,_f:any,attempt:string)=>{direct.push(attempt);};
  c.uploadFile=async()=>{relay.push('upload');};
  c.startReadyUploads();
  assert.deepEqual(direct,['rtc-one']);assert.equal(relay.length,0);
  delete t.files[0].rtc;c.startReadyUploads();assert.equal(relay.length,0);
});

test('late OPFS restoration cannot bring a removed local file back into the cache',async()=>{
  const {c}=fixture(),t=transfer('restoring','received','auto','direct');c.transfers=[t];
  let finish:((value:unknown)=>void)|undefined;
  c.rtcStore={get:()=>new Promise(resolve=>{finish=resolve;}),expiry:()=>Date.now()+60000,remove:async()=>{}};
  c.reconcileRtc();c.hideFile('restoring','file-restoring');finish!({name:'restored-file'});
  await Promise.resolve();await Promise.resolve();
  assert.equal(c.rtcLocalFiles.size,0);
});

function savedEntry(id='one/file',name='收到的文件.txt',receivedAt=Date.now()) {
  return {id,scope:id.split('/')[0],key:id.split('/')[1],name,mimeType:'text/plain',size:9,sha256:'a'.repeat(64),receivedAt,expiresAt:receivedAt+86400000};
}
function savedLibrary(c:any,entries:any[]) {
  const rules={retentionHours:24,categories:['image','video','audio','text','archive','other'],sizeRule:'any',sizeMiB:0};
  c.fileLibrary.service={list:async()=>entries,cleanupPreferences:async()=>rules,get:async(id:string)=>new File(['文件内容\n可复制'],entries.find(entry=>entry.id===id)!.name,{type:'text/plain'}),rename:async(id:string,name:string)=>{const entry=entries.find(entry=>entry.id===id);entry.name=name;return {...entry};},remove:async(id:string)=>{entries.splice(entries.findIndex(entry=>entry.id===id),1);},setCleanupPreferences:async(value:any)=>{Object.assign(rules,value);return rules;}};
}
test('local library stays available without a session and keeps files from different groups after sign-out',async()=>{
  const {c}=fixture();savedLibrary(c,[savedEntry(),savedEntry('other/saved','另一个组.txt')]);
  await c.openLibrary();assert.equal(c.fileLibrary.entries.length,2);
  c.signOut();assert.equal(c.fileLibrary.entries.length,2);assert.match(c.onboarding(),/data-action="library"/);
  await c.openLibrary();const html=c.modalHtml();
  assert.equal(c.fileLibrary.entries.length,2);assert.match(html,/class="library-grid"/);
  c.fileLibrary.enterEdit('one/file');assert.doesNotMatch(c.modalHtml(),/data-library-target/);assert.doesNotMatch(c.modalHtml(),/data-library-action="forward"/);
});
test('local text opens read-only with copy-all and rename preserves file identity and receipt time',async()=>{
  const {c,render,document,Event}=fixture();const entry=savedEntry();savedLibrary(c,[entry]);await c.openLibrary();
  await c.fileLibrary.preview(entry.id);render();
  assert.equal(document.querySelector('#library-text')?.hasAttribute('readonly'),true);
  const copied:string[]=[];c.copy=(value:string)=>copied.push(value);
  document.querySelector('[data-library-action="copy"]')!.dispatchEvent(new Event('click',{bubbles:true}));assert.deepEqual(copied,['文件内容\n可复制']);
  c.fileLibrary.closePreview();c.fileLibrary.enterEdit(entry.id);c.fileLibrary.renameSelected();c.fileLibrary.renameName='新名字.txt';await c.fileLibrary.saveRename();
  assert.equal(c.fileLibrary.entries[0].name,'新名字.txt');assert.equal(c.fileLibrary.entries[0].id,entry.id);assert.equal(c.fileLibrary.entries[0].receivedAt,entry.receivedAt);
});
test('local image preview releases its object URL when leaving the preview or closing the library',async()=>{
  const {c,context}=fixture();const entry={...savedEntry('images/photo','photo.png'),mimeType:'image/png'};savedLibrary(c,[entry]);
  const created:string[]=[],revoked:string[]=[];
  (context as any).URL=class extends URL {static createObjectURL(){const url='blob:fixture-'+created.length;created.push(url);return url;}static revokeObjectURL(url:string){revoked.push(url);}};
  await c.openLibrary();await c.fileLibrary.preview(entry.id);assert.match(c.workspace(),/library-image-preview/);assert.equal(c.modal,null);assert.equal(c.contentView,'library');c.fileLibrary.closePreview();assert.deepEqual(revoked,[created[0]]);
  await c.fileLibrary.preview(entry.id);c.fileLibrary.close();assert.deepEqual(revoked,created);
});
test('local forwarding uses the chosen online device and disk File without changing the composer draft',async()=>{
  const {c,context}=fixture(),entry=savedEntry();savedLibrary(c,[entry]);
  c.devices=[{deviceId:'online',name:'手机',online:true},{deviceId:'offline',name:'离线设备',online:false}];
  const requests:any[]=[];(context as any).fetch=async(_url:string,options:any)=>{const body=JSON.parse(options.body);requests.push(body);return {ok:true,json:async()=>({transfer:{...body,sourceDeviceId:'receiver',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),files:body.files.map((file:any)=>({...file,status:'offered'}))}})};};
  c.text='不能发送的编辑草稿';c.target='another-draft-target';c.picked=[new File(['original'],'composer.txt')];
  await c.openLibrary();c.fileLibrary.enterEdit(entry.id);c.fileLibrary.target='online';await c.fileLibrary.forwardSelected();
  assert.equal(requests.length,1);assert.equal(requests[0].targetDeviceId,'online');assert.equal(requests[0].files[0].name,entry.name);assert.equal(requests[0].files[0].sha256,entry.sha256);
  assert.equal(c.text,'不能发送的编辑草稿');assert.equal(c.picked[0].name,'composer.txt');assert.equal(c.target,'another-draft-target');assert.equal(c.fileSources.size,1);
  c.fileLibrary.enterEdit(entry.id);c.fileLibrary.target='offline';await c.fileLibrary.forwardSelected();assert.equal(requests.length,1);assert.match(c.fileLibrary.error,/在线/);
});
test('an uncertain local forwarding response retains the same invitation through close and retry',async()=>{
  const {c,context}=fixture(),entry=savedEntry();savedLibrary(c,[entry]);c.devices=[{deviceId:'online',name:'手机',online:true}];
  const requests:any[]=[];let failure=true;(context as any).fetch=async(_url:string,options:any)=>{const body=JSON.parse(options.body);requests.push(body);if(failure)throw new Error('network lost');return {ok:true,json:async()=>({transfer:{...body,sourceDeviceId:'receiver',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),files:body.files.map((file:any)=>({...file,status:'offered'}))}})};};
  await c.openLibrary();c.fileLibrary.enterEdit(entry.id);c.fileLibrary.target='online';await c.fileLibrary.forwardSelected();
  assert.ok(c.libraryForward);c.fileLibrary.close();await c.openLibrary();assert.equal(c.fileLibrary.editing,true);assert.equal(c.fileLibrary.selected.has(entry.id),true);
  failure=false;await c.fileLibrary.forwardSelected();assert.equal(requests.length,2);assert.equal(requests[0].transferId,requests[1].transferId);assert.equal(requests[0].files[0].fileId,requests[1].files[0].fileId);assert.equal(c.libraryForward,null);
});
test('local cleanup controls save duration, categories and strict size without session credentials',async()=>{
  const {c}=fixture();savedLibrary(c,[savedEntry()]);c.signOut();await c.openLibrary();
  c.fileLibrary.retentionValue='6';c.fileLibrary.retentionUnit='hours';c.fileLibrary.cleanupDraft.categories=['image'];c.fileLibrary.cleanupDraft.sizeRule='greater';c.fileLibrary.cleanupDraft.sizeMiB=10;c.fileLibrary.cleanupDirty=true;
  await c.fileLibrary.saveCleanup();assert.equal(c.fileLibrary.cleanup.retentionHours,6);assert.equal(c.fileLibrary.cleanup.sizeRule,'greater');assert.equal(c.fileLibrary.cleanup.sizeMiB,10);assert.equal(c.fileLibrary.cleanup.categories.join(','),'image');
  assert.match(c.modalHtml(),/按规则清理/);assert.equal(c.fileLibrary.cleanupDirty,false);
});
test('library deletion invalidates the active dock cache and does not resurrect its removed record or import another scope',async()=>{
  const {c}=fixture(),t=transfer('saved','received','auto','direct'),key='saved:file-saved';c.transfers=[t];
  let present=true;
  const entries=[{...savedEntry('current/saved%3Afile-saved'),scope:'current',key},{...savedEntry('old-group/old'),scope:'old-group',key:'old'}];
  savedLibrary(c,entries);
  c.rtcStore={scope:'current',get:async()=>present?new File(['saved'],'saved.txt'):undefined,expiry:()=>Date.now()+60000};
  c.rtcLocalFiles.set(key,new File(['stale'],'stale.txt'));
  c.fileLibrary.service.remove=async(id:string)=>{entries.splice(entries.findIndex(entry=>entry.id===id),1);present=false;};
  await c.openLibrary();for(let i=0;i<6;i++)await Promise.resolve();assert.equal(c.rtcLocalFiles.has(key),true);
  c.fileLibrary.enterEdit('current/saved%3Afile-saved');await c.fileLibrary.deleteSelected();for(let i=0;i<6;i++)await Promise.resolve();
  assert.equal(c.rtcLocalFiles.has(key),false);assert.equal(c.rtcFileExpiry.has(key),false);assert.equal(c.rtcRestoring.size,0);assert.equal(c.rtcLocalFiles.has('old'),false);
  await assert.rejects(()=>c.download('saved','file-saved'),/文件已清理/);
  present=true;c.reconcileRtc();for(let i=0;i<6;i++)await Promise.resolve();assert.equal(c.rtcLocalFiles.has(key),false);assert.equal(c.rtcRestoring.size,0);assert.equal(c.visibleFiles(t).length,0);
});

test('late acceptance cannot put an old transfer back after switching group',async()=>{
  const {c}=fixture();c.transfers=[transfer('old')];
  let finish: ((value:unknown)=>void)|undefined;
  c.api.request=()=>new Promise(resolve=>{finish=resolve;});
  const pending=c.acceptIncoming();c.signOut();
  c.session={deviceToken:'new',device:{deviceId:'receiver'},groupId:'new'};
  c.transfers=[transfer('new')];finish!({transfer:transfer('old','accepted')});await pending;
  assert.deepEqual(c.transfers.map((item:any)=>item.transferId),['new']);
});

test('manual native-only acceptance gives the real limitation, while rejecting remains available',async()=>{
  const {c}=fixture(),t=transfer('lan','offered','lan');c.transfers=[t];
  const calls:any[]=[];c.api.request=async(path:string,body:any)=>{calls.push(body);return {transfer:transfer('lan','rejected','lan')};};
  await assert.rejects(()=>c.acceptFiles(t,[t.files[0].fileId],false),/原生直连/);
  await c.acceptFiles(t,[],false);assert.equal(calls.length,1);assert.equal(calls[0].fileIds.length,0);
});

test('outgoing received status shows receiver confirmation instead of ready or direct waiting copy',()=>{
  const {c}=fixture();
  for(const transport of ['relay','direct']){
    const received=transfer('saved','received','auto',transport);
    const html=c.fileHtml(received,received.files[0],true);
    assert.doesNotMatch(html,/card-status/);
    assert.doesNotMatch(html,/中心已保存，等待对方下载/);
    assert.doesNotMatch(html,/此文件由原生设备直收，中心无可下载副本/);
  }
  const ready=transfer('pending','ready','relay','relay');
  assert.doesNotMatch(c.fileHtml(ready,ready.files[0],true),/card-status|已就绪/);
assert.doesNotMatch(c.fileHtml(ready,ready.files[0],true),/已送达/);
});

test('relay auto receive defaults to 32 MiB and leaves large or mixed batches for one manual accept',async()=>{
  const {c}=fixture();assert.equal(c.autoAcceptMaxBytes,32*1048576);
  const small=transfer('small'),large=transfer('large'),mixed=transfer('mixed');
  small.files[0].size=32*1048576;large.files[0].size=33*1048576;
  mixed.files=[{...small.files[0],fileId:'mixed-small'},{...large.files[0],fileId:'mixed-large'}];
  c.transfers=[small,large,mixed];c.initializeConsent();
  const calls:any[]=[];
  c.api.request=async(path:string,body:any)=>{
    calls.push({path,body});const t=c.transfers.find((item:any)=>path===`/transfers/${item.transferId}/accept`);
    return {transfer:{...t,files:t.files.map((file:any)=>({...file,status:body.fileIds.includes(file.fileId)?'accepted':'rejected'}))}};
  };
  await c.acceptIncoming();
  assert.deepEqual(calls.map(item=>item.path),['/transfers/small/accept']);
  assert.equal(c.transfers.find((item:any)=>item.transferId==='mixed').files[0].status,'offered');
  assert.match(c.incomingTransferHtml(large),/中继，需手动接收/);
  await c.acceptTransfer('mixed');
  assert.deepEqual(Array.from(calls[1].body.fileIds),['mixed-small','mixed-large']);
});
test('settings names the unchanged 32 MiB relay threshold without redundant download guidance',()=>{
  const {c,document}=fixture();document.querySelector('#app')!.innerHTML=c.convenienceHtml();
  const field=document.querySelector<HTMLInputElement>('#auto-accept-limit')!;
  assert.equal(field.value,'32');assert.equal(field.getAttribute('aria-label'),'中继确认阈值 MiB');
  assert.match(document.querySelector('label[for="auto-accept-limit"]')!.textContent!,/中继确认阈值/);
  assert.doesNotMatch(c.convenienceHtml(),/自动接收上限|超限需确认|直连自动接收|Web 下载需点击/);
  assert.equal(c.autoAcceptMaxBytes,32*1048576);
});

test('relay auto receive threshold is configurable and isolated with the group preference',()=>{
  const {c}=fixture();c.autoAccept=false;c.setAutoAcceptLimit(64);
  assert.equal(c.autoAcceptMaxBytes,64*1048576);
  c.session={...c.session,groupId:'second'};c.loadPreferences();
  assert.equal(c.autoAcceptMaxBytes,32*1048576);
  c.session={...c.session,groupId:'group-one'};c.loadPreferences();
  assert.equal(c.autoAcceptMaxBytes,64*1048576);
});

test('compact pages retain send, dock, settings and relay size without marketing or routine TTL footnotes',()=>{
  const {c}=fixture();
  const workspace=c.workspace(),login=c.onboarding();
  assert.doesNotMatch(workspace,/<h2>(发送|接收)/);assert.match(workspace,/data-mobile-view-button="send">.*?发送/);assert.match(workspace,/data-mobile-view-button="receive"/);
  assert.match(workspace,/data-action="settings"/);
  assert.match(workspace,/data-action="pick-media"[^>]*>.*?媒体<\/button>/);assert.doesNotMatch(workspace,/图片\/视频/);
  assert.doesNotMatch(workspace+login,/A LITTLE|YOUR DEVICES|传递，自在|让设备之间|你的设备，你的私有空间/);
  assert.doesNotMatch(workspace,/文字最长保留/);
  assert.match(c.convenienceHtml(),/value="32"/);
  c.tab='files';c.picked=[new File(['content'],'sample.txt')];
  assert.match(c.workspace(),/1 项 · 7 B/);
  c.modal='settings';assert.match(c.modalHtml(),/id="auto-accept-limit"/);
  assert.match(c.modalHtml(),/value="32"/);
});

test('narrow workspace defaults to send and switches views without rebuilding or losing drafts and files',()=>{
  const {c,document}=fixture();
  assert.equal(c.mobileView,'send');
  const mobileHtml=c.workspace();
  assert.ok(mobileHtml.indexOf('id="mobile-send-tab"')<mobileHtml.indexOf('id="mobile-receive-tab"'));
  assert.match(mobileHtml,/data-mobile-view-button="receive">.*?接收<\/button>/);
  assert.match(mobileHtml,/data-mobile-view-button="sent">.*?历史<\/button>/);
  assert.match(mobileHtml,/data-mobile-view-button="library">.*?文件<\/button>/);
  const attributes=new Map<string,string>();
  const button=(view:string)=>({dataset:{mobileViewButton:view},attributes:new Map<string,string>(),active:false,
    setAttribute(name:string,value:string){this.attributes.set(name,value);},
    classList:{toggle(_name:string,_enabled:boolean){}}});
  const receive=button('receive'),send=button('send');
  (document as any).querySelector=()=>({setAttribute:(name:string,value:string)=>attributes.set(name,value)});
  (document as any).querySelectorAll=()=>[receive,send];
  let renders=0;c.render=()=>{renders++;};
  const file=new File(['keep'],'draft.txt');
  c.text='未发送草稿';c.picked=[file];c.target='sender';c.tab='files';
  c.devices=[{deviceId:'sender',name:'Sender',platform:'android',online:true}];
  assert.match(c.workspace(),/data-mobile-view="send"/);
  assert.match(c.workspace(),/aria-controls="receive-panel"/);
  c.setMobileView('send');
  assert.equal(attributes.get('data-mobile-view'),'send');
  assert.equal(send.attributes.get('aria-selected'),'true');
  assert.equal(receive.attributes.get('aria-selected'),'false');
  assert.equal(c.text,'未发送草稿');assert.equal(c.picked[0],file);assert.equal(c.target,'sender');
  assert.match(c.workspace(),/data-mobile-view="send"/);
  c.setMobileView('receive');
  assert.equal(attributes.get('data-mobile-view'),'receive');
  assert.equal(c.picked[0],file);assert.equal(c.tab,'files');assert.equal(renders,0);
  const html=c.workspace();
  assert.match(html,/data-action="settings"/);assert.match(html,/data-action="clear-dock"/);
  assert.match(html,/id="receive-panel"/);assert.match(html,/id="send-panel"/);
});

test('mobile four destinations preserve drafts and expose history and files without nested tabs',()=>{
  const {c,document,render}=fixture();c.render=render;let opened=0;c.fileLibrary.open=async()=>{opened++;};c.text='未确认草稿';c.stagedTexts=[{id:'keep',text:'待发'}];c.render();
  assert.deepEqual(Array.from(document.querySelectorAll('.mobile-view-tabs button'),node=>node.textContent),['发送','接收','历史','文件']);
  for(const [destination,view] of [['receive','receive'],['sent','sent'],['library','library'],['send','library']]){
    document.querySelector<HTMLElement>(`[data-mobile-view-button="${destination}"]`)!.click();
    assert.equal(c.mobileView,destination==='send'?'send':'receive');assert.equal(c.contentView,view);
    assert.equal(document.querySelector('[aria-selected="true"][data-mobile-view-button]')!.getAttribute('data-mobile-view-button'),destination);
  }
  assert.equal(opened,1);assert.equal(c.text,'未确认草稿');assert.equal(c.stagedTexts[0].text,'待发');
});

test('device context inspection shows actual cached paths without sending the queue',()=>{
  const {c,document,render,Event}=fixture();c.render=render;let refreshed='';c.stagedTexts=[{id:'keep',text:'待发'}];
  c.rtcProbes={status:()=>'',results:[{initiatorDeviceId:'receiver',responderDeviceId:'sender',scope:'lan',success:true,elapsedMs:12,checkedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString()}],refreshPeer:async(id:string)=>{refreshed=id;}};
  c.render();const event=new Event('contextmenu',{bubbles:true,cancelable:true});document.querySelector('[data-target="sender"]')!.dispatchEvent(event);
  assert.equal(c.modal,'device-network');assert.equal(refreshed,'sender');assert.match(document.querySelector('.device-network-modal')!.textContent!,/可达 · 12 ms/);assert.match(document.querySelector('.device-network-modal')!.textContent!,/未测试/);assert.equal(c.stagedTexts.length,1);
});

test('receipt batches use actual receipt timestamps rather than insertion or creation order',()=>{
  const {c,document,render}=fixture();c.render=render;
  c.receivedAt={'text:a':'2026-10-27T01:00:00Z','text:b':'2026-10-27T03:00:00Z','text:c':'2026-10-27T02:00:00Z'};
  for(const id of ['b','a','c'])c.showReceipt({id,version:'1',source:'sender',title:'文本',text:id});
  assert.deepEqual(Array.from(document.querySelectorAll('[data-view-receipt]'),node=>node.getAttribute('data-view-receipt')),['b','c','a']);
  c.showReceipt({id:'a',version:'2',source:'sender',title:'文本已修改',text:'修改'});
  assert.deepEqual(Array.from(document.querySelectorAll('[data-view-receipt]'),node=>node.getAttribute('data-view-receipt')),['b','c','a']);
});

test('forced network reconnect discards late old ticket responses without resetting active file state',async()=>{
  const {c,connect}=fixture(),tickets:((value:any)=>void)[]=[];c.api.request=async()=>new Promise(resolve=>tickets.push(resolve));
  const file=new File(['keep'],'keep.txt');c.picked=[file];c.stagedTexts=[{id:'keep',text:'草稿'}];
  connect();connect(true);assert.equal(tickets.length,2);
  tickets[0]({ticket:'old'});await new Promise(resolve=>setImmediate(resolve));assert.equal(c.ws,null);
  tickets[1]({ticket:'new'});await new Promise(resolve=>setImmediate(resolve));assert.ok(c.ws);assert.equal(c.picked[0],file);assert.equal(c.stagedTexts[0].text,'草稿');
});

test('mobile file and media buttons stage multiple originals and reset media filters for files and resume',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.render();c.installFileInputs();
  const files=document.querySelector<HTMLButtonElement>('.mobile-file-actions [data-action="pick-files"]')!;
  const media=document.querySelector<HTMLButtonElement>('.mobile-file-actions [data-action="pick-media"]')!;
  assert.equal(files.textContent?.trim(),'文件');assert.equal(media.textContent?.trim(),'媒体');
  const input=document.querySelector<HTMLInputElement>('#file-input')!;
  assert.equal(input.hasAttribute('multiple'),true);
  media.click();assert.equal(input.accept,'image/*,video/*');
  const photo=new File(['photo'],'图片.png',{type:'image/png'}),video=new File(['video'],'视频.mp4',{type:'video/mp4'});
  Object.defineProperty(input,'files',{configurable:true,value:[photo,video]});input.dispatchEvent(new Event('change'));
  assert.equal(c.picked.length,2);assert.equal(c.picked[0],photo);assert.equal(c.picked[1],video);
  document.querySelector<HTMLButtonElement>('.mobile-file-actions [data-action="pick-files"]')!.click();
  assert.equal(input.accept,'');
  c.openFilePicker(undefined,true);
  const resume=document.querySelector<HTMLInputElement>('#resume-file')!;resume.accept='image/*';
  c.openFilePicker('transfer:file');assert.equal(resume.accept,'');
  assert.equal(document.querySelectorAll('.targets-section').length,1);
});

test('file picker nodes survive real app rerenders and original change listener accepts the same file again once',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.installFileInputs();
  const input=document.querySelector<HTMLInputElement>('#file-input')!;
  const resume=document.querySelector<HTMLInputElement>('#resume-file')!;
  assert.equal(document.querySelector('#app')!.contains(input),false);
  c.openFilePicker();c.render();c.render();
  assert.equal(document.querySelector('#file-input'),input);assert.equal(input.isConnected,true);
  assert.equal(document.querySelector('#resume-file'),resume);assert.equal(resume.isConnected,true);
  const file=new File(['keep'],'重复选择.txt');
  Object.defineProperty(input,'files',{configurable:true,value:[file]});input.value='selection';
  input.dispatchEvent(new Event('change'));
  assert.equal(c.picked.length,1);assert.equal(c.picked[0],file);assert.equal(input.value,'');
  c.installFileInputs();c.openFilePicker();c.render();input.value='selection';
  input.dispatchEvent(new Event('change'));
  assert.equal(c.picked.length,2,'one installed listener must handle one new selection');
  assert.equal(c.picked[1],file);assert.equal(input.value,'');
});

test('persistent resume picker retains its original target across rerender and clears old-session selections',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.installFileInputs();
  const input=document.querySelector<HTMLInputElement>('#file-input')!;
  const resume=document.querySelector<HTMLInputElement>('#resume-file')!;
  const file=new File(['resume'],'resume.txt'),calls:any[]=[];
  c.attachResumeSource=async(source:File,key:string)=>{calls.push({source,key});};
  c.openFilePicker('transfer-one:file-one');c.render();c.resumeKey='unrelated:file';
  Object.defineProperty(resume,'files',{configurable:true,value:[file]});resume.value='selection';
  resume.dispatchEvent(new Event('change'));await Promise.resolve();
  assert.equal(calls.length,1);assert.equal(calls[0].source,file);assert.equal(calls[0].key,'transfer-one:file-one');
  assert.equal(resume.value,'');
  c.openFilePicker();c.openFilePicker('stale:file');c.signOut();
  c.session={deviceToken:'new',device:{deviceId:'receiver',name:'New'},groupId:'new'};
  Object.defineProperty(input,'files',{configurable:true,value:[file]});input.value='old';resume.value='old';
  input.dispatchEvent(new Event('change'));resume.dispatchEvent(new Event('change'));await Promise.resolve();
  assert.equal(c.picked.length,0);assert.equal(calls.length,1);
  assert.equal(input.value,'');assert.equal(resume.value,'');
  assert.equal(c.filePickerGeneration,null);assert.equal(c.resumePicker,null);assert.equal(c.resumeKey,'');
  assert.equal(document.querySelector('#file-input'),input);assert.equal(document.querySelector('#resume-file'),resume);
});

test('paper editor keeps the textarea node, draft, selection and scroll when expanded or reconciled',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.toggleEditor(true);
  const field=document.querySelector<HTMLTextAreaElement>('#send-text')!;
  field.value='第一行草稿\n第二行草稿';field.dispatchEvent(new Event('input'));
  field.setSelectionRange(2,8,'backward');field.scrollTop=72;
  assert.equal(document.querySelector('#text-count')!.textContent,`${[...field.value].length} 字符`);
  c.render();assert.equal(document.querySelector('#send-text'),field);
  assert.equal(field.selectionStart,2);assert.equal(field.selectionEnd,8);assert.equal(field.scrollTop,72);
  c.toggleEditor(true);
  assert.equal(c.modal,'editor');assert.equal(document.querySelectorAll('#send-text').length,1);
  assert.equal(document.querySelector('.editor-modal #send-text'),field);
  assert.equal(field.selectionStart,2);assert.equal(field.selectionEnd,8);assert.equal(field.selectionDirection,'backward');
  assert.equal(field.scrollTop,72);assert.equal(c.text,'第一行草稿\n第二行草稿');
  c.toggleEditor(false);
  assert.equal(c.modal,null);assert.equal(document.querySelector('#send-text'),null);c.toggleEditor(true);assert.equal(document.querySelector('#send-text'),field);
  assert.equal(field.selectionStart,2);assert.equal(field.selectionEnd,8);assert.equal(field.scrollTop,72);
  const saved=c.session;c.signOut();c.session=saved;c.render();
  assert.notEqual(document.querySelector('#send-text'),field);
  field.value='旧会话输入';field.dispatchEvent(new Event('input'));
  assert.equal(c.text,'');
});

test('editor Enter remains a newline while Ctrl or Meta Enter stages text and only Send creates the message',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.target='sender';c.toggleEditor(true);
  const field=document.querySelector<HTMLTextAreaElement>('#send-text')!;
  const requests:any[]=[];c.api.request=async(path:string,body:any)=>{requests.push({path,body});return {};};
  const key=(ctrlKey=false,metaKey=false)=>{const event=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(event,{key:'Enter',ctrlKey,metaKey,isComposing:false});field.dispatchEvent(event);return event;};
  field.value='第一行';field.dispatchEvent(new Event('input'));
  assert.equal(key().defaultPrevented,false);assert.equal(requests.length,0);
  field.value+='\n第二行';field.dispatchEvent(new Event('input'));
  assert.equal(key(true).defaultPrevented,true);assert.equal(requests.length,0);
  assert.equal(c.stagedTexts.length,1);assert.equal(c.stagedTexts[0].text,'第一行\n第二行');assert.equal(c.text,'');assert.equal(field.value,'');assert.equal(c.modal,null);
  c.toggleEditor(true);assert.equal(document.querySelector('#send-text'),field);
  field.value='下一段';field.dispatchEvent(new Event('input'));assert.equal(key(false,true).defaultPrevented,true);
  assert.equal(c.stagedTexts.length,2);assert.equal(requests.length,0);
  await c.sendQueue();assert.equal(requests.length,2);assert.equal(requests[0].path,'/texts');assert.equal(requests[0].body.text,'第一行\n第二行');assert.equal(requests[1].body.text,'下一段');assert.equal(c.stagedTexts.length,0);
});

test('only online peers appear in discovery, editor and settings while past messages remain',()=>{
  const {c,document,render}=fixture();c.render=render;
  c.devices=[
    {deviceId:'receiver',name:'Browser',platform:'web',online:true},
    {deviceId:'online',name:'在线手机',platform:'android',online:true},
    {deviceId:'offline',name:'离线电脑',platform:'windows',online:false},
    {deviceId:'revoked',name:'已撤销',platform:'web',online:true,revoked:true},
  ];
  c.events=[{eventId:'kept',type:'text.created',cursor:1,sourceDeviceId:'offline',targetDeviceId:'receiver',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),payload:{text:'保留历史'}}];
  c.selectOnlineTarget();c.render();
  assert.deepEqual(Array.from(document.querySelectorAll('[data-target]')).map(node=>node.getAttribute('data-target')),['online']);
  assert.equal(document.querySelectorAll('.target-device').length,1);
  assert.equal(c.target,'online');assert.match(document.querySelector('#receive-panel')!.textContent!,/保留历史/);assert.equal(c.deviceLabel('offline'),'离线电脑');
  c.toggleEditor(true);
  assert.equal(document.querySelector('#editor-target-device'),null);
  c.modal='settings';c.render();
  assert.equal(document.querySelector('[data-revoke="offline"]'),null);
  assert.equal(document.querySelector('.offline-devices'),null);
  assert.doesNotMatch(document.querySelector('.settings-modal')!.textContent!,/离线电脑|已撤销/);
  assert.equal(c.devices.length,4);assert.equal(c.events[0].eventId,'kept');
});

test('presence retains offline targets for attempts and restores peers without losing the editor',async()=>{
  const {c,document,render,connect,Event}=fixture();c.render=render;
  c.devices=[{deviceId:'first',name:'First',platform:'android',online:true},{deviceId:'second',name:'Second',platform:'windows',online:true}];
  c.target='first';c.toggleEditor(true);
  const field=document.querySelector<HTMLTextAreaElement>('#send-text')!;
  field.value='继续输入';field.dispatchEvent(new Event('input'));field.setSelectionRange(1,3);field.scrollTop=22;
  c.api.request=async()=>({ticket:'ticket'});
  connect();await new Promise(resolve=>setImmediate(resolve));
  const socket=c.ws;
  const presence=(deviceId:string,online:boolean)=>socket.onmessage({data:JSON.stringify({type:'presence',deviceId,online})});
  presence('first',false);
  assert.equal(c.target,'first');assert.ok(document.querySelector('[data-target="first"]'));assert.match(document.querySelector('[data-target="first"]')!.textContent!,/暂离线/);
  assert.equal(document.querySelector('#send-text'),field);assert.equal(field.value,'继续输入');
  assert.equal(field.selectionStart,1);assert.equal(field.selectionEnd,3);assert.equal(field.scrollTop,22);
  presence('second',false);
  assert.equal(c.target,'first');assert.equal(document.querySelector('#send-button'),null);
  assert.equal(document.querySelectorAll('.target-device.offline').length,2);
  let requests=0;c.api.request=async()=>{requests++;return {};};
  await c.sendText();assert.equal(requests,1);assert.equal(c.text,'');
  c.refresh=async()=>{c.updateDevices([{deviceId:'first',name:'First',platform:'android',online:true}]);c.render();};
  presence('first',true);
  assert.equal(c.target,'first');assert.ok(document.querySelector('[data-target="first"]'));
  let refreshed=0;c.refresh=async()=>{refreshed++;};presence('new-device',true);
  assert.equal(refreshed,1);
  socket.onmessage({data:JSON.stringify({type:'devices.changed'})});assert.equal(refreshed,2);
  c.scheduleReconnect=()=>{};socket.onclose();
  assert.equal(c.target,'first');assert.equal(c.peers().length,2);assert.equal(c.onlinePeers().length,0);assert.equal(c.devices.every((device:any)=>!device.online),true);
});

test('grace deadline timer removes offline target at 30s, resumes prune stale state, and sign-out resets scope',async()=>{
  const {c,context,document,render}=fixture();c.render=render;
  let now=1000;
  (context as any).Date=class extends Date {static now(){return now;}};
  let callback:(()=>void)|undefined,delay=0;
  context.window.setTimeout=(fn:()=>void,ms:number)=>{if(ms>=10000){callback=fn;delay=ms;}return 1;};
  const phone={...c.devices[0],peer:{candidates:['https://[2408::1]:8788'],expiresAt:new Date(Date.now()+1800000).toISOString()}};
  c.devices=[phone];c.updateDevices([]);c.render();
  assert.equal(delay,30000);assert.ok(document.querySelector('[data-target="sender"]'));assert.equal(c.isSendablePeer('sender'),true);assert.equal(c.isOnlinePeer('sender'),false);
  const queued:any[]=[];c.stagedTexts=[{text:'离线尝试'}];c.api.request=async(path:string,body:any)=>{queued.push({path,body});return {};};
  await c.sendQueue(['sender']);assert.equal(queued[0].path,'/texts');assert.equal(c.stagedTexts.length,0);
  now=30999;assert.equal(c.isSendablePeer('sender'),true);
  now=31000;callback!();assert.equal(c.isSendablePeer('sender'),false);assert.equal(document.querySelector('[data-target="sender"]'),null);assert.equal(c.recentDevices.deadlines.size,0);
  c.updateDevices([phone]);now=40000;c.updateDevices([]);now=80000;
  Object.defineProperty(document,'visibilityState',{value:'visible',configurable:true});c.resumeDiscovery();assert.equal(c.peers().length,0);
  c.updateDevices([phone]);c.updateDevices([]);assert.equal(c.recentDevices.deadlines.size,1);c.signOut();assert.equal(c.recentDevices.deadlines.size,0);
});

test('settings edits the current device name without losing its draft on refresh and persists the saved name',async()=>{
  const {c,document,render,refresh,Event,persistent}=fixture();c.render=render;
  c.devices=[{...c.session.device,online:true},{deviceId:'sender',name:'Sender',platform:'android',online:true}];
  c.openSettings();
  const field=document.querySelector<HTMLInputElement>('#device-display-name')!;
  field.value='  我的平板  ';field.dispatchEvent(new Event('input'));
  c.api.request=async(path:string)=>path==='/devices'?{devices:[{...c.session.device,name:'服务端名称',online:true},c.devices[1]]}:path==='/transfers'?{transfers:[]}:{events:[],cursor:0,hasMore:false};
  await refresh();
  assert.equal(c.session.device.name,'服务端名称');
  assert.equal(document.querySelector<HTMLInputElement>('#device-display-name')!.value,'  我的平板  ');
  const requests:any[]=[];
  c.api.request=async(path:string,body:any,method:string)=>{requests.push({path,body,method});return {device:{...c.session.device,name:body.name,online:true}};};
  await c.saveDeviceName();
  assert.equal(requests.length,1);assert.equal(requests[0].path,'/devices/me');assert.equal(requests[0].method,'PATCH');
  assert.equal(requests[0].body.name,'我的平板');assert.equal(c.session.device.name,'我的平板');
  assert.equal(c.devices[0].name,'我的平板');assert.equal(document.querySelector<HTMLInputElement>('#device-display-name')!.value,'我的平板');
  assert.equal(JSON.parse(persistent.get(c.key+':session')!).device.name,'我的平板');
  assert.match(document.querySelector('.app-title')!.textContent!,/我的平板/);
});

test('device name errors keep the entered draft and a pending save does not replace newly typed text',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.openSettings();
  let calls=0;c.api.request=async()=>{calls++;throw new Error('连接中断');};
  c.deviceNameDraft='   ';await c.saveDeviceName();assert.equal(calls,0);assert.match(c.deviceNameError,/1–80/);
  c.deviceNameDraft='保留名称';await c.saveDeviceName();assert.equal(calls,1);assert.equal(c.deviceNameDraft,'保留名称');assert.equal(c.deviceNameError,'连接中断');
  let finish: ((value:any)=>void)|undefined;
  c.api.request=()=>new Promise(resolve=>{finish=resolve;});
  const saving=c.saveDeviceName();
  assert.equal(document.querySelector('#save-device-name')!.hasAttribute('disabled'),true);
  const field=document.querySelector<HTMLInputElement>('#device-display-name')!;field.value='继续修改';field.dispatchEvent(new Event('input'));
  finish!({device:{...c.session.device,name:'保留名称'}});await saving;
  assert.equal(c.session.device.name,'保留名称');assert.equal(c.deviceNameDraft,'继续修改');
  assert.equal(document.querySelector<HTMLInputElement>('#device-display-name')!.value,'继续修改');
  const icon=(platform:string)=>c.deviceInner({deviceId:'same',name:'Same',platform,online:true}).match(/<svg.*?<\/svg>/)?.[0];
  assert.notEqual(icon('web'),icon('android'));assert.notEqual(icon('web'),icon('windows'));assert.notEqual(icon('android'),icon('windows'));
});

test('HTTP snapshots select targets and retain recently offline choices, device names and transfers',async()=>{
  const {c,refresh}=fixture();
  const snapshot=[{deviceId:'receiver',name:'Browser',platform:'web',online:true},{deviceId:'old',name:'Old',platform:'windows',online:false},{deviceId:'new',name:'New',platform:'android',online:true}];
  const saved=transfer('saved','received');saved.sourceDeviceId='old';
  c.target='old';c.api.request=async(path:string)=>path==='/devices'?{devices:snapshot}:path==='/transfers'?{transfers:[saved]}:{events:[],cursor:0,hasMore:false};
  await refresh();
  assert.equal(c.target,'new');assert.equal(c.deviceLabel('old'),'Old');assert.equal(c.transfers[0].transferId,'saved');
  snapshot[2].online=false;await refresh();assert.equal(c.target,'new');assert.equal(c.isOnlinePeer('new'),false);
  snapshot[1].online=true;await refresh();assert.equal(c.target,'new');assert.equal(c.isSendablePeer('old'),true);
});

test('a pending file invitation keeps its original destination when presence selects a different peer',async()=>{
  const {c,document,render}=fixture();c.render=render;
  c.devices=[{deviceId:'original',name:'Original',platform:'windows',online:false},{deviceId:'other',name:'Other',platform:'android',online:true}];
  c.target='original';c.tab='files';c.picked=[new File(['keep'],'keep.txt')];
  c.pendingOffer={transferId:'fixed',targetDeviceId:'original',routePreference:'relay',files:[{fileId:'file-fixed',name:'keep.txt',size:4,mimeType:'text/plain',sha256:'a'.repeat(64)}]};
  c.selectOnlineTarget();c.render();
  assert.equal(c.target,'other');assert.equal(document.querySelector('#send-button')!.hasAttribute('disabled'),true);
  assert.match(document.querySelector('.send-note')!.textContent!,/Original · 等待上线/);
  const requests:any[]=[];c.api.request=async(path:string,body:any)=>{requests.push({path,body});return {transfer:transfer('fixed','offered','relay')};};
  await c.sendFiles();assert.equal(requests.length,0);assert.equal(c.pendingOffer.targetDeviceId,'original');
  c.devices[0].online=true;c.selectOnlineTarget();c.render();
  assert.match(document.querySelector('.send-note')!.textContent!,/Original · 待重试/);
  await c.sendFiles();assert.equal(requests.length,1);assert.equal(requests[0].body.targetDeviceId,'original');
});

test('IME composition defers only painting and never submits an unfinished editor draft',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.target='sender';c.toggleEditor(true);
  const field=document.querySelector<HTMLTextAreaElement>('#send-text')!;
  let calls=0;c.api.request=async()=>{calls++;return {};};
  field.dispatchEvent(new Event('compositionstart'));
  field.value='中文';field.dispatchEvent(new Event('input'));
  c.devices=[{deviceId:'sender',name:'New presence',platform:'android',online:true}];c.render();
  assert.equal(c.editorRenderPending,true);assert.equal(field.isConnected,true);assert.equal(document.querySelector('#send-text'),field);
  const event=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(event,{key:'Enter',ctrlKey:true,metaKey:false,isComposing:true});
  field.dispatchEvent(event);assert.equal(calls,0);
  field.value='中文完成';field.dispatchEvent(new Event('compositionend'));
  assert.equal(c.editorComposing,false);assert.equal(c.editorRenderPending,false);assert.equal(c.text,'中文完成');
  assert.equal(document.querySelector('#send-text'),field);assert.equal(c.devices[0].name,'New presence');
});

function textEvent(eventId='message',outgoing=false,text='原始文字'): any {
  return {eventId,type:'text.created',cursor:1,sourceDeviceId:outgoing?'receiver':'sender',targetDeviceId:outgoing?'sender':'receiver',
    createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString(),payload:{text}};
}

test('receive cards use persisted receipt time and restore only the current library scope metadata',()=>{
  const {c,session}=fixture(),incoming=transfer('receipt','accepted');incoming.createdAt='2026-10-24T01:00:00.000Z';c.transfers=[incoming];
  assert.doesNotMatch(c.fileHtml(incoming,incoming.files[0],false),/邀请时间|card-meta/);c.setFile('receipt',{...incoming.files[0],status:'received'});
  const receivedAt=c.receivedAt['receipt:file-receipt'];assert.ok(Date.parse(receivedAt)>Date.parse(incoming.createdAt));assert.equal(JSON.parse(session.get(c.dockKey)!).receivedAt['receipt:file-receipt'],receivedAt);
  assert.doesNotMatch(c.fileHtml(incoming,incoming.files[0],false),/接收时间|card-meta/);assert.doesNotMatch(c.fileHtml(incoming,incoming.files[0],false),/邀请 /);
  c.rtcStore={scope:'current-scope'};c.reconcileRtc=()=>{};
  c.syncLibraryCache([{scope:'other-scope',key:'receipt:file-receipt',receivedAt:1},{scope:'current-scope',key:'receipt:file-receipt',receivedAt:Date.parse('2026-10-25T02:00:00.000Z')}]);
  assert.equal(c.receivedAt['receipt:file-receipt'],'2026-10-25T02:00:00.000Z');
  c.recordReceipt('receipt:file-receipt');assert.equal(c.receivedAt['receipt:file-receipt'],'2026-10-25T02:00:00.000Z');
});

test('workspace queue retries the same recipient with the same event identity',async()=>{
  const {c}=fixture();c.target='sender';c.text='保留这条';c.stageDraft();
  const calls:any[]=[];let fail=true;c.api.request=async(path:string,body:any)=>{calls.push({path,body});if(fail)throw new Error('断开');return {};};
  await c.sendQueue();assert.equal(c.stagedTexts.length,1);assert.equal(c.sendBatch.target('sender').state,'failed');
  fail=false;await c.sendQueue();
  assert.equal(c.stagedTexts.length,0);assert.equal(calls[1].body.eventId,calls[0].body.eventId);assert.equal(calls[1].body.targetDeviceId,'sender');
});

test('device click sends and consumes a confirmed queue; multi-select waits for confirmation',async()=>{
  const {c,document,render}=fixture();c.render=render;
  c.devices.push({deviceId:'tablet',name:'平板',platform:'web',online:true});
  c.stagedTexts=[{id:'draft-one',text:'一批正文'}];
  const requests:any[]=[];c.api.request=async(path:string,body:any)=>{requests.push({path,body});return {};};
  render();assert.equal(document.querySelector('#send-button'),null);
  document.querySelector<HTMLButtonElement>('[data-target="sender"]')!.click();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(requests.length,1);assert.equal(requests[0].body.targetDeviceId,'sender');assert.equal(c.stagedTexts.length,0);
  c.stagedTexts.push({id:'draft-two',text:'多选正文'});render();
  document.querySelector<HTMLButtonElement>('[data-action="multi-send"]')!.click();
  document.querySelector<HTMLButtonElement>('[data-target="sender"]')!.click();
  document.querySelector<HTMLButtonElement>('[data-target="tablet"]')!.click();
  assert.equal(requests.length,1);assert.equal(c.selectedTargets.size,2);
  document.querySelector<HTMLButtonElement>('[data-action="send-queue"]')!.click();
  await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(requests.slice(1).map(request=>request.body.targetDeviceId),['sender','tablet']);
  assert.equal(c.stagedTexts.length,0);assert.equal(c.selectedTargets.size,0);
  assert.equal(c.multiSend,false);
  assert.equal(document.querySelector('[data-action="send-queue"]'),null);
  assert.match(document.querySelector('[data-action="multi-send"]')!.textContent!,/多选/);
  c.stagedTexts.push({id:'draft-three',text:'下一批直接发'});render();
  document.querySelector<HTMLButtonElement>('[data-target="tablet"]')!.click();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(requests.length,4);assert.equal(requests[3].body.targetDeviceId,'tablet');
  assert.equal(c.stagedTexts.length,0);assert.equal(c.multiSend,false);
});

test('multi-recipient retry skips completed recipients and preserves uncertain offer identity',async()=>{
  const {c}=fixture();c.multiSend=true;c.devices.push({deviceId:'tablet',name:'平板',platform:'web',online:true});
  c.stagedTexts=[{id:'one',text:'第一段'},{id:'two',text:'第二段'}];c.picked=[new File(['body'],'notes.txt')];c.digest=async()=> 'a'.repeat(64);
  const requests:any[]=[];let fail=true;c.api.request=async(path:string,body:any)=>{
    requests.push({path,body:structuredClone(body)});
    if(path==='/transfers' && body.targetDeviceId==='tablet' && fail){fail=false;throw new Error('response lost');}
    return path==='/transfers'?{transfer:{...transfer(body.transferId),targetDeviceId:body.targetDeviceId,files:body.files}}:{};
  };
  await c.sendQueue(['sender','tablet']);
  assert.equal(c.picked.length,1);assert.equal(c.stagedTexts.length,2);
  assert.equal(c.sendBatch.target('sender').state,'sent');assert.equal(c.sendBatch.target('tablet').state,'failed');
  assert.equal(c.multiSend,false);assert.equal(c.selectedTargets.size,0);const before=requests.length;
  await c.sendQueue(['sender','tablet']);
  assert.equal(requests.length,before+1);assert.deepEqual(requests[before].body,requests[before-1].body);
  assert.equal(c.picked.length,0);assert.equal(c.stagedTexts.length,0);
});

test('new content added during a send remains queued and received modal does not replace editing',async()=>{
  const {c,document,render}=fixture();c.render=render;c.stagedTexts=[{id:'first',text:'当前批次'}];
  let finish:(value:unknown)=>void=()=>{};c.api.request=async()=>new Promise(resolve=>{finish=resolve;});
  const pending=c.sendQueue(['sender']);await new Promise(resolve=>setImmediate(resolve));
  c.stagedTexts.push({id:'later',text:'稍后发送'});finish({});await pending;
  assert.equal(c.stagedTexts.length,1);assert.equal(c.stagedTexts[0].id,'later');
  c.text='未确认正文';c.toggleEditor(true);const field=document.querySelector('#send-text');
  c.showReceipt({id:'notice',version:'1',source:'sender',title:'发来一条文本',text:'完整收件'});
  assert.equal(c.modal,'editor');assert.equal(document.querySelector('#send-text'),field);assert.equal(c.text,'未确认正文');
  c.toggleEditor(false);assert.equal(c.modal,'receipt');assert.match(document.querySelector('.receipt-content')!.textContent!,/完整收件/);
  c.closeModal();assert.equal(c.modal,null);
  c.showReceipt({id:'notice',version:'1',source:'sender',title:'重复',text:'完整收件'});assert.equal(c.modal,null);
  c.showReceipt({id:'notice',version:'2',source:'sender',title:'文本已更新',text:'最新完整收件'});assert.equal(c.modal,'receipt');
  assert.equal(document.querySelector('.receipt-modal')!.getAttribute('draggable'),'true');
  assert.equal(document.querySelector('.receipt-modal')!.getAttribute('data-drag-receipt'),'notice');
  for(const selector of ['.receipt-content','.receipt-modal .card-copy'])assert.equal(document.querySelector(selector)!.closest<HTMLElement>('[data-drag-receipt]')!.dataset.dragReceipt,'notice');
  assert.equal(c.text,'未确认正文');assert.equal(c.events.length,0);
});

test('right click and more button share one context menu action set',()=>{
  const {c,document,render,Event,context}=fixture();c.render=render;Object.assign(context.window,{innerWidth:950,innerHeight:619});
  const event={eventId:'text',type:'text.created',cursor:1,sourceDeviceId:'sender',targetDeviceId:'receiver',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),payload:{text:'正文'}};
  c.events=[event];render();
  const rightClick=new Event('contextmenu',{bubbles:true,cancelable:true});Object.assign(rightClick,{clientX:900,clientY:600});
  document.querySelector('[data-drag-text]')!.dispatchEvent(rightClick);
  const actions=Array.from(document.querySelectorAll('[data-card-command]')).map(node=>node.textContent);
  assert.deepEqual(actions,['复制','加入待发送','删除','详情']);assert.equal(rightClick.defaultPrevented,true);
  c.contextMenu=null;render();const more=document.querySelector<HTMLButtonElement>('[data-card-menu]')!;
  more.getBoundingClientRect=()=>({right:100,bottom:100} as DOMRect);more.click();
  assert.deepEqual(Array.from(document.querySelectorAll('[data-card-command]')).map(node=>node.textContent),actions);
});

test('shared text preserves local edits on remote conflict and explicit retry uses the latest revision',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.info.features={groupSharedText:true};c.render();
  c.shared.receive({text:'原文',revision:1,updatedAt:'',updatedBy:'sender'});
  const field=document.querySelector<HTMLTextAreaElement>('#shared-group-text')!;field.value='我的草稿';field.dispatchEvent(new Event('input'));
  c.shared.receive({text:'另一设备的修改',revision:2,updatedAt:'',updatedBy:'sender'});
  assert.equal(c.shared.conflict,true);assert.equal(field.value,'我的草稿');assert.equal(c.shared.draft,'我的草稿');
  let request:any;c.api.request=async(path:string,body:any)=>{request={path,body};return {text:body.text,revision:3,updatedAt:'',updatedBy:'receiver',mutationId:body.mutationId};};
  c.shared.conflict=false;await c.shared.save();assert.equal(request.path,'/group/shared-text');assert.equal(request.body.baseRevision,2);assert.equal(request.body.text,'我的草稿');assert.equal(c.shared.dirty,false);
  field.value='继续写';field.dispatchEvent(new Event('input'));c.render();assert.equal(document.querySelector('#shared-group-text'),field);assert.equal(field.value,'继续写');
});

test('shared text does not paint through IME composition or discard later typing after an own-save echo',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.info.features={groupSharedText:true};c.render();
  c.shared.receive({text:'',revision:0,updatedAt:'',updatedBy:''});const field=document.querySelector<HTMLTextAreaElement>('#shared-group-text')!;
  field.dispatchEvent(new Event('compositionstart'));field.value='中文';field.dispatchEvent(new Event('input'));c.render();assert.equal(document.querySelector('#shared-group-text'),field);assert.equal(field.isConnected,true);
  field.dispatchEvent(new Event('compositionend'));let finish:((value:any)=>void)|undefined,body:any;c.api.request=async(_path:string,value:any)=>{body=value;return new Promise(resolve=>{finish=resolve;});};
  const saving=c.shared.save();field.value='中文继续';field.dispatchEvent(new Event('input'));const echo={text:'中文',revision:1,updatedAt:'',updatedBy:'receiver',mutationId:body.mutationId};c.shared.receive(echo);finish!(echo);await saving;
  assert.equal(c.shared.draft,'中文继续');assert.equal(field.value,'中文继续');assert.equal(c.shared.dirty,true);assert.equal(c.shared.conflict,false);
});
function textUpdate(original:any,text:string,cursor=2): any {
  return {...original,eventId:`update-${cursor}`,type:'text.updated',cursor,payload:{sourceEventId:original.eventId,text,editedAt:new Date().toISOString()}};
}

test('web URLs are directly available from message cards, reader, edited drafts and receipt',()=>{
  const {c,document,render,Event}=fixture();c.render=render;
  c.events=[textEvent('link-message',false,'访问 https://example.com/a?q=1&b=2。')];c.render();
  const action=document.querySelector<HTMLAnchorElement>('.text-card .web-link')!;
  assert.equal(action.textContent,'https://example.com/a?q=1&b=2');assert.equal(action.getAttribute('href'),'https://example.com/a?q=1&b=2');
  document.querySelector<HTMLButtonElement>('[data-read="link-message"]')!.click();
  assert.equal(document.querySelector('[data-reader-links] a')!.getAttribute('target'),'_blank');
  c.modal=null;c.events=[textEvent('own-link',true,'原文')];c.openText('own-link');
  const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;
  field.value='修改 www.example.com';field.dispatchEvent(new Event('input'));
  assert.equal(document.querySelector('[data-reader-links] a')!.getAttribute('href'),'https://www.example.com/');
  assert.equal(document.querySelector('#reader-text'),field);
  c.receipt={id:'receipt-link',version:1,source:'sender',title:'收到文本',text:'https://example.com <b>原文</b>'};
  c.modal='receipt';c.render();
  assert.equal(document.querySelector('.receipt-content .web-link')!.getAttribute('href'),'https://example.com/');
  assert.equal(document.querySelector('.receipt-content b'),null);
});

test('short and long received text uses a full drag surface and whole-message copy without selection input',()=>{
  const {c,document,render}=fixture();c.render=render;
  for(const text of ['短文字','完整长文\n'.repeat(150)]){
    c.events=[textEvent('incoming',false,text)];c.render();
    document.querySelector<HTMLButtonElement>('[data-read="incoming"]')!.click();
    const field=document.querySelector<HTMLPreElement>('#reader-text')!;
    assert.equal(field.tagName,'PRE');assert.equal(field.textContent,text);
    assert.equal(field.closest('[data-drag-text]'),document.querySelector('.reader-modal'));
    assert.equal(document.querySelector('[data-action="save-reader"]'),null);
    let copied='';c.copy=(value:string)=>{copied=value;};
    document.querySelector<HTMLButtonElement>('[data-action="copy-reader"]')!.click();
    assert.equal(copied,text);
    assert.equal(document.querySelector('[data-action="select-reader"]'),null);
    assert.equal(document.querySelector('[data-action="copy-reader"]')!.textContent!.trim(),'复制');
    document.querySelector<HTMLButtonElement>('[data-action="close-modal"]')!.click();
  }
});

test('sent-message editing patches the original identity after target presence changes and never posts a new message',async()=>{
  const {c,document,render,Event,session}=fixture();c.render=render;
  const original=textEvent('outgoing',true);c.events=[original];
  c.devices=[{deviceId:'sender',name:'原收件人',platform:'android',online:true},{deviceId:'other',name:'另一设备',platform:'web',online:true}];
  c.target='sender';c.text='另一个未发送草稿';c.modal='history';c.render();
  document.querySelector<HTMLButtonElement>('[data-read="outgoing"]')!.click();
  const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;
  assert.equal(field.readOnly,false);assert.equal(document.querySelector('.reader-modal [data-target-select]'),null);
  field.value='修改原消息';field.dispatchEvent(new Event('input'));
  c.devices[0].online=false;c.selectOnlineTarget();c.render();
  assert.equal(c.target,'other');assert.equal(document.querySelector('#reader-text'),field);
  assert.match(document.querySelector('.reader-meta')!.textContent!,/原收件人/);
  const calls:any[]=[];
  c.api.request=async(path:string,body:any,method:string)=>{calls.push({path,body,method});return {event:textUpdate(original,body.text)};};
  await c.saveViewedText();
  assert.deepEqual(calls.map(call=>[call.path,call.method,call.body.text]),[['/texts/outgoing','PATCH','修改原消息']]);
  assert.equal('targetDeviceId' in calls[0].body,false);
  assert.equal(c.text,'另一个未发送草稿');assert.equal(c.pendingTexts.length,0);
  assert.equal(c.events.filter((event:any)=>event.type==='text.created').length,1);
  assert.equal(c.events.find((event:any)=>event.eventId==='outgoing').payload.text,'修改原消息');
  assert.equal(document.querySelector('#reader-status')!.textContent,'');
  assert.equal(JSON.parse(session.get(c.dockKey)!).events[0].payload.text,'修改原消息');
});

test('an in-flight text save preserves later typing, selection and scroll; closing keeps the draft without resending',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;
  const original=textEvent('draft',true);c.events=[original];c.openText('draft');
  const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;
  field.value='先保存这一版';field.dispatchEvent(new Event('input'));
  let finish:((value:any)=>void)|undefined,calls=0;
  c.api.request=()=>{calls++;return new Promise(resolve=>{finish=resolve;});};
  const pending=c.saveViewedText();
  assert.equal(document.querySelector<HTMLButtonElement>('[data-action="save-reader"]')!.disabled,true);
  field.value='保存期间继续修改';field.dispatchEvent(new Event('input'));field.setSelectionRange(2,6,'backward');field.scrollTop=84;
  c.render();assert.equal(document.querySelector('#reader-text'),field);assert.equal(field.scrollTop,84);
  finish!({event:textUpdate(original,'先保存这一版')});await pending;
  assert.equal(field.value,'保存期间继续修改');assert.equal(field.selectionStart,2);assert.equal(field.selectionEnd,6);
  assert.equal(field.selectionDirection,'backward');assert.equal(field.scrollTop,84);
  assert.equal(c.events[0].payload.text,'先保存这一版');assert.equal(document.querySelector('#reader-status')!.textContent,'未保存');
  document.querySelector<HTMLButtonElement>('[data-action="close-modal"]')!.click();
  assert.equal(calls,1);assert.equal(c.modal,null);c.openText('draft');
  assert.equal(document.querySelector('#reader-text'),field);assert.equal(field.value,'保存期间继续修改');assert.equal(calls,1);
});

test('text save errors keep the draft and distinguish an old center from missing or expired original messages',async()=>{
  const {c,document,render,Event,ApiError}=fixture();c.render=render;c.events=[textEvent('error',true)];c.openText('error');
  const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;
  field.value='不能丢的修改';field.dispatchEvent(new Event('input'));
  for(const [error,message] of [
    [new ApiError(404,'HTTP_ERROR','请求失败 (404)'),/升级中心/],
    [new ApiError(404,'NOT_FOUND','Sent text not found'),/原消息已不存在/],
    [new ApiError(410,'EXPIRED','This message has expired'),/已过期/],
    [new Error('连接中断，请稍后重试'),/连接中断，请稍后重试/],
  ] as const){
    c.api.request=async()=>{throw error;};await c.saveViewedText();
    assert.equal(field.value,'不能丢的修改');assert.equal(document.querySelector('#reader-text'),field);
    assert.match(document.querySelector('#reader-status')!.textContent!,message);
    assert.equal(c.events[0].payload.text,'原始文字');
  }
});

test('message-editor IME blocks save clicks and shortcuts, preserves composition during refresh, and saves once after commit',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;const original=textEvent('ime',true);c.events=[original];c.openText('ime');
  const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;
  let calls=0;c.api.request=async(_path:string,body:any)=>{calls++;return {event:textUpdate(original,body.text)};};
  field.dispatchEvent(new Event('compositionstart'));field.value='中文拼';field.dispatchEvent(new Event('input'));
  c.render();assert.equal(c.editorRenderPending,true);assert.equal(field.isConnected,true);
  await c.saveViewedText();assert.equal(calls,0);
  const key=(name:string,composing:boolean)=>{const event=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(event,{key:name,ctrlKey:true,metaKey:false,isComposing:composing,keyCode:composing?229:13});field.dispatchEvent(event);return event;};
  key('Enter',true);key('Escape',true);assert.equal(calls,0);assert.equal(c.modal,'reader');
  field.value='中文已提交';field.dispatchEvent(new Event('compositionend'));
  assert.equal(c.editorRenderPending,false);assert.equal(document.querySelector('#reader-text'),field);
  assert.equal(key('Enter',false).defaultPrevented,true);await new Promise(resolve=>setImmediate(resolve));
  assert.equal(calls,1);assert.equal(c.events[0].payload.text,'中文已提交');
});

test('a late edit response and detached input cannot restore a previous group draft',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;const original=textEvent('old-group',true);c.events=[original];c.openText('old-group');
  const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;field.value='旧组修改';field.dispatchEvent(new Event('input'));
  let finish:((value:any)=>void)|undefined;c.api.request=()=>new Promise(resolve=>{finish=resolve;});
  const pending=c.saveViewedText();c.signOut();
  c.session={deviceToken:'new',device:{deviceId:'receiver',name:'新设备'},groupId:'new'};c.events=[textEvent('new-group',true,'新组内容')];
  field.value='迟到的输入';field.dispatchEvent(new Event('input'));
  finish!({event:textUpdate(original,'旧组修改')});await pending;
  assert.equal(c.textViews.size,0);assert.equal(c.readingEventId,'');assert.equal(c.events.length,1);assert.equal(c.events[0].eventId,'new-group');
});

test('recipient replay updates the original open read-only viewer and card without creating a duplicate',async()=>{
  const {c,document,render,refresh}=fixture();c.render=render;
  const original=textEvent('received-replay',false,'收到旧文字');c.events=[original];c.openText(original.eventId);
  const field=document.querySelector<HTMLPreElement>('#reader-text')!;field.scrollTop=30;
  c.api.request=async(path:string)=>path==='/devices'?{devices:[]}:path==='/transfers'?{transfers:[]}:
    path.startsWith('/events?')?{events:[textUpdate(original,'收到修订后的完整文字')],cursor:2,hasMore:false}:{};
  await refresh();
  assert.equal(document.querySelector('#reader-text'),field);assert.equal(field.tagName,'PRE');assert.equal(field.textContent,'收到修订后的完整文字');
  assert.equal(field.scrollTop,30);assert.equal(document.querySelectorAll('.text-card [data-read]').length,1);
  assert.equal(document.querySelector('[data-read="received-replay"]')!.textContent,'收到修订后的完整文字');
  let copied='';c.copy=(text:string)=>{copied=text;};document.querySelector<HTMLButtonElement>('[data-action="copy-reader"]')!.click();
  assert.equal(copied,'收到修订后的完整文字');
});

test('expiry keeps an open unsaved edit available to copy but disables saving',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;const original=textEvent('expires',true);c.events=[original];c.openText('expires');
  const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;field.value='到期前的未存草稿';field.dispatchEvent(new Event('input'));
  original.expiresAt=new Date(0).toISOString();c.render();
  assert.equal(c.modal,'reader');assert.equal(document.querySelector('#reader-text'),field);assert.equal(field.value,'到期前的未存草稿');
  assert.match(document.querySelector('#reader-status')!.textContent!,/已过期/);
  let calls=0;c.api.request=async()=>{calls++;};await c.saveViewedText();assert.equal(calls,0);
});


test('shared collaboration syncs silently and a focused shared field stays connected across workspace updates',()=>{
  const {c,document,render}=fixture();c.render=render;c.info.features={groupSharedText:true};c.render();
  c.shared.receive({text:'initial',revision:1,updatedAt:'',updatedBy:'sender'});
  const field=document.querySelector('#shared-group-text')!;
  Object.defineProperty(document,'activeElement',{configurable:true,value:field});
  c.shared.receive({text:'remote edit',revision:2,updatedAt:'',updatedBy:'sender'});
  c.render();
  assert.equal(field.isConnected,true);assert.equal(document.querySelector('#shared-group-text'),field);
  assert.equal((field as HTMLTextAreaElement).value,'remote edit');
  assert.equal(c.modal,null);assert.equal(c.pendingReceipt,null);assert.equal(c.receipt,null);
  c.showReceipt({id:'ordinary',version:'1',source:'sender',title:'message',text:'ordinary text'});
  assert.equal(c.modal,null);assert.equal(c.pendingReceipt.text,'ordinary text');
  Object.defineProperty(document,'activeElement',{configurable:true,value:null});c.render();
  assert.equal(c.modal,'receipt');assert.equal(c.receipt.text,'ordinary text');
});

test('receipt batches retain every pending item, update one text card and end without deleting history',()=>{
  const {c,document,render}=fixture();c.render=render;c.toggleEditor(true);
  c.showReceipt({id:'a',version:'1',source:'sender',title:'发来一条文本',text:'first'});
  c.showReceipt({id:'b',version:'2',source:'sender',title:'发来一条文本',text:'second'});
  c.showReceipt({id:'a',version:'3',source:'sender',title:'文本已更新',text:'edited first'});
  c.showReceipt({id:'a',version:'1',source:'sender',title:'late replay',text:'stale first'});
  assert.equal(c.modal,'editor');assert.equal(c.receiptBatch.size,2);
  c.toggleEditor(false);
  assert.equal(c.modal,'receipt');assert.equal(document.querySelectorAll('.receipt-batch-grid [data-receipt-id]').length,2);
  assert.match(document.querySelector('[data-receipt-id="a"]')!.textContent!,/edited first/);
  document.querySelector<HTMLButtonElement>('[data-view-receipt="b"]')!.click();
  assert.match(document.querySelector('.receipt-content')!.textContent!,/second/);
  document.querySelector<HTMLButtonElement>('[data-action="receipt-grid"]')!.click();
  assert.equal(document.querySelectorAll('.receipt-batch-grid [data-receipt-id]').length,2);
  const before=c.events;c.closeModal();assert.equal(c.modal,null);assert.equal(c.receiptBatch.size,0);assert.deepEqual(c.events,before);
  c.showReceipt({id:'a',version:'3',source:'sender',title:'same',text:'edited first'});assert.equal(c.modal,null);
  c.showReceipt({id:'a',version:'4',source:'sender',title:'new edit',text:'new batch'});assert.equal(c.receiptBatch.size,1);assert.ok(document.querySelector('.receipt-single-grid'));
});

test('file receipt offered through received remains one card beside ordinary messages',()=>{
  const {c,document,render}=fixture();c.render=render;
  const incoming=transfer('batch-file','offered');c.transfers=[incoming];
  c.noticeFile(incoming,incoming.files[0]);
  c.showReceipt({id:'text',version:'1',source:'sender',title:'文本',text:'message'});
  assert.equal(c.receiptBatch.size,2);
  for(const status of ['accepted','uploading','ready','received']){c.setFile(incoming.transferId,{...incoming.files[0],status});c.render();assert.equal(c.receiptBatch.size,2);}
  assert.equal(document.querySelectorAll('[data-receipt-id="batch-file:file-batch-file"]').length,1);
  assert.match(document.querySelector('[data-receipt-id="batch-file:file-batch-file"]')!.getAttribute('aria-label')!,/sample.txt/);
  assert.doesNotMatch(document.querySelector('[data-receipt-id="batch-file:file-batch-file"]')!.textContent!,/已保存|查看/);
});

test('receive select-all includes mixed file types, copy counts text only and does not touch send target selection',()=>{
  const {c,document,render}=fixture();c.render=render;
  const now=new Date().toISOString(),expiresAt=new Date(Date.now()+60000).toISOString();
  c.events=['a','b'].map((eventId,index)=>({eventId,type:'text.created',cursor:index+1,sourceDeviceId:'sender',targetDeviceId:'receiver',createdAt:now,expiresAt,payload:{text:eventId}}));
  const file=transfer('mixed','received');file.files.push({...file.files[0],fileId:'image',name:'photo.png',mimeType:'image/png'});c.transfers=[file];
  c.selectedTargets.add('sender');c.receiveSelecting=true;c.render();c.toggleAllReceive();
  assert.equal(c.selected.size,4);assert.equal(c.selectedTextCount(),2);assert.equal(c.allReceiveSelected(),true);
  assert.equal(c.selectedTargets.size,1);assert.equal(c.multiSend,false);
  assert.equal(document.querySelectorAll('.dock-items [role="checkbox"]').length,4);
  assert.equal(document.querySelectorAll('.dock-items .content-card[draggable="true"]').length,4);
  assert.equal(document.querySelector('[data-action="copy-selected"]')!.textContent,'复制 2');
  let copied='';c.copy=(text:string)=>{copied=text;};c.copySelected();assert.equal(copied,'a\n\nb');
  c.toggleAllReceive();assert.equal(c.selected.size,0);assert.equal(c.selectedTextCount(),0);
  c.filter='files';c.toggleAllReceive();assert.equal(c.selected.size,2);assert.equal(c.selectedTextCount(),0);
  assert.equal(document.querySelector('[data-action="copy-selected"]')!.hasAttribute('disabled'),true);
});

test('bulk receive delete removes only selected records and local file cache, preserving unselected and active transfers',()=>{
  const {c}=fixture();const now=new Date().toISOString(),expiresAt=new Date(Date.now()+60000).toISOString();
  c.events=['keep','remove'].map((eventId,index)=>({eventId,type:'text.created',cursor:index+1,sourceDeviceId:'sender',targetDeviceId:'receiver',createdAt:now,expiresAt,payload:{text:eventId}}));
  const removed=transfer('remove-file','received'),kept=transfer('keep-file','received'),active=transfer('active-file','uploading');c.transfers=[removed,kept,active];
  kept.files[0].sha256='b'.repeat(64); // distinct contents must remain after deleting another group
  c.rtcLocalFiles.set('remove-file:file-remove-file',new File(['owned'],'owned.txt'));c.rtcLocalFiles.set('keep-file:file-keep-file',new File(['keep'],'keep.txt'));
  const removedKeys:string[]=[];c.rtcStore={remove:async(key:string)=>{removedKeys.push(key);}};
  c.selected=new Set(['remove','file:remove-file:file-remove-file','file:active-file:file-active-file']);
  c.deleteSelectedReceive();
  assert.deepEqual(Array.from(c.receivedTexts(),(item:any)=>item.eventId),['keep']);
  assert.equal(c.visibleFiles(removed).length,0);assert.equal(c.visibleFiles(kept).length,1);assert.equal(c.visibleFiles(active).length,1);
  assert.deepEqual(removedKeys,['remove-file:file-remove-file']);assert.equal(c.rtcLocalFiles.has('keep-file:file-keep-file'),true);
  assert.equal(c.selected.size,1);assert.equal(c.selected.has('file:active-file:file-active-file'),true);
});

test('receive toolbar offers all/delete/cancel and cancelling restores normal card interactions',()=>{
  const {c,document,render}=fixture();c.render=render;c.receiveSelecting=true;c.render();
  assert.ok(document.querySelector('[data-action="receive-select-all"]'));assert.ok(document.querySelector('[data-action="receive-delete-selected"]'));
  c.selected.add('temporary');document.querySelector<HTMLButtonElement>('[data-action="receive-multi-select"]')!.click();
  assert.equal(c.receiveSelecting,false);assert.equal(c.selected.size,0);assert.equal(document.querySelector('[data-action="receive-delete-selected"]'),null);
  assert.equal(document.querySelector('[data-action="receive-multi-select"]')!.textContent,'多选');
});
test('identical text and file cards merge without losing deliveries and deleting a group does not reveal old duplicates',()=>{
  const {c}=fixture(),now=new Date().toISOString(),expiresAt=new Date(Date.now()+60000).toISOString();
  c.events=['a','b'].map((eventId,index)=>({eventId,type:'text.created',cursor:index+1,sourceDeviceId:'sender',targetDeviceId:'receiver',createdAt:now,expiresAt,payload:{text:'same'}}));
  assert.equal(c.displayTexts(false).length,1);assert.equal(c.events.length,2);
  c.hideText(c.displayTexts(false)[0].eventId);assert.equal(c.displayTexts(false).length,0);
  const first=transfer('first','received'),second=transfer('second','received');c.transfers=[first,second];
  c.rtcLocalFiles.set('first:file-first',new File(['same'],'first.txt'));c.rtcLocalFiles.set('second:file-second',new File(['same'],'second.txt'));
  c.rtcStore={remove:async()=>{}};
  const cards=c.displayTransfers(false).flatMap((item:any)=>item.files.map((file:any)=>({item,file})));assert.equal(cards.length,1);
  c.hideFile(cards[0].item.transferId,cards[0].file.fileId);assert.equal(c.displayTransfers(false).flatMap((item:any)=>item.files).length,0);
});
test('directory change pauses new receives and refreshes staged, sent and received file snapshots before resuming',async()=>{
  const {c,context}=fixture(),old=new File(['old'],'saved.txt'),next=new File(['new'],'saved.txt');
  context.setTimeout=setTimeout as any;
  c.picked=[old];c.rtcLocalFiles.set('transfer:file',old);c.fileSources.set('transfer:file',old);c.retainedSources.set('transfer:file',old);
  c.rtcReceives.set('active',new AbortController());let changed=false,refreshed=false,resumed=false;
  c.ensureFileStore=async()=>({scope:'scope',setDestination:async()=>{assert.equal(c.rtcReceives.size,0);changed=true;return {name:'chosen',relocated:[{scope:'scope',key:'transfer:file'}]};},get:async()=>next});
  c.fileLibrary.service={get:async()=>next};c.fileLibrary.refreshLocations=async()=>{refreshed=true;};
  c.startReadyUploads=()=>{};c.selectIncomingRelays=async()=>{resumed=true;};
  const move=c.changeReceiveDirectory({});assert.equal(c.receiveDirectoryChanging,true);assert.equal(changed,false);
  c.rtcReceives.clear();await move;
  assert.equal(c.picked[0],next);assert.equal(c.fileSources.get('transfer:file'),next);assert.equal(c.retainedSources.get('transfer:file'),next);
  assert.equal(c.receiveDestination,'chosen');assert.equal(refreshed,true);assert.equal(resumed,true);assert.equal(c.receiveDirectoryChanging,false);
});
test('file scheduling defaults to four shared send/receive slots and persists live concurrency changes',()=>{
  const {c}=fixture();c.selectIncomingRelays=async()=>{};
  assert.equal(c.transferConcurrency,4);
  c.transfers=Array.from({length:8},(_,index)=>{const item=transfer('parallel-'+index,'accepted','relay','relay');item.sourceDeviceId=c.session.device.deviceId;return item;});
  for(const item of c.transfers)c.fileSources.set(item.transferId+':'+item.files[0].fileId,new File(['data'],'sample.txt'));
  c.uploadFile=async(transferId:string,fileId:string)=>{c.uploads.set(transferId+':'+fileId,new AbortController());};
  c.startReadyUploads();assert.equal(c.uploads.size,4);
  c.setTransferConcurrency(6);assert.equal(c.uploads.size,6);
  c.setTransferConcurrency(2);assert.equal(c.uploads.size,6,'lowering the limit leaves running files intact');
  c.loadPreferences();assert.equal(c.transferConcurrency,2);
  c.uploads.clear();c.rtcReceives.set('receive-a',new AbortController());c.rtcReceives.set('receive-b',new AbortController());
  c.startReadyUploads();assert.equal(c.uploads.size,0);
  c.setTransferConcurrency(4);assert.equal(c.uploads.size,2);assert.equal(c.activeFileTransfers,4);
});
test('desktop content tabs live in the right header beside compact connection/settings controls, not inside the content pane',()=>{
  const {c,document,render}=fixture();c.render=render;c.render();
  const navigation=document.querySelector('.topbar .right-header .content-tabs');assert.ok(navigation);
  assert.deepEqual(Array.from(navigation!.querySelectorAll('button'),button=>button.textContent),['接收','已发送','文件库']);
  assert.equal(document.querySelector('.dock-panel .content-tabs'),null);
  assert.ok(document.querySelector('.right-header [data-action="connection"]'));assert.ok(document.querySelector('.right-header [data-action="settings"]'));
  assert.equal(document.querySelectorAll('.mobile-view-tabs button').length,4);
  document.querySelector<HTMLButtonElement>('[data-content-view="sent"]')!.click();assert.equal(c.contentView,'sent');
});
test('Web file menu starts with open and keeps delete and details as its last actions',()=>{
  const {c,document,render}=fixture();c.render=render;
  c.contextMenu={kind:'file',key:'transfer:file',x:20,y:20};c.render();
  const labels=Array.from(document.querySelectorAll('[data-card-command]'),button=>button.textContent);
  assert.equal(labels[0],'打开');assert.deepEqual(labels.slice(-2),['删除','详情']);
});
test('bulk drag exports all forty local files and stages the entire batch on an internal queue drop',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.preparePreview=async()=>{};
  c.transfers=Array.from({length:40},(_,index)=>{const item=transfer('bulk-'+index,'received');item.files[0].sha256=String(index).padStart(64,'0');return item;});
  for(const item of c.transfers)c.rtcLocalFiles.set(item.transferId+':'+item.files[0].fileId,new File(['data'],item.transferId+'.bin'));
  c.installWindowDrop();c.render();const files:File[]=[];
  const data={types:[] as string[],values:new Map<string,string>(),effectAllowed:'',dropEffect:'',items:{add:(file:File)=>files.push(file)},setData(type:string,value:string){this.values.set(type,value);this.types.push(type);},getData(type:string){return this.values.get(type) || '';},setDragImage:()=>{}};
  const start=new Event('dragstart',{bubbles:true,cancelable:true});Object.assign(start,{dataTransfer:data});document.querySelector('[data-drag-all="receive"]')!.dispatchEvent(start);
  assert.equal(files.length,40);assert.equal(data.effectAllowed,'copy');assert.ok(document.querySelector('.drag-ghost'));
  const drop=new Event('drop',{bubbles:true,cancelable:true});Object.assign(drop,{dataTransfer:data});document.querySelector('[data-queue-drop]')!.dispatchEvent(drop);
  assert.equal(c.picked.length,40);
});

test('receive selection cards expose only the checkbox action and normal mode restores ordinary controls',()=>{
  const {c,document,render}=fixture();c.render=render;c.receiveSelecting=true;
  c.events=[{eventId:'clean-mode',type:'text.created',cursor:1,sourceDeviceId:'sender',targetDeviceId:'receiver',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),payload:{text:'正文 https://example.com'}}];
  const file=transfer('clean-file','received');file.files[0].name='photo.png';file.files[0].mimeType='image/png';c.transfers=[file];c.render();
  assert.equal(document.querySelectorAll('.dock-items [role="checkbox"]').length,2);
  assert.equal(document.querySelectorAll('.dock-items .card-actions,.dock-items [data-card-menu],.dock-items button,.dock-items a[href],.dock-items input').length,0);
  assert.equal(document.querySelectorAll('.dock-items .receive-select-indicator').length,2);
  assert.match(document.querySelector('[data-receive-key="clean-mode"]')!.getAttribute('aria-label')!,/选择文本：正文/);assert.match(document.querySelector('[data-receive-key="file:clean-file:file-clean-file"]')!.getAttribute('aria-label')!,/选择文件：photo.png/);
  assert.match(c.fileHtml(file,file.files[0],true),/data-card-menu/,'send history keeps its normal actions');
  c.receiveSelecting=false;c.render();
  assert.equal(document.querySelectorAll('.dock-items [role="checkbox"]').length,0);
  assert.equal(document.querySelectorAll('.dock-items [data-card-menu]').length,2);
  assert.ok(document.querySelector('.dock-items [data-copy]'));assert.equal(document.querySelector('.dock-items [data-hide-text]'),null);assert.equal(document.querySelector('.dock-items [data-download]'),null);assert.ok(document.querySelector('.dock-items [data-open-file]'));assert.ok(document.querySelector('.dock-items a[href]'));
  document.querySelector<HTMLElement>('.dock-items [data-card-menu]')!.click();assert.ok(document.querySelector('[data-card-command="delete"]'));assert.ok(document.querySelector('[data-card-command="requeue"]'));
});

test('text metadata counts Unicode code points across staging, received cards and editors',()=>{
  const {c,document,render,Event}=fixture();c.render=render;const text='中A😀𝄞';
  c.stagedTexts=[{id:'unicode-stage',text}];c.events=[{eventId:'unicode',type:'text.created',cursor:1,sourceDeviceId:'sender',targetDeviceId:'receiver',createdAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),payload:{text}}];c.render();
  assert.match(document.querySelector('.staged-description')!.textContent!,/4 字符/);assert.equal(document.querySelector('.text-card .card-meta'),null);assert.match(document.querySelector('.text-card')!.textContent!,/中A😀𝄞/);
  c.toggleEditor(true);const field=document.querySelector<HTMLTextAreaElement>('#send-text')!;field.value=text;field.dispatchEvent(new Event('input'));assert.equal(document.querySelector('#text-count')!.textContent,'4 字符');
});

test('sent target feedback is distinct from selected targets and confirmation exposes complete device names',()=>{
  const {c,document,render}=fixture();c.render=render;c.multiSend=true;c.stagedTexts=[{id:'payload',text:'正文'}];c.devices.push({deviceId:'long-peer',name:'工作室里完整的很长设备名称😀',platform:'windows',online:true});c.selectedTargets=new Set(['sender','long-peer']);
  c.sendBatch={matches:()=>true,targets:new Map([['sender',{state:'sent'}]])};c.render();
  const sent=document.querySelector('[data-target="sender"]')!;assert.equal(sent.getAttribute('aria-pressed'),'false');assert.equal(sent.querySelector('.target-check')!.textContent,'');assert.equal(sent.classList.contains('sent'),true);assert.ok(sent.querySelector('.target-icon svg'));assert.doesNotMatch(sent.textContent!,/已发送/);
  assert.match(document.querySelector('.target-selection-summary')!.textContent!,/工作室里完整的很长设备名称😀/);assert.match(document.querySelector('[data-target="long-peer"]')!.getAttribute('aria-label')!,/工作室里完整的很长设备名称😀/);
});

test('settings fields preserve their live IME node through a reconciliation',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.openSettings();
  const field=document.querySelector<HTMLInputElement>('#device-display-name')!;
  field.dispatchEvent(new Event('compositionstart',{bubbles:true}));field.value='设备名😀';field.dispatchEvent(new Event('input',{bubbles:true}));c.render();
  assert.equal(document.querySelector('#device-display-name'),field);assert.equal(field.isConnected,true);
  field.dispatchEvent(new Event('compositionend',{bubbles:true}));c.render();assert.equal((document.querySelector('#device-display-name') as HTMLInputElement).value,'设备名😀');
});

test('library Escape during an IME composition does not dismiss the form',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.modal='library';c.fileLibrary.opened=true;c.render();
  const root=document.querySelector('.file-library-modal')!;const event=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(event,{key:'Escape',isComposing:true});root.dispatchEvent(event);assert.equal(c.modal,'library');
  const close=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(close,{key:'Escape',isComposing:false,keyCode:27});root.dispatchEvent(close);assert.equal(c.modal,null);
});

test('desktop actions and right-side page tabs have separate ownership and leave the queue intact',async()=>{
  const {c,document,render}=fixture();c.render=render;savedLibrary(c,[savedEntry()]);c.stagedTexts=[{id:'keep',text:'下一轮内容'}];c.render();
  assert.equal(document.querySelectorAll('.topbar .compose-action').length,2);assert.equal(document.querySelector('.topbar [data-action="history"]'),null);
  document.querySelector<HTMLElement>('[data-content-view="sent"]')!.click();assert.equal(c.contentView,'sent');assert.equal(c.modal,null);assert.equal(c.stagedTexts[0].text,'下一轮内容');
  await c.openLibrary();assert.equal(c.contentView,'library');assert.ok(document.querySelector('.right-content .embedded-library'));assert.equal(document.querySelector('.modal-backdrop'),null);
});

test('queue blank click opens a focused composer while an existing card edits its own draft',()=>{
  const {c,document,render}=fixture();c.render=render;c.render();document.querySelector<HTMLElement>('.queue-empty')!.click();assert.equal(c.modal,'editor');assert.ok(document.querySelector('#send-text'));
  c.toggleEditor(false);c.stagedTexts=[{id:'existing',text:'原来的内容'}];c.render();document.querySelector<HTMLElement>('[data-edit-staged]')!.click();assert.equal(c.text,'原来的内容');assert.equal(c.editingStagedId,'existing');
});

test('normal shared synchronization is silent and only failure or conflict is surfaced',()=>{
  const {c}=fixture();c.shared.loaded=true;assert.equal(c.shared.status(),'');c.shared.dirty=true;assert.equal(c.shared.status(),'');c.shared.saving=true;assert.equal(c.shared.status(),'');c.shared.error='连接中断';assert.equal(c.shared.status(),'未同步');c.shared.conflict=true;assert.match(c.shared.status(),/未同步.*冲突/);
});

test('image cards keep the image dominant and filename accessible without a visible filename row',()=>{
  const {c,document,render}=fixture();c.render=render;const t=transfer('photo','received');t.files[0].name='1000060721.png';t.files[0].mimeType='image/png';c.transfers=[t];c.render();
  const card=document.querySelector('.image-card')!;assert.ok(card);assert.equal(card.querySelector('.card-name'),null);assert.match(card.getAttribute('aria-label')!,/1000060721.png/);assert.equal(card.querySelector('.image-card-footer'),null);assert.equal(card.querySelector('[data-action="view"]'),null);assert.ok(card.querySelector('[data-card-menu]'));
});

test('a successful target briefly shows a check and restores the ordinary device without another send action',async()=>{
  const {c,context,document,render}=fixture();c.render=render;let now=Date.now();context.Date=class extends Date{static now(){return now;}};c.stagedTexts=[{id:'one',text:'正文'}];c.api.request=async()=>({});await c.sendQueue(['sender']);
  assert.equal(c.stagedTexts.length,0);assert.equal(c.targetState('sender'),'sent');now+=3000;c.render();assert.equal(c.targetState('sender'),'');assert.equal(document.querySelector('[data-target="sender"]')!.classList.contains('sent'),false);
});

test('switching groups preserves local messages and File references without replaying old credentials',async()=>{
  const {c,document,render,Event,persistent}=fixture();c.render=render;c.session.deviceToken='old-secret-token';c.events=[textEvent('old-own',true,'原文'),textEvent('old-incoming',false,'旧接收')];const t=transfer('old-file','received');c.transfers=[t];const file=new File(['saved'],'保留文件.txt');c.fileSources.set('old-file:file-old-file',file);c.persist();c.signOut();
  c.session={deviceToken:'new-secret-token',device:{deviceId:'new-device',name:'同一用户',platform:'web'},groupId:'new-group'};c.api.session=c.session;c.loadPreferences();let requests=0;c.api.request=async()=>{requests++;throw new Error('old history must remain local');};
  assert.equal(c.receivedTexts()[0].payload.text,'旧接收');assert.equal(c.displayTexts(true)[0].payload.text,'原文');assert.equal(c.localFile('old-file:file-old-file'),file);
  c.openText('old-own');const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;assert.equal(field.readOnly,false);field.value='本地修改';field.dispatchEvent(new Event('input'));await c.saveViewedText();assert.equal(c.localEvent('old-own').payload.text,'本地修改');assert.equal(requests,0);
  const archive=persistent.get('globalsend:local-history')!;assert.doesNotMatch(archive,/old-secret-token|new-secret-token|deviceToken/);
});

test('internal card drag has a copy preview and only the queue accepts it for another send',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.events=[textEvent('again',false,'再发一次')];c.installWindowDrop();c.render();
  const transfer={types:[] as string[],values:new Map<string,string>(),effectAllowed:'',dropEffect:'',items:{add:()=>{}},setData(type:string,value:string){this.values.set(type,value);this.types.push(type);},getData(type:string){return this.values.get(type) || '';},setDragImage:()=>{}};
  const start=new Event('dragstart',{bubbles:true,cancelable:true});Object.assign(start,{dataTransfer:transfer});document.querySelector<HTMLElement>('[data-drag-text="again"]')!.dispatchEvent(start);assert.equal(transfer.effectAllowed,'copy');assert.ok(document.querySelector('.drag-ghost'));assert.equal(transfer.values.get('text/plain'),'再发一次');
  const over=new Event('dragover',{bubbles:true,cancelable:true});Object.assign(over,{dataTransfer:transfer});document.querySelector('[data-queue-drop]')!.dispatchEvent(over);assert.equal(over.defaultPrevented,true);assert.equal(transfer.dropEffect,'copy');
  const drop=new Event('drop',{bubbles:true,cancelable:true});Object.assign(drop,{dataTransfer:transfer});document.querySelector('[data-queue-drop]')!.dispatchEvent(drop);assert.equal(c.stagedTexts.length,1);assert.equal(c.stagedTexts[0].text,'再发一次');assert.equal(c.events[0].payload.text,'再发一次');
});

test('auto route actually attempts both scopes within one decision, aborts signaling and ignores a late first response',async()=>{
  const {c,context}=fixture(),t=transfer('budget','accepted');t.files[0].size=20;c.transfers=[t];c.devices[0].rtc={scopes:['lan','public'],expiresAt:new Date(Date.now()+60000).toISOString()};
  context.setTimeout=setTimeout;context.clearTimeout=clearTimeout;context.window.setTimeout=setTimeout;c.ensureRtc=async()=>{};c.rtcStore={get:async()=>undefined,open:async()=>9,close:async()=>{},remove:async()=>{}};
  const calls:{scope:string;offset:number;signal:AbortSignal}[]=[];let relayAt=0;const start=Date.now();
  context.fetch=async(url:string,options:any)=>{
    if(url.endsWith('/relay')){relayAt=Date.now();return {ok:true,json:async()=>({file:{...t.files[0],transport:'relay'}})};}
    const body=JSON.parse(options.body);calls.push({...body,signal:options.signal});
    if(body.scope==='lan')return new Promise(resolve=>setTimeout(()=>resolve({ok:true,json:async()=>({rtc:{attemptId:'late-old'}})}),650));
    return new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(new DOMException('aborted','AbortError')),{once:true}));
  };
  await c.receiveRtc(t,t.files[0]);assert.deepEqual(calls.map(call=>call.scope),['lan','public']);assert.deepEqual(calls.map(call=>call.offset),[9,9]);assert.ok(calls.every(call=>call.signal.aborted));assert.ok(relayAt-start>=850 && relayAt-start<1600);assert.equal(c.transfers[0].files[0].transport,'relay');assert.notEqual(c.transfers[0].files[0].rtc?.attemptId,'late-old');
});

test('manual direct mode never silently falls back to relay',async()=>{
  const {c,context}=fixture(),t=transfer('forced','accepted','lan');c.transfers=[t];c.devices[0].rtc={scopes:['lan','public'],expiresAt:new Date(Date.now()+60000).toISOString()};c.ensureRtc=async()=>{};c.rtcStore={get:async()=>undefined,open:async()=>0,close:async()=>{}};let relay=false;
  context.fetch=async(url:string)=>{if(url.endsWith('/relay'))relay=true;throw new Error('no direct path');};await c.receiveRtc(t,t.files[0]);assert.equal(relay,false);assert.ok(c.uploadErrors.has('forced:file-forced'));
});


test('explicit discovery refresh coalesces and republishes before reading device snapshots and regathering probes',async()=>{
  const {c}=fixture(),calls:string[]=[];let release!:()=>void;
  c.rtcRegisteredAt=Date.now();
  c.rtcProbes={setForeground:async(value:boolean)=>{calls.push(value?'regather':'invalidate');if(!value)await new Promise<void>(resolve=>release=resolve);},refreshAllPeers:async()=>{calls.push('probe-all');}};
  c.ensureRtc=async()=>{assert.equal(c.rtcRegisteredAt,0);calls.push('publish-rtc');};
  c.refresh=async()=>{calls.push('snapshot');};c.syncProbeMonitor=()=>{calls.push('monitor');};c.probeForeground=()=>true;
  const first=c.refreshDiscovery(),second=c.refreshDiscovery();assert.deepEqual(calls,['invalidate']);release();await Promise.all([first,second]);
  assert.deepEqual(calls,['invalidate','publish-rtc','snapshot','monitor','regather','probe-all']);assert.equal(c.discoveryRefresh,null);
  await c.refreshDiscovery();assert.equal(calls.length,6,'duplicate focus events within debounce do not publish again');
});

test('device-change broadcasts reread snapshots without republishing this device',async()=>{
  const {c,connect}=fixture();c.ws=null;let snapshots=0,published=0;
  c.api.request=async()=>({ticket:'ticket'});c.refresh=async()=>{snapshots++;};c.ensureRtc=async()=>{published++;};c.refreshDiscovery=async()=>{published++;};
  connect();for(let i=0;i<4;i++)await Promise.resolve();const socket=c.ws;assert.ok(socket);
  socket.onmessage({data:JSON.stringify({type:'devices.changed'})});for(let i=0;i<4;i++)await Promise.resolve();assert.equal(snapshots,1);assert.equal(published,0);
});


test('transient sent feedback never disables selecting that device for a new batch',()=>{
  const {c,document,render,context}=fixture();c.render=render;c.multiSend=true;c.stagedTexts=[{id:'next',text:'下一批'}];
  c.sentFeedback.set('sender',Date.now()+2500);c.selectedTargets.add('sender');c.render();
  const target=document.querySelector('[data-target="sender"]')!;assert.equal(target.hasAttribute('disabled'),false);assert.equal(target.getAttribute('aria-pressed'),'true');assert.equal(target.classList.contains('sent'),true);
});


test('explicit RTC publication requests a broadcast only when the center advertises discoveryRefresh',async()=>{
  for(const advertised of [false,true]){
    const {c,context}=fixture();Object.defineProperty(c,'rtcEnabled',{value:true});c.info.features={discoveryRefresh:advertised};
    c.rtcStore={cleanup:async()=>{}};c.syncProbeMonitor=()=>{};const calls:any[]=[];
    context.fetch=async(_url:string,options:any)=>{calls.push(JSON.parse(options.body));return {ok:true,json:async()=>({})};};
    await c.ensureRtc(true);assert.deepEqual(calls[0],{scopes:['lan','public'],...(advertised?{refresh:true}:{})});
    c.rtcRegisteredAt=0;await c.ensureRtc();assert.deepEqual(calls[1],{scopes:['lan','public']});
  }
});

test('reopening restores same-origin OPFS references across groups without old center credentials',async()=>{
  const {c,context}=fixture(),saved=transfer('persisted-file','received','auto','direct');saved.files[0].transport='direct';
  c.transfers=[saved];c.events=[textEvent('persisted-text',false,'旧组文字')];c.archiveLocalContent();
  const cold=new context.module.exports.GlobalSend(),file=new File(['kept'],'sample.txt');cold.render=()=>{};
  let requests=0;cold.api.request=async()=>{requests++;throw new Error('must remain local');};
  cold.fileLibrary.references=async()=>({entries:[{key:'persisted-file:file-persisted-file'}],files:new Map([['persisted-file:file-persisted-file',file]])});
  await cold.restoreLocalReferences();assert.equal(cold.localFile('persisted-file:file-persisted-file'),file);assert.equal(cold.localEvent('persisted-text').payload.text,'旧组文字');assert.equal(requests,0);
  cold.fileLibrary.references=async()=>({entries:[],files:new Map()});await cold.restoreLocalReferences();assert.equal(cold.localTransfer('persisted-file').files.length,0);assert.equal(cold.localEvent('persisted-text').payload.text,'旧组文字');
});


test('coalesced snapshot callers wait for the requested follow-up read rather than an old in-flight snapshot',async()=>{
  const {c,refresh}=fixture();c.refresh=refresh;c.ensureRtc=async()=>{};c.syncProbeMonitor=()=>{};let reads=0,releaseFirst!:()=>void,releaseSecond!:()=>void;
  c.api.request=async(path:string)=>{if(path==='/devices'){reads++;await new Promise<void>(resolve=>{if(reads===1)releaseFirst=resolve;else releaseSecond=resolve;});return {devices:[]};}if(path==='/transfers')return {transfers:[]};return {events:[],cursor:0,hasMore:false};};
  const first=refresh();let joined=false;const waiting=refresh().then(()=>{joined=true;});releaseFirst();await new Promise(resolve=>setImmediate(resolve));assert.equal(reads,2);assert.equal(joined,false);releaseSecond();await Promise.all([first,waiting]);assert.equal(joined,true);
});

test('dragging an editor blank exports its current draft, not the last saved message',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.events=[textEvent('draft-export',true,'原文')];c.openText('draft-export');const field=document.querySelector<HTMLTextAreaElement>('#reader-text')!;field.value='未保存的新正文';field.dispatchEvent(new Event('input'));
  const values=new Map<string,string>(),event=new Event('dragstart',{bubbles:true,cancelable:true});Object.assign(event,{dataTransfer:{items:{add:()=>{}},setData:(type:string,value:string)=>values.set(type,value),setDragImage:()=>{}}});document.querySelector('[data-drag-text="draft-export"]')!.dispatchEvent(event);assert.equal(values.get('text/plain'),'未保存的新正文');assert.equal(c.localEvent('draft-export').payload.text,'原文');
});


function editSharedField(field:HTMLTextAreaElement,Event:any,text:string,start=text.length,end=start,type='insertText'){
  const before=new Event('beforeinput',{bubbles:true,cancelable:true});Object.assign(before,{inputType:type});field.dispatchEvent(before);
  field.value=text;field.setSelectionRange(start,end);const input=new Event('input',{bubbles:true});Object.assign(input,{inputType:type});field.dispatchEvent(input);
}
function sharedKey(field:HTMLTextAreaElement,Event:any,key:string,modifiers:Record<string,boolean>={ctrlKey:true}){
  const event=new Event('keydown',{bubbles:true,cancelable:true});Object.assign(event,{key,...modifiers});field.dispatchEvent(event);return event;
}

test('shared undo and redo buttons and keyboard preserve the field, selection, new-edit branch and synchronized saves',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.info.features={groupSharedText:true};c.render();c.shared.receive({text:'起点',revision:1,updatedAt:'',updatedBy:'sender'});
  const field=document.querySelector<HTMLTextAreaElement>('#shared-group-text')!,undo=()=>document.querySelector<HTMLButtonElement>('[data-shared-action="undo"]')!,redo=()=>document.querySelector<HTMLButtonElement>('[data-shared-action="redo"]')!;
  assert.equal(undo().disabled,true);assert.equal(redo().disabled,true);field.setSelectionRange(1,2,'backward');editSharedField(field,Event,'起修改',3);
  assert.equal(undo().disabled,false);undo().click();assert.equal(field.value,'起点');assert.equal(field.selectionStart,1);assert.equal(field.selectionEnd,2);assert.equal(field.selectionDirection,'backward');assert.equal(redo().disabled,false);
  assert.equal(sharedKey(field,Event,'y').defaultPrevented,true);assert.equal(field.value,'起修改');assert.equal(field.selectionStart,3);
  sharedKey(field,Event,'z',{metaKey:true});assert.equal(field.value,'起点');sharedKey(field,Event,'Z',{metaKey:true,shiftKey:true});assert.equal(field.value,'起修改');
  sharedKey(field,Event,'z');editSharedField(field,Event,'另一条本地编辑');assert.equal(redo().disabled,true);assert.equal(document.querySelector('#shared-group-text'),field);
  const sent:any[]=[];c.api.request=async(_path:string,body:any)=>{sent.push(body);return {text:body.text,revision:sent.length+1,updatedAt:'',updatedBy:'receiver',mutationId:body.mutationId};};
  await c.shared.save();assert.equal(c.shared.canUndo,true);sharedKey(field,Event,'z');await c.shared.save();assert.equal(sent[1].text,'起点');assert.equal(c.shared.dirty,false);
});

test('remote synchronization remains undoable while own ACK and same-content refresh add no false steps',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.info.features={groupSharedText:true};c.render();c.shared.receive({text:'A',revision:1,updatedAt:'',updatedBy:'sender'});const field=document.querySelector<HTMLTextAreaElement>('#shared-group-text')!;
  editSharedField(field,Event,'AB');c.api.request=async(_path:string,body:any)=>{const value={text:body.text,revision:2,updatedAt:'',updatedBy:'receiver',mutationId:body.mutationId};c.shared.receive(value);return value;};await c.shared.save();assert.equal(c.shared.canUndo,true);
  c.shared.receive({text:'AB',revision:2,updatedAt:'',updatedBy:'receiver'});assert.equal(c.shared.canUndo,true);c.shared.receive({text:'远端新正文',revision:3,updatedAt:'',updatedBy:'sender'});assert.equal(c.shared.canUndo,true);assert.equal(c.shared.canRedo,false);
  assert.equal(sharedKey(field,Event,'z').defaultPrevented,true);assert.equal(field.value,'AB');const nativeUndo=new Event('beforeinput',{bubbles:true,cancelable:true});Object.assign(nativeUndo,{inputType:'historyUndo'});field.dispatchEvent(nativeUndo);assert.equal(nativeUndo.defaultPrevented,true);assert.equal(field.value,'A');assert.equal(c.shared.canUndo,false);
  c.shared.redo();assert.equal(field.value,'AB');c.shared.redo();assert.equal(field.value,'远端新正文');
  editSharedField(field,Event,'本地草稿');c.shared.receive({text:'另一设备',revision:4,updatedAt:'',updatedBy:'sender'});assert.equal(c.shared.conflict,true);assert.equal(c.shared.canUndo,true);document.querySelector<HTMLButtonElement>('[data-shared-action="remote"]')!.click();assert.equal(field.value,'另一设备');assert.equal(c.shared.canUndo,true);c.shared.undo();assert.equal(field.value,'本地草稿');c.shared.redo();assert.equal(field.value,'另一设备');assert.equal(document.querySelector('#shared-group-text'),field);
});

test('shared IME is one undo transaction and does not consume composing shortcuts or split the final input',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.info.features={groupSharedText:true};c.render();c.shared.receive({text:'原文',revision:1,updatedAt:'',updatedBy:'sender'});const field=document.querySelector<HTMLTextAreaElement>('#shared-group-text')!;field.setSelectionRange(2,2);
  field.dispatchEvent(new Event('compositionstart'));field.value='原文中';field.dispatchEvent(new Event('input'));field.value='原文中文';field.dispatchEvent(new Event('input'));assert.equal(c.shared.canUndo,false);assert.equal(sharedKey(field,Event,'z',{ctrlKey:true,isComposing:true}).defaultPrevented,false);
  field.dispatchEvent(new Event('compositionend'));editSharedField(field,Event,'原文中文。',6,6,'insertFromComposition');assert.equal(c.shared.canUndo,true);c.shared.undo();assert.equal(field.value,'原文');assert.equal(c.shared.canUndo,false);c.shared.redo();assert.equal(field.value,'原文中文。');assert.equal(document.querySelector('#shared-group-text'),field);
});

test('an undo during an in-flight save remains pending after the own ACK and uses the updated server revision',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.info.features={groupSharedText:true};c.render();c.shared.receive({text:'A',revision:1,updatedAt:'',updatedBy:'sender'});const field=document.querySelector<HTMLTextAreaElement>('#shared-group-text')!;editSharedField(field,Event,'AB');let finish!:(value:any)=>void,body:any;
  c.api.request=async(_path:string,value:any)=>{body=value;return new Promise(resolve=>finish=resolve);};const saving=c.shared.save();c.shared.undo();const ack={text:'AB',revision:2,updatedAt:'',updatedBy:'receiver',mutationId:body.mutationId};c.shared.receive(ack);finish(ack);await saving;assert.equal(field.value,'A');assert.equal(c.shared.dirty,true);assert.equal(c.shared.canRedo,true);
  c.api.request=async(_path:string,value:any)=>{body=value;return {text:value.text,revision:3,updatedAt:'',updatedBy:'receiver',mutationId:value.mutationId};};await c.shared.save();assert.equal(body.baseRevision,2);assert.equal(body.text,'A');
});

test('empty clipboard reads are silent no-ops but genuine permission denial remains actionable',async()=>{
  const {c,context}=fixture();let toasts=0,renders=0;c.toast=()=>{toasts++;};c.render=()=>{renders++;};c.mobileView='receive';c.contentView='sent';
  for(const clipboard of [{read:async()=>[]},{read:async()=>[{types:['text/plain'],getType:async()=>new Blob(['  \n'])}]},{readText:async()=>''},{readText:async()=>'   '}]){context.navigator.clipboard=clipboard;await c.readClipboard();}
  assert.equal(toasts,0);assert.equal(renders,0);assert.equal(c.mobileView,'receive');assert.equal(c.stagedTexts.length,0);
  context.navigator.clipboard={read:async()=>{throw new DOMException('denied','NotAllowedError');}};await c.readClipboard();assert.equal(toasts,1);
});

test('sent batch selection is independent, whole-card and removes only selected history references',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;const sentA=textEvent('sent-a',true,'发送一'),sentB=textEvent('sent-b',true,'发送二'),incoming=textEvent('incoming-keep',false,'收到的内容');c.events=[sentA,sentB,incoming];const file=transfer('sent-file','received');file.sourceDeviceId='receiver';file.targetDeviceId='sender';c.transfers=[file];const original=new File(['external-original'],'original.txt');c.fileSources.set('sent-file:file-sent-file',original);let removedBytes=0;c.rtcStore={remove:async()=>{removedBytes++;}};
  c.selected.add('incoming-keep');c.receiveSelecting=true;c.contentView='sent';c.render();document.querySelector<HTMLButtonElement>('[data-action="sent-multi-select"]')!.click();assert.equal(c.sentSelected.size,0);assert.equal(c.selected.has('incoming-keep'),true);
  document.querySelector<HTMLButtonElement>('[data-action="sent-select-all"]')!.click();assert.equal(c.sentSelected.size,3);assert.equal(c.allSentSelected(),true);document.querySelector<HTMLButtonElement>('[data-action="sent-select-all"]')!.click();assert.equal(c.sentSelected.size,0);
  document.querySelector<HTMLElement>('[data-sent-key="sent-a"] .card-text-lines')!.click();document.querySelector<HTMLElement>('[data-sent-key="file:sent-file:file-sent-file"] .card-preview-button')!.click();assert.equal(c.sentSelected.size,2);assert.equal(c.modal,null);assert.equal(document.querySelectorAll('.history-items button,.history-items a').length,0);assert.equal(document.querySelector('[data-sent-key="sent-a"]')!.getAttribute('aria-checked'),'true');
  document.querySelector<HTMLButtonElement>('[data-action="sent-delete-selected"]')!.click();assert.equal(c.displayTexts(true).some((event:any)=>event.eventId==='sent-a'),false);assert.equal(c.displayTexts(true).some((event:any)=>event.eventId==='sent-b'),true);assert.equal(c.receivedTexts().some((event:any)=>event.eventId==='incoming-keep'),true);assert.equal(c.selected.has('incoming-keep'),true);assert.equal(c.visibleFiles(file).length,0);assert.equal(removedBytes,0);assert.equal(await original.text(),'external-original');
});

test('the title menu lists only this browser device addresses and stages a selected literal without losing drafts',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.info.features={groupSharedText:true};
  c.devices=[{...c.session.device,online:true,peer:{candidates:['http://10.0.0.4:8787','http://[2001:db8::4]:8787']}},{deviceId:'sender',name:'另一设备',online:true,platform:'android',peer:{candidates:['http://10.99.99.99:8787']}}];
  c.rtcProbes={ownCandidates:['candidate:1 1 udp 1 1.2.3.4 1234 typ srflx'],status:()=>''};
  c.rtcChannels.set('local-channel',{ownCandidates:['candidate:2 1 udp 1 fd00::4 1234 typ host','candidate:3 1 udp 1 hidden.local 1234 typ host']});
  c.text='保留未确认草稿';c.stagedTexts=[{id:'kept',text:'已有待发送'}];c.render();
  const field=document.querySelector('#shared-group-text')!;Object.defineProperty(document,'activeElement',{configurable:true,value:field});
  const pointer=new Event('pointerdown',{bubbles:true,cancelable:true});document.querySelector('[data-action="ip-addresses"]')!.dispatchEvent(pointer);assert.equal(pointer.defaultPrevented,true);
  await c.openIpAddresses();
  assert.deepEqual(Array.from(document.querySelectorAll('.ip-address-source>h3'),node=>node.textContent),['浏览器本机','公网映射','已发布地址']);
  assert.deepEqual(Array.from(document.querySelectorAll('.ip-address-group h4'),node=>node.textContent),['IPv6 内网','IPv4 公网','IPv4 内网','IPv6 公网']);
  assert.deepEqual(Array.from(document.querySelectorAll('[data-stage-ip]'),node=>node.getAttribute('data-stage-ip')),['fd00::4','1.2.3.4','10.0.0.4','2001:db8::4']);
  document.querySelector<HTMLElement>('[data-stage-ip="2001:db8::4"]')!.click();
  assert.equal(c.modal,null);assert.equal(c.text,'保留未确认草稿');assert.equal(c.stagedTexts.length,2);assert.equal(c.stagedTexts[0].text,'已有待发送');assert.equal(c.stagedTexts[1].text,'2001:db8::4');assert.equal(c.mobileView,'send');
});

test('unavailable local storage preserves ordinary relay fallback and never advertises a usable folder receiver',async()=>{
  const {c,context}=fixture();
  context.RTCPeerConnection=class {};context.Worker=class {};context.navigator.storage={getDirectory:async()=>({})};
  c.info.features={rtcDataChannels:true,folderTransfer:true};
  c.ensureFileStore=async()=>{throw new Error('fixture storage unavailable');};
  assert.equal(c.rtcEnabled,true);await c.ensureRtc();assert.equal(c.rtcUnavailable,true);assert.equal(c.rtcEnabled,false);
  const calls:any[]=[];c.api.request=async(path:string,body:any)=>{calls.push({path,body});return {};};
  await c.ensureFolderCapability();assert.deepEqual(JSON.parse(JSON.stringify(calls)),[{path:'/devices/me/capabilities',body:{folderTransfer:false}}]);
  assert.equal(c.folderRegisteredScope,'');
});

test('receive storage failures are reported to both participants without losing the committed prefix',async()=>{
  const {c}=fixture(),t=transfer('disk','uploading','auto','relay');t.files[0].offset=3;c.transfers=[t];c.info.features={receiveErrorReporting:true};
  c.ensureFileStore=async()=>{throw new DOMException('目录不可写','NotAllowedError');};
  const calls:any[]=[];c.api.request=async(path:string,body:any)=>{calls.push({path,body});return {file:{...t.files[0],status:'failed',receiveFailure:true,errorCode:body.message}};};
  await c.receiveDirectory(t,t.files[0]);
  assert.equal(calls.length,1);assert.match(calls[0].path,/\/receive-error$/);assert.equal(calls[0].body.message,'目录不可写');
  assert.equal(c.transfers[0].files[0].status,'failed');assert.equal(c.transfers[0].files[0].offset,3);assert.equal(c.transfers[0].files[0].receiveFailure,true);
});

test('receive confirmation network failures and relay confirmation prompts are not reported as storage failures',async()=>{
  const {c}=fixture(),t=transfer('ack','accepted');c.transfers=[t];c.info.features={receiveErrorReporting:true};
  c.ensureFileStore=async()=>({directory:async()=>{},get:async()=>undefined});const calls:string[]=[];
  c.api.request=async(path:string)=>{calls.push(path);throw new Error('连接中断');};
  await c.receiveDirectory(t,t.files[0]);assert.equal(calls.length,1);assert.match(calls[0],/\/received$/);
  c.ensureRtc=async()=>{};c.ensureFileStore=async()=>({get:async()=>undefined,open:async()=>3,close:async()=>{}});
  c.rtcReceives.clear();c.uploadErrors.clear();c.autoAcceptMaxBytes=1;
  await c.receiveRtc(t,t.files[0]);assert.match(c.uploadErrors.get('ack:file-ack'),/中继需确认/);assert.equal(calls.length,1);
});

test('structured relay disk writes report receiver failure while retaining received bytes for retry',async()=>{
  const {c,context}=fixture(),t=transfer('write','ready','auto','relay');t.files[0].relativePath='资料/sample.txt';c.transfers=[t];c.info.features={receiveErrorReporting:true};
  c.ensureFileStore=async()=>({get:async()=>undefined,open:async()=>2,write:async()=>{throw new DOMException('空间不足','QuotaExceededError');},close:async()=>{}});
  const calls:any[]=[];c.api.request=async(path:string,body:any)=>{calls.push({path,body});return path.endsWith('/download-ticket')?{downloadPath:'/api/v1/downloads/test-token'}:{file:{...t.files[0],status:'failed',receiveFailure:true}};};
  (context as any).fetch=async(_url:string,options:any)=>{assert.equal(options.headers.Range,'bytes=2-');return {ok:true,status:206,body:{getReader:()=>({read:async()=>({done:false,value:new Uint8Array([1])}),cancel:async()=>{},releaseLock:()=>{}})}};};
  await c.receiveStructuredRelay(t,t.files[0]);assert.equal(calls.length,2);assert.match(calls[1].path,/\/receive-error$/);assert.equal(calls[1].body.message,'空间不足');
});

test('RTC storage setup failure does not try public or relay and reports the actual receiver error',async()=>{
  const {c}=fixture(),t=transfer('rtc-disk','accepted');c.transfers=[t];c.info.features={receiveErrorReporting:true};c.ensureRtc=async()=>{};
  c.ensureFileStore=async()=>({get:async()=>undefined,open:async()=>{throw new Error('文件夹已移除');},close:async()=>{}});
  const calls:string[]=[];c.api.request=async(path:string)=>{calls.push(path);return {file:{...t.files[0],status:'failed',receiveFailure:true}};};
  await c.receiveRtc(t,t.files[0]);assert.equal(calls.length,1);assert.match(calls[0],/\/receive-error$/);assert.equal(c.uploadErrors.get('rtc-disk:file-rtc-disk'),'文件夹已移除');
});

test('receiver failures retry through receive-retry for either participant and preserve offset and attempt',async()=>{
  for(const receiving of [true,false]){
    const {c}=fixture(),t=transfer('resume','failed','auto','relay');Object.assign(t.files[0],{offset:3,attemptId:'original',receiveFailure:true});c.transfers=[t];
    if(!receiving){c.session.device.deviceId='sender';c.fileSources.set('resume:file-resume',new File(['data'],'sample.txt'));}
    c.startReadyUploads=()=>{};c.selectIncomingRelays=async()=>{};const calls:any[]=[];
    c.api.request=async(path:string,body:any)=>{calls.push({path,body});return {file:{...t.files[0],status:'uploading',receiveFailure:false}};};
    await c.retryFile('resume','file-resume');assert.equal(calls.length,1);assert.match(calls[0].path,/\/receive-retry$/);assert.deepEqual(Object.keys(calls[0].body),[]);
    assert.equal(c.transfers[0].files[0].offset,3);assert.equal(c.transfers[0].files[0].attemptId,'original');assert.equal(c.transfers[0].files[0].status,'uploading');
  }
});

test('pausing a waiting receive aborts it immediately and its late storage result cannot acknowledge or restart',async()=>{
  const {c}=fixture(),t=transfer('pause-receive','accepted'),gate=deferred<any>();c.transfers=[t];let created=0,calls=0;
  c.ensureFileStore=()=>gate.promise;c.api.request=async()=>{calls++;return {};};
  const receiving=c.receiveDirectory(t,t.files[0]),key='pause-receive:file-pause-receive',controller=c.rtcReceives.get(key);
  c.pauseFile(key);assert.equal(controller.signal.aborted,true);assert.equal(c.paused.has(key),true);
  gate.resolve({directory:async()=>created++,get:async()=>undefined});await receiving;
  assert.equal(created,0);assert.equal(calls,0);assert.equal(c.rtcReceives.size,0);assert.equal(c.uploadErrors.has(key),false);
});

test('pausing a waiting upload aborts its metadata request and ignores the late accepted snapshot',async()=>{
  const {c}=fixture(),t=transfer('pause-upload','accepted'),gate=deferred<any>();c.transfers=[t];c.session.device.deviceId='sender';
  const key='pause-upload:file-pause-upload';c.fileSources.set(key,new File(['data'],'sample.txt'));let signal:AbortSignal,uploads=0;
  c.api.request=async(_path:string,_body:any,_method:string,requestSignal:AbortSignal)=>{signal=requestSignal;return gate.promise;};c.api.upload=async()=>{uploads++;return {};};
  const uploading=c.uploadFile(t.transferId,t.files[0].fileId);c.pauseFile(key);assert.equal(signal!.aborted,true);
  gate.resolve({transfer:{...t,files:[{...t.files[0],offset:3}]}});await uploading;
  assert.equal(uploads,0);assert.equal(c.uploadProgress.has(key),false);assert.equal(c.uploadErrors.has(key),false);
});

test('cancel is immediate even while channel close and center RPC are pending and stale responses cannot revive it',async()=>{
  const {c,context}=fixture(),t=transfer('cancel-now','accepted'),closed=deferred<void>(),rpc=deferred<any>();c.transfers=[t];let requested=false;
  const key='cancel-now:file-cancel-now',upload=new AbortController(),receive=new AbortController();c.uploads.set(key,upload);c.rtcReceives.set(key,receive);c.rtcChannels.set(key,{close:()=>closed.promise});
  (context as any).fetch=async(url:string)=>{requested=url.endsWith('/cancel');return rpc.promise;};
  await c.cancelFile(t.transferId,t.files[0].fileId);assert.equal(requested,true);assert.equal(upload.signal.aborted,true);assert.equal(receive.signal.aborted,true);assert.equal(c.transfers[0].files[0].status,'canceled');
  c.setFile(t.transferId,{...t.files[0],status:'uploading',offset:3});assert.equal(c.transfers[0].files[0].status,'canceled');
  closed.resolve();rpc.resolve({ok:true,json:async()=>({file:{...t.files[0],status:'canceled'}})});for(let i=0;i<12;i++)await Promise.resolve();
});

test('waiting receiver cards offer pause and cancel, paused cards continue, failed cards retry',()=>{
  const {c,document}=fixture(),t=transfer('controls','accepted');c.transfers=[t];const key='controls:file-controls';
  document.querySelector('#app')!.innerHTML=c.fileHtml(t,t.files[0],false);assert.ok(document.querySelector('[data-pause]'));assert.ok(document.querySelector('[data-cancel]'));
  c.pauseFile(key);document.querySelector('#app')!.innerHTML=c.fileHtml(t,t.files[0],false);assert.equal(document.querySelector('[data-retry]')!.textContent,'继续');assert.equal(document.querySelector('[data-pause]'),null);
  c.paused.delete(key);t.files[0].status='failed';t.files[0].receiveFailure=true;document.querySelector('#app')!.innerHTML=c.fileHtml(t,t.files[0],false);assert.equal(document.querySelector('[data-retry]')!.textContent,'重试');
});

test('a paused relay selection aborts its request and a late relay result cannot restart incoming work',async()=>{
  const {c}=fixture(),t=transfer('pause-route','accepted'),gate=deferred<any>();c.transfers=[t];let signal:AbortSignal;
  c.api.request=async(_path:string,_body:any,_method:string,value:AbortSignal)=>{signal=value;return gate.promise;};
  const selecting=c.selectIncomingRelays(),key='pause-route:file-pause-route';c.pauseFile(key);assert.equal(signal!.aborted,true);
  gate.resolve({file:{...t.files[0],transport:'relay'}});await selecting;
  assert.equal(c.transfers[0].files[0].transport,null);assert.equal(c.uploadErrors.has(key),false);assert.equal(c.fileRequests.size,0);assert.equal(c.paused.has(key),true);
});

test('an older center refresh cannot revive a locally canceled file',async()=>{
  const {c,refresh}=fixture(),t=transfer('canceled-snapshot','accepted');c.transfers=[t];c.canceled.add('canceled-snapshot:file-canceled-snapshot');
  c.ensureRtc=async()=>{};c.ensureFolderCapability=async()=>{};c.syncProbeMonitor=()=>{};c.acceptIncoming=async()=>{};c.selectIncomingRelays=async()=>{};
  c.api.request=async(path:string)=>path==='/devices'?{devices:c.devices}:path==='/transfers'?{transfers:[t]}:{events:[],cursor:0,hasMore:false};
  await refresh();assert.equal(c.transfers[0].files[0].status,'canceled');
});

test('retry clicked during receiver error reporting waits for that same failure then preserves the server prefix',async()=>{
  const {c}=fixture(),t=transfer('report-race','uploading','auto','relay'),gate=deferred<any>();t.files[0].offset=3;c.transfers=[t];c.info.features={receiveErrorReporting:true};
  c.ensureFileStore=async()=>{throw new Error('目录不可写');};c.selectIncomingRelays=async()=>{};const paths:string[]=[];
  c.api.request=async(path:string)=>{paths.push(path);return path.endsWith('/receive-error')?gate.promise:{file:{...t.files[0],status:'uploading',receiveFailure:false}};};
  const receiving=c.receiveDirectory(t,t.files[0]);for(let i=0;i<8;i++)await Promise.resolve();
  const retrying=c.retryFile(t.transferId,t.files[0].fileId);assert.equal(paths.length,1);
  gate.resolve({file:{...t.files[0],status:'failed',receiveFailure:true}});await receiving;await retrying;
  assert.equal(paths.length,2);assert.match(paths[1],/\/receive-retry$/);assert.equal(c.transfers[0].files[0].offset,3);assert.equal(c.transfers[0].files[0].status,'uploading');
});


test('file reuse is negotiated before acceptance and refreshes receipt without any payload route',async()=>{
 const {c,context}=fixture();context.Worker=class {};context.navigator.storage={getDirectory:async()=>{}};
 c.info.features={fileReuse:true};const t=transfer('reuse-now');t.files[0].size=40*1024*1024;c.transfers=[t];
 const calls:any[]=[],at='2026-10-28T01:00:00.000Z',file=new File(['existing'],'sample.txt');
 c.ensureFileStore=async()=>({reuse:async(key:string)=>{calls.push(['local-verify',key]);return file;},expiry:()=>Infinity,receivedAt:()=>at,unlinkReuse:async()=>{throw new Error('should not unlink saved match');}});
 c.api.request=async(path:string,body:any)=>{calls.push([path,body]);if(path.endsWith('/reuse'))return {file:{...t.files[0],status:'received',transport:'direct',reused:true,receivedAt:at}};return {transfer:{...t,files:[{...t.files[0],status:'received',transport:'direct',reused:true}]}};};
 await c.acceptIncoming();assert.equal(calls.length,3);assert.equal(calls[0][0],'local-verify');assert.match(calls[1][0],/\/reuse$/);assert.match(calls[2][0],/\/accept$/);assert.deepEqual(Array.from(calls[2][1].fileIds),[]);
 assert.equal(c.rtcLocalFiles.get('reuse-now:file-reuse-now'),file);assert.equal(c.receivedAt['reuse-now:file-reuse-now'],at);assert.equal(c.transfers[0].files[0].status,'received');
 assert.equal(c.uploads.size+c.rtcReceives.size,0);assert.equal(c.uploadProgress.size,0);
});
test('a missing saved file falls through to ordinary acceptance, and unsupported centers keep their contract',async()=>{
 for(const supported of [true,false]){
  const {c,context}=fixture();context.Worker=class {};context.navigator.storage={getDirectory:async()=>{}};c.info.features={fileReuse:supported};const t=transfer('cache-missing');c.transfers=[t];const calls:any[]=[];
  c.ensureFileStore=async()=>({reuse:async()=>{calls.push('lookup');return undefined;}});
  c.api.request=async(path:string,body:any)=>{calls.push(path);assert.match(path,/\/accept$/);assert.deepEqual(Array.from(body.fileIds),[t.files[0].fileId]);return {transfer:{...t,files:[{...t.files[0],status:'accepted'}]}};};
  await c.acceptFiles(t,[t.files[0].fileId],true);assert.deepEqual(calls,supported?['lookup','/transfers/cache-missing/accept']:['/transfers/cache-missing/accept']);
 }
});
test('Receive, History and Files use the same compact toolbar in normal and selected modes',()=>{
 const {c,document,render}=fixture();c.render=render;
 for(const view of ['receive','sent','library'])for(const selecting of [false,true]){
  c.contentView=view;c.receiveSelecting=selecting;c.sentSelecting=selecting;c.fileLibrary.editing=selecting;c.fileLibrary.opened=true;
  render();const toolbar=document.querySelector('.dock-panel .content-toolbar');assert.ok(toolbar,view);assert.equal(document.querySelectorAll('.dock-panel .content-toolbar').length,1);
  if(view==='library'){assert.equal(document.querySelector('.library-selection'),null);assert.equal(document.querySelector('.library-pane-header .library-subtitle')?.textContent,'');assert.ok(toolbar.querySelector(selecting?'[data-library-action="select-all"]':'#library-sort'));}
 }
});
test('device diagnostic shows selected source-to-target endpoints and separates untested from failed',()=>{
 const {c}=fixture();c.networkDevice='sender';const base={attemptId:'rtc',initiatorDeviceId:'sender',responderDeviceId:'receiver',scope:'lan',success:true,elapsedMs:3,checkedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),initiatorAddress:'10.1.2.3:123',responderAddress:'10.2.3.4:456'};
 c.rtcProbes={results:[base]};let html=c.deviceNetworkHtml();assert.match(html,/10.2.3.4:456 → 10.1.2.3:123/);assert.match(html,/未测试/);
 c.rtcProbes={results:[{...base,success:false}]};html=c.deviceNetworkHtml();assert.match(html,/本次未连通/);assert.doesNotMatch(html,/probe-addresses/);
});


test('selected cards keep native HTML drag enabled on Receive, History and Files without changing selection',()=>{
 for(const view of ['receive','sent','library']){
  const {c,document,render,Event}=fixture();c.render=render;c.contentView=view;c.receiveSelecting=view==='receive';c.sentSelecting=view==='sent';c.fileLibrary.editing=view==='library';c.fileLibrary.opened=true;
  const files=[0,1,2].map(index=>new File(['data'],'item-'+index+'.bin'));
  if(view==='library'){
   c.fileLibrary.entries=files.map((file,index)=>({id:'scope/'+index,key:String(index),scope:'scope',name:file.name,mimeType:file.type,size:file.size,receivedAt:Date.now(),expiresAt:Date.now()+60000}));
   files.forEach((file,index)=>c.fileLibrary.files.set('scope/'+index,file));c.fileLibrary.selected=new Set(['scope/0','scope/1']);
  }else{
   c.transfers=files.map((file,index)=>{const t=transfer('drag-'+index,'received');t.files[0].sha256=String(index).repeat(64);if(view==='sent'){t.sourceDeviceId='receiver';t.targetDeviceId='sender';c.fileSources.set(t.transferId+':'+t.files[0].fileId,file);}else c.rtcLocalFiles.set(t.transferId+':'+t.files[0].fileId,file);return t;});
   const selected=new Set(['file:drag-0:file-drag-0','file:drag-1:file-drag-1']);if(view==='sent')c.sentSelected=selected;else c.selected=selected;
  }
  render();const selector=view==='library'?'[data-library-id="scope/2"]':'[data-drag-file="drag-2:file-drag-2"]',card=document.querySelector(selector)!;assert.equal(card.getAttribute('draggable'),'true');
  const before=Array.from(view==='library'?c.fileLibrary.selected:view==='sent'?c.sentSelected:c.selected),values=new Map(),added:any[]=[],drag=new Event('dragstart',{bubbles:true,cancelable:true});
  Object.assign(drag,{dataTransfer:{items:{add:(file:File)=>added.push(file)},setData:(key:string,value:string)=>values.set(key,value),setDragImage(){}}});card.dispatchEvent(drag);
  assert.equal(drag.defaultPrevented,false);assert.equal(added.length,2);assert.deepEqual(added,files.slice(0,2));assert.deepEqual(Array.from(view==='library'?c.fileLibrary.selected:view==='sent'?c.sentSelected:c.selected),before);assert.equal(values.get('application/x-globalsend-card'),'1');
 }
});
test('a touch hold enters selection without detaching the source and a later hold never changes existing picks',()=>{
 for(const view of ['receive','sent','library']){
  const {c,document,render,Event,context}=fixture();c.render=render;c.contentView=view;c.fileLibrary.opened=true;const timers:(()=>void)[]=[];context.window.setTimeout=(fn:()=>void,ms:number)=>{if(ms===450)timers.push(fn);return 1;};
  if(view==='library'){c.fileLibrary.entries=[0,1].map(index=>({id:'scope/'+index,key:String(index),scope:'scope',name:'item.bin',mimeType:'application/octet-stream',size:4,receivedAt:Date.now(),expiresAt:Date.now()+60000}));}
  else c.events=[textEvent('hold-a',view==='sent'),textEvent('hold-b',view==='sent','second')];
  render();const selector=view==='library'?'[data-library-id="scope/0"]':'[data-drag-text="hold-a"]',card=document.querySelector(selector)!,down=new Event('pointerdown',{bubbles:true,cancelable:true});Object.assign(down,{pointerType:'touch',clientX:30,clientY:40});card.dispatchEvent(down);timers.pop()!();
  const menu=new Event('contextmenu',{bubbles:true,cancelable:true});card.dispatchEvent(menu);assert.equal(c.contextMenu,null);assert.equal(card.isConnected,true);assert.equal(view==='library'?c.fileLibrary.editing:view==='sent'?c.sentSelecting:c.receiveSelecting,true);const selection=view==='library'?c.fileLibrary.selected:view==='sent'?c.sentSelected:c.selected;assert.deepEqual(Array.from(selection),[view==='library'?'scope/0':'hold-a']);
  render();const second=document.querySelector(view==='library'?'[data-library-id="scope/1"]':'[data-drag-text="hold-b"]')!,again=new Event('pointerdown',{bubbles:true,cancelable:true});Object.assign(again,{pointerType:'touch',clientX:30,clientY:40});second.dispatchEvent(again);timers.pop()!();assert.deepEqual(Array.from(selection),[view==='library'?'scope/0':'hold-a']);
 }
});

test('external native text and files still drop after a missing internal dragend, and cross-window card markers are external',async()=>{
  for(const marker of [false,true]){
    const {c,document,render,Event}=fixture();c.render=render;c.installWindowDrop();render();
    const stale=document.querySelector('[data-queue-drop]')!;stale.setAttribute('data-internal-drag','true');
    c.internalPayload={text:'old gesture'};
    const file=new File(['native file'],'桌面文件.txt',{type:'text/plain'});
    const data={types:marker?['application/x-globalsend-card','Files']:['Files'],files:[file],items:[{kind:'file',getAsFile:()=>file}],getData:()=>''};
    const over=new Event('dragover',{bubbles:true,cancelable:true});Object.assign(over,{dataTransfer:data});document.querySelector('.brand')!.dispatchEvent(over);
    assert.equal(over.defaultPrevented,true,'external drag is accepted throughout the window');
    const drop=new Event('drop',{bubbles:true,cancelable:true});Object.assign(drop,{dataTransfer:data});document.querySelector('.brand')!.dispatchEvent(drop);
    await new Promise(resolve=>setImmediate(resolve));assert.equal(c.picked[0],file);assert.equal(c.stagedTexts.length,0);
  }
});

test('URL-only drags and plain text on nested elements enter the queue without navigating or losing whitespace',async()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.installWindowDrop();render();
  for(const [type,value,expected] of [['text/uri-list','# browser link\r\nhttps://example.com/path\r\n','https://example.com/path'],['text/plain','  一段文字\n保留换行  ','  一段文字\n保留换行  ']]){
    const drop=new Event('drop',{bubbles:true,cancelable:true});Object.assign(drop,{dataTransfer:{types:[type],files:[],items:[],getData:(key:string)=>key===type?value:''}});
    document.querySelector('.brand span')!.dispatchEvent(drop);assert.equal(drop.defaultPrevented,true);await new Promise(resolve=>setImmediate(resolve));assert.equal(c.stagedTexts.at(-1).text,expected);
  }
});

test('crossing child elements during native drag does not flash the full-window drop feedback',()=>{
  const {c,document,render,Event}=fixture();c.render=render;c.installWindowDrop();render();
  const data={types:['Files'],dropEffect:'',files:[],items:[],getData:()=>''};
  const send=(type:string,target:Element,relatedTarget:Element|null)=>{const event=new Event(type,{bubbles:true,cancelable:true});Object.assign(event,{dataTransfer:data,relatedTarget,clientX:80,clientY:90});target.dispatchEvent(event);};
  send('dragenter',document.querySelector('.brand')!,null);const overlay=document.querySelector('#window-drop')!;assert.equal(overlay.classList.contains('visible'),true);
  send('dragleave',document.querySelector('.brand span')!,null);assert.equal(overlay.classList.contains('visible'),true,'native null-relatedTarget is not an immediate window exit');
  send('dragover',document.querySelector('[data-queue-drop]')!,null);assert.equal(overlay.classList.contains('visible'),true);
  send('drop',document.querySelector('[data-queue-drop]')!,null);assert.equal(overlay.classList.contains('visible'),false);
});

test('Web card actions keep the app action hierarchy with details last and browser download replacing unavailable locate',()=>{
 const {c,document}=fixture();
 for(const [kind,labels] of [['file',['打开','下载','加入待发送','删除','详情']],['text',['复制','加入待发送','删除','详情']],['receipt',['加入待发送','关闭此项','详情']]]){
  c.contextMenu={kind,key:'sample',x:20,y:20};document.querySelector('#app')!.innerHTML=c.cardMenuHtml();assert.deepEqual([...document.querySelectorAll('[role=menuitem]')].map(node=>node.textContent),labels);
 }
});

test('Web diagnostics do not draw a reachable-address arrow when either observed endpoint is unknown',()=>{
 const {c,document}=fixture();c.networkDevice='sender';c.rtcProbes={results:[{initiatorDeviceId:'receiver',responderDeviceId:'sender',scope:'lan',success:true,elapsedMs:4,checkedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+60000).toISOString(),initiatorAddress:'10.0.0.1:2000'}]};
 document.querySelector('#app')!.innerHTML=c.deviceNetworkHtml();assert.doesNotMatch(document.querySelector('.probe-addresses')!.textContent!,/→/);assert.match(document.querySelector('.probe-addresses')!.textContent!,/目标：未获取/);
 c.rtcProbes.results[0].responderAddress='10.0.0.2:3000';document.querySelector('#app')!.innerHTML=c.deviceNetworkHtml();assert.match(document.querySelector('.probe-addresses')!.textContent!,/10.0.0.1:2000 → 10.0.0.2:3000/);
});
