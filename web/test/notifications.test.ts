import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import {WebNotifications,type WebNotice,type WebNotificationEnvironment} from '../src/notifications.ts';

function fixture(options:Partial<WebNotificationEnvironment>={}) {
  const values=new Map<string,string>();
  const requests:string[]=[];
  const notifications:{title:string;options:NotificationOptions}[]=[];
  const opens:string[]=[];
  const registrations:{url:string;options:unknown}[]=[];
  const listeners=new Set<(event:any)=>void>();
  let visible=false;
  class BrowserNotification {
    static permission:NotificationPermission='default';
    static async requestPermission(){requests.push('permission');this.permission='granted';return this.permission;}
    onclick?:()=>void;
    onclose?:()=>void;
    onerror?:()=>void;
    closed=false;
    constructor(title:string,options:NotificationOptions){notifications.push({title,options});}
    close(){this.closed=true;}
  }
  const env:WebNotificationEnvironment={
    secure:true,notification:BrowserNotification as unknown as typeof Notification,
    pageUrl:'https://123.207.180.163/globalsend/app/',foreground:()=>visible,focus:()=>requests.push('focus'),
    appleMobile:false,standalone:false,
    store:{getItem:key=>values.get(key) ?? null,setItem:(key,value)=>{values.set(key,value);}},
    ...options,
  };
  const registration={active:{},showNotification:async(title:string,options:NotificationOptions)=>{notifications.push({title,options});}} as unknown as ServiceWorkerRegistration;
  const worker={
    register:async(url:string|URL,options:unknown)=>{registrations.push({url:String(url),options});return registration;},
    addEventListener:(_type:string,listener:any)=>listeners.add(listener),
    removeEventListener:(_type:string,listener:any)=>listeners.delete(listener),
  } as unknown as ServiceWorkerContainer;
  const make=(extra:Partial<WebNotificationEnvironment>={})=>new WebNotifications({onOpen:id=>opens.push(id),env:{...env,...extra}});
  return {env,worker,make,values,requests,notifications,opens,registrations,listeners,BrowserNotification,setVisible:(value:boolean)=>{visible=value;}};
}
const text=(revision=1):WebNotice=>({id:'message',revision,kind:'text',phase:revision===1?'incoming':'updated',title:'DongLan',body:'新的文本',itemId:'text:message'});
const file=(phase:'incoming'|'received'='incoming',revision=1):WebNotice=>({id:'transfer/file',revision,kind:'file',phase,title:'DongLan',body:phase==='received'?'可下载 · image.png':'等待接收 · image.png',itemId:'file:transfer/file'});

test('startup and receipt never request permission; only the explicit enable call does',async()=>{
  const f=fixture(),n=f.make();assert.equal(await n.notify(text()),false);assert.deepEqual(f.requests,[]);
  const enabling=n.requestEnable();assert.deepEqual(f.requests,['permission']);assert.equal(await enabling,true);assert.equal(n.state().enabled,true);n.dispose();
});
test('shared editing never notifies, including changed revisions',async()=>{
  const f=fixture(),n=f.make();await n.requestEnable();assert.equal(await n.notify({...text(),kind:'shared'}),false);assert.equal(f.notifications.length,0);n.dispose();
});
test('foreground messages stay in-page, background messages notify once per revision across reload',async()=>{
  const f=fixture(),n=f.make();await n.requestEnable();f.setVisible(true);assert.equal(await n.notify(text()),false);
  f.setVisible(false);assert.equal(await n.notify(text()),false);assert.equal(await n.notify(text(2)),true);assert.equal(await n.notify(text(2)),false);
  n.dispose();const next=f.make();assert.equal(await next.notify(text(2)),false);assert.equal(await next.notify(text(3)),true);assert.equal(f.notifications.length,2);next.dispose();
});
test('service worker uses same-origin subpath and routes notification click back to item',async()=>{
  const f=fixture(),n=f.make({serviceWorker:f.worker});await n.requestEnable();assert.equal(await n.notify(text()),true);
  assert.equal(f.registrations[0].url,'https://123.207.180.163/globalsend/app/notifications-sw.js');assert.deepEqual(f.registrations[0].options,{scope:'/globalsend/app/',updateViaCache:'none'});
  for(const listener of f.listeners)listener({data:{type:'globalsend.notification.open',itemId:'text:message'}});
  assert.deepEqual(f.opens,['text:message']);n.dispose();assert.equal(f.listeners.size,0);
});
test('one file announces incoming once then quietly replaces same tag on completion despite concurrent ticks',async()=>{
  const f=fixture(),n=f.make({serviceWorker:f.worker});await n.requestEnable();
  await Promise.all([n.notify(file()),n.notify(file('incoming',2)),n.notify(file('received',3))]);
  assert.equal(f.notifications.length,2);assert.equal(f.notifications[0].options.tag,f.notifications[1].options.tag);
  assert.equal(f.notifications[0].options.silent,false);assert.equal(f.notifications[1].options.silent,true);
  assert.match(f.notifications[1].options.body!,/可下载/);assert.equal(await n.notify(file('incoming',4)),false);n.dispose();
});
test('ready is not received and both updates retain one silent notification tag without stale phase regression',async()=>{
  const f=fixture(),n=f.make({serviceWorker:f.worker});await n.requestEnable();
  await n.notify(file());
  await n.notify({...file(),phase:'ready',body:'文件可下载'});
  await n.notify({...file('received'),body:'已接收文件'});
  assert.deepEqual(f.notifications.map(item=>item.options.body),['等待接收 · image.png','文件可下载','已接收文件']);
  assert.deepEqual(f.notifications.map(item=>item.options.silent),[false,true,true]);
  assert.equal(new Set(f.notifications.map(item=>item.options.tag)).size,1);
  assert.equal(await n.notify({...file(),phase:'ready'}),false);n.dispose();
});
test('denied, insecure and iPad Safari tabs never prompt or throw',async()=>{
  for(const options of [{secure:false},{appleMobile:true,standalone:false},{notification:undefined}] as Partial<WebNotificationEnvironment>[]){
    const f=fixture(options),n=f.make();assert.equal(await n.requestEnable(),false);assert.equal(await n.notify(text()),false);assert.deepEqual(f.requests,[]);n.dispose();
  }
  const f=fixture();f.BrowserNotification.permission='denied';const n=f.make();assert.equal(await n.requestEnable(),false);assert.equal(n.state().reason,'denied');assert.deepEqual(f.requests,[]);n.dispose();
});
test('iPad home-screen app can use persistent SW notifications without a window Notification constructor',async()=>{
  const f=fixture({appleMobile:true,standalone:true});
  const notification={permission:'granted',requestPermission:async()=> 'granted'} as unknown as typeof Notification;
  const n=f.make({notification,serviceWorker:f.worker});await n.requestEnable();assert.equal(await n.notify(text()),true);n.dispose();
});
test('service worker failure uses desktop fallback, but disabled preference stops future notifications',async()=>{
  const f=fixture(),n=f.make({serviceWorker:{...f.worker,register:async()=>{throw new Error('offline');}} as unknown as ServiceWorkerContainer});
  await n.requestEnable();assert.equal(await n.notify(text()),true);n.setEnabled(false);assert.equal(await n.notify(text(2)),false);n.dispose();
});
test('new-tab click fragment opens after construction, then only its own fragment is consumed',async()=>{
  const f=fixture(),consumed:string[]=[];const n=f.make({pageUrl:'https://send.example/team/app/#gs-receipt=file%3At%2Ff',consumeHash:hash=>consumed.push(hash)});
  assert.deepEqual(f.opens,[]);await Promise.resolve();assert.deepEqual(f.opens,['file:t/f']);assert.deepEqual(consumed,['#gs-receipt=file%3At%2Ff']);n.dispose();
});
test('notification worker focuses existing app without navigation, otherwise opens a scoped receipt URL',async()=>{
  const handlers:Record<string,(event:any)=>void>={};const messages:any[]=[],opened:string[]=[];let focused=0;
  let clients:any[]=[{url:'https://send.example/team/app/',focus:async()=>{focused++;},postMessage:(message:any)=>messages.push(message)}];
  const self={registration:{scope:'https://send.example/team/app/'},clients:{matchAll:async()=>clients,openWindow:async(url:string)=>opened.push(url)},addEventListener:(type:string,handler:any)=>{handlers[type]=handler;}};
  runInNewContext(readFileSync(new URL('../public/notifications-sw.js',import.meta.url),'utf8'),{self,URL,encodeURIComponent});
  async function click(){let work:Promise<void>|undefined;handlers.notificationclick({notification:{close:()=>{},data:{type:'globalsend.notification.open',itemId:'file:t/f'}},waitUntil:(promise:Promise<void>)=>{work=promise;}});await work;}
  await click();assert.equal(focused,1);assert.equal(messages[0].itemId,'file:t/f');assert.deepEqual(opened,[]);
  clients=[{url:'https://send.example/another-app/'}];await click();assert.deepEqual(opened,['https://send.example/team/app/#gs-receipt=file%3At%2Ff']);
});
