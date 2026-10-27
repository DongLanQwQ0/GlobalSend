export interface WebNotice {
  id:string;
  revision:string|number;
  kind:'text'|'file'|'shared';
  phase:'incoming'|'ready'|'received'|'updated';
  title:string;
  body:string;
  itemId:string;
}

export interface WebNotificationState {
  available:boolean;
  enabled:boolean;
  permission:NotificationPermission|'unsupported';
  reason:''|'insecure'|'unsupported'|'home-screen'|'denied'|'unavailable';
}

interface NotificationStore {
  getItem(key:string):string|null;
  setItem(key:string,value:string):void;
}

/** Injectable browser boundary; unit tests do not ask the user's OS permission. */
export interface WebNotificationEnvironment {
  secure:boolean;
  notification?:typeof Notification;
  serviceWorker?:Pick<ServiceWorkerContainer,'register'|'addEventListener'|'removeEventListener'>;
  pageUrl:string;
  foreground:()=>boolean;
  focus:()=>void;
  store?:NotificationStore;
  appleMobile:boolean;
  standalone:boolean;
  consumeHash?:(hash:string)=>void;
}

const enabledKey='globalsend.web-notifications.enabled';
const seenKey='globalsend.web-notifications.seen';
const clickType='globalsend.notification.open';
const clickPrefix='#gs-receipt=';

function browserEnvironment():WebNotificationEnvironment {
  const nav=typeof navigator==='undefined'?undefined:navigator;
  const loc=typeof location==='undefined'?undefined:location;
  const win=typeof window==='undefined'?undefined:window;
  let store:NotificationStore|undefined;
  try {store=typeof localStorage==='undefined'?undefined:localStorage;} catch { /* Storage disabled by the browser. */ }
  return {
    secure:typeof isSecureContext!=='undefined' && isSecureContext,
    notification:typeof Notification==='undefined'?undefined:Notification,
    serviceWorker:nav?.serviceWorker,
    pageUrl:loc?.href ?? `${loc?.origin ?? 'http://localhost'}${loc?.pathname ?? '/app/'}`,
    foreground:()=>typeof document!=='undefined' && document.visibilityState==='visible' && (document.hasFocus?.() ?? true),
    focus:()=>win?.focus?.(),
    store,
    appleMobile:!!nav && (/iPad|iPhone|iPod/.test(nav.userAgent) || /Macintosh/.test(nav.userAgent) && nav.maxTouchPoints>1),
    standalone:!!(nav as Navigator & {standalone?:boolean}|undefined)?.standalone || !!win?.matchMedia?.('(display-mode: standalone)').matches,
    consumeHash:hash=>{
      if (loc?.hash===hash) win?.history?.replaceState(null,'',`${loc.pathname}${loc.search}`);
    },
  };
}

export class WebNotifications {
  private readonly env:WebNotificationEnvironment;
  private readonly onOpen:(itemId:string)=>void;
  private readonly onChange:()=>void;
  private readonly appUrl:URL;
  private readonly seen=new Set<string>();
  private readonly live=new Set<Notification>();
  private registration?:Promise<ServiceWorkerRegistration>;
  private optedIn=false;
  private unavailable=false;
  private disposed=false;
  private delivery=Promise.resolve();
  private readonly message=(event:MessageEvent)=>{
    if (event.data?.type===clickType && typeof event.data.itemId==='string') this.open(event.data.itemId);
  };

  constructor(options:{onOpen:(itemId:string)=>void;onChange?:()=>void;env?:Partial<WebNotificationEnvironment>}) {
    this.env={...browserEnvironment(),...options.env};
    this.onOpen=options.onOpen;
    this.onChange=options.onChange ?? (()=>{});
    this.appUrl=new URL('./',this.env.pageUrl);
    try {
      this.optedIn=this.env.store?.getItem(enabledKey)==='true';
      const saved=JSON.parse(this.env.store?.getItem(seenKey) ?? '[]');
      if (Array.isArray(saved)) for (const key of saved.slice(-256)) if (typeof key==='string') this.seen.add(key);
    } catch { /* A storage restriction does not prevent in-page reception. */ }
    this.env.serviceWorker?.addEventListener('message',this.message as EventListener);
    const hash=new URL(this.env.pageUrl).hash;
    if (hash.startsWith(clickPrefix)) {
      try {
        const itemId=decodeURIComponent(hash.slice(clickPrefix.length));
        if (itemId) queueMicrotask(()=>{if(!this.disposed)this.open(itemId);});
        this.env.consumeHash?.(hash);
      } catch { /* An unrelated or incomplete fragment is not a notification. */ }
    }
    if (this.state().enabled && this.env.serviceWorker) void this.worker().catch(()=>{});
  }

  state():WebNotificationState {
    const notification=this.env.notification;
    const permission=notification?.permission ?? 'unsupported';
    const reason=!this.env.secure?'insecure':this.env.appleMobile && !this.env.standalone?'home-screen':!notification?'unsupported':permission==='denied'?'denied':this.unavailable?'unavailable':'';
    const available=this.env.secure && !!notification && (!this.env.appleMobile || this.env.standalone);
    return {available,enabled:available && this.optedIn && permission==='granted',permission,reason};
  }

  /** Call directly from a click/tap, never from an incoming event or startup. */
  async requestEnable():Promise<boolean> {
    if (!this.state().available || this.env.notification!.permission==='denied') {this.onChange();return false;}
    const notification=this.env.notification!;
    try {
      // Request before the first await so Safari receives the original gesture.
      const permission=notification.permission==='granted'?'granted':await notification.requestPermission();
      if (permission!=='granted' || this.disposed) {this.onChange();return false;}
      this.setEnabled(true);
      if (this.env.serviceWorker) void this.worker().catch(()=>{});
      return true;
    } catch {this.unavailable=true;this.onChange();return false;}
  }

  setEnabled(value:boolean):void {
    this.optedIn=value;
    this.unavailable=false;
    try {this.env.store?.setItem(enabledKey,String(value));} catch { /* Session-only preference. */ }
    if (!value) {for(const notification of this.live)notification.close();this.live.clear();}
    this.onChange();
  }

  async notify(notice:WebNotice):Promise<boolean> {
    if (this.disposed || notice.kind==='shared' || notice.kind==='file' && notice.phase==='updated') return false;
    // File progress can arrive from polling and WS in quick succession. There
    // are only arrival/ready/received phases, regardless of offset ticks.
    const key=notice.kind==='file'?JSON.stringify(['file',notice.itemId,notice.phase]):JSON.stringify([notice.kind,notice.id,notice.revision,notice.phase]);
    if (notice.kind==='file' && notice.phase!=='received' && this.seen.has(JSON.stringify(['file',notice.itemId,'received']))) return false;
    if (notice.kind==='file' && notice.phase==='incoming' && this.seen.has(JSON.stringify(['file',notice.itemId,'ready']))) return false;
    if (this.seen.has(key)) return false;
    this.remember(key);
    if (!this.state().enabled || this.env.foreground()) return false;
    const result=this.delivery.then(()=>this.deliver(notice));
    this.delivery=result.then(()=>{},()=>{});
    return result;
  }

  private async deliver(notice:WebNotice):Promise<boolean> {
    const shownKey=JSON.stringify(['file',notice.itemId,'shown']);
    const options=():NotificationOptions=>({
      body:notice.body,
      tag:`globalsend:${notice.itemId}`,
      silent:notice.kind==='file' && this.seen.has(shownKey),
      icon:new URL('notification-icon.svg',this.appUrl).href,
      data:{type:clickType,itemId:notice.itemId,url:this.appUrl.href},
    });
    const delivered=()=>{
      if (notice.kind==='file') this.remember(shownKey);
      this.unavailable=false;
    };
    if (this.env.serviceWorker) {
      try {
        const registration=await this.worker();
        if (this.disposed || !this.state().enabled || this.env.foreground()) return false;
        await registration.showNotification(notice.title,options());
        delivered();
        return true;
      } catch { /* Desktop browsers may still support the window constructor. */ }
    }
    try {
      if (this.disposed || !this.state().enabled || this.env.foreground()) return false;
      const notification=new this.env.notification!(notice.title,options());
      this.live.add(notification);
      notification.onclick=()=>{notification.close();this.live.delete(notification);this.env.focus();this.open(notice.itemId);};
      notification.onclose=()=>this.live.delete(notification);
      notification.onerror=()=>{this.unavailable=true;this.onChange();};
      delivered();
      return true;
    } catch {this.unavailable=true;this.onChange();return false;}
  }

  private worker():Promise<ServiceWorkerRegistration> {
    return this.registration ??= this.registerWorker().catch(error=>{this.registration=undefined;throw error;});
  }

  private remember(key:string):void {
    this.seen.add(key);
    while (this.seen.size>256) this.seen.delete(this.seen.values().next().value!);
    try {this.env.store?.setItem(seenKey,JSON.stringify([...this.seen]));} catch { /* Deduplicate in this tab. */ }
  }

  private async registerWorker():Promise<ServiceWorkerRegistration> {
    const registration=await this.env.serviceWorker!.register(new URL('notifications-sw.js',this.appUrl).href,{scope:this.appUrl.pathname,updateViaCache:'none'});
    if (registration.active) return registration;
    const worker=registration.installing ?? registration.waiting;
    if (!worker) throw new Error('通知服务未就绪');
    await new Promise<void>((resolve,reject)=>{
      const done=()=>{
        if (worker.state==='activated' || worker.state==='redundant') {
          clearTimeout(timer);worker.removeEventListener('statechange',done);
          worker.state==='activated'?resolve():reject(new Error('通知服务未就绪'));
        }
      };
      const timer=setTimeout(()=>{worker.removeEventListener('statechange',done);reject(new Error('通知服务未就绪'));},4000);
      worker.addEventListener('statechange',done);done();
    });
    return registration;
  }

  private open(itemId:string):void {
    if (!this.disposed && itemId) this.onOpen(itemId);
  }

  dispose():void {
    this.disposed=true;
    this.env.serviceWorker?.removeEventListener('message',this.message as EventListener);
    for(const notification of this.live)notification.close();
    this.live.clear();
  }
}
