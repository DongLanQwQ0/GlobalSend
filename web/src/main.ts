import './style.css';
import { clipboardSuggestion } from './clipboard_suggestion';
import type { ClipboardSuggestionKind } from './clipboard_suggestion';
import { folderCards, folderMembers, folderRoot, isFolderRoot, summarizeFolder } from './folder_cards';
import { centeredDragImage } from './drag_image';
import { digestFile } from './files';
import { emptyGroupData, publicSession, validateGroupKey } from './group';
import { Api, ApiError } from './api';
import { baseFromLocation, centerWebSocketUrl, suggestedDeviceName, escapeHtml as e, formatBytes, characterCount, mergeEvents, normalizeBaseUrl, safeDownloadUrl, statusLabel, storageKey } from './model';
import type { Device, ServerInfo, Session, StoredState, Transfer, TransferFile, WireEvent } from './model';
import { icon, platformIcon } from './icons';
import { dockScopeKey, expiryLabel, fileItemKey, localTextDeadline, textItemKey, visibleLocalEvents } from './dock';
import type { HiddenItems } from './dock';
import { RtcFileChannel, RtcFileStore, rtcStorageSupported } from './rtc';
import type { RtcScope, RtcView } from './rtc';
import type { RoutePreference, FolderReuseRequest, FolderReuseReceipt } from '../../packages/protocol/src/index';
import { LocalLibraryView } from './library_view';
import type { LocalFileEntry } from './library';
import { RtcProbeMonitor, orientedProbeAddresses } from './rtc_probe';
import { droppedFiles, completeFolderParts, directoryParts } from './folder';
import { acceptsWindowDrop, droppedText, WindowDropFeedback } from './drop';
import { prepareFolderSend, emptyFileHash } from './folder_send';
import type { OfferFile } from './folder_send';
import type { QueueOffer } from './send_batch';
import { localStorageSupported } from './storage';
import { exportFolderEntries } from './folder_export';
import type { FolderPart } from './folder';
import { SharedGroupEditor } from './shared_text';
import type { SharedDocument } from './shared_text';
import { filePreviewKind, readLocalText } from './library';
import { workspaceHtml, dockHtml, fileCard, historyHtml } from './workspace_view';
import { SendBatch } from './send_batch';
import { RecentDevices } from './recent_devices';
import { linkifyHtml, webLinkActions } from './web_links';
import { enableTextSelection, isTextSelectionTarget, isTextSelectionPoint, textSelectionActive } from './text_selection';
import { LocalHistory } from './local_history';
import { DirectConnectionBudget, ConnectAttempt, preferredScopes, verifiedScopeLatency } from './rtc_route';
import { groupIpSources, browserHostCandidates, literalIp, IP_GROUPS } from './ip_addresses';
import type { IpSource } from './ip_addresses';
import { applyTextDocuments } from './model';
import type { TextDocument } from './model';
import { WebNotifications } from './notifications';
import { MobileViewport } from './mobile_viewport';
import { PageDisplay } from './page_display';
import { AppearancePreferences, appearanceKey } from './appearance';
import type { AppearanceMode, AccentColor } from './appearance';

const app = document.querySelector<HTMLDivElement>('#app')!;
const brand = `<button class="brand brand-button" type="button" data-action="ip-addresses" aria-label="GlobalSend，本机地址">GlobalSend</button>`;
const id = () => crypto.randomUUID();
const fileKey = (transferId: string,fileId: string) => `${transferId}:${fileId}`;
const time = (date: string) => new Intl.DateTimeFormat('zh-CN',{hour:'2-digit',minute:'2-digit'}).format(new Date(date));
const errorText = (error: unknown) => error instanceof Error ? error.message : '操作失败，请重试。';
class ReceiveStorageError extends Error {}
async function receiveStorage<T>(action:()=>Promise<T>):Promise<T> {
  try{return await action();}catch(error){throw new ReceiveStorageError(errorText(error));}
}
const localGet = (key: string) => { try { return sessionStorage.getItem(key); } catch { return null; } };
const localSet = (key: string,value: string) => { try { sessionStorage.setItem(key,value); } catch { /* Session still works in memory if storage is unavailable. */ } };
const rememberedGet = (key: string) => { try { return localStorage.getItem(key); } catch { return null; } };
const rememberedSet = (key: string,value: string) => { try { localStorage.setItem(key,value); } catch { /* Private browsing can keep the current session only. */ } };

interface TextView {
  event: WireEvent;
  scope: string;
  draft: string;
  savedText: string;
  busy: boolean;
  composing: boolean;
  error: string;
  saved: boolean;
  element: HTMLTextAreaElement|null;
  displayElement?:HTMLPreElement;
}

class GlobalSend {
  clipboardSuggestion: ClipboardSuggestionKind | null = null;
  private clipboardSuggestionDismissed=false;
  private clipboardSuggestionBusy=false;
  textSelectionRenderPending=false;
  private formComposing:HTMLElement|null=null;
  private workspaceViewKey='';
  private viewAnimation:Animation|null=null;
  constructor() {
    document.addEventListener('click',event=>{
      const target=event.target as Element,card=target.closest<HTMLElement>('[data-read],[data-open-text],[data-open-file]');
      if(!card || window.getSelection?.()?.isCollapsed===false)return;
      const control=target.closest('button,a,input,textarea,select');
      if(control && !control.matches('[data-read]'))return;
      const text=card.dataset.read || card.dataset.openText;
      if(text)this.openText(text);
      else if(card.dataset.openFile){const [transferId,fileId]=card.dataset.openFile.split(':');void this.run(()=>this.openFilePreview(transferId,fileId));}
    });
    enableTextSelection(document,()=>{
      if(this.textSelectionRenderPending && !textSelectionActive(document)) {
        this.textSelectionRenderPending=false;this.render();
      }
    });
    document.addEventListener('compositionstart',event=>{
      const field=event.target as HTMLElement;
      if(field.matches?.('input,textarea'))this.formComposing=field;
    });
    const finishFormComposition=(event:Event)=>{
      if(event.target!==this.formComposing)return;
      this.formComposing=null;
      window.setTimeout(()=>{if(this.editorRenderPending){this.editorRenderPending=false;this.render();}},0);
    };
    document.addEventListener('compositionend',finishFormComposition);
    document.addEventListener('focusout',finishFormComposition);
    new MobileViewport(window,document);
    window.addEventListener('storage',event=>{if(event.key===appearanceKey)this.appearance.reload();});
  }
  appearance=new AppearancePreferences(document,()=>rememberedGet(appearanceKey),value=>rememberedSet(appearanceKey,value));
  pageDisplay=new PageDisplay(document,window,()=>{if(!this.loading)this.render();});
  baseUrl = baseFromLocation(location);
  api = new Api(this.baseUrl);
  info: (ServerInfo & {enrollment?:{groupKey:boolean;allowGroupCreation:boolean;minGroupKeyLength:number;legacyBootstrap?:boolean}})|null = null;
  session: Session|null = null;
  loading = true;
  startupError = '';
  devices: Device[] = [];
  recentDevices=new RecentDevices();
  deviceGraceTimer=0;
  deviceNames=new Map<string,string>();
  localHistory=new LocalHistory(()=>rememberedGet('globalsend:local-history'),value=>rememberedSet('globalsend:local-history',value));
  private retainedSources=new Map<string,File>();
  private knownLibraryKeys=new Set<string>();
  events: WireEvent[] = [];
  transfers: Transfer[] = [];
  cursor = 0;
  target = '';
  text = '';
  tab: 'text'|'files' = 'text';
  mobileView: 'receive'|'send' = 'send';
  contentView:'receive'|'sent'|'library'='receive';
  filter: 'all'|'text'|'files' = 'all';
  selected = new Set<string>();
  receiveSelecting=false;
  private heldCardKey='';
  private cardHoldTimer=0;
  sentSelecting=false;
  sentSelected=new Set<string>();
  hiddenItems: HiddenItems = {};
  receivedAt:Record<string,string>={};
  readingEventId = '';
  textViews = new Map<string,TextView>();
  expiredTextCount = 0;
  expanded = new Set<string>();
  consent = new Map<string,boolean>();
  autoAccept = true;
  autoAcceptMaxBytes = 32 * 1024 * 1024;
  autoAcceptLimitDraft:string|null=null;
  private autoAcceptLimitElement:HTMLInputElement|null=null;
  rememberDevice = true;
  accepting = new Set<string>();
  autoAcceptRetryAt = new Map<string,number>();
  selectingRelays = new Set<string>();
  relayRetryAt = new Map<string,number>();
  routePreference:RoutePreference='auto';
  rtcStore:RtcFileStore|null=null;
  rtcRegisteredAt=0;
  rtcRegistering:Promise<void>|null=null;
  rtcClosing:Promise<void>=Promise.resolve();
  rtcUnavailable=false;
  rtcChannels=new Map<string,RtcFileChannel>();
  rtcReceives=new Map<string,AbortController>();
  rtcAttempts=new Map<string,string>();
  rtcLocalFiles=new Map<string,File>();
  rtcFileExpiry=new Map<string,number>();
  rtcRestoring=new Set<string>();
  rtcCacheRevision=0;
  relayConfirmed=new Set<string>();
  rtcProbes:RtcProbeMonitor|null=null;
  private rtcProbeScope='';
  picked: File[] = [];
  stagedTexts:{id:string;text:string;target?:string}[]=[];
  editingStagedId='';
  queueSending=false;
  retryingFailedSends=false;
  multiSend=false;
  selectedTargets=new Set<string>();
  sendBatch:SendBatch|null=null;
  private sentFeedback=new Map<string,number>();
  private speedSamples=new Map<string,{at:number;bytes:number;speed:number}>();
  private internalPayload:{text?:string;file?:File;files?:File[];libraryId?:string;receivedKey?:string}|null=null;
  private dragOriginOnText=false;
  receipt:{id:string;version:string;source:string;title:string;text?:string;fileKey?:string;receivedAt?:string}|null=null;
  pendingReceipt:GlobalSend['receipt']=null;
  receiptBatch=new Map<string,NonNullable<GlobalSend['receipt']>>();
  private folderReceiptRenderQueued=false;
  receiptFocusId='';
  private receiptVersions=new Map<string,string>();
  private receiptsInitialized=false;
  contextMenu:{kind:'text'|'file'|'receipt';key:string;x:number;y:number}|null=null;
  private modalClosing=false;
  private modalOpenedAt=0;
  private renderedModalKey='';
  private receiptBindings=new WeakMap<HTMLElement,Set<string>>();
  pendingNotificationId='';
  notifications=new WebNotifications({onOpen:itemId=>{this.pendingNotificationId=itemId;this.openNotificationReceipt();},onChange:()=>{if(!this.loading)this.render();}});
  folderNames=new WeakMap<File,string>();
  folderParts=new WeakMap<File,FolderPart[]>();
  folderRegisteredScope='';
  private folderRegistering:Promise<void>|null=null;
  private storeStarting:Promise<RtcFileStore>|null=null;
  receiveDestination='浏览器文件库';
  transferConcurrency=4;
  get activeFileTransfers(){return this.uploads.size+this.rtcReceives.size;}
  private receiveDirectoryChanging=false;
  private librarySourceIds=new WeakMap<File,string>();
  previews=new Map<string,{url?:string;text?:string;kind:'image'|'text'|'file'}>();
  previewSources=new Map<string,File>();
  previewLoading=new Set<string>();
  previewFailed=new Set<string>();
  pickedKeys=new WeakMap<File,string>();
  previewKey=0;
  folderBusy=false;
  private dropInstalled=false;
  private windowDropVisible=false;
  private readonly internalDragType='application/x-globalsend-source-'+id();
  private folderPickerGeneration:number|null=null;
  private groupEditors=new Map<string,SharedGroupEditor>();
  get shared(){return this.sharedForGroup(this.session?.groupId || '');}
  private sharedForGroup(groupId:string){const key=this.key+':'+this.session?.device.deviceId+':'+(this.info?.features?.multiGroup?'multi:':'single:')+groupId;let editor=this.groupEditors.get(key);if(!editor){editor=new SharedGroupEditor(()=>this.api,()=>this.render(),this.info?.features?.multiGroup?groupId:'');this.groupEditors.set(key,editor);}return editor;}
  fileSources = new Map<string,File>();
  uploads = new Map<string,AbortController>();
  hashes = new Set<AbortController>();
  paused = new Set<string>();
  canceled = new Set<string>();
  cancelRequests = new Set<string>();
  fileRequests = new Map<string,AbortController>();
  receiveReports = new Map<string,Promise<void>>();
  uploadErrors = new Map<string,string>();
  uploadProgress = new Map<string,number>();
  handed = new Set<string>();
  pendingTexts: {eventId:string;targetDeviceId:string;text:string;error:string;busy:boolean}[] = [];
  pendingOffer: QueueOffer|null = null;
  libraryForward: {transferId:string;targetDeviceId:string;routePreference:RoutePreference;entryIds:string[];files:(OfferFile & {fileId:string})[]}|null=null;
  fileLibrary=new LocalLibraryView({
    changed:()=>{if(this.modal==='library' || this.contentView==='library')this.render();},
    inventory:entries=>this.syncLibraryCache(entries),
    close:()=>{this.modal=null;this.contentView='receive';this.render();},
    peers:()=>this.peers(),signedIn:()=>!!this.session,copy:text=>this.copy(text),
    stage:file=>{this.addFiles([file]);this.setMobileView('send');},stageEntry:entry=>this.stageLibraryEntry(entry),
    forward:(entries,target)=>this.forwardLibraryFiles(entries,target),
    pendingForward:()=>!!this.libraryForward,discardForward:()=>this.discardLibraryForward(),
  });
  busy = false;
  preparation = '';
  ws: WebSocket|null = null;
  connecting = false;
  private socketEpoch=0;
  connected = false;
  helloReceived=false;
  discoveryEpoch=0;
  discoveryRefresh:Promise<void>|null=null;
  discoveryRefreshedAt=0;
  localReferencesRestoring:Promise<void>|null=null;
  deviceSnapshotRevision=0;
  syncing = false;
  refreshWait:Promise<void>=Promise.resolve();
  syncAgain = false;
  reconnectTimer = 0;
  reconnectAttempt = 0;
  generation = 0;
  refreshTimer = 0;
  acked = new Set<string>();
  modal: 'settings'|'pair'|'reader'|'editor'|'library'|'history'|'file-preview'|'receipt'|'ip-addresses'|'device-network'|null = null;
  private networkDevice='';
  private deviceHold:ReturnType<typeof setTimeout>|null=null;
  private heldDevice='';
  private deviceHoldOrigin:{x:number;y:number}|null=null;
  openDeviceNetwork(deviceId:string){this.networkDevice=deviceId;this.modal='device-network';this.render();void this.rtcProbes?.refreshPeer(deviceId);}
  deviceNetworkHtml(){
    const peer=this.device(this.networkDevice),self=this.session?.device.deviceId;
    const results=(this.rtcProbes?.results || []).filter(result=>[result.initiatorDeviceId,result.responderDeviceId].includes(this.networkDevice) && [result.initiatorDeviceId,result.responderDeviceId].includes(self || '') && Date.parse(result.expiresAt)>Date.now()).sort((a,b)=>b.checkedAt.localeCompare(a.checkedAt));
    const candidates=(peer?.peer?.candidates || []).map(value=>literalIp(value)).filter((value):value is NonNullable<typeof value>=>!!value);
    return `<div class="modal-backdrop"><section class="modal device-network-modal" role="dialog" aria-modal="true" aria-labelledby="device-network-title"><div class="modal-header"><h2 id="device-network-title">${e(this.deviceLabel(this.networkDevice))}</h2><button class="icon-button quiet" data-action="close-modal" aria-label="关闭连接检测">${icon('close')}</button></div><p class="muted">本机与此设备 · RTC 路径检测</p><div class="device-network-paths">${(['lan','public'] as const).map(scope=>{const result=results.find(item=>item.scope===scope);return `<div class="setting-row"><span>${scope==='lan'?'局域网':'公网'} · RTC</span><span>${result?result.success?`可达 · ${result.elapsedMs} ms`:'本次未连通':'未测试'}${result?` · ${time(result.checkedAt)}`:''}</span>${result?.success?(()=>{const {source,target}=orientedProbeAddresses(result,self || '');return `<code class="probe-addresses">${source && target?`${e(source)} → ${e(target)}`:`源：${e(source || '未获取')}<br>目标：${e(target || '未获取')}`}</code>`;})():''}</div>`;}).join('')}<div class="setting-row"><span>中继中心</span><span>${this.connected?'已连接':'未连接'}</span></div></div>${candidates.length?`<div class="modal-section"><h3>对方地址</h3>${candidates.map(value=>`<p><small>${IP_GROUPS[value.group]} · 未单独检测</small><br><code>${e(value.address)}</code></p>`).join('')}</div>`:''}<p class="device-network-note muted">浏览器通过 RTC 测试；没有公开地址时不显示 IP。中心连接不代表端到端文件已通过。</p><button class="secondary" data-action="refresh-device-network">${icon('retry')}重新检测</button></section></div>`;
  }
  ipSources:IpSource[]=[];
  ipLoading=false;
  ipError='';
  private ipAbort:AbortController|null=null;
  async openIpAddresses(){
    this.ipAbort?.abort();const request=new AbortController();this.ipAbort=request;
    const own=this.devices.find(device=>device.deviceId===this.session?.device.deviceId);
    const known=[...(own?.peer?.candidates || this.session?.device.peer?.candidates || []),...(this.rtcProbes?.ownCandidates || []),...[...this.rtcChannels.values()].flatMap(channel=>channel.ownCandidates)];
    this.ipSources=groupIpSources(known);this.ipLoading=true;this.ipError='';this.modal='ip-addresses';this.render();
    try {
      const gathered=await browserHostCandidates(request.signal);
      if(request.signal.aborted || this.modal!=='ip-addresses')return;
      this.ipSources=groupIpSources([...known,...gathered]);
    } catch {if(!request.signal.aborted)this.ipError='无法读取本机地址';}
    finally {if(!request.signal.aborted && this.modal==='ip-addresses'){this.ipLoading=false;this.render();}}
  }
  stageIpAddress(address:string){
    if(!this.ipSources.some(source=>source.groups.some(group=>group.addresses.includes(address))))return;
    this.ipAbort?.abort();this.stagedTexts.push({id:id(),text:address});this.modal=null;this.setMobileView('send');this.render();
  }
  openedFile:{key:string;name:string;size:number;source:string;createdAt:string;route:string;status:string}|null=null;
  editorElement: HTMLTextAreaElement|null = null;
  editorComposing = false;
  editorRenderPending = false;
  groupKey = '';
  showGroupKey = false;
  deviceName = suggestedDeviceName(navigator);
  deviceNameDraft: string|null = null;
  deviceNameBusy = false;
  deviceNameError = '';
  pairError = '';
  pairBusy = false;
  serverDraft = this.baseUrl;
  resumeKey = '';
  fileInputsInstalled = false;
  filePickerGeneration: number|null = null;
  resumePicker: {generation:number;key:string}|null = null;

  async start() {
    this.installFileInputs();
    this.installWindowDrop();
    this.render();
    try {
      this.info = await this.api.request<ServerInfo>('/info');
      if (this.info.protocolVersion !== 1) throw new Error('此中心协议版本不受支持，请更新客户端。');
      this.rememberDevice = rememberedGet(this.key + ':remember') !== 'false';
      const stored = (this.rememberDevice ? rememberedGet(this.key + ':session') : null) || localGet(this.key + ':session');
      if (stored) {
        try { this.session = JSON.parse(stored); this.api.session = this.session; } catch { this.session = null; }
      }
      this.loadPreferences();
      if(this.session)this.saveSession();
      const scopedState = localGet(this.dockKey);
      const state = scopedState || localGet(this.key + ':state');
      if (state && this.session) {
        try {
          const parsed: StoredState = JSON.parse(state);
          this.hiddenItems = parsed.hidden || {};
          this.receivedAt=parsed.receivedAt || {};
          this.events = visibleLocalEvents(mergeEvents([],parsed.events.filter(event=>event.sourceDeviceId===this.session!.device.deviceId || event.targetDeviceId===this.session!.device.deviceId)),this.hiddenItems);
          this.cursor = scopedState && Number.isSafeInteger(parsed.cursor) ? parsed.cursor : 0;
          this.persist();localSet(this.key + ':state','');
        } catch { /* Ignore an incomplete local snapshot. */ }
      }
      if (this.session) await this.refresh();
    } catch (error) { this.startupError = errorText(error); }
    this.loading = false;
    this.render();
    void this.restoreLocalReferences();
    if (this.session) this.connect();
    this.refreshTimer = window.setInterval(() => {
      if(document.visibilityState==='visible' && (this.modal==='library' || this.contentView==='library'))void this.fileLibrary.refresh();
      if (document.visibilityState !== 'visible' || !this.session) return;
      this.pruneLocal();this.persist();this.render();
      if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({type:'ping'}));
      void this.refresh();
    },20000);
    const networkChanged=()=>this.networkChanged();
    window.addEventListener('online',networkChanged);
    window.addEventListener('offline',()=>this.syncProbeMonitor());
    window.addEventListener('focus',()=>{this.resumeDiscovery();void this.refreshClipboardSuggestion();});
    window.addEventListener('blur',()=>{this.clipboardSuggestionDismissed=false;});
    window.addEventListener('pageshow',()=>{this.resumeDiscovery();void this.refreshClipboardSuggestion();});
    (navigator as Navigator & {connection?:EventTarget}).connection?.addEventListener('change',networkChanged);
    document.addEventListener('visibilitychange',() => {
      this.syncProbeMonitor();
      if(document.visibilityState==='visible' && this.modal==='library')void this.fileLibrary.refresh();
      if (document.visibilityState === 'visible') {this.resumeDiscovery();void this.refreshClipboardSuggestion();}
    });
    window.addEventListener('beforeunload',event => {
      if (this.uploads.size || this.rtcReceives.size || this.busy || this.pendingTexts.length || this.pendingOffer || this.libraryForward || this.stagedTexts.length || this.shared.dirty || [...this.textViews.values()].some(view=>view.busy || view.draft!==view.savedText)) { event.preventDefault(); event.returnValue = ''; }
    });
  }
  get key() { return storageKey(this.baseUrl,this.info?.instanceId || 'unknown'); }
  networkChanged(){
    if(!this.session)return;
    this.discoveryEpoch++;this.rtcRegisteredAt=0;this.discoveryRefreshedAt=0;
    void this.rtcProbes?.networkChanged(()=>this.probeForeground());
    this.connect(true);void this.refreshDiscovery();
  }
  resumeDiscovery() {
    if(!this.session || document.visibilityState!=='visible')return;
    this.expireDevices();
    this.pruneLocal();this.persist();this.render();this.connect();void this.refreshDiscovery();void this.restoreLocalReferences();
  }
  /** User/lifecycle refresh publishes first. Broadcast readers never republish. */
  refreshDiscovery() {
    if(!this.session)return Promise.resolve();
    if(this.discoveryRefresh)return this.discoveryRefresh;
    if(Date.now()-this.discoveryRefreshedAt<400)return Promise.resolve();
    const generation=this.generation;
    const refresh=(async()=>{
      this.discoveryRefreshedAt=Date.now();
      const probes=this.rtcProbes;
      await probes?.setForeground(false);
      if(generation!==this.generation || !this.session)return;
      this.rtcRegisteredAt=0;
      await this.ensureRtc(true);
      if(generation!==this.generation || !this.session)return;
      await this.refresh();
      if(generation!==this.generation || !this.session)return;
      this.syncProbeMonitor();
      await this.rtcProbes?.setForeground(this.probeForeground());
      await this.rtcProbes?.refreshAllPeers();
    })();
    this.discoveryRefresh=refresh;
    return refresh.finally(()=>{if(this.discoveryRefresh===refresh)this.discoveryRefresh=null;});
  }
  get dockKey() { return dockScopeKey(this.key,this.session?.device.deviceId || 'none',this.session?.historyGroupId ?? this.session?.groupId); }
  saveSession() {
    const value = this.session ? JSON.stringify(publicSession(this.session)) : '';
    localSet(this.key + ':session',value);
    rememberedSet(this.key + ':remember',String(this.rememberDevice));
    rememberedSet(this.key + ':session',this.rememberDevice ? value : '');
  }
  loadPreferences() {
    for(const editor of this.groupEditors.values())editor.reset();this.groupEditors.clear();
    this.receivedAt={};
    this.autoAcceptLimitDraft=null;this.autoAcceptLimitElement=null;
    const route=this.session?rememberedGet(this.dockKey+':route'):null;
    this.routePreference=['auto','lan','public','relay'].includes(route || '')?route as RoutePreference:'auto';
    this.autoAccept = this.session ? rememberedGet(this.dockKey + ':autoAccept') !== 'false' : true;
    const stored=this.session?rememberedGet(this.dockKey + ':autoAcceptMaxBytes'):null;
    const limit=stored===null?NaN:Number(stored);
    this.autoAcceptMaxBytes=Number.isSafeInteger(limit) && limit>=0?limit:32*1024*1024;
    const concurrency=Number(this.session?rememberedGet(this.dockKey+':transferConcurrency'):null);
    this.transferConcurrency=Number.isInteger(concurrency) && concurrency>=1 && concurrency<=16?concurrency:4;
  }
  setTransferConcurrency(value:number){
    if(!Number.isInteger(value) || value<1 || value>16)throw new Error('并发数为 1–16');
    this.transferConcurrency=value;
    if(this.session)rememberedSet(this.dockKey+':transferConcurrency',String(value));
    this.render();this.startReadyUploads();void this.selectIncomingRelays();
  }
  setAutoAcceptLimit(megabytes: number) {
    const bytes=Math.round(megabytes*1024*1024);
    if(!Number.isFinite(megabytes) || megabytes<0 || !Number.isSafeInteger(bytes))throw new Error('请输入有效的文件大小。');
    this.autoAcceptMaxBytes=bytes;
    this.autoAcceptLimitDraft=null;
    if(this.session)rememberedSet(this.dockKey+':autoAcceptMaxBytes',String(bytes));
    this.autoAcceptRetryAt.clear();this.render();if(this.autoAccept)void this.acceptIncoming();
  }
  setAutoAccept(enabled: boolean) {
    this.autoAccept = enabled;
    if(this.session)rememberedSet(this.dockKey + ':autoAccept',String(enabled));
    this.autoAcceptRetryAt.clear();this.render();
    if(enabled)void this.acceptIncoming();
  }
  mountAutoAcceptLimit() {
    const rendered=document.querySelector<HTMLInputElement>('#auto-accept-limit');if(!rendered)return;
    let field=this.autoAcceptLimitElement;
    if(!field) {
      field=rendered;this.autoAcceptLimitElement=field;
      const input=field,scope=this.dockKey;
      const current=()=>this.autoAcceptLimitElement===input && this.dockKey===scope;
      input.addEventListener('input',()=>{if(current())this.autoAcceptLimitDraft=input.value;});
      input.addEventListener('change',()=>{
        if(!current())return;
        this.autoAcceptLimitDraft=input.value;
        if(!input.value.trim())return;
        try{this.setAutoAcceptLimit(Number(input.value));}catch(error){this.toast(errorText(error),true);}
      });
    } else if(field!==rendered)rendered.replaceWith(field);
    const value=this.autoAcceptLimitDraft ?? String(this.autoAcceptMaxBytes/1048576);
    // Reusing the number input also retains native caret/selection and undo,
    // which selectionStart/setSelectionRange do not expose for this input type.
    if(field.value!==value)field.value=value;
  }
  setMobileView(view: 'receive'|'send') {
    this.mobileView=view;
    document.querySelector<HTMLElement>('.workspace')?.setAttribute('data-mobile-view',view);
    document.querySelectorAll<HTMLButtonElement>('[data-mobile-view-button]').forEach(button=>{
      const active=button.dataset.mobileViewButton===(view==='send'?'send':this.contentView);
      button.setAttribute('aria-selected',String(active));button.classList.toggle('active',active);
    });
    this.animateWorkspaceView();
  }
  setMobileDestination(view:'send'|'receive'|'sent'|'library') {
    if(view==='send'){this.setMobileView('send');return;}
    const changed=this.contentView!==view;
    this.contentView=view;
    if(changed){this.mobileView='receive';this.render();}else this.setMobileView('receive');
    if(view==='library')void this.openLibrary();
  }
  animateWorkspaceView() {
    const mobile=typeof window.innerWidth==='number' && window.innerWidth<=760;
    const key=mobile?(this.mobileView==='send'?'send':this.contentView):this.contentView;
    const previous=this.workspaceViewKey;this.workspaceViewKey=key;
    if(!previous)return;
    const target=document.querySelector<HTMLElement>(mobile?(this.mobileView==='send'?'#send-panel':'#receive-panel'):'#right-content');
    if(!target?.animate || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches)return;
    if(previous===key){
      const running=this.viewAnimation,effect=running?.effect;
      if(running?.playState==='running' && effect instanceof KeyframeEffect && effect.target!==target){
        const elapsed=running.currentTime,keyframes=effect.getKeyframes(),timing=effect.getTiming();running.cancel();
        this.viewAnimation=target.animate(keyframes,timing);if(elapsed!==null)this.viewAnimation.currentTime=elapsed;
      }
      return;
    }
    this.viewAnimation?.cancel();
    const order=['send','receive','sent','library'],direction=order.indexOf(key)<order.indexOf(previous)?-1:1;
    this.viewAnimation=target.animate([{opacity:0,transform:`translateX(${direction*16}px)`},{opacity:1,transform:'translateX(0)'}],{duration:180,easing:'ease-out'});
  }
  installFileInputs() {
    if(this.fileInputsInstalled)return;
    this.fileInputsInstalled=true;
    const input=document.querySelector<HTMLInputElement>('#file-input')!;
    const resume=document.querySelector<HTMLInputElement>('#resume-file')!;
    let folder=document.querySelector<HTMLInputElement>('#folder-input');
    if(!folder){folder=document.createElement('input');folder.type='file';folder.id='folder-input';folder.hidden=true;folder.multiple=true;folder.setAttribute('webkitdirectory','');document.body.append(folder);}
    const directoryInput=folder;
    directoryInput.addEventListener('change',()=>{
      const generation=this.folderPickerGeneration,files=Array.from(directoryInput.files || []);this.folderPickerGeneration=null;directoryInput.value='';
      if(generation!==this.generation || !this.session || !files.length)return;
      const groups=new Map<string,FolderPart[]>();
      for(const file of files){const path=file.webkitRelativePath || file.name,name=path.split('/')[0];const parts=groups.get(name) || [];parts.push({path,file});groups.set(name,parts);}
      void this.run(()=>this.addFolders([...groups].map(([name,parts])=>({name,parts}))));
    });
    input.addEventListener('change',()=>{
      const generation=this.filePickerGeneration,files=Array.from(input.files || []);
      this.filePickerGeneration=null;input.value='';
      if(generation!==this.generation || !this.session)return;
      this.addFiles(files);
    });
    resume.addEventListener('change',()=>{
      const picker=this.resumePicker,file=resume.files?.[0];
      this.resumePicker=null;resume.value='';
      if(!picker || picker.generation!==this.generation || !this.session || !file)return;
      void this.run(()=>this.attachResumeSource(file,picker.key));
    });
    input.addEventListener('cancel',()=>{this.filePickerGeneration=null;input.value='';});
    resume.addEventListener('cancel',()=>{this.resumePicker=null;resume.value='';});
  }
  openFilePicker(resumeKey?: string, media = false) {
    this.installFileInputs();
    if(resumeKey){this.resumeKey=resumeKey;this.resumePicker={generation:this.generation,key:resumeKey};}
    else this.filePickerGeneration=this.generation;
    const input=document.querySelector<HTMLInputElement>(resumeKey?'#resume-file':'#file-input')!;
    input.accept=media && !resumeKey?'image/*,video/*':'';
    input.value='';input.click();
  }
  clearFilePickers() {
    this.filePickerGeneration=null;this.resumePicker=null;this.resumeKey='';
    this.folderPickerGeneration=null;
    for(const selector of ['#file-input','#resume-file','#folder-input']){
      const input=document.querySelector<HTMLInputElement>(selector);if(input)input.value='';
    }
  }
  mountEditor() {
    const host=document.querySelector<HTMLElement>('[data-editor-host]');
    if(!host)return;
    if(!this.editorElement){
      const field=document.createElement('textarea');
      field.id='send-text';field.className='text-input';field.placeholder='输入或粘贴文字';
      field.setAttribute('aria-label','要发送的文字');
      field.addEventListener('input',()=>{
        if(field!==this.editorElement || !this.session)return;
        this.text=field.value;this.updateEditorChrome();
      });
      field.addEventListener('compositionstart',()=>{if(field===this.editorElement)this.editorComposing=true;});
      field.addEventListener('compositionend',()=>{
        if(field!==this.editorElement || !this.session)return;
        this.text=field.value;this.editorComposing=false;this.updateEditorChrome();
        if(this.editorRenderPending){this.editorRenderPending=false;this.render();}
      });
      field.addEventListener('keydown',event=>{
        if(field!==this.editorElement || !this.session)return;
        if(event.key!=='Enter' || !(event.ctrlKey || event.metaKey) || event.isComposing || this.editorComposing)return;
        event.preventDefault();
        if(this.text.trim() && !this.busy)this.stageDraft();
      });
      this.editorElement=field;
    }
    const field=this.editorElement;
    field.maxLength=this.info?.limits.maxTextLength || 100000;
    // Reuse the textarea itself: ordinary reconciliation must not reset native
    // editing/undo state. Only a real draft change (e.g. Send) assigns its value.
    if(field.value!==this.text)field.value=this.text;
    host.append(field);this.updateEditorChrome();
  }
  updateEditorChrome() {
    const count=document.querySelector('#text-count');if(count)count.textContent=`${characterCount(this.text)} 字符`;
    document.querySelectorAll<HTMLButtonElement>('[data-text-send]').forEach(button=>{button.disabled=!this.text.trim() || this.busy;});
  }
  toggleEditor(expanded: boolean) {
    if(!expanded){this.closeModal();return;}
    const field=this.editorElement;
    const selection=field?{start:field.selectionStart,end:field.selectionEnd,direction:field.selectionDirection,scroll:field.scrollTop}:null;
    this.modal=expanded?'editor':null;this.render();
    const next=this.editorElement;
    if(next){next.focus({preventScroll:true});if(selection){next.setSelectionRange(selection.start,selection.end,selection.direction);next.scrollTop=selection.scroll;}}
  }
  stageDraft(){
    if(!this.text.trim())return;
    const existing=this.stagedTexts.find(item=>item.id===this.editingStagedId && !item.target);
    if(existing)existing.text=this.text;else this.stagedTexts.push({id:id(),text:this.text});
    this.editingStagedId='';this.text='';if(this.editorElement)this.editorElement.value='';this.modal=null;this.setMobileView('send');this.render();
  }
  async refreshClipboardSuggestion(){
    if(!this.session || document.visibilityState!=='visible' || this.clipboardSuggestionBusy || this.clipboardSuggestionDismissed)return;
    this.clipboardSuggestionBusy=true;const generation=this.generation;
    try {
      const kind=await clipboardSuggestion(navigator);
      if(generation===this.generation && kind!==this.clipboardSuggestion){this.clipboardSuggestion=kind;this.render();}
    } finally {this.clipboardSuggestionBusy=false;}
  }
  async readClipboard(){
    if(!this.session)return;
    const generation=this.generation;
    try {
      if(navigator.clipboard?.read){
        const values=await navigator.clipboard.read();if(generation!==this.generation)return;
        let added=0;
        for(const value of values){
          const image=value.types.find(type=>type.startsWith('image/'));
          if(image){const blob=await value.getType(image);if(generation!==this.generation)return;this.addFiles([new File([blob],`剪贴板-${Date.now()}.${image.split('/')[1] || 'png'}`,{type:image})]);added++;}
          else if(value.types.includes('text/plain') || value.types.includes('text/html')){
            const type=value.types.includes('text/plain')?'text/plain':'text/html',blob=await value.getType(type);
            let text=await blob.text();if(type==='text/html')text=new DOMParser().parseFromString(text,'text/html').body.textContent || '';
            if(generation!==this.generation)return;if(text.trim()){this.stagedTexts.push({id:id(),text});added++;}
          }
        }
        if(!added)return;
      }else if(navigator.clipboard?.readText){const text=await navigator.clipboard.readText();if(generation!==this.generation)return;if(!text.trim())return;this.stagedTexts.push({id:id(),text});}
      else throw new Error('浏览器不支持读取剪贴板，请粘贴到文本框');
      this.clipboardSuggestion=null;this.clipboardSuggestionDismissed=true;
      this.setMobileView('send');this.render();
    }catch(error){this.toast(error instanceof DOMException && error.name==='NotAllowedError'?'请允许读取剪贴板，或在文本框中粘贴':errorText(error),true);}
  }
  async sendQueue(targets=this.multiSend?[...this.selectedTargets]:[this.target],selection?:{files:File[];texts:{id:string;text:string;target?:string}[]}){
    if(this.receiveDirectoryChanging)return;
    if(this.pendingOffer){if(selection){this.toast('拖入内容已保留，请先处理上次发送。');return;}await this.sendFiles(this.pendingOffer.targetDeviceId);return;}
    const files=selection?.files ?? this.picked,texts=selection?.texts ?? this.stagedTexts;
    if(this.queueSending || this.busy || (!files.length && !texts.length))return;
    const recipients=[...new Set(targets)].filter(Boolean);if(!recipients.length)return;
    this.multiSend=false;this.selectedTargets.clear();
    const generation=this.generation;
    if(!this.sendBatch?.matches(files,texts))this.sendBatch=new SendBatch(files,texts,this.rtcEnabled?this.routePreference:'relay');
    const batch=this.sendBatch;this.queueSending=true;this.contextMenu=null;
    for(const target of recipients){const progress=batch.target(target);if(progress.state!=='sent')progress.state='queued';}
    this.render();
    try {
      if(!batch.metadata){
        const prepared=await prepareFolderSend(batch.files,file=>this.folderParts.get(file),file=>this.digest(file),this.info?.limits.maxFileSize || 0);
        if(generation!==this.generation)return;batch.metadata=prepared.metadata;batch.sources=prepared.sources;
      }
      for(const target of recipients){
        const progress=batch.target(target);if(progress.state==='sent')continue;
        progress.state='sending';this.render();
        try {
          if(!this.isSendablePeer(target))throw new Error('目标设备已离线');
          while(progress.nextText<batch.texts.length){
            const index=progress.nextText;
            await this.api.request('/texts',{eventId:progress.textIds[index],targetDeviceId:target,text:batch.texts[index].text});
            if(generation!==this.generation)return;progress.nextText++;
          }
          if(batch.files.length && !progress.filesSent){
            if(['lan','public'].includes(this.routePreference) && !this.rtcEnabled)throw new Error('当前浏览器或中心暂不支持直连');
            this.requireFolderReceiver(target,batch.metadata!);
            progress.offer ||= {transferId:id(),targetDeviceId:target,routePreference:batch.route,files:batch.metadata!.map(file=>({...file,fileId:id()}))};
            this.rememberOfferSources(progress.offer,batch.sources,batch.files);
            const {transfer}=await this.api.request<{transfer:Transfer}>('/transfers',progress.offer);
            if(generation!==this.generation)return;
            this.transfers=[transfer,...this.transfers.filter(item=>item.transferId!==transfer.transferId)];progress.filesSent=true;
          }
          progress.state='sent';
          this.sentFeedback.set(target,Date.now()+2500);
          window.setTimeout(()=>{if(generation===this.generation)this.render();},2600);
        }catch(error){if(generation!==this.generation)return;progress.state='failed';this.toast(`${this.deviceLabel(target)}：${errorText(error)}`,true);}
      }
      if(batch.complete){
        this.picked=this.picked.filter(file=>!batch.files.includes(file));
        this.stagedTexts=this.stagedTexts.filter(item=>!batch.texts.some(sent=>sent.id===item.id && sent.text===item.text));
        this.selectedTargets.clear();
      }
      this.startReadyUploads();await this.refresh();
    }catch(error){if(generation===this.generation){for(const target of recipients)if(batch.target(target).state!=='sent')batch.target(target).state='failed';this.toast(errorText(error),true);}}
    finally {if(generation===this.generation){this.queueSending=false;this.render();}}
  }
  requireFolderReceiver(target:string,files:OfferFile[]){
    if(!files.some(file=>file.relativePath))return;
    if(!this.info?.features?.folderTransfer)throw new Error('中心需更新后才能传输文件夹');
    if(!this.device(target)?.folderTransfer)throw new Error('对方需更新后才能接收文件夹');
  }
  rememberOfferSources(offer:QueueOffer,sources:(File|undefined)[],selected:File[]){
    const parts=selected.flatMap(file=>this.folderParts.get(file) || []);
    offer.files.forEach((file,index)=>{
      let source=sources[index];
      if(file.entryKind==='directory'){
        source=new File([],file.name,{type:'inode/directory'});const path=file.relativePath!;
        this.folderParts.set(source,parts.filter(part=>part.path.replace(/\/$/,'')===path || part.path.startsWith(path+'/')));this.folderNames.set(source,path.split('/')[0]);
      }
      if(source)this.fileSources.set(fileKey(offer.transferId,file.fileId),source);
    });
  }
  async addFolders(folders:{name:string;parts:FolderPart[]}[]){
    for(const folder of folders){
      let name=folder.name,index=0;
      while(this.picked.some(file=>this.folderNames.get(file)===name))name=`${folder.name} (${++index})`;
      const parts=completeFolderParts(name,folder.parts.map(part=>({...part,path:name+part.path.slice(folder.name.length)})));
      const reference=new File([],name,{type:'inode/directory'});
      this.folderParts.set(reference,parts);this.folderNames.set(reference,name);this.addFiles([reference]);
    }
  }
  async pickFolder(){
    const picker=(window as Window & {showDirectoryPicker?:(options?:unknown)=>Promise<FileSystemDirectoryHandle>}).showDirectoryPicker;
    if(picker){const generation=this.generation;try{const handle=await picker({id:'globalsend-send-folder'});const parts=await directoryParts(handle);if(generation===this.generation)await this.addFolders([{name:handle.name,parts}]);}catch(error){if((error as Error).name!=='AbortError')throw error;}return;}
    this.installFileInputs();this.folderPickerGeneration=this.generation;const field=document.querySelector<HTMLInputElement>('#folder-input')!;field.value='';field.click();
  }
  installWindowDrop(){
    if(this.dropInstalled)return;this.dropInstalled=true;
    document.addEventListener('pointerdown',event=>{this.dragOriginOnText=isTextSelectionPoint(event);},true);
    document.addEventListener('click',event=>{if(this.contextMenu && !(event.target as Element).closest('.content-menu,[data-card-menu]')){this.contextMenu=null;document.querySelector('.content-menu')?.remove();}});
    document.addEventListener('keydown',event=>{
      if(event.defaultPrevented || event.isComposing || event.keyCode===229 || this.editorComposing || this.shared.composingActive || this.viewedText()?.composing || event.key!=='Escape')return;
      if(this.contextMenu){event.preventDefault();this.contextMenu=null;document.querySelector('.content-menu')?.remove();}
      else if(this.modal){event.preventDefault();this.modal==='editor'?this.toggleEditor(false):this.closeModal();}
      else if(this.contentView==='library' && this.fileLibrary.back())event.preventDefault();
      else if(this.exitSelection())event.preventDefault();
      else if(this.contentView!=='receive'){event.preventDefault();this.contentView='receive';this.render();}
    });
    const show=(visible:boolean)=>{this.windowDropVisible=visible;document.querySelector('#window-drop')?.classList.toggle('visible',visible);};
    const feedback=new WindowDropFeedback(show);
    const queue=(event:Event)=>(event.target as Element).closest?.('[data-queue-drop],[data-target]');
    const dropDevice=(event:DragEvent)=>(event.target as Element).closest<HTMLElement>('[data-target]')?.dataset.target || '';
    const external=(event:DragEvent)=>acceptsWindowDrop(event.dataTransfer);
    document.addEventListener('dragstart',event=>{const field=(event.target as Element).closest<HTMLElement>('[data-drag-shared]');if(field)this.beginContentDrag(event,field);});
    document.addEventListener('dragenter',event=>{if(!this.session)return;if(this.isInternalDrag(event)){if(queue(event))event.preventDefault();return;}if(!external(event))return;event.preventDefault();this.endContentDrag();feedback.enter();},true);
    document.addEventListener('dragover',event=>{
      if(!this.session)return;
      if(this.isInternalDrag(event)){const target=queue(event);document.querySelector('[data-queue-drop]')?.classList.toggle('queue-drop-active',!!target);if(target){event.preventDefault();if(event.dataTransfer)event.dataTransfer.dropEffect='copy';}return;}
      if(!external(event))return;event.preventDefault();this.endContentDrag();if(event.dataTransfer)event.dataTransfer.dropEffect='copy';feedback.enter();
    },true);
    document.addEventListener('dragleave',event=>{if(!this.session)return;if(!event.relatedTarget || !document.documentElement.contains(event.relatedTarget as Node))feedback.leave();const target=queue(event);if(target && !target.contains(event.relatedTarget as Node))target.classList.remove('queue-drop-active');},true);
    document.addEventListener('dragend',()=>{feedback.reset();this.endContentDrag();},true);
    document.addEventListener('keydown',event=>{if(event.key==='Escape'){feedback.reset();this.endContentDrag();}},true);
    document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden'){feedback.reset();this.endContentDrag();}});
    document.addEventListener('drop',event=>{
      feedback.reset();
      if(!this.session)return;
      if(this.isInternalDrag(event)){
        const payload=this.internalPayload,target=queue(event),device=dropDevice(event);this.endContentDrag();
        if(!target || !payload)return;event.preventDefault();event.stopPropagation();
        if(this.modal==='receipt')this.closeModal();
        void this.run(async()=>{
          const beforeFiles=this.picked.length,beforeTexts=this.stagedTexts.length;
          if(payload.libraryId){const entry=this.fileLibrary.entries.find(entry=>entry.id===payload.libraryId);if(entry)await this.stageLibraryEntry(entry);}
          else if(payload.receivedKey)await this.stageReceivedFile(payload.receivedKey);
          else if(payload.files)this.addFiles(payload.files);
          else if(payload.file)this.addFiles([payload.file]);
          if(payload.text?.trim()){this.stagedTexts.push({id:id(),text:payload.text});this.setMobileView('send');this.render();}
          if(device)await this.sendQueue([device],{files:this.picked.slice(beforeFiles),texts:this.stagedTexts.slice(beforeTexts)});
        });
        return;
      }
      if(!external(event))return;
      event.preventDefault();this.endContentDrag();const transfer=event.dataTransfer!,generation=this.generation,device=dropDevice(event);
      const files=droppedFiles(transfer),text=droppedText(transfer);
      void this.run(async()=>{const [content,value]=await Promise.all([files,text]);if(generation!==this.generation)return;const beforeFiles=this.picked.length,beforeTexts=this.stagedTexts.length;if(content.files.length)this.addFiles(content.files);if(content.folders.length)await this.addFolders(content.folders);if(!content.files.length && !content.folders.length && value.trim()){this.stagedTexts.push({id:id(),text:value});this.setMobileView('send');this.render();}if(device)await this.sendQueue([device],{files:this.picked.slice(beforeFiles),texts:this.stagedTexts.slice(beforeTexts)});});
    },true);
  }
  bulkDragFiles(outgoing:boolean){
    const selection=outgoing?this.sentSelected:this.selected,selecting=outgoing?this.sentSelecting:this.receiveSelecting;
    return [...new Set(this.displayTransfers(outgoing).flatMap(transfer=>this.visibleFiles(transfer).flatMap(file=>{
      if(file.entryKind==='directory' || selecting && !selection.has(fileItemKey(transfer.transferId,file.fileId)))return [];
      const local=this.localFile(fileKey(transfer.transferId,file.fileId));return local?[local]:[];
    })))];
  }
  exitSelection(){
    if(!this.receiveSelecting && !this.sentSelecting && !this.multiSend)return false;
    this.receiveSelecting=false;this.sentSelecting=false;this.multiSend=false;this.selected.clear();this.sentSelected.clear();this.selectedTargets.clear();this.render();return true;
  }
  bulkDragButton(outgoing:boolean){
    const files=this.bulkDragFiles(outgoing);return files.length?'<button class="icon-button quiet bulk-drag" draggable="true" data-drag-all="'+(outgoing?'sent':'receive')+'" aria-label="全部拖拽" title="拖出 '+files.length+' 个本地文件">'+icon('drag')+'</button>':'';
  }
  beginBulkDrag(event:Event,node:HTMLElement){
    const drag=event as DragEvent,files=node.dataset.dragAll==='library'?this.fileLibrary.filesForBulkDrag():this.bulkDragFiles(node.dataset.dragAll==='sent');if(!drag.dataTransfer || !files.length){drag.preventDefault();return;}
    this.internalPayload={files};node.dataset.internalDrag='true';drag.stopPropagation();drag.dataTransfer.effectAllowed='copy';drag.dataTransfer.setData('application/x-globalsend-card','1');drag.dataTransfer.setData(this.internalDragType,'1');
    for(const file of files)drag.dataTransfer.items.add(file);
    const ghost=document.createElement('div');ghost.className='drag-ghost';ghost.innerHTML=icon('file')+'<span>'+files.length+' 个文件</span><span class="drag-copy">＋ 复制</span>';centeredDragImage(drag,ghost);
    document.body.classList.add('content-dragging');
  }
  beginSelectedDrag(event:Event,node:HTMLElement){
    if(!node.hasAttribute('data-receive-key') && !node.hasAttribute('data-sent-key') && !node.dataset.dragLibrary)return false;
    const outgoing=node.hasAttribute('data-sent-key'),selecting=node.dataset.dragLibrary?this.fileLibrary.editing:outgoing?this.sentSelecting:this.receiveSelecting;
    if(!selecting)return false;
    const selection=node.dataset.dragLibrary?this.fileLibrary.selected:outgoing?this.sentSelected:this.selected;
    if(!selection.size)return false; // Empty selection still allows the pressed card.
    const files=node.dataset.dragLibrary?this.fileLibrary.filesForBulkDrag():this.bulkDragFiles(outgoing);
    const texts=node.dataset.dragLibrary?[]:this.displayTexts(outgoing).filter(event=>selection.has(event.eventId)).map(event=>event.payload.text || '');
    const drag=event as DragEvent;if(!drag.dataTransfer || !files.length && !texts.length)return false;
    this.internalPayload={files,text:texts.length?texts.join('\n\n'):undefined};node.dataset.internalDrag='true';drag.stopPropagation();drag.dataTransfer.effectAllowed='copy';drag.dataTransfer.setData('application/x-globalsend-card','1');drag.dataTransfer.setData(this.internalDragType,'1');
    for(const file of files)drag.dataTransfer.items.add(file);if(texts.length)drag.dataTransfer.setData('text/plain',texts.join('\n\n'));
    const ghost=document.createElement('div');ghost.className='drag-ghost';ghost.innerHTML=icon(files.length?'file':'text')+'<span>'+ (files.length+texts.length)+' 项</span><span class="drag-copy">＋ 复制</span>';centeredDragImage(drag,ghost);document.body.classList.add('content-dragging');return true;
  }
  beginContentDrag(event:Event,node:HTMLElement){
    const drag=event as DragEvent;if(!drag.dataTransfer)return;
    if(this.beginSelectedDrag(event,node))return;
    // A native drag of selected glyphs keeps the browser's selected substring.
    if(this.dragOriginOnText || isTextSelectionPoint(drag))return;
    if((drag.target as Element).closest('button,input,select') && !node.hasAttribute('data-drag-library')){drag.preventDefault();return;}
    let text:string|undefined,file:File|undefined;
    if(node.dataset.dragShared)text=this.shared.draft;
    else if(node.dataset.dragText)text=this.viewedText()?.event.eventId===node.dataset.dragText?this.viewedText()!.draft:this.localEvent(node.dataset.dragText)?.payload.text || '';
    else if(node.dataset.dragReceipt)text=(this.receiptBatch.get(node.dataset.dragReceipt) || this.receipt)?.text || '';
    else if(node.dataset.dragLibrary)file=this.fileLibrary.fileForDrag(node.dataset.dragLibrary);
    else file=this.localFile(node.dataset.dragFile!);
    if(text===undefined && !file){drag.preventDefault();this.toast('请先将文件接收到本机',true);return;}
    this.internalPayload={text,file,...(node.dataset.dragLibrary?{libraryId:node.dataset.dragLibrary}:{}),...(node.dataset.dragFile?{receivedKey:node.dataset.dragFile}:{}),...(node.dataset.dragReceipt && file?{receivedKey:(this.receiptBatch.get(node.dataset.dragReceipt) || this.receipt)?.fileKey}: {})};node.dataset.internalDrag='true';drag.stopPropagation();drag.dataTransfer.effectAllowed='copy';drag.dataTransfer.setData('application/x-globalsend-card','1');drag.dataTransfer.setData(this.internalDragType,'1');
    if(text!==undefined)drag.dataTransfer.setData('text/plain',text);
    if(file && file.type!=='inode/directory'){drag.dataTransfer.items.add(file);const url=URL.createObjectURL(file);drag.dataTransfer.setData('DownloadURL',(file.type || 'application/octet-stream')+':'+file.name+':'+url);window.setTimeout(()=>URL.revokeObjectURL(url),60000);}
    document.body.classList.add('content-dragging');
    const ghost=document.createElement('div');ghost.className='drag-ghost';ghost.innerHTML=text!==undefined?e(text.slice(0,180)):file && file.type.startsWith('image/')?'<img alt="" src="'+e(node.querySelector('img')?.src || '')+'"><span>'+e(file.name)+'</span>':icon(file?.type==='inode/directory' || file?.name.endsWith('.zip')?'folder':'file')+'<span>'+e(file?.name)+'</span>';
    ghost.innerHTML+='<span class="drag-copy">＋ 复制</span>';centeredDragImage(drag,ghost);
  }
  endContentDrag(){this.internalPayload=null;document.body.classList.remove('content-dragging');document.querySelector('[data-queue-drop]')?.classList.remove('queue-drop-active');document.querySelectorAll<HTMLElement>('[data-internal-drag]').forEach(node=>delete node.dataset.internalDrag);}
  isInternalDrag(event:DragEvent){return !!this.internalPayload && Array.from(event.dataTransfer?.types || []).includes(this.internalDragType);}
  pickedKey(file:File){let key=this.pickedKeys.get(file);if(!key){key=`picked-${++this.previewKey}`;this.pickedKeys.set(file,key);}return key;}
  pickedSize(file:File){return this.folderParts.get(file)?.reduce((size,part)=>size+(part.file?.size || 0),0) ?? file.size;}
  previewHtml(key:string,name:string,mimeType=''){
    if(mimeType==='inode/directory')return `<span class="content-preview file">${icon('folder')}<span class="preview-type">文件夹</span></span>`;
    const value=this.previews.get(key),kind=value?.kind || filePreviewKind({name,mimeType});
    return `<span class="content-preview ${kind}" data-preview-key="${e(key)}">${value?.url?`<img src="${e(value.url)}" alt="${e(name)}" loading="lazy">`:value?.text!==undefined?`<span class="file-text-preview">${e(value.text.slice(0,500))}</span>`:`${icon(kind==='image'?'image':kind==='text'?'text':name.endsWith('.zip')?'folder':'file')}<span class="preview-type">${kind==='image'?'图片':kind==='text'?'文本':name.split('.').pop()?.slice(0,7).toUpperCase() || '文件'}</span>`}</span>`;
  }
  async preparePreview(key:string,file:File){
    if(file.type==='inode/directory' || this.previews.has(key) || this.previewLoading.has(key))return;
    const generation=this.generation;this.previewLoading.add(key);
    try {const kind=filePreviewKind({name:file.name,mimeType:file.type}),value:{url?:string;text?:string;kind:'image'|'text'|'file'}={kind};
      if(kind==='image')value.url=URL.createObjectURL(file);
      else if(kind==='text')value.text=(await readLocalText(file.slice(0,32768))).text;
      if(generation!==this.generation){if(value.url)URL.revokeObjectURL(value.url);return;}
      this.previews.set(key,value);
      this.previewSources.set(key,file);
      this.paintPreview(key);
    }finally {this.previewLoading.delete(key);}
  }
  paintPreview(key:string){
    for(const node of document.querySelectorAll<HTMLElement>('[data-preview-key]'))if(node.dataset.previewKey===key){const value=this.previews.get(key);if(!value)continue;node.className=`content-preview ${value.kind}`;node.replaceChildren();if(value.url){const img=document.createElement('img');img.src=value.url;img.alt='图片预览';img.loading='lazy';node.append(img);}else if(value.text!==undefined){const text=document.createElement('span');text.className='file-text-preview';text.textContent=value.text.slice(0,500);node.append(text);}}
  }
  mountPreviews(){
    for(const file of this.picked)void this.preparePreview(this.pickedKey(file),file);
    const visible=new Set(Array.from(document.querySelectorAll<HTMLElement>('[data-preview-key]')).map(node=>node.dataset.previewKey));
    for(const key of visible){if(!key)continue;const file=this.localFile(key);if(file)void this.preparePreview(key,file);}
    for(const transfer of this.transfers)for(const file of transfer.files){const key=fileKey(transfer.transferId,file.fileId);if(!visible.has(key))continue;const source=this.fileSources.get(key) || this.rtcLocalFiles.get(key);if(source)void this.preparePreview(key,source);else if(transfer.targetDeviceId===this.session?.device.deviceId && file.transport!=='direct' && ['ready','received'].includes(file.status) && file.size<=8*1024*1024 && (filePreviewKind({name:file.name,mimeType:file.mimeType})!=='file' || this.modal==='receipt' && [...this.receiptBatch.values()].some(item=>item.fileKey===key)) && !this.previews.has(key) && !this.previewLoading.has(key) && !this.previewFailed.has(key))void this.loadRelayPreview(transfer,file);}
  }
  async loadRelayPreview(transfer:Transfer,file:TransferFile){
    const key=fileKey(transfer.transferId,file.fileId),generation=this.generation;this.previewLoading.add(key);
    try {const {downloadPath}=await this.api.request<{downloadPath:string}>(`/transfers/${transfer.transferId}/files/${file.fileId}/download-ticket`,{});const response=await fetch(safeDownloadUrl(this.baseUrl,downloadPath),{credentials:'omit',cache:'no-store'});if(!response.ok)throw new Error('无法预览');const blob=await response.blob();if(generation!==this.generation)return;this.previewLoading.delete(key);await this.preparePreview(key,new File([blob],file.name,{type:file.mimeType}));}
    catch {if(generation===this.generation)this.previewFailed.add(key);}
    finally {this.previewLoading.delete(key);if(this.modal==='receipt' && [...this.receiptBatch.values()].some(item=>item.fileKey===key))this.paintReceiptReady();}
  }
  paintReceiptReady(){for(const button of document.querySelectorAll<HTMLButtonElement>('[data-prepare-receipt]')){const key=button.dataset.prepareReceipt!;const ready=this.fileSources.has(key) || this.rtcLocalFiles.has(key) || this.previewSources.has(key);if(ready){button.remove();continue;}button.textContent=this.previewLoading.has(key)?'准备中…':'准备拖出';button.disabled=this.previewLoading.has(key);}}
  async prepareReceiptDrag(key=this.receipt?.fileKey){if(!key || this.previewLoading.has(key))return;const [transferId,fileId]=key.split(':'),transfer=this.transfers.find(item=>item.transferId===transferId),file=transfer?.files.find(item=>item.fileId===fileId);if(!transfer || !file)return;await this.loadRelayPreview(transfer,file);if(!this.previewSources.has(key))this.toast('准备失败，请重试或下载文件',true);}
  async openFilePreview(transferId:string,fileId:string){
    const transfer=this.localTransfer(transferId),file=transfer?.files.find(item=>item.fileId===fileId);if(!transfer || !file)return;
    const key=fileKey(transferId,fileId),generation=this.generation,source=this.localFile(key);
    if(file.entryKind==='directory'){const parts=source && this.folderParts.get(source);if(parts)this.previews.set(key,{kind:'text',text:parts.map(part=>part.path).join('\n')});else{await this.openLibrary();const entry=this.fileLibrary.entries.find(entry=>entry.key===key);if(entry)await this.fileLibrary.preview(entry.id);return;}}
    this.openedFile={key,name:file.name,size:file.size,source:this.deviceLabel(transfer.sourceDeviceId===this.session?.device.deviceId?transfer.targetDeviceId:transfer.sourceDeviceId),createdAt:this.receiptTime(key,transfer.createdAt),route:file.transport==='direct'?'直连':'中继',status:file.status==='received'?'已保存':statusLabel[file.status]};this.modal='file-preview';this.render();
    if(source && filePreviewKind({name:file.name,mimeType:file.mimeType})==='text'){
      const content=await readLocalText(source);if(generation!==this.generation)return;
      this.previews.set(key,{kind:'text',text:content.text});
      if(this.modal==='file-preview' && this.openedFile?.key===key)this.render();
    }
  }
  clearPreviews(){for(const value of this.previews.values())if(value.url)URL.revokeObjectURL(value.url);this.previews.clear();this.previewSources.clear();this.previewLoading.clear();this.previewFailed.clear();}
  viewedText() { return this.textViews.get(this.readingEventId); }
  canEditText(view: TextView) { return view.scope.startsWith('local:')?view.event.sourceDeviceId===this.localHistory.event(view.event.eventId)?.scope.deviceId:view.event.sourceDeviceId===this.session?.device.deviceId; }
  openText(eventId: string) {
    this.pruneLocal();
    const event=this.localEvent(eventId),live=this.events.some(event=>event.eventId===eventId);if(event?.type!=='text.created')return;
    if(!event)return;
    if(!this.textViews.has(eventId))this.textViews.set(eventId,{event,scope:live?this.dockKey:'local:'+this.localHistory.event(eventId)!.scope.scope,draft:event.payload.text || '',savedText:event.payload.text || '',busy:false,composing:false,error:'',saved:false,element:null});
    this.readingEventId=eventId;this.modal='reader';this.render();
    const view=this.viewedText();if(view && this.canEditText(view))view.element?.focus({preventScroll:true});
  }
  syncViewedText() {
    const view=this.viewedText();if(!view)return;
    const event=this.localEvent(view.event.eventId);
    if(!event){view.error='文字已过期，无法修改';return;}
    if(!this.canEditText(view) || (!view.busy && view.draft===view.savedText)){
      view.draft=event.payload.text || '';view.savedText=view.draft;
    }
    view.event=event;
  }
  mountTextViewer() {
    const host=document.querySelector<HTMLElement>('[data-reader-host]'),view=this.viewedText();
    if(!host || !view)return;
    if(!this.canEditText(view)){
      const text=view.displayElement ?? document.createElement('pre');
      text.id='reader-text';text.className='text-input readonly-text';text.setAttribute('aria-label','收到的文字全文');
      text.textContent=view.draft;view.displayElement=text;host.append(text);this.updateTextViewerChrome();return;
    }
    if(!view.element){
      const field=document.createElement('textarea');field.id='reader-text';field.className='text-input selectable-text';field.spellcheck=false;
      const current=()=>this.session && (view.scope===this.dockKey || view.scope.startsWith('local:')) && this.textViews.get(view.event.eventId)===view;
      field.addEventListener('input',()=>{
        if(!current() || !this.canEditText(view))return;
        view.draft=field.value;view.error='';view.saved=false;this.updateTextViewerChrome();
      });
      field.addEventListener('compositionstart',()=>{if(current()){view.composing=true;this.updateTextViewerChrome();}});
      field.addEventListener('compositionend',()=>{
        if(!current())return;
        if(this.canEditText(view))view.draft=field.value;
        view.composing=false;this.updateTextViewerChrome();
        if(this.editorRenderPending){this.editorRenderPending=false;this.render();}
      });
      field.addEventListener('keydown',event=>{
        if(!current() || !this.canEditText(view) || event.isComposing || view.composing || event.keyCode===229)return;
        if(event.key==='Enter' && (event.ctrlKey || event.metaKey)){
          event.preventDefault();event.stopPropagation();void this.saveViewedText(view.event.eventId);
        }
      });
      view.element=field;
    }
    const field=view.element,editable=this.canEditText(view);
    field.readOnly=!editable;field.maxLength=this.info?.limits.maxTextLength || 100000;
    field.setAttribute('aria-label',editable?'编辑已发送文字':'收到的文字全文');
    if(field.value!==view.draft)field.value=view.draft;
    host.append(field);this.updateTextViewerChrome();
  }
  updateTextViewerChrome() {
    const view=this.viewedText();if(!view)return;
    const links=document.querySelector('[data-reader-links]');if(links)links.innerHTML=webLinkActions(view.draft);
    const count=document.querySelector('#reader-count');if(count)count.textContent=`${characterCount(view.draft)} 字符`;
    const status=document.querySelector<HTMLElement>('#reader-status');
    if(status){status.textContent=view.busy?'保存中…':view.error || (view.draft!==view.savedText?'未保存':'');status.classList.toggle('error',Boolean(view.error));}
    const button=document.querySelector<HTMLButtonElement>('[data-action="save-reader"]');
    if(button)button.disabled=view.busy || view.composing || !view.draft.trim() || view.draft===view.savedText || localTextDeadline(view.event)<=Date.now();
  }
  async saveViewedText(eventId=this.readingEventId) {
    const view=this.textViews.get(eventId);
    if(view?.scope.startsWith('local:')){
      if(!this.canEditText(view) || view.composing || !view.draft.trim() || view.draft===view.savedText)return;
      const record=this.localHistory.event(eventId);if(!record)return;
      record.event.payload={...record.event.payload,text:view.draft,editedAt:new Date().toISOString()};view.event=record.event;view.savedText=view.draft;view.error='';this.localHistory.save();this.closeModal();return;
    }
    if(!view || !this.session || view.scope!==this.dockKey || !this.canEditText(view) || view.busy || view.composing || !view.draft.trim() || view.draft===view.savedText)return;
    if(localTextDeadline(view.event)<=Date.now()){view.error='文字已过期，无法修改';this.updateTextViewerChrome();return;}
    const generation=this.generation,scope=this.dockKey,text=view.draft;
    view.busy=true;view.error='';this.updateTextViewerChrome();
    try {
      const {event}=await this.api.request<{event:WireEvent}>(`/texts/${encodeURIComponent(eventId)}`,{text},'PATCH');
      if(generation!==this.generation || scope!==this.dockKey || this.textViews.get(eventId)!==view)return;
      this.events=visibleLocalEvents(mergeEvents(this.events,[event]),this.hiddenItems);this.persist();
      const original=this.events.find(item=>item.eventId===eventId);
      view.savedText=original?.payload.text ?? text;
      if(view.draft===text)view.draft=view.savedText;
      view.saved=true;
      if(this.readingEventId===eventId && view.draft===view.savedText)this.closeModal();
    } catch(error) {
      if(generation!==this.generation || scope!==this.dockKey || this.textViews.get(eventId)!==view)return;
      view.error=error instanceof ApiError && error.code==='NOT_FOUND'?'原消息已不存在，无法保存':
        error instanceof ApiError && error.status===410?'文字已过期，无法修改':
        error instanceof ApiError && [404,405,501].includes(error.status)?'中心尚不支持文字编辑，请升级中心':errorText(error);
    } finally {
      view.busy=false;
      if(generation===this.generation && scope===this.dockKey && this.textViews.get(eventId)===view)this.render();
    }
  }
  clearTextViews() {
    for(const view of this.textViews.values())if(view.element)view.element.value='';
    this.textViews.clear();this.readingEventId='';
  }
  persist() { if(this.session){localSet(this.dockKey,JSON.stringify({cursor:this.cursor,events:this.events,hidden:this.hiddenItems,receivedAt:this.receivedAt}));this.archiveLocalContent();} }
  archiveLocalContent(){
    if(!this.session)return;
    for(const [key,file] of [...this.fileSources,...this.rtcLocalFiles,...this.previewSources])this.retainedSources.set(key,file);
    const names=Object.fromEntries(this.deviceNames);for(const device of [...this.devices,this.session.device])names[device.deviceId]=device.name;
    this.localHistory.remember({scope:this.dockKey,deviceId:this.session.device.deviceId,events:this.events,transfers:this.transfers,names,receivedAt:this.receivedAt,hidden:this.hiddenItems});
  }
  localEvent(id:string){return this.events.find(event=>event.eventId===id) || this.localHistory.event(id)?.event;}
  localTransfer(id:string){return this.transfers.find(transfer=>transfer.transferId===id) || this.localHistory.transfer(id)?.transfer;}
  localFile(key:string){return this.fileSources.get(key) || this.rtcLocalFiles.get(key) || this.previewSources.get(key) || this.retainedSources.get(key);}
  restoreLocalReferences() {
    if(this.localReferencesRestoring)return this.localReferencesRestoring;
    const saved=this.localHistory.scopes.flatMap(scope=>scope.transfers.flatMap(transfer=>transfer.files.map(file=>({scope,transfer,file,key:fileKey(transfer.transferId,file.fileId)}))));
    const restore=(async()=>{
      const result=await this.fileLibrary.references(new Set(saved.map(item=>item.key)));if(!result)return;
      for(const [key,file] of result.files)this.retainedSources.set(key,file);
      for(const {scope,transfer,file,key} of saved)if(transfer.targetDeviceId===scope.deviceId && (file.transport==='direct' || file.relativePath) && file.status==='received' && !result.files.has(key)){
        this.retainedSources.delete(key);this.previewSources.delete(key);this.localHistory.removeFile(transfer.transferId,file.fileId);
        this.hiddenItems[fileItemKey(transfer.transferId,file.fileId)]=Math.max(Date.parse(transfer.expiresAt) || 0,Date.now()+86400000);
      }
      this.knownLibraryKeys=new Set(result.entries.map(entry=>entry.key));this.persist();this.render();
    })().catch(()=>{/* Keep references until the next successful local inventory. */});
    this.localReferencesRestoring=restore;return restore.finally(()=>{if(this.localReferencesRestoring===restore)this.localReferencesRestoring=null;});
  }
  allDisplayTexts(outgoing:boolean){
    const values=new Map<string,WireEvent>();
    for(const scope of this.localHistory.scopes)for(const event of scope.events)if(event.type==='text.created' && (outgoing?event.sourceDeviceId===scope.deviceId:event.targetDeviceId===scope.deviceId) && !(scope.hidden[textItemKey(event.eventId)]>Date.now()) && localTextDeadline(event)>Date.now())values.set(event.eventId,event);
    for(const event of this.events)if(event.type==='text.created' && (outgoing?event.sourceDeviceId===this.session?.device.deviceId:event.targetDeviceId===this.session?.device.deviceId))values.set(event.eventId,event);
    return [...values.values()].filter(event=>!(this.hiddenItems[textItemKey(event.eventId)]>Date.now()));
  }
  displayTexts(outgoing:boolean){
    const seen=new Set<string>();
    return this.allDisplayTexts(outgoing).sort((a,b)=>b.createdAt.localeCompare(a.createdAt)).filter(event=>{
      const key=event.payload.clipboard?event.eventId:'text:'+event.payload.text;
      if(seen.has(key))return false;seen.add(key);return true;
    });
  }
  allDisplayTransfers(outgoing:boolean){
    const values=new Map<string,Transfer>();for(const scope of this.localHistory.scopes)for(const transfer of scope.transfers)if(outgoing?transfer.sourceDeviceId===scope.deviceId:transfer.targetDeviceId===scope.deviceId)values.set(transfer.transferId,transfer);
    for(const transfer of this.transfers)if(outgoing?transfer.sourceDeviceId===this.session?.device.deviceId:transfer.targetDeviceId===this.session?.device.deviceId)values.set(transfer.transferId,transfer);
    return [...values.values()];
  }
  displayTransfers(outgoing:boolean){
    const seen=new Set<string>();
    return this.allDisplayTransfers(outgoing).sort((a,b)=>b.createdAt.localeCompare(a.createdAt)).map(transfer=>({...transfer,files:folderCards(this.visibleFiles(transfer),file=>this.uploadProgress.get(fileKey(transfer.transferId,file.fileId)) ?? file.offset).filter(file=>{
      const key=file.entryKind!=='directory' && file.sha256 && (outgoing?['ready','received'].includes(file.status):!!this.localFile(fileKey(transfer.transferId,file.fileId)))?'sha:'+file.sha256+':'+file.size:fileKey(transfer.transferId,file.fileId);
      if(seen.has(key))return false;seen.add(key);return true;
    })}));
  }
  applyLatestTexts(documents:TextDocument[]){
    this.events=applyTextDocuments(this.events,documents);
    for(const scope of this.localHistory.scopes)scope.events=applyTextDocuments(scope.events,documents);
    this.localHistory.save();this.syncViewedText();this.persist();
  }
  receiptTime(key:string,fallback:string){return this.receivedAt[key] || this.localHistory.scopes.map(scope=>scope.receivedAt[key]).find(Boolean) || fallback;}
  recordReceipt(key:string,at=new Date().toISOString()){this.receivedAt[key] ||= at;this.persist();}
  showReceipt(receipt:NonNullable<GlobalSend['receipt']>){
    const previous=this.receiptVersions.get(receipt.id);
    if(previous===receipt.version || previous && /^\d+$/.test(previous) && /^\d+$/.test(receipt.version) && Number(receipt.version)<Number(previous))return;
    this.receiptVersions.set(receipt.id,receipt.version);
    receipt.receivedAt=this.receiptBatch.get(receipt.id)?.receivedAt || receipt.receivedAt || new Date().toISOString();
    this.receiptBatch.set(receipt.id,receipt);
    this.pendingReceipt=receipt;
    if((!this.modal && !this.shared.dirty && !this.shared.focusedActive) || this.modal==='receipt'){
      this.receipt=receipt;this.pendingReceipt=null;this.modal='receipt';this.contextMenu=null;
      document.querySelector('#toasts')?.replaceChildren();
    }
    this.render();
  }
  noticeEvents(events:WireEvent[],notify=true){
    for(const event of events){
      if(event.sourceDeviceId===this.session?.device.deviceId || event.targetDeviceId!==this.session?.device.deviceId)continue;
      if(event.type!=='text.created' && event.type!=='text.updated')continue;
      const originalId=event.type==='text.updated'?event.payload.sourceEventId:event.eventId;
      if(!originalId || this.events.some(item=>item.eventId===event.eventId))continue;
      const receipt={id:originalId,version:String(event.cursor),source:event.sourceDeviceId,title:event.type==='text.updated'?'文本已更新':'发来一条文本',text:event.payload.text || ''};
      if(notify){this.showReceipt(receipt);void this.notifications.notify({id:originalId,revision:receipt.version,kind:'text',phase:event.type==='text.updated'?'updated':'received',title:this.deviceLabel(event.sourceDeviceId),body:receipt.text,itemId:originalId});}else this.receiptVersions.set(originalId,receipt.version);
    }
  }
  noticeFile(transfer:Transfer,file:TransferFile){
    if(transfer.targetDeviceId!==this.session?.device.deviceId)return;
    const root=folderRoot(file,transfer.files);
    if(isFolderRoot(root))file=summarizeFolder(root,folderMembers(root,transfer.files));
    const key=fileKey(transfer.transferId,file.fileId),current=this.receiptBatch.get(key);
    if(['offered','accepted','uploading','ready','received'].includes(file.status))void this.notifications.notify({id:key,revision:'file',kind:'file',phase:file.status==='ready'?'ready':file.status==='received'?'received':'incoming',title:this.deviceLabel(transfer.sourceDeviceId),body:file.name+' · '+(file.status==='received'?'已接收文件':file.status==='ready'?'文件可下载':file.status==='offered'?'收到文件请求，待接收':'正在连接文件传输'),itemId:key});
    if(current){this.receiptBatch.set(key,{...current,title:file.name});if(this.receipt?.id===key)this.receipt=this.receiptBatch.get(key)!;
      if(isFolderRoot(root)){if(!this.folderReceiptRenderQueued){this.folderReceiptRenderQueued=true;void Promise.resolve().then(()=>{this.folderReceiptRenderQueued=false;this.render();});}}
      else this.render();return;}
    if(!['offered','accepted','uploading','ready','received'].includes(file.status))return;
    this.showReceipt({id:key,version:'file',source:transfer.sourceDeviceId,title:file.name,fileKey:key});
  }
  openNotificationReceipt(){
    if(this.loading || !this.session || !this.pendingNotificationId)return;
    const key=this.pendingNotificationId,event=this.localEvent(key),[transferId,fileId]=key.split(':'),transfer=this.localTransfer(transferId),file=transfer?.files.find(item=>item.fileId===fileId);
    const receipt:GlobalSend['receipt']=event?{id:key,version:String(event.cursor),source:event.sourceDeviceId,title:'文本',text:event.payload.text || ''}:file && transfer?{id:key,version:'file',source:transfer.sourceDeviceId,title:file.name,fileKey:key}:null;
    if(!receipt)return;this.pendingNotificationId='';this.receiptBatch.set(key,receipt);this.receipt=receipt;this.receiptFocusId=key;this.modal='receipt';this.render();
  }
  closeModal(){
    if(this.modalClosing)return;
    const closingModal=this.modal;
    const addressMenu=this.modal==='ip-addresses';if(addressMenu)this.ipAbort?.abort();
    if(this.modal==='receipt'){this.receiptBatch.clear();this.receiptFocusId='';this.receipt=null;this.pendingReceipt=null;}
    const close=()=>{this.modalClosing=false;const readerId=this.readingEventId,view=this.viewedText();if(view)view.composing=false;this.readingEventId='';this.deviceNameDraft=null;this.deviceNameError='';this.modal=null;this.render();if(readerId)document.getElementById(`read-${readerId}`)?.focus();if(addressMenu)document.querySelector<HTMLElement>('[data-action="ip-addresses"]')?.focus();};
    const backdrop=document.querySelector<HTMLElement>('.modal-backdrop');
    if(backdrop && typeof backdrop.animate==='function' && !window.matchMedia('(prefers-reduced-motion: reduce)').matches){
      this.modalClosing=true;backdrop.classList.add('leaving');
      window.setTimeout(()=>{if(this.modal===closingModal)close();else this.modalClosing=false;},150);
    }else close();
  }
  receiptCardHtml(receipt:NonNullable<GlobalSend['receipt']>){
    const transfer=receipt.fileKey?this.localTransfer(receipt.fileKey.split(':')[0]):undefined,file=transfer?.files.find(item=>item.fileId===receipt.fileKey?.split(':')[1]);
    if(file && transfer)return fileCard(this,transfer,file,false,receipt.id);
    const attributes='data-receipt-id="'+e(receipt.id)+'" data-view-receipt="'+e(receipt.id)+'" tabindex="0" draggable="false" data-drag-receipt="'+e(receipt.id)+'"';
    const menu='<button class="icon-button quiet card-menu-button" data-receipt-menu="'+e(receipt.id)+'" aria-label="更多">···</button>';
    return '<article class="content-card text-card preview-card" '+attributes+'>'+menu+'<div class="card-text receipt-content selectable-text"><span class="card-text-lines">'+linkifyHtml((receipt.text || '').slice(0,this.receiptFocusId===receipt.id || this.receiptBatch.size===1?100000:500))+'</span></div><button class="quiet card-copy preview-copy" data-copy-receipt="'+e(receipt.id)+'">'+icon('copy')+'复制</button></article>';
  }
  receiptHtml(){
    const stamp=(item:NonNullable<GlobalSend['receipt']>)=>this.receiptTime(item.fileKey || 'text:'+item.id,item.receivedAt || '1970-01-01T00:00:00.000Z');
    const items=[...this.receiptBatch.values()].sort((a,b)=>stamp(b).localeCompare(stamp(a)) || a.id.localeCompare(b.id));
    if(!items.length && this.receipt)items.push(this.receipt);if(!items.length)return '';
    const focused=this.receiptBatch.get(this.receiptFocusId),visible=focused?[focused]:items,single=visible.length===1;
    const drag=single?`draggable="true" ${visible[0].text!==undefined?'data-drag-receipt':'data-drag-file'}="${e(visible[0].fileKey || visible[0].id)}"`:'';
    return `<div class="modal-backdrop receipt-backdrop"><section class="modal receipt-modal ${single?'receipt-single-modal':'receipt-batch-modal'}" ${drag} role="dialog" aria-modal="true" aria-labelledby="receipt-title" tabindex="-1"><div class="modal-header"><h2 id="receipt-title">${focused && items.length>1?`<button class="quiet receipt-back" data-action="receipt-grid">← 全部 ${items.length} 项</button>`:items.length>1?`${items.length} 项新收件`:'新收件'}</h2><button class="icon-button quiet" data-action="close-modal" aria-label="关闭收件">${icon('close')}</button></div><div class="receipt-batch-grid receive-grid ${single?'receipt-single-grid':''}">${visible.map(item=>this.receiptCardHtml(item)).join('')}</div></section></div>`;
  }
  updateReceiptDom(backdrop:HTMLElement){
    const template=document.createElement('div');template.innerHTML=this.receiptHtml();
    const fresh=template.querySelector<HTMLElement>('.receipt-modal'),modal=backdrop.querySelector<HTMLElement>('.receipt-modal');if(!fresh || !modal)return;
    modal.className=fresh.className;modal.style.animation='none';
    for(const name of ['draggable','data-drag-receipt','data-drag-file']){if(fresh.hasAttribute(name))modal.setAttribute(name,fresh.getAttribute(name)!);else modal.removeAttribute(name);}
    const header=modal.querySelector('.modal-header')!,nextHeader=fresh.querySelector('.modal-header')!;
    if(header.innerHTML!==nextHeader.innerHTML)header.innerHTML=nextHeader.innerHTML;
    const grid=modal.querySelector('.receipt-batch-grid')!,nextGrid=fresh.querySelector('.receipt-batch-grid')!;grid.className=nextGrid.className;
    const existing=new Map(Array.from(grid.children).map(node=>[(node as HTMLElement).dataset.receiptId,node as HTMLElement]));
    const keys=new Set<string>();let index=0;
    for(const next of Array.from(nextGrid.children) as HTMLElement[]){
      const key=next.dataset.receiptId!,previous=existing.get(key),node=previous || next;keys.add(key);
      if(previous && previous.dataset.internalDrag!=='true'){
        if(previous.innerHTML!==next.innerHTML)previous.innerHTML=next.innerHTML;
        for(const name of previous.getAttributeNames())if(!next.hasAttribute(name))previous.removeAttribute(name);
        for(const name of next.getAttributeNames())previous.setAttribute(name,next.getAttribute(name)!);
      }
      if(grid.children[index]!==node)grid.insertBefore(node,grid.children[index] || null);index++;
    }
    for(const node of Array.from(grid.children) as HTMLElement[])if(!keys.has(node.dataset.receiptId!))node.remove();
  }
  openCardMenu(kind:'text'|'file'|'receipt',key:string,x:number,y:number){this.contextMenu={kind,key,x:Math.min(x,window.innerWidth-188),y:Math.min(y,window.innerHeight-214)};this.render();document.querySelector<HTMLElement>('.content-menu button')?.focus();}
  cardMenuHtml(){
    const menu=this.contextMenu;if(!menu)return '';
    const actions=menu.kind==='receipt'?[['requeue','加入待发送'],['dismiss','关闭此项'],['details','详情']]:menu.kind==='text'?[['copy','复制'],['requeue','加入待发送'],['delete','删除'],['details','详情']]:[['open','打开'],['download','下载'],['requeue','加入待发送'],['delete','删除'],['details','详情']];
    return `<div class="content-menu" role="menu" aria-label="内容操作" style="left:${Math.max(8,menu.x)}px;top:${Math.max(8,menu.y)}px">${actions.map(([action,label])=>`<button role="menuitem" data-card-command="${action}">${label}</button>`).join('')}</div>`;
  }
  async cardCommand(action:string){
    const menu=this.contextMenu;if(!menu)return;this.contextMenu=null;
    if(menu.kind==='receipt'){
      const receipt=this.receiptBatch.get(menu.key) || this.receipt;if(!receipt)return;
      if(action==='details'){this.receiptFocusId=receipt.id;this.render();return;}
      if(action==='requeue'){if(receipt.text!==undefined)this.stagedTexts.push({id:id(),text:receipt.text});else if(receipt.fileKey)await this.stageReceivedFile(receipt.fileKey);this.closeModal();this.setMobileView('send');}
      if(action==='dismiss'){this.receiptBatch.delete(receipt.id);if(!this.receiptBatch.size)this.closeModal();}
      this.render();return;
    }
    if(menu.kind==='text'){
      const event=this.localEvent(menu.key);if(!event)return;
      if(action==='details')this.openText(menu.key);
      if(action==='copy')await this.copy(event.payload.text || '');
      if(action==='requeue'){this.stagedTexts.push({id:id(),text:event.payload.text || ''});this.setMobileView('send');}
      if(action==='delete')this.hideText(menu.key);
    }else{
      const [transferId,fileId]=menu.key.split(':'),file=this.localFile(menu.key);
      if(action==='details' || action==='open')await this.openFilePreview(transferId,fileId);
      if(action==='download')await this.download(transferId,fileId);
      if(action==='requeue')await this.stageReceivedFile(menu.key);
      if(action==='delete')this.hideFile(transferId,fileId);
    }
    this.render();
  }
  pruneLocal() {
    const now=Date.now();
    // The OPFS cleanup policy owns deletion; this cache only releases expired
    // references. A longer retention or unmatched category must retain bytes.
    for(const [key,expiry] of this.rtcFileExpiry)if(expiry<=now){this.rtcLocalFiles.delete(key);this.rtcFileExpiry.delete(key);}
    const before=this.events.filter(event=>event.type==='text.created' && localTextDeadline(event)<=now).length;
    this.events=visibleLocalEvents(this.events,this.hiddenItems,now);this.expiredTextCount+=before;
    for(const [key,expiresAt] of Object.entries(this.hiddenItems))if(expiresAt<=now)delete this.hiddenItems[key];
    const ids=new Set([...this.displayTexts(false),...this.displayTexts(true)].map(event=>event.eventId));
    const selectable=new Set([...this.receivedTexts().map(event=>event.eventId),...this.displayTransfers(false).flatMap(transfer=>this.visibleFiles(transfer).map(file=>fileItemKey(transfer.transferId,file.fileId)))]);
    for(const key of this.selected)if(!selectable.has(key))this.selected.delete(key);
    const sentSelectable=new Set(this.sentSelectionKeys());for(const key of this.sentSelected)if(!sentSelectable.has(key))this.sentSelected.delete(key);
    if(this.readingEventId && !ids.has(this.readingEventId)){
      const view=this.viewedText();
      if(view && this.canEditText(view) && (view.busy || view.draft!==view.savedText))view.error='文字已过期，无法修改';
      else {this.readingEventId='';if(this.modal==='reader')this.modal=null;}
    }
  }
  receivedTexts() { return this.displayTexts(false); }
  visibleFiles(transfer: Transfer) { const archived=this.localHistory.transfer(transfer.transferId)?.scope;return transfer.files.filter(file=>!((this.hiddenItems[fileItemKey(transfer.transferId,file.fileId)] || archived?.hidden[fileItemKey(transfer.transferId,file.fileId)] || 0)>Date.now())); }
  hideText(eventId: string,quiet=false,group=true) {
    const event=this.localEvent(eventId);if(!event)return false;
    if(group && !event.payload.clipboard){
      const outgoing=event.sourceDeviceId===(this.localHistory.event(eventId)?.scope.deviceId || this.session?.device.deviceId);
      for(const copy of this.allDisplayTexts(outgoing).filter(copy=>copy.eventId!==eventId && !copy.payload.clipboard && copy.payload.text===event.payload.text))this.hideText(copy.eventId,true,false);
    }
    this.localHistory.removeText(eventId);
    this.hiddenItems[textItemKey(eventId)]=Date.parse(event.expiresAt);this.pruneLocal();if(quiet)return true;this.persist();this.render();
    const next=this.receivedTexts()[0];if(next)document.getElementById(`read-${next.eventId}`)?.focus();else document.querySelector<HTMLButtonElement>('[data-action="clear-dock"]')?.focus();
    this.toast('已移除');
    return true;
  }
  hideFile(transferId: string,fileId: string,quiet=false,group=true) {
    const transfer=this.localTransfer(transferId);const file=transfer?.files.find(item=>item.fileId===fileId);
    if(!transfer || !file)return false;
    if(isFolderRoot(file)){
      const members=folderMembers(file,transfer.files);
      if(members.some(member=>this.transfers.includes(transfer) && ['offered','accepted','uploading'].includes(member.status) && Date.parse(transfer.expiresAt)>Date.now())){if(!quiet)this.toast('请先取消传输。');return false;}
      for(const member of members)if(member.fileId!==fileId)this.hideFile(transferId,member.fileId,true,false);
    }
    if(this.transfers.includes(transfer) && ['offered','accepted','uploading'].includes(file.status) && Date.parse(transfer.expiresAt)>Date.now()){if(!quiet)this.toast('请先取消传输。');return false;}
    if(group && file.sha256 && file.entryKind!=='directory'){
      const outgoing=transfer.sourceDeviceId===(this.localHistory.transfer(transferId)?.scope.deviceId || this.session?.device.deviceId);
      for(const copy of this.allDisplayTransfers(outgoing))for(const item of [...copy.files])if((copy.transferId!==transferId || item.fileId!==fileId) && item.entryKind!=='directory' && item.sha256===file.sha256 && item.size===file.size && ['ready','received'].includes(item.status))this.hideFile(copy.transferId,item.fileId,true,false);
    }
    this.localHistory.removeFile(transferId,fileId);
    this.hiddenItems[fileItemKey(transferId,fileId)]=Math.max(Date.parse(transfer.expiresAt),Date.now()+86400000);
    const key=fileKey(transferId,fileId);this.fileSources.delete(key);this.previewSources.delete(key);const preview=this.previews.get(key);if(preview?.url)URL.revokeObjectURL(preview.url);this.previews.delete(key);
    if(transfer.targetDeviceId===this.session?.device.deviceId){this.rtcLocalFiles.delete(key);this.rtcFileExpiry.delete(key);void this.rtcStore?.remove(key).catch(()=>{});}
    if(!quiet){this.persist();this.render();this.toast('已删除');}return true;
  }
  receiveSelectionKeys(){return [...(this.filter==='files'?[]:this.receivedTexts().map(event=>event.eventId)),...(this.filter==='text'?[]:this.displayTransfers(false).flatMap(transfer=>this.visibleFiles(transfer).map(file=>fileItemKey(transfer.transferId,file.fileId))))];}
  selectedTextCount(){return this.receivedTexts().filter(event=>this.selected.has(event.eventId)).length;}
  allReceiveSelected(){const keys=this.receiveSelectionKeys();return !!keys.length && keys.every(key=>this.selected.has(key));}
  toggleReceiveSelection(key:string){if(this.selected.has(key))this.selected.delete(key);else this.selected.add(key);this.render();}
  toggleAllReceive(){const keys=this.receiveSelectionKeys(),all=this.allReceiveSelected();for(const key of keys)if(all)this.selected.delete(key);else this.selected.add(key);this.render();}
  sentSelectionKeys(){return [...this.displayTexts(true).map(event=>event.eventId),...this.displayTransfers(true).flatMap(transfer=>this.visibleFiles(transfer).map(file=>fileItemKey(transfer.transferId,file.fileId)))];}
  allSentSelected(){const keys=this.sentSelectionKeys();return !!keys.length && keys.every(key=>this.sentSelected.has(key));}
  toggleSentSelection(key:string){if(this.sentSelected.has(key))this.sentSelected.delete(key);else this.sentSelected.add(key);this.render();}
  toggleAllSent(){const keys=this.sentSelectionKeys(),all=this.allSentSelected();for(const key of keys)if(all)this.sentSelected.delete(key);else this.sentSelected.add(key);this.render();}
  deleteSelectedSent(){
    this.pruneLocal();if(!this.sentSelected.size)return;let removed=0,blocked=0;
    for(const key of [...this.sentSelected]){const file=key.startsWith('file:')?key.slice(5).split(':'):null;const deleted=file?this.hideFile(file[0],file[1],true):this.hideText(key,true);if(deleted){this.sentSelected.delete(key);removed++;}else blocked++;}
    this.pruneLocal();this.persist();this.render();this.toast(blocked?`已删除 ${removed} 项；${blocked} 项传输中，请先取消传输`:`已删除 ${removed} 项`);
  }
  deleteSelectedReceive(){
    this.pruneLocal();
    let removed=0,blocked=0;
    for(const key of [...this.selected]){const file=key.startsWith('file:')?key.slice(5).split(':'):null;const deleted=file?this.hideFile(file[0],file[1],true):this.hideText(key,true);if(deleted){this.selected.delete(key);removed++;}else blocked++;}
    this.pruneLocal();this.persist();this.render();this.toast(blocked?`已删除 ${removed} 项；${blocked} 项传输中，请先取消传输`:`已删除 ${removed} 项`);
  }
  clearFinishedDock() {
    for(const event of this.receivedTexts())this.hiddenItems[textItemKey(event.eventId)]=Date.parse(event.expiresAt);
    for(const transfer of this.transfers.filter(item=>item.targetDeviceId===this.session?.device.deviceId))for(const file of transfer.files){
      if(!['offered','accepted','uploading'].includes(file.status) || Date.parse(transfer.expiresAt)<=Date.now())this.hiddenItems[fileItemKey(transfer.transferId,file.fileId)]=Math.max(Date.parse(transfer.expiresAt),Date.now()+86400000);
    }
    this.pruneLocal();this.persist();this.render();this.toast('已清理');
  }
  copySelected() {
    this.pruneLocal();
    const texts=this.receivedTexts().filter(event=>this.selected.has(event.eventId));
    if(!texts.length){this.toast('请先选择文字。');this.render();return;}
    this.copy(texts.map(event=>event.payload.text || '').join('\n\n'));
  }
  targetExplanation() {
    if(!this.target)return '';
    if(!this.connected || this.startupError)return '连接中断，草稿已保留。';
    return this.rtcProbes?.status(this.target) || '';
  }
  device(deviceId: string) { return this.devices.find(device => device.deviceId === deviceId); }
  deviceLabel(deviceId: string) { return this.device(deviceId)?.name || this.deviceNames.get(deviceId) || this.localHistory.scopes.map(scope=>scope.names[deviceId]).find(Boolean) || '另一台设备'; }
  peers() { return this.devices.filter(device => device.deviceId !== this.session?.device.deviceId && this.recentDevices.available(device)); }
  onlinePeers() { return this.connected && this.helloReceived ? this.devices.filter(device=>device.deviceId!==this.session?.device.deviceId && !device.revoked && device.online) : []; }
  selectOnlineTarget() {
    const peers=this.peers();
    if(!peers.some(device=>device.deviceId===this.target))this.target=peers[0]?.deviceId || '';
  }
  isOnlinePeer(deviceId: string) { return this.onlinePeers().some(device=>device.deviceId===deviceId); }
  isSendablePeer(deviceId:string) { return this.peers().some(device=>device.deviceId===deviceId); }
  scheduleDeviceExpiry() {
    clearTimeout(this.deviceGraceTimer);
    if(!this.recentDevices.deadlines.size)return;
    this.deviceGraceTimer=window.setTimeout(()=>{this.expireDevices();this.render();},Math.max(0,Math.min(...this.recentDevices.deadlines.values())-Date.now()));
  }
  expireDevices() {
    this.devices=this.recentDevices.merge(this.devices,this.devices);
    this.selectOnlineTarget();this.scheduleDeviceExpiry();
  }
  clearPresence() {
    void this.rtcProbes?.setForeground(false);
    this.discoveryEpoch++;
    this.deviceSnapshotRevision++;
    for(const device of this.devices)this.dropDeviceConnectivity(device.deviceId);
    this.devices=this.recentDevices.merge(this.devices,this.devices.map(device=>({...device,online:false})));
    this.scheduleDeviceExpiry();
    this.selectOnlineTarget();
  }
  dropDeviceConnectivity(deviceId:string) {
    this.rtcProbes?.removePeer(deviceId);
    const device=this.device(deviceId);if(device)this.deviceNames.set(device.deviceId,device.name);
    for(const transfer of this.transfers) {
      if(![transfer.sourceDeviceId,transfer.targetDeviceId].includes(deviceId))continue;
      for(const file of transfer.files) {
        const key=fileKey(transfer.transferId,file.fileId),channel=this.rtcChannels.get(key);
        if(channel || this.rtcReceives.has(key) || file.transport==='direct' && this.rtcAttempts.has(key)) {
          this.rtcReceives.get(key)?.abort();this.uploads.get(key)?.abort();void channel?.close();this.rtcChannels.delete(key);this.rtcAttempts.delete(key);
          if(['accepted','uploading'].includes(file.status))this.uploadErrors.set(key,'等待设备上线');
        }
      }
    }
  }
  updateDevices(values:Device[]) {
    const self=this.session?.device.deviceId,online=new Set(values.filter(device=>device.online && !device.revoked).map(device=>device.deviceId));
    for(const device of values)this.deviceNames.set(device.deviceId,device.name);
    for(const device of this.devices)if(device.deviceId!==self && !online.has(device.deviceId))this.dropDeviceConnectivity(device.deviceId);
    const ready=this.connected && this.helloReceived;
    this.devices=this.recentDevices.merge(this.devices,values.filter(device=>device.deviceId===self || ready || device.revoked).map(device=>({...device,online:ready && device.online,peer:ready && device.online && device.peer && Date.parse(device.peer.expiresAt)>Date.now()?device.peer:null,rtc:ready && device.online && device.rtc && Date.parse(device.rtc.expiresAt)>Date.now()?device.rtc:null})));
    this.scheduleDeviceExpiry();
    for(const transfer of this.transfers)for(const file of transfer.files){const key=fileKey(transfer.transferId,file.fileId);if(this.uploadErrors.get(key)==='等待设备上线' && online.has(transfer.sourceDeviceId===self?transfer.targetDeviceId:transfer.sourceDeviceId))this.uploadErrors.delete(key);}
    this.selectOnlineTarget();
    this.rtcProbes?.setOnlinePeers(this.onlinePeers().map(device=>device.deviceId));
  }
  openSettings() {
    this.autoAcceptLimitDraft=null;this.autoAcceptLimitElement=null;
    this.deviceNameDraft=this.session?.device.name || null;
    this.deviceNameError='';this.serverDraft=this.baseUrl;this.modal='settings';this.render();

  }
  async saveDeviceName() {
    if(!this.session || this.deviceNameBusy)return;
    const name=(this.deviceNameDraft || '').trim();
    if(!name || name.length>80){this.deviceNameError='请输入 1–80 字的设备名';this.render();return;}
    const generation=this.generation;
    this.deviceNameBusy=true;this.deviceNameError='';this.render();
    try {
      const {device}=await this.api.request<{device:Device}>('/devices/me',{name},'PATCH');
      if(generation!==this.generation || !this.session)return;
      this.session.device={...this.session.device,...device};
      this.devices=this.devices.map(item=>item.deviceId===device.deviceId?{...item,...device}:item);
      if(this.deviceNameDraft?.trim()===name)this.deviceNameDraft=device.name;
      this.saveSession();this.toast('名称已保存');
    } catch(error) { if(generation===this.generation)this.deviceNameError=errorText(error); }
    finally { if(generation===this.generation){this.deviceNameBusy=false;this.render();} }
  }
  async useAutomaticDeviceName() {
    if(!this.session || this.deviceNameBusy)return;
    this.deviceNameDraft=suggestedDeviceName(navigator);await this.saveDeviceName();
  }
  toast(message: string,error = false) {
    const node = document.createElement('div'); node.className = `toast${error ? ' error' : ''}`; node.textContent = message;
    document.querySelector('#toasts')!.replaceChildren(node); setTimeout(() => node.remove(),3500);
  }
  async run(action: () => Promise<unknown>) { const generation=this.generation;try { await action(); } catch (error) { if(generation===this.generation)this.toast(errorText(error),true); } }
  groupJoinName='';groupJoinPassword='';groupJoining=false;
  adoptGroups(groups:NonNullable<Session['groups']>) {
    if(!this.session)return;
    this.session.historyGroupId ??= this.session.groupId || 'legacy';
    this.session.groups=groups;
    if(!groups.some(group=>group.groupId===this.session!.groupId))this.session.groupId=groups[0]?.groupId || '';
    this.saveSession();
  }
  selectSharedGroup(groupId:string){
    if(!this.session?.groups?.some(group=>group.groupId===groupId))return;
    this.session.historyGroupId ??= this.session.groupId || 'legacy';
    this.session.groupId=groupId;this.saveSession();this.render();void this.shared.refresh();
  }
  async joinAdditionalGroup(){
    if(this.groupJoining)return;
    const password=validateGroupKey(this.groupJoinPassword),generation=this.generation;
    this.groupJoining=true;this.render();
    try{
      const result=await this.api.request<{groupId:string;groups:NonNullable<Session['groups']>}>('/groups/join',{groupKey:password,...(this.groupJoinName.trim()?{name:this.groupJoinName.trim()}:{})});
      if(generation!==this.generation)return;
      this.deviceSnapshotRevision++;this.adoptGroups(result.groups);this.selectSharedGroup(result.groupId);
      this.groupJoinName=this.groupJoinPassword='';await this.refresh();this.toast('已加入');
    }finally{if(generation===this.generation){this.groupJoining=false;this.render();}}
  }
  async leaveGroup(groupId:string){
    if(!confirm('退出此组？本地文件和历史记录保留。'))return;
    const generation=this.generation,result=await this.api.request<{groups:NonNullable<Session['groups']>}>('/groups/'+encodeURIComponent(groupId),undefined,'DELETE');
    if(generation!==this.generation)return;
    this.deviceSnapshotRevision++;this.adoptGroups(result.groups);this.recentDevices.clear();this.devices=[];
    await this.refresh();this.render();if(this.session?.groupId)void this.shared.refresh();
  }
  sharedGroupPickerHtml(){
    const groups=this.session?.groups || [];
    return groups.length>1?`<label class="shared-group-picker">组内共享<select data-shared-group aria-label="共享文本分组">${groups.map(group=>`<option value="${e(group.groupId)}" ${group.groupId===this.session?.groupId?'selected':''}>${e(group.name)}</option>`).join('')}</select></label>`:'';
  }
  groupsHtml(){
    if(!this.info?.features?.multiGroup || !this.session)return '';
    return `<section class="settings-card group-settings"><h3>分组</h3>${(this.session.groups || []).map(group=>`<div class="group-membership"><label><input type="radio" name="shared-group" data-shared-group value="${e(group.groupId)}" ${group.groupId===this.session?.groupId?'checked':''}>${e(group.name)}</label><button class="icon-button quiet" data-leave-group="${e(group.groupId)}" aria-label="退出 ${e(group.name)}">${icon('logout')}</button></div>`).join('')}<form id="group-join-form"><label class="field">名称（可选）<input id="group-join-name" maxlength="80" value="${e(this.groupJoinName)}"></label><label class="field">组密码<input id="group-join-password" type="password" minlength="10" maxlength="256" required value="${e(this.groupJoinPassword)}" autocomplete="off"></label><button class="secondary" ${this.groupJoining?'disabled':''}>加入分组</button></form></section>`;
  }
  async enroll() {
    if (this.pairBusy) return;
    const generation=this.generation;
    this.pairBusy = true; this.pairError = ''; this.render();
    try {
      const name=this.deviceName.trim() || suggestedDeviceName(navigator);
      const credential = {groupKey:validateGroupKey(this.groupKey)};
      const response = await this.api.request<Session & {createdGroup?:boolean}>('/devices/enroll',{name,platform:'web',...credential});
      if(generation!==this.generation)return;
      this.archiveLocalContent();
      this.session = publicSession(response);
      this.api.session = this.session;
      this.saveSession();this.loadPreferences();
      this.groupKey = ''; this.showGroupKey = false;
      this.startupError = '';
      await this.refresh(); this.connect();
      this.toast('已加入分组');
    } catch (error) {
      if(generation===this.generation)this.pairError = error instanceof ApiError ? this.joinError(error) : errorText(error);
    }
    finally { if(generation===this.generation){this.pairBusy = false; this.render();} }
  }
  signOut() {
    this.archiveLocalContent();
    this.formComposing=null;
    clearTimeout(this.deviceGraceTimer);this.recentDevices.clear();
    this.generation++; clearTimeout(this.reconnectTimer); this.ws?.close(); this.ws = null;
    this.clearFilePickers();
    if(this.editorElement)this.editorElement.value='';
    this.editorElement=null;this.editorComposing=false;this.editorRenderPending=false;
    this.clearTextViews();
    this.receivedAt={};
    for(const editor of this.groupEditors.values())editor.reset();this.groupEditors.clear();this.clearPreviews();this.stagedTexts=[];this.queueSending=false;this.folderBusy=false;this.openedFile=null;
    this.sendBatch=null;this.multiSend=false;this.receiveSelecting=false;this.sentSelecting=false;this.sentSelected.clear();this.selected.clear();this.selectedTargets.clear();this.receipt=null;this.pendingReceipt=null;this.receiptBatch.clear();this.receiptFocusId='';this.receiptVersions.clear();this.receiptsInitialized=false;this.contextMenu=null;
    for (const controller of this.uploads.values()) controller.abort();
    for (const controller of this.hashes) controller.abort();
    this.stopRtc();
    this.helloReceived=false;this.deviceNames.clear();
    this.libraryForward=null;this.fileLibrary.close();
    this.uploads.clear(); this.fileSources.clear(); this.api.session = null;
    for(const controller of this.fileRequests.values())controller.abort();this.fileRequests.clear();this.receiveReports.clear();this.canceled.clear();this.cancelRequests.clear();this.paused.clear();
    rememberedSet(this.key + ':session','');
    localSet(this.key + ':session',''); localSet(this.key + ':state','');localSet(this.dockKey,'');
    this.session = null; this.connected = false; this.modal = null;
    this.deviceNameDraft=null;this.deviceNameBusy=false;this.deviceNameError='';
    this.mobileView='send';
    this.autoAccept=true;this.autoAcceptMaxBytes=32*1024*1024;this.autoAcceptLimitDraft=null;this.autoAcceptLimitElement=null;this.accepting=new Set();this.autoAcceptRetryAt=new Map();this.selectingRelays=new Set();this.relayRetryAt=new Map();
    Object.assign(this,emptyGroupData());
    this.render();
  }
  async refresh() {
    if (!this.session) return;
    if (this.syncing) { this.syncAgain = true; return this.refreshWait; }
    this.syncing = true;
    let settled!:()=>void;this.refreshWait=new Promise<void>(resolve=>settled=resolve);
    const generation = this.generation,deviceRevision=this.deviceSnapshotRevision,knownEvents=new Set(this.events.map(event=>event.eventId));
    try {
      const [devices,transfers] = await Promise.all([
        this.api.request<{devices:Device[];groups?:import('../../packages/protocol/src/index.ts').GroupMembership[]}>('/devices'),this.api.request<{transfers:Transfer[]}>('/transfers'),
      ]);
      if (generation !== this.generation || !this.session) return;
      if(deviceRevision===this.deviceSnapshotRevision && devices.groups)this.adoptGroups(devices.groups);
      if(deviceRevision===this.deviceSnapshotRevision)this.updateDevices(devices.devices);else this.syncAgain=true;
      const ownGroupId = (this.device(this.session.device.deviceId) as (Device & {groupId?:string})|undefined)?.groupId;
      if (!this.info?.features?.multiGroup && ownGroupId && this.session.groupId !== ownGroupId) { const previousDockKey=this.dockKey;this.archiveLocalContent();this.events=[];this.transfers=[];this.cursor=0;this.stopRtc();this.recentDevices.clear();clearTimeout(this.deviceGraceTimer);this.devices=[];this.updateDevices(devices.devices);this.clearTextViews();if(this.modal==='reader')this.modal=null;this.session.groupId = ownGroupId; this.saveSession();this.loadPreferences();this.persist();localSet(previousDockKey,''); }
      if (this.device(this.session.device.deviceId)?.revoked) { this.signOut(); this.toast('此设备已断开，请重新加入。',true); return; }
      const ownDevice=this.device(this.session.device.deviceId);
      if(ownDevice && ownDevice.name!==this.session.device.name){this.session.device={...this.session.device,...ownDevice};this.saveSession();}
      const previousFiles=new Map(this.transfers.flatMap(transfer=>transfer.files.map(file=>[fileKey(transfer.transferId,file.fileId),file.status])));
      this.transfers = transfers.transfers.map(transfer=>({...transfer,files:transfer.files.map(file=>this.canceled.has(fileKey(transfer.transferId,file.fileId))?{...file,status:'canceled' as const}:file)}));
      if(this.receiptsInitialized)for(const transfer of this.transfers)for(const file of transfer.files)if(previousFiles.get(fileKey(transfer.transferId,file.fileId))!==file.status)this.noticeFile(transfer,file);
      this.reconcileRtc();
      this.selectOnlineTarget();
      let more = true;
      while (more) {
        const page = await this.api.request<{events:WireEvent[];cursor:number;hasMore:boolean}>(`/events?after=${this.cursor}&limit=100`);
        if (generation !== this.generation || !this.session) return;
        this.noticeEvents(page.events,this.receiptsInitialized);
        this.events = visibleLocalEvents(mergeEvents(this.events,page.events),this.hiddenItems); this.cursor = page.cursor; more = page.hasMore;
        this.persist();
      }
      if((this.info?.features as {textContentSync?:boolean}|undefined)?.textContentSync){
        const latest=await this.api.request<{documents:TextDocument[]}>('/texts/latest');
        if(generation!==this.generation || !this.session)return;
        this.applyLatestTexts(latest.documents);
      }
      this.startupError = '';
      for (const event of this.events) {
        if (event.type === 'text.created' && event.targetDeviceId === this.session.device.deviceId && !this.acked.has(event.eventId)) {
          if(!knownEvents.has(event.eventId))this.recordReceipt(`text:${event.eventId}`);
          this.acked.add(event.eventId);
          void this.api.request(`/events/${event.eventId}/ack`,{}).catch(() => this.acked.delete(event.eventId));
        }
      }
      this.receiptsInitialized=true;this.openNotificationReceipt();
      this.initializeConsent(); this.render(); this.startReadyUploads();
      if((this.info?.features as {groupSharedText?:boolean}|undefined)?.groupSharedText)void this.shared.refresh();
      void this.ensureRtc();void this.ensureFolderCapability();
      this.syncProbeMonitor();
      void this.acceptIncoming();
      void this.selectIncomingRelays();
    } catch (error) {
      if (generation !== this.generation) return;
      if (error instanceof ApiError && error.status === 401) { this.signOut(); this.toast('会话已失效，请重新输入组密码。',true); }
      else { this.startupError = errorText(error); this.render(); }
    } finally {
      this.syncing = false;
      if (this.syncAgain) { this.syncAgain = false; await this.refresh(); }
      settled();
    }
  }
  connect(force=false) {
    if(force){
      this.socketEpoch++;const previous=this.ws;this.ws=null;this.connecting=false;
      this.connected=false;this.helloReceived=false;clearTimeout(this.reconnectTimer);
      if(previous){previous.onclose=null;previous.onmessage=null;previous.onopen=null;previous.onerror=null;previous.close();}
    }
    if (!this.session || this.connecting || this.ws?.readyState === WebSocket.CONNECTING || this.ws?.readyState === WebSocket.OPEN) return;
    this.connecting = true;
    clearTimeout(this.reconnectTimer);
    const generation = this.generation, socketEpoch=this.socketEpoch;
    void (async () => {
      try {
        const {ticket} = await this.api.request<{ticket:string}>('/session/ws-ticket',{});
        if ((generation !== this.generation || socketEpoch !== this.socketEpoch) || !this.session) return;
        const url = centerWebSocketUrl(this.baseUrl,ticket);
        const socket = new WebSocket(url); this.ws = socket;
        socket.onopen = () => { if ((generation !== this.generation || socketEpoch !== this.socketEpoch)) { socket.close(); return; } this.render(); };
        socket.onmessage = message => {
          if ((generation !== this.generation || socketEpoch !== this.socketEpoch)) return;
          try {
            const data = JSON.parse(String(message.data));
            if(data.type==='hello') {
              this.connected=true;this.helloReceived=true;this.deviceSnapshotRevision++;this.reconnectAttempt=0;this.rtcRegisteredAt=0;this.discoveryRefreshedAt=0;this.folderRegisteredScope='';this.render();void this.ensureFolderCapability();
              if(this.discoveryRefresh)void this.discoveryRefresh.finally(()=>{if(generation===this.generation && this.connected){this.discoveryRefreshedAt=0;void this.refreshDiscovery();}});
              else void this.refreshDiscovery();
            }
            else if (data.type === 'presence') {
              this.deviceSnapshotRevision++;
              const device = this.device(data.deviceId);
              if(!data.online){this.dropDeviceConnectivity(data.deviceId);this.updateDevices(this.devices.map(item=>item.deviceId===data.deviceId?{...item,online:false}:item));this.render();}
              else {if(device){this.recentDevices.deadlines.delete(device.deviceId);device.online=true;this.scheduleDeviceExpiry();this.render();}void this.refresh();}
            }
            else if (data.type === 'devices.changed') {this.deviceSnapshotRevision++;void this.refresh();}
            else if(data.type==='sharedText.updated'){const groupId=data.groupId || this.session?.groupId;if(!this.info?.features?.multiGroup || this.session?.groups?.some(group=>group.groupId===groupId))this.sharedForGroup(groupId || '').receive(data as SharedDocument);}
            else if(data.type==='rtc.probes.changed')void this.rtcProbes?.changed();
            else if (data.type === 'rtc.changed') {
              const channel=this.rtcChannels.get(fileKey(data.transferId,data.fileId));
              if(channel && channel.view.attemptId===data.attemptId)void channel.refresh();
              else void this.refresh();
            }
            else if (data.type === 'event') {
              const event = data.event as WireEvent;
              this.noticeEvents([event]);
              if(event.type==='text.created' && event.targetDeviceId===this.session?.device.deviceId && !this.events.some(item=>item.eventId===event.eventId))this.recordReceipt(`text:${event.eventId}`);
              if (event.type === 'device.revoked' && event.payload.deviceId === this.session?.device.deviceId) { this.signOut(); this.toast('此设备已撤销。',true); return; }
              // Only the ordered HTTP replay advances the cursor: a WS notification may arrive ahead of earlier events.
              this.events = visibleLocalEvents(mergeEvents(this.events,[event]),this.hiddenItems); void this.refresh();
            }
          } catch { /* A malformed notification is reconciled from the HTTP source of truth. */ }
        };
        socket.onerror = () => socket.close();
        socket.onclose = () => { if ((generation !== this.generation || socketEpoch !== this.socketEpoch)) return; this.ws = null; this.connected = false;this.helloReceived=false;this.rtcRegisteredAt=0; this.clearPresence(); this.render(); this.scheduleReconnect(); };
      } catch { if ((generation === this.generation && socketEpoch === this.socketEpoch)) { this.connected = false;this.helloReceived=false;this.rtcRegisteredAt=0; this.clearPresence(); this.render(); this.scheduleReconnect(); } }
      finally { if(socketEpoch===this.socketEpoch)this.connecting = false; }
    })();
  }
  scheduleReconnect() {
    if (!this.session) return;
    clearTimeout(this.reconnectTimer);
    const delay = Math.min(30000,1000 * 2 ** this.reconnectAttempt++) * (.8 + Math.random() * .4);
    this.reconnectTimer = window.setTimeout(() => this.connect(),delay);
  }
  initializeConsent() {
    for (const transfer of this.transfers) if (transfer.targetDeviceId === this.session?.device.deviceId) {
      for (const file of transfer.files) if (file.status === 'offered' && !this.consent.has(fileKey(transfer.transferId,file.fileId))) this.consent.set(fileKey(transfer.transferId,file.fileId),true);
    }
  }
  async sendText(existingId?: string) {
    const generation = this.generation;
    let pending = this.pendingTexts.find(item => item.eventId === existingId);
    if (!pending) {
      if (!this.isSendablePeer(this.target) || !this.text.trim()) return;
      pending = {eventId:id(),targetDeviceId:this.target,text:this.text,error:'',busy:false};
      this.pendingTexts.push(pending); this.text = '';
    }
    if (!this.isSendablePeer(pending.targetDeviceId)) { pending.error='设备离线'; this.render(); return; }
    pending.busy = true; pending.error = ''; this.render();
    try {
      await this.api.request('/texts',{eventId:pending.eventId,targetDeviceId:pending.targetDeviceId,text:pending.text});
      if (generation !== this.generation) return;
      this.pendingTexts = this.pendingTexts.filter(item => item !== pending);
      this.toast('已发送'); await this.refresh();
    } catch (error) { if(generation === this.generation)pending.error = errorText(error); }
    finally { pending.busy = false; if(generation === this.generation)this.render(); }
  }
  addFiles(files: File[]) {
    if (this.busy || this.queueSending) { this.toast('正在准备中，请稍后添加。'); return; }
    if (this.pendingOffer) { this.toast('上次邀请结果未确认，请先重试发送邀请。',true); return; }
    if (this.picked.length + files.length > 10000) { this.toast('超出本次发送项数上限',true); return; }
    for (const file of files) {
      if (file.size > (this.info?.limits.maxFileSize || 0)) { this.toast(`${file.name} 超过单文件上限。`,true); continue; }
      // Manual repeated selections remain independent; the remove control lets the user correct an accidental selection.
      this.picked.push(file);
    }
    this.tab = 'files'; this.setMobileView('send');this.render();
  }
  async digest(file: File,onProgress?: (done:number) => void): Promise<string> {
    const controller = new AbortController(); this.hashes.add(controller);
    try { return await digestFile(file,{blockSize:this.info?.limits.chunkSize,onProgress,signal:controller.signal}); }
    finally { this.hashes.delete(controller); }
  }
  async sendFiles(targetDeviceId=this.target) {
    if (this.busy || !this.picked.length || !this.isSendablePeer(this.pendingOffer?.targetDeviceId || targetDeviceId)) return;
    this.busy = true;
    const generation = this.generation;
    const selected = [...this.picked]; const transferId = id(); const target = targetDeviceId;
    try {
      const prepared=this.pendingOffer?null:await prepareFolderSend(selected,file=>this.folderParts.get(file),file=>this.digest(file),this.info?.limits.maxFileSize || 0);
      if(generation!==this.generation)return;
      const files=this.pendingOffer?.files || prepared!.metadata.map(file=>({...file,fileId:id()}));
      this.requireFolderReceiver(target,files);
      if(prepared)this.rememberOfferSources({transferId,targetDeviceId:target,routePreference:this.routePreference,files},prepared.sources,selected);
      // Keep the complete offer identity on an uncertain HTTP outcome. Retry cannot create a duplicate batch.
      if(['lan','public'].includes(this.routePreference) && !this.rtcEnabled)throw new Error('当前浏览器或中心暂不支持直连。');
      this.pendingOffer ||= {transferId,targetDeviceId:target,routePreference:this.rtcEnabled?this.routePreference:'relay',files};
      const {transfer} = await this.api.request<{transfer:Transfer}>('/transfers',this.pendingOffer);
      if (generation !== this.generation) return;
      this.transfers = [transfer,...this.transfers.filter(item => item.transferId !== transfer.transferId)];
      this.picked = []; this.pendingOffer = null; this.toast('已发送');
      await this.refresh();
    } catch (error) { if(generation === this.generation)this.toast(errorText(error),true); }
    finally { if(generation === this.generation){this.busy = false; this.preparation = ''; this.render();} }
  }
  async openLibrary() {
    if(this.libraryForward){this.fileLibrary.editing=true;this.fileLibrary.selected=new Set(this.libraryForward.entryIds);this.fileLibrary.target=this.libraryForward.targetDeviceId;}
    if(this.session){this.contentView='library';this.setMobileView('receive');this.modal=null;}
    else this.modal='library';
    await this.fileLibrary.open();
  }
  targetState(target:string){const state=this.sendBatch?.targets.get(target)?.state,until=this.sentFeedback.get(target) || 0;if(state==='sent' && this.sentFeedback.has(target) && until<=Date.now())return '';return state || (until>Date.now()?'sent':'');}
  targetAlreadySent(target:string){return !!this.sendBatch?.matches(this.picked,this.stagedTexts) && this.sendBatch.targets.get(target)?.state==='sent';}
  transferSpeed(key:string){const sample=this.speedSamples.get(key);return sample && sample.speed>0?formatBytes(sample.speed)+'/s':'';}
  async forwardLibraryFiles(entries:LocalFileEntry[],target:string) {
    if(!this.session || !this.isSendablePeer(target))throw new Error('请选择设备');
    if(!this.fileLibrary.service || !entries.length)return;
    const generation=this.generation,api=new Api(this.baseUrl,this.session),ids=entries.map(entry=>entry.id);
    let offer=this.libraryForward;
    if(offer && (offer.targetDeviceId!==target || JSON.stringify(offer.entryIds)!==JSON.stringify(ids)))throw new Error('请先重试或取消上次转发');
    if(!offer) {
      const transferId=id(),files:(OfferFile & {fileId:string})[]=[];
      const expanded=entries.some(entry=>entry.relativePath)?await this.fileLibrary.service.expand(entries.map(entry=>entry.id)):await Promise.all(entries.map(async entry=>({entry,file:await this.fileLibrary.service!.get(entry.id)})));
      for(const {entry,file:local} of expanded) {
        if(local)this.librarySourceIds.set(local,entry.id);
        if(entry.entryKind==='directory'){files.push({fileId:id(),name:entry.name,size:0,mimeType:'inode/directory',sha256:emptyFileHash,relativePath:entry.relativePath,entryKind:'directory'});continue;}
        if(entry.size>(this.info?.limits.maxFileSize || 0))throw new Error(`${entry.name} 超过中心文件上限`);
        const source=local || await this.fileLibrary.service.get(entry.id),fileId=id();
        const sha256=entry.sha256 || await this.digest(source);
        if(generation!==this.generation)return;
        files.push({fileId,name:entry.name,size:source.size,mimeType:entry.mimeType || source.type || 'application/octet-stream',sha256,...(entry.relativePath?{relativePath:entry.relativePath,entryKind:'file' as const}:{})});
      }
      this.requireFolderReceiver(target,files);
      offer={transferId,targetDeviceId:target,routePreference:this.rtcEnabled?this.routePreference:'relay',entryIds:ids,files};
      const references=expanded.map(({entry,file})=>{if(file)return file;const reference=new File([],entry.name,{type:'inode/directory'});this.folderParts.set(reference,expanded.filter(item=>item.entry.relativePath && (item.entry.relativePath===entry.relativePath || item.entry.relativePath.startsWith(entry.relativePath!+'/'))).map(item=>({path:item.entry.relativePath!+(item.entry.entryKind==='directory'?'/':''),...(item.file?{file:item.file}:{})})));return reference;});
      this.rememberOfferSources(offer,references,references);
      this.libraryForward=offer;
    }
    const {entryIds:_,...body}=offer;
    const {transfer}=await api.request<{transfer:Transfer}>('/transfers',body);
    if(generation!==this.generation)return;
    this.transfers=[transfer,...this.transfers.filter(item=>item.transferId!==transfer.transferId)];
    this.libraryForward=null;this.toast('已转发');await this.refresh();
  }
  async discardLibraryForward() {
    const offer=this.libraryForward;if(!offer)return;
    const generation=this.generation,api=new Api(this.baseUrl,this.session);
    try {
      const {transfer}=await api.request<{transfer:Transfer}>(`/transfers/${offer.transferId}`);
      if(generation!==this.generation)return;
      for(const file of transfer.files){if(generation!==this.generation)return;await api.request(`/transfers/${offer.transferId}/files/${file.fileId}/cancel`,{});}
    }catch(error){if(!(error instanceof ApiError && error.status===404))throw error;}
    if(generation!==this.generation)return;
    for(const file of offer.files)this.fileSources.delete(fileKey(offer.transferId,file.fileId));
    this.libraryForward=null;await this.refresh();
  }
  async discardOffer() {
    if (!this.pendingOffer) return;
    const generation = this.generation;
    const offer = this.pendingOffer;
    try {
      const {transfer} = await this.api.request<{transfer:Transfer}>(`/transfers/${offer.transferId}`);
      if (generation !== this.generation) return;
      for (const file of transfer.files) { if(generation !== this.generation)return;await this.api.request(`/transfers/${offer.transferId}/files/${file.fileId}/cancel`,{}); }
    } catch (error) {
      if (!(error instanceof ApiError && error.status === 404)) throw error;
    }
    if (generation !== this.generation) return;
    for (const file of offer.files) this.fileSources.delete(fileKey(offer.transferId,file.fileId));
    this.pendingOffer = null; this.picked = []; this.render(); await this.refresh();
  }
  startReadyUploads() {
    if(this.receiveDirectoryChanging)return;
    if (!this.session) return;
    let available = this.transferConcurrency - this.activeFileTransfers;
    for (const transfer of this.transfers) {
      if (transfer.sourceDeviceId !== this.session.device.deviceId) continue;
      if(Date.parse(transfer.expiresAt)<=Date.now())continue;
      for (const file of transfer.files) {
        const key = fileKey(transfer.transferId,file.fileId);
        if(file.entryKind==='directory')continue;
        if (available <= 0) return;
        if (['accepted','uploading'].includes(file.status) && this.fileSources.has(key) && !this.uploads.has(key) && !this.fileRequests.has(key) && !this.paused.has(key) && !this.canceled.has(key) && !this.uploadErrors.has(key)) {
          if(file.transport==='direct' || (!file.transport && this.rtcEnabled)) {
            const rtc=(file as TransferFile & {rtc?:RtcView}).rtc;
            if(rtc && rtc.state!=='failed' && this.rtcAttempts.get(key)!==rtc.attemptId){available--;void this.sendRtc(transfer,file,rtc.attemptId);}
            continue;
          }
          available--; void this.uploadFile(transfer.transferId,file.fileId);
        }
      }
    }
  }
  isFailedSend(transfer:Transfer,file:TransferFile){
    const key=fileKey(transfer.transferId,file.fileId),error=this.uploadErrors.get(key);
    if(transfer.sourceDeviceId!==this.session?.device.deviceId || this.paused.has(key) || this.canceled.has(key) || this.uploads.has(key) || this.fileRequests.has(key) || (this.hiddenItems[fileItemKey(transfer.transferId,file.fileId)] || 0)>Date.now())return false;
    return file.status==='failed' || !!error && !['received','ready','canceled','expired','rejected'].includes(file.status) && !/等待设备上线|中继需确认/.test(error);
  }
  failedSendFiles(){return this.transfers.flatMap(transfer=>transfer.files.filter(file=>this.isFailedSend(transfer,file)).map(file=>({transfer,file,key:fileKey(transfer.transferId,file.fileId)})));}
  clearFailedSends(){
    for(const {transfer,file,key} of this.failedSendFiles()){
      this.hiddenItems[fileItemKey(transfer.transferId,file.fileId)]=Math.max(Date.parse(transfer.expiresAt),Date.now()+86400000);
      this.fileSources.delete(key);this.retainedSources.delete(key);this.uploadErrors.delete(key);this.localHistory.removeFile(transfer.transferId,file.fileId);
    }
    this.persist();this.render();
  }
  async retryFailedSends(){
    if(this.retryingFailedSends)return;this.retryingFailedSends=true;this.render();
    const queue=this.failedSendFiles();let cursor=0,missing=0;
    try{await Promise.all(Array.from({length:Math.min(queue.length,this.transferConcurrency)},async()=>{
      while(cursor<queue.length){const {transfer,file,key}=queue[cursor++];if(!this.isFailedSend(transfer,file))continue;
        if(!this.fileSources.has(key)){missing++;continue;}await this.retryFile(transfer.transferId,file.fileId);
      }
    }));if(missing)this.toast('部分文件需要重新选择原文件',true);}
    finally{this.retryingFailedSends=false;this.render();}
  }
  setFile(transferId: string,file: TransferFile) {
    if(this.canceled.has(fileKey(transferId,file.fileId)) && file.status!=='canceled')return;
    const transfer = this.transfers.find(item => item.transferId === transferId);
    if(file.status==='received' && transfer?.targetDeviceId===this.session?.device.deviceId)this.recordReceipt(fileKey(transferId,file.fileId));
    if (transfer) transfer.files = transfer.files.map(item => item.fileId === file.fileId ? file : item);
    if(transfer)this.noticeFile(transfer,file);
  }
  fileActive(key:string,controller:AbortController,generation:number){return generation===this.generation && !controller.signal.aborted && !this.paused.has(key) && !this.canceled.has(key);}
  stopFile(key:string){
    this.uploads.get(key)?.abort();this.rtcReceives.get(key)?.abort();this.fileRequests.get(key)?.abort();
    return this.rtcChannels.get(key)?.close().catch(()=>{}) || Promise.resolve();
  }
  pauseFile(key:string){
    const [transferId,fileId]=key.split(':'),transfer=this.localTransfer(transferId),root=transfer?.files.find(file=>file.fileId===fileId);
    for(const file of root && transfer?folderMembers(root,transfer.files):[]){
      const memberKey=fileKey(transferId,file.fileId);if(this.canceled.has(memberKey) || file.status==='received')continue;
      this.paused.add(memberKey);this.uploadErrors.delete(memberKey);void this.stopFile(memberKey);
    }
    this.render();
  }
  async reportReceiveError(transfer:Transfer,file:TransferFile,error:unknown,controller:AbortController,generation:number){
    const key=fileKey(transfer.transferId,file.fileId);
    if(!this.fileActive(key,controller,generation))return;
    this.uploadErrors.set(key,errorText(error));this.render();
    if(!(this.info?.features as {receiveErrorReporting?:boolean}|undefined)?.receiveErrorReporting)return;
    const reporting=(async()=>{
      try{
        const {file:failed}=await this.api.request<{file:TransferFile}>(`/transfers/${transfer.transferId}/files/${file.fileId}/receive-error`,{message:errorText(error).slice(0,500)||'无法保存接收文件'},'POST',controller.signal);
        if(this.fileActive(key,controller,generation)){this.setFile(transfer.transferId,failed);this.render();}
      }catch{/* The local failure remains visible when the center is unavailable. */}
    })();
    this.receiveReports.set(key,reporting);
    try{await reporting;}finally{if(this.receiveReports.get(key)===reporting)this.receiveReports.delete(key);}
  }
  async uploadFile(transferId: string,fileId: string) {
    const generation = this.generation;
    const key = fileKey(transferId,fileId); const source = this.fileSources.get(key);
    if (!source || this.uploads.has(key) || this.paused.has(key) || this.canceled.has(key)) return;
    const controller = new AbortController(); this.uploads.set(key,controller); this.uploadErrors.delete(key); this.render();
    try {
      // A failed HTTP response may have committed data: always reconcile before uploading/resuming.
      const {transfer} = await this.api.request<{transfer:Transfer}>(`/transfers/${transferId}`,undefined,'GET',controller.signal);
      if (!this.fileActive(key,controller,generation)) return;
      let file = transfer.files.find(item => item.fileId === fileId)!; this.setFile(transferId,file);
      if (!['accepted','uploading'].includes(file.status)) return;
      if(file.transport==='direct' || !file.transport && this.rtcEnabled)return;
      while (file.offset < source.size) {
        if (controller.signal.aborted) throw new DOMException('已暂停','AbortError');
        const offset = file.offset;
        const bytes = source.slice(offset,Math.min(source.size,offset + (this.info?.limits.chunkSize || 1048576)));
        const response = await this.api.upload<{file:TransferFile}>(`/transfers/${transferId}/files/${fileId}/chunks?offset=${offset}`,bytes,loaded => {
          if (!this.fileActive(key,controller,generation)) return;
          this.uploadProgress.set(key,offset + loaded); this.paintProgress(key,offset + loaded,source.size);
        },controller.signal);
        if (!this.fileActive(key,controller,generation)) return;
        file = response.file; this.setFile(transferId,file); this.uploadProgress.set(key,file.offset); this.render();
      }
      if (controller.signal.aborted) throw new DOMException('已暂停','AbortError');
      const {file:ready} = await this.api.request<{file:TransferFile}>(`/transfers/${transferId}/files/${fileId}/complete`,{},'POST',controller.signal);
      if (!this.fileActive(key,controller,generation)) return;
      this.setFile(transferId,ready);
    } catch (error) {
      if (this.fileActive(key,controller,generation) && !(error instanceof DOMException && error.name === 'AbortError')) this.uploadErrors.set(key,errorText(error));
    } finally {
      if (generation === this.generation) { if(this.uploads.get(key)===controller)this.uploads.delete(key); this.uploadProgress.delete(key); this.render(); this.startReadyUploads();void this.selectIncomingRelays(); }
    }
  }
  paintProgress(key: string,loaded: number,total: number,aggregate=true) {
    const now=Date.now(),previous=this.speedSamples.get(key);
    if(!previous || loaded<previous.bytes)this.speedSamples.set(key,{at:now,bytes:loaded,speed:0});
    else if(now-previous.at>=250)this.speedSamples.set(key,{at:now,bytes:loaded,speed:(loaded-previous.bytes)*1000/(now-previous.at)});
    const speed=document.getElementById('speed-'+key);if(speed)speed.textContent=this.transferSpeed(key);
    const progress = document.getElementById(`progress-${key}`);
    if (progress) { progress.style.width = `${total ? Math.min(100,loaded/total*100) : 0}%`; progress.parentElement?.setAttribute('aria-valuenow',String(loaded)); }
    const label = document.getElementById(`bytes-${key}`); if (label) label.textContent = `${formatBytes(loaded)} / ${formatBytes(total)}`;
    for(const node of document.querySelectorAll<HTMLElement>('[data-transfer-progress]'))if(node.dataset.transferProgress===key){node.style.width=`${total?Math.min(100,loaded/total*100):0}%`;node.parentElement?.setAttribute('aria-valuenow',String(loaded));}
    for(const node of document.querySelectorAll<HTMLElement>('[data-transfer-bytes]'))if(node.dataset.transferBytes===key)node.textContent=`${formatBytes(loaded)} / ${formatBytes(total)}`;
    for(const node of document.querySelectorAll<HTMLElement>('[data-transfer-speed]'))if(node.dataset.transferSpeed===key)node.textContent=this.transferSpeed(key);
    if(aggregate){
      const [transferId,fileId]=key.split(':'),transfer=this.localTransfer(transferId),file=transfer?.files.find(item=>item.fileId===fileId);
      if(file && transfer){const root=folderRoot(file,transfer.files);if(root.fileId!==fileId){
        const folder=summarizeFolder(root,folderMembers(root,transfer.files),member=>member.fileId===fileId?loaded:this.uploadProgress.get(fileKey(transferId,member.fileId)) ?? member.offset);
        this.paintProgress(fileKey(transferId,root.fileId),folder.offset,folder.size,false);
      }}
    }
  }
  async retryFile(transferId: string,fileId: string) {
    const transfer=this.localTransfer(transferId),root=transfer?.files.find(file=>file.fileId===fileId);
    if(root && transfer && isFolderRoot(root)){
      for(const member of folderMembers(root,transfer.files))if(member.fileId!==fileId && member.status!=='received' && (this.paused.has(fileKey(transferId,member.fileId)) || member.status==='failed' || this.uploadErrors.has(fileKey(transferId,member.fileId))))await this.retryFile(transferId,member.fileId);
      if(root.status==='received')return;
    }
    const generation=this.generation;
    const key = fileKey(transferId,fileId);
    let file = this.transfers.find(item => item.transferId === transferId)?.files.find(item => item.fileId === fileId);
    if (!file || this.canceled.has(key) || this.fileRequests.has(key)) return;
    const incoming=this.transfers.find(item=>item.transferId===transferId);
    const receiving=incoming?.targetDeviceId===this.session?.device.deviceId;
    if (!receiving && !this.fileSources.has(key)) { this.openFilePicker(key); return; }
    const controller=new AbortController();this.fileRequests.set(key,controller);this.paused.delete(key);this.uploadErrors.delete(key);this.render();
    try{
      await this.receiveReports.get(key);
      if(!this.fileActive(key,controller,generation))return;
      file=this.transfers.find(item=>item.transferId===transferId)?.files.find(item=>item.fileId===fileId);if(!file)return;
      if(file.receiveFailure || file.status==='failed' && !receiving){
        const response=await this.api.request<{file:TransferFile}>(`/transfers/${transferId}/files/${fileId}/${file.receiveFailure?'receive-retry':'retry'}`,file.receiveFailure?{}:{attemptId:id()},'POST',controller.signal);
        if(!this.fileActive(key,controller,generation))return;this.setFile(transferId,response.file);
      }
    }catch(error){if(this.fileActive(key,controller,generation))this.uploadErrors.set(key,errorText(error));}
    finally{if(this.fileRequests.get(key)===controller)this.fileRequests.delete(key);if(generation===this.generation){this.render();this.startReadyUploads();void this.selectIncomingRelays();}}
  }
  async attachResumeSource(file: File,key = this.resumeKey) {
    const generation = this.generation;
    const [transferId,fileId] = key.split(':');
    const remote = this.transfers.find(item => item.transferId === transferId)?.files.find(item => item.fileId === fileId);
    if (!remote) return;
    this.toast('正在核对源文件…');
    if (file.size !== remote.size || await this.digest(file) !== remote.sha256) throw new Error('所选文件与原始文件不一致，请选择原来的文件。');
    if (generation !== this.generation) return;
    this.fileSources.set(key,file); await this.retryFile(transferId,fileId);
  }
  async acceptTransfer(transferId: string) {
    const transfer = this.transfers.find(item => item.transferId === transferId);
    if (!transfer) return;
    const fileIds = transfer.files.filter(file => file.status === 'offered' && this.consent.get(fileKey(transferId,file.fileId))).map(file => file.fileId);
    await this.acceptFiles(transfer,fileIds,false);
  }
  async acceptIncoming() {
    const generation=this.generation;
    for(const transfer of this.transfers){
      if(generation!==this.generation || !this.session || !this.autoAccept)return;
      if(transfer.targetDeviceId!==this.session.device.deviceId || Date.parse(transfer.expiresAt)<=Date.now() || (this.autoAcceptRetryAt.get(transfer.transferId) || 0)>Date.now())continue;
      const offered=transfer.files.filter(file=>file.status==='offered');
      // Accept is a batch decision: selecting only small items would reject the
      // remaining large files. Leave the whole mixed batch for one manual click.
      const fileIds=offered.map(file=>file.fileId);
      if(!fileIds.length || this.accepting.has(transfer.transferId))continue;
      try{await this.acceptFiles(transfer,fileIds,true);}
      catch(error){
        if(generation!==this.generation)return;
        this.autoAcceptRetryAt.set(transfer.transferId,Date.now()+30000);
        this.toast('自动接收暂未完成，可手动重试：'+errorText(error),true);
      }
    }
  }
  async acceptFiles(transfer: Transfer,fileIds: string[],automatic: boolean) {
    const generation=this.generation;
    const transferId=transfer.transferId;
    if(!this.session || transfer.targetDeviceId!==this.session.device.deviceId || this.accepting.has(transferId) || Date.parse(transfer.expiresAt)<=Date.now())return;
    if(!automatic)for(const fileId of fileIds)this.relayConfirmed.add(fileKey(transferId,fileId));
    this.accepting.add(transferId);this.render();
    try{
      const selected=new Set(fileIds);
      if(this.info?.features?.folderReuse && fileIds.length && localStorageSupported()){
        let folderReused=false;
        for(const root of transfer.files.filter(file=>file.entryKind==='directory' && file.relativePath && !file.relativePath.includes('/'))){
          const members=transfer.files.filter(file=>file.fileId===root.fileId || file.relativePath?.startsWith(root.relativePath!+'/'));
          if(!members.every(file=>selected.has(file.fileId) && file.status==='offered' && !this.canceled.has(fileKey(transferId,file.fileId)) && !this.paused.has(fileKey(transferId,file.fileId))))continue;
          const store=await this.ensureFileStore();
          const local=await store.reuseFolder(transferId,members);if(!local)continue;
          const keys=members.map(file=>fileKey(transferId,file.fileId));
          if(generation!==this.generation || keys.some(key=>this.canceled.has(key) || this.paused.has(key))){await Promise.all(keys.map(key=>store.unlinkReuse(key)));return;}
          try{
            const request:FolderReuseRequest={files:members.map(({fileId,sha256,size})=>({fileId,sha256,size}))};
            const response=await this.api.request<FolderReuseReceipt>(`/transfers/${transferId}/folders/${root.fileId}/reuse`,request);
            const receivedAt=response.files[0].receivedAt!;await store.confirmFolderReuse(keys,receivedAt);
            if(generation!==this.generation)return;
            for(const file of response.files){const key=fileKey(transferId,file.fileId);this.rtcLocalFiles.set(key,local.get(key)!);this.rtcFileExpiry.set(key,store.expiry(key));this.receivedAt[key]=file.receivedAt!;this.setFile(transferId,file);selected.delete(file.fileId);}
            this.persist();folderReused=true;
          }catch(error){
            // Keep durable aliases after an unknown/lost response: the center
            // may have committed its receipt, and refresh must find the bytes.
            if(!(error instanceof ApiError && error.code==='TRANSFER_STARTED'))throw error;
            await Promise.all(keys.map(key=>store.unlinkReuse(key)));
          }
        }
        if(folderReused)await this.fileLibrary.refresh();
      }
      if(this.info?.features?.fileReuse && fileIds.length && localStorageSupported()){
        const store=await this.ensureFileStore();
        for(const file of transfer.files.filter(file=>selected.has(file.fileId) && file.status==='offered' && !file.relativePath && file.entryKind!=='directory')){
          const key=fileKey(transferId,file.fileId),local=await store.reuse(key,file);
          if(!local)continue;
          if(generation!==this.generation || this.canceled.has(key) || this.paused.has(key)){await store.unlinkReuse(key);return;}
          try{
            const response=await this.api.request<{file:TransferFile}>(`/transfers/${transferId}/files/${file.fileId}/reuse`,{sha256:file.sha256,size:file.size});
            if(generation!==this.generation)return;
            this.rtcLocalFiles.set(key,local);this.rtcFileExpiry.set(key,store.expiry(key));
            this.receivedAt[key]=response.file.receivedAt || store.receivedAt(key) || new Date().toISOString();
            this.setFile(transferId,response.file);selected.delete(file.fileId);this.persist();
          }catch(error){await store.unlinkReuse(key);if(!(error instanceof ApiError && error.code==='TRANSFER_STARTED'))throw error;}
        }
        await this.fileLibrary.refresh();
      }
      const remaining=transfer.files.filter(file=>selected.has(file.fileId));
      if(remaining.length && this.requiresNative(transfer)){
        if(automatic)return;
        throw new Error('发送方指定原生直连，请改为自动/中继或使用原生客户端。');
      }
      // Reused large files need no relay confirmation. A mixed batch still
      // waits for consent on all remaining bytes instead of rejecting them.
      if(automatic && remaining.some(file=>file.size>this.autoAcceptMaxBytes) && !this.rtcPeer(transfer))return;
      const response=await this.api.request<{transfer:Transfer}>(`/transfers/${transferId}/accept`,{fileIds:[...selected]});
      if(generation!==this.generation)return;
      this.transfers=this.transfers.map(item=>item.transferId===transferId?{...response.transfer,files:response.transfer.files.map(file=>this.canceled.has(fileKey(transferId,file.fileId))?{...file,status:'canceled' as const}:file)}:item);
      this.autoAcceptRetryAt.delete(transferId);
      if(!automatic)this.toast(fileIds.length ? '开始接收' : '已拒绝');
      await this.refresh();
    }finally{if(generation===this.generation){this.accepting.delete(transferId);this.render();}}
  }
  get rtcEnabled() {return !this.rtcUnavailable && !!(this.info?.features as {rtcDataChannels?:boolean}|undefined)?.rtcDataChannels && rtcStorageSupported();}
  async ensureFileStore():Promise<RtcFileStore>{
    if(this.rtcStore){await this.rtcStore.ready;return this.rtcStore;}
    if(this.storeStarting)return this.storeStarting;
    const generation=this.generation,scope=this.dockKey;
    const starting=(async()=>{
      await this.rtcClosing;
      const store=new RtcFileStore(scope);
      try{await store.ready;if(generation!==this.generation)throw new DOMException('会话已切换','AbortError');this.rtcStore=store;this.receiveDestination=(await store.destination()).name;return store;}
      catch(error){await store.dispose().catch(()=>{});throw error;}
    })();
    this.storeStarting=starting;try{return await starting;}finally{if(this.storeStarting===starting)this.storeStarting=null;}
  }
  async ensureFolderCapability(){
    if(!this.info?.features?.folderTransfer || !this.session || !this.connected || !this.helloReceived || this.folderRegisteredScope===this.dockKey)return;
    if(this.folderRegistering)return this.folderRegistering;
    const generation=this.generation,scope=this.dockKey;
    const register=(async()=>{const supported=localStorageSupported();if(supported)await this.ensureFileStore();if(generation!==this.generation)return;await this.api.request('/devices/me/capabilities',{folderTransfer:supported});if(generation===this.generation){this.folderRegisteredScope=scope;this.reconcileRtc();}})();
    this.folderRegistering=register;try{await register;this.uploadErrors.delete('folder-storage');}catch(error){if(generation===this.generation){this.uploadErrors.set('folder-storage',errorText(error));await this.api.request('/devices/me/capabilities',{folderTransfer:false}).catch(()=>{});}}finally{if(this.folderRegistering===register)this.folderRegistering=null;}
  }
  async chooseReceiveDirectory(){
    const picker=(window as Window & {showDirectoryPicker?:(options?:unknown)=>Promise<FileSystemDirectoryHandle>}).showDirectoryPicker;
    if(!picker)throw new Error('此浏览器将文件夹保存在浏览器文件库');
    try{
      const handle=await picker({id:'globalsend-receive-folder',mode:'readwrite'});
      await this.changeReceiveDirectory(handle);
    }catch(error){if((error as Error).name!=='AbortError')throw error;}
  }
  async changeReceiveDirectory(handle?:FileSystemDirectoryHandle){
    if(this.receiveDirectoryChanging)return;
    const generation=this.generation;
    try{
      this.receiveDirectoryChanging=true;this.render();
      // Let already accepted streams commit; the scheduler below holds new receives.
      while(this.rtcReceives.size || this.uploads.size)await new Promise(resolve=>setTimeout(resolve,50));
      if(generation!==this.generation)throw new DOMException('会话已切换','AbortError');
      const store=await this.ensureFileStore(),result=await store.setDestination(handle);
      this.receiveDestination=result.name;
      const replacements=new Map<File,File>();
      this.fileLibrary.service ||= new (await import('./library')).LocalFileLibrary();
      const folderReferences=new Set([...this.picked,...this.fileSources.values(),...this.retainedSources.values(),...this.rtcLocalFiles.values()]);
      const indexedSources=new Map<string,File[]>();
      for(const source of [...folderReferences,...[...folderReferences].flatMap(folder=>(this.folderParts.get(folder) || []).flatMap(part=>part.file?[part.file]:[]))]){
        const origin=this.librarySourceIds.get(source);if(origin)indexedSources.set(origin,[...indexedSources.get(origin) || [],source]);
      }
      for(const {scope,key} of result.relocated || []){
        const file=scope===store.scope?await store.get(key):await this.fileLibrary.service.get(scope+'/'+encodeURIComponent(key));
        if(!file)continue;
        const origin=scope+'/'+encodeURIComponent(key);this.librarySourceIds.set(file,origin);
        for(const source of indexedSources.get(origin) || [])replacements.set(source,file);
        for(const map of [this.rtcLocalFiles,this.fileSources,this.retainedSources,this.previewSources]){
          const previous=map.get(key);if(previous){replacements.set(previous,file);map.set(key,file);}
        }
      }
      this.picked=this.picked.map(file=>replacements.get(file) || file);
      for(const folder of folderReferences){const parts=this.folderParts.get(folder);if(!parts)continue;
        for(const part of parts)if(part.file && replacements.has(part.file))part.file=replacements.get(part.file)!;
        const next=replacements.get(folder);if(next){this.folderParts.set(next,parts);const name=this.folderNames.get(folder);if(name)this.folderNames.set(next,name);}
      }
      this.clearPreviews();await this.fileLibrary.refreshLocations();
      if(result.cleanupPending)this.toast('目录已更改，旧文件被占用，稍后重试清理',true);
    }finally{this.receiveDirectoryChanging=false;this.render();this.startReadyUploads();void this.selectIncomingRelays();}
  }
  async stageLibraryEntry(entry:LocalFileEntry){
    const service=this.fileLibrary.service;if(!service)return;
    if(entry.entryKind!=='directory'){const file=await service.get(entry.id);this.librarySourceIds.set(file,entry.id);if(entry.relativePath){const reference=new File([],entry.relativePath.split('/')[0],{type:'inode/directory'});this.folderParts.set(reference,completeFolderParts(reference.name,[{path:entry.relativePath,file}]));this.folderNames.set(reference,reference.name);this.addFiles([reference]);}else this.addFiles([file]);return;}
    const expanded=await service.expand([entry.id]),root=entry.relativePath!.split('/')[0];
    for(const {entry:child,file} of expanded)if(file)this.librarySourceIds.set(file,child.id);
    await this.addFolders([{name:root,parts:expanded.map(({entry,file})=>({path:entry.relativePath!+(entry.entryKind==='directory'?'/':''),...(file?{file}:{})}))}]);
  }
  async stageReceivedFile(key:string){
    const file=this.localFile(key);if(!file)throw new Error('请先将文件接收到本机');
    const parts=this.folderParts.get(file);if(parts){await this.addFolders([{name:parts[0].path.split('/')[0],parts}]);return;}
    const transfer=this.localTransfer(key.split(':')[0]),remote=transfer?.files.find(value=>value.fileId===key.split(':')[1]);
    if(remote?.relativePath){this.fileLibrary.service ||= new (await import('./library')).LocalFileLibrary();const entry=(await this.fileLibrary.service.list()).find(value=>value.key===key);if(!entry)throw new Error('本机文件已不存在');await this.stageLibraryEntry(entry);}else this.addFiles([file]);
  }
  async receiveDirectory(transfer:Transfer,file:TransferFile){
    if(this.receiveDirectoryChanging || this.activeFileTransfers>=this.transferConcurrency)return;
    const key=fileKey(transfer.transferId,file.fileId),generation=this.generation;if(this.rtcReceives.has(key) || this.paused.has(key) || this.canceled.has(key))return;
    const controller=new AbortController();this.rtcReceives.set(key,controller);
    try{
      const store=await receiveStorage(()=>this.ensureFileStore());if(!this.fileActive(key,controller,generation))return;
      await receiveStorage(()=>store.directory(key,file));if(!this.fileActive(key,controller,generation))return;
      const local=await receiveStorage(()=>store.get(key));if(!this.fileActive(key,controller,generation))return;
      if(local)this.rtcLocalFiles.set(key,local);
      const response=await this.api.request<{file:TransferFile}>(`/transfers/${transfer.transferId}/files/${file.fileId}/received`,{},'POST',controller.signal);
      if(this.fileActive(key,controller,generation)){this.recordReceipt(key,store.receivedAt(key));this.setFile(transfer.transferId,response.file);this.uploadErrors.delete(key);}
    }catch(error){if(this.fileActive(key,controller,generation)){if(error instanceof ReceiveStorageError)await this.reportReceiveError(transfer,file,error,controller,generation);else this.uploadErrors.set(key,errorText(error));}}
    finally{if(generation===this.generation){if(this.rtcReceives.get(key)===controller)this.rtcReceives.delete(key);this.render();this.startReadyUploads();void this.selectIncomingRelays();}}
  }
  async receiveStructuredRelay(transfer:Transfer,file:TransferFile){
    if(this.receiveDirectoryChanging || this.activeFileTransfers>=this.transferConcurrency)return;
    const key=fileKey(transfer.transferId,file.fileId),generation=this.generation;if(this.rtcReceives.has(key) || this.paused.has(key) || this.canceled.has(key))return;
    const controller=new AbortController();this.rtcReceives.set(key,controller);this.uploadErrors.delete(key);
    let store:RtcFileStore|undefined;
    try{
      store=await receiveStorage(()=>this.ensureFileStore());if(!this.fileActive(key,controller,generation))return;
      let local=await receiveStorage(()=>store!.get(key));if(!this.fileActive(key,controller,generation))return;
      if(!local){
        let offset=await receiveStorage(()=>store!.open(key,file,Date.now()+86400000));if(!this.fileActive(key,controller,generation))return;
        if(offset<file.size){
          const {downloadPath}=await this.api.request<{downloadPath:string}>(`/transfers/${transfer.transferId}/files/${file.fileId}/download-ticket`,this.info?.features?.relayStreaming?{live:true}:{},'POST',controller.signal);
          if(!this.fileActive(key,controller,generation))return;
          const response=await fetch(safeDownloadUrl(this.baseUrl,downloadPath),{signal:controller.signal,credentials:'omit',cache:'no-store',headers:offset?{Range:`bytes=${offset}-`}:undefined});
          if(!response.ok || offset && response.status!==206)throw new Error('文件下载无法从已接收位置继续');
          const reader=response.body!.getReader();
          try{for(;;){const {done,value}=await reader.read();if(!this.fileActive(key,controller,generation))return;if(done)break;const bytes=value.buffer.slice(value.byteOffset,value.byteOffset+value.byteLength) as ArrayBuffer;offset=await receiveStorage(()=>store!.write(key,offset,bytes));if(!this.fileActive(key,controller,generation))return;this.uploadProgress.set(key,offset);this.paintProgress(key,offset,file.size);}}finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
        }
        local=await receiveStorage(()=>store!.finish(key));if(!this.fileActive(key,controller,generation))return;
        if(await digestFile(local,{signal:controller.signal})!==file.sha256){await store.remove(key);throw new Error('文件校验不一致，请重试');}
        await receiveStorage(()=>store!.confirm(key));
      }
      if(!this.fileActive(key,controller,generation))return;
      this.rtcLocalFiles.set(key,local);this.rtcFileExpiry.set(key,store.expiry(key));this.recordReceipt(key,store.receivedAt(key));
      const {file:received}=await this.api.request<{file:TransferFile}>(`/transfers/${transfer.transferId}/files/${file.fileId}/received`,{transport:'relay'},'POST',controller.signal);
      if(this.fileActive(key,controller,generation)){this.setFile(transfer.transferId,received);void this.fileLibrary.refresh();}
    }catch(error){if(this.fileActive(key,controller,generation) && (error as Error).name!=='AbortError'){if(error instanceof ReceiveStorageError)await this.reportReceiveError(transfer,file,error,controller,generation);else this.uploadErrors.set(key,errorText(error));}}
    finally{await store?.close(key).catch(()=>{});if(generation===this.generation){if(this.rtcReceives.get(key)===controller)this.rtcReceives.delete(key);this.uploadProgress.delete(key);this.render();this.startReadyUploads();void this.selectIncomingRelays();}}
  }
  stopRtc() {
    const probes=this.rtcProbes;this.rtcProbes=null;this.rtcProbeScope='';void probes?.dispose();
    for(const controller of this.rtcReceives.values())controller.abort();
    const channels=[...this.rtcChannels.values()],store=this.rtcStore;
    this.rtcClosing=Promise.all([this.rtcClosing,...channels.map(channel=>channel.close())]).then(()=>store?.dispose()).catch(()=>{});
    this.rtcChannels=new Map();this.rtcReceives=new Map();this.rtcAttempts=new Map();this.rtcLocalFiles=new Map();this.rtcFileExpiry=new Map();this.rtcRestoring=new Set();this.relayConfirmed=new Set();
    this.rtcStore=null;this.storeStarting=null;this.folderRegisteredScope='';this.folderRegistering=null;this.rtcRegisteredAt=0;this.rtcUnavailable=false;this.rtcRegistering=null;
  }
  async ensureRtc(explicitRefresh=false):Promise<void> {
    if(!this.rtcEnabled || !this.session || !this.connected || !this.helloReceived)return;
    if(this.rtcRegistering){try{await this.rtcRegistering;}catch{return;}if(explicitRefresh)return this.ensureRtc(true);return;}
    if(!explicitRefresh && Date.now()-this.rtcRegisteredAt<120000)return;
    const generation=this.generation,epoch=this.discoveryEpoch,scope=this.dockKey,api=new Api(this.baseUrl,this.session);
    const register=(async()=>{
      await this.rtcClosing;if(generation!==this.generation || epoch!==this.discoveryEpoch || !this.connected || !this.helloReceived)return;
      let store:RtcFileStore;
      try{store=await this.ensureFileStore();}catch(error){if(generation===this.generation)this.rtcUnavailable=true;throw error;}
      if(generation!==this.generation || epoch!==this.discoveryEpoch || !this.connected || !this.helloReceived)return;
      await api.request('/devices/me/rtc',{scopes:['lan','public'],...(this.info?.features?.rtcParallelProbes?{parallelProbes:true}:{}),...(explicitRefresh && (this.info?.features as {discoveryRefresh?:boolean}|undefined)?.discoveryRefresh?{refresh:true}:{})});
      if(generation!==this.generation || epoch!==this.discoveryEpoch || !this.connected || !this.helloReceived)return;
      this.rtcRegisteredAt=Date.now();await store.cleanup();if(!explicitRefresh){this.syncProbeMonitor();void this.refresh();}
    })();
    this.rtcRegistering=register;
    try{await register;}
    catch(error){if(generation===this.generation && epoch===this.discoveryEpoch && this.connected && this.helloReceived){this.rtcRegisteredAt=Date.now()-90000;this.toast('直连暂不可用：'+errorText(error),true);}}
    finally{if(this.rtcRegistering===register){this.rtcRegistering=null;if(generation===this.generation && epoch!==this.discoveryEpoch && this.connected && this.helloReceived)void this.ensureRtc();}}
  }
  probeForeground() {return !!this.session && this.connected && this.helloReceived && document.visibilityState==='visible' && navigator.onLine!==false;}
  syncProbeMonitor() {
    if(!this.session || !this.info?.features?.rtcProbes || !this.rtcEnabled || !this.rtcRegisteredAt) {void this.rtcProbes?.setForeground(false);return;}
    if(!this.rtcProbes || this.rtcProbeScope!==this.dockKey) {
      const previous=this.rtcProbes;void previous?.dispose();
      const monitor=new RtcProbeMonitor({api:new Api(this.baseUrl,this.session),deviceId:this.session.device.deviceId,reportAddresses:this.info.features.rtcProbeAddresses===true,parallel:this.info.features.rtcParallelProbes===true,changed:()=>{if(this.rtcProbes===monitor)this.render();}});
      this.rtcProbes=monitor;this.rtcProbeScope=this.dockKey;
    }
    this.rtcProbes.setOnlinePeers(this.onlinePeers().map(device=>device.deviceId));void this.rtcProbes.setForeground(this.probeForeground());
  }
  reconcileRtc() {
    if(!this.session)return;
    for(const [key,channel] of this.rtcChannels) {
      const transfer=this.transfers.find(t=>t.transferId===channel.view.transferId),file=transfer?.files.find(f=>f.fileId===channel.view.fileId);
      const attempt=(file as TransferFile & {rtc?:RtcView}|undefined)?.rtc;
      if(!transfer || !file || Date.parse(transfer.expiresAt)<=Date.now() || !['accepted','uploading'].includes(file.status) || attempt && attempt.attemptId!==channel.view.attemptId) {
        this.rtcReceives.get(key)?.abort();this.uploads.get(key)?.abort();void channel.close();
      }
    }
    const generation=this.generation,store=this.rtcStore;
    if(!store)return;
    for(const transfer of this.transfers)for(const file of transfer.files) {
      const key=fileKey(transfer.transferId,file.fileId);
      if(transfer.sourceDeviceId===this.session.device.deviceId && ['canceled','rejected','expired'].includes(file.status))this.fileSources.delete(key);
      if(transfer.targetDeviceId!==this.session.device.deviceId || file.status!=='received' || !(file.transport==='direct' || file.relativePath) || this.hiddenItems[fileItemKey(transfer.transferId,file.fileId)]>Date.now() || this.rtcLocalFiles.has(key) || this.rtcRestoring.has(key))continue;
      const restoring=this.rtcRestoring,revision=this.rtcCacheRevision;restoring.add(key);
      void store.get(key).then(local=>{if(local && generation===this.generation && store===this.rtcStore && revision===this.rtcCacheRevision && !(this.hiddenItems[fileItemKey(transfer.transferId,file.fileId)]>Date.now())){this.rtcLocalFiles.set(key,local);this.rtcFileExpiry.set(key,store.expiry(key));const receivedAt=store.receivedAt?.(key);if(receivedAt){this.receivedAt[key]=receivedAt;this.persist();}this.render();}}).catch(()=>{}).finally(()=>{restoring.delete(key);if(generation===this.generation && store===this.rtcStore && revision!==this.rtcCacheRevision)this.reconcileRtc();});
    }
  }
  syncLibraryCache(entries:LocalFileEntry[]) {
    // These maps belong only to the active session's store. Re-read that store
    // after a library rename/delete/policy update; never inject another group's
    // inventory into the current receive dock.
    for(const entry of entries)if(entry.scope===this.rtcStore?.scope)this.receivedAt[entry.key]=new Date(entry.receivedAt).toISOString();
    const keys=new Set(entries.flatMap(entry=>[entry.key,...entry.aliases || []]));for(const key of this.knownLibraryKeys)if(!keys.has(key)){this.retainedSources.delete(key);this.previewSources.delete(key);const [transferId,fileId]=key.split(':');this.localHistory.removeFile(transferId,fileId);this.hiddenItems[fileItemKey(transferId,fileId)]=Math.max(Date.parse(this.localTransfer(transferId)?.expiresAt || '') || 0,Date.now()+86400000);}
    this.knownLibraryKeys=keys;
    this.persist();this.rtcCacheRevision++;this.rtcLocalFiles.clear();this.rtcFileExpiry.clear();this.reconcileRtc();
  }
  async sendRtc(transfer:Transfer,file:TransferFile,attemptId:string) {
    const generation=this.generation,key=fileKey(transfer.transferId,file.fileId),source=this.fileSources.get(key);
    if(!source || !this.session || !this.connected || !this.helloReceived || !this.isOnlinePeer(transfer.targetDeviceId) || this.uploads.has(key) || this.paused.has(key) || this.canceled.has(key))return;
    const api=new Api(this.baseUrl,this.session),controller=new AbortController();
    this.uploads.set(key,controller);this.rtcAttempts.set(key,attemptId);this.uploadErrors.delete(key);this.render();
    let channel:RtcFileChannel|undefined;
    try {
      const {rtc}=await api.request<{rtc:RtcView}>(`/transfers/${transfer.transferId}/files/${file.fileId}/rtc/${attemptId}`,undefined,'GET',controller.signal);
      if(generation!==this.generation || controller.signal.aborted)return;
      channel=new RtcFileChannel(api,rtc,'source',(this.info as ServerInfo & {rtc?:{iceServers:RTCIceServer[]}})?.rtc?.iceServers || [],controller.signal);
      this.rtcChannels.set(key,channel);
      await channel.send(source,offset=>{if(this.fileActive(key,controller,generation)){this.uploadProgress.set(key,offset);this.paintProgress(key,offset,file.size);}});
    } catch(error) {
      if(generation===this.generation && !controller.signal.aborted) {
        // Receiver owns the next route. A failed attempt must not poison a later
        // public attempt or force a relay upload from the source.
        if(channel)await api.request(channel.path+'/fail',{error:errorText(error)}).catch(()=>{});
      }
    } finally {
      await channel?.close();
      if(generation===this.generation){if(this.rtcChannels.get(key)===channel)this.rtcChannels.delete(key);if(this.uploads.get(key)===controller)this.uploads.delete(key);this.render();this.startReadyUploads();void this.selectIncomingRelays();void this.refresh();}
    }
  }
  async receiveRtc(transfer:Transfer,file:TransferFile) {
    if(this.receiveDirectoryChanging || this.activeFileTransfers>=this.transferConcurrency)return;
    const generation=this.generation,key=fileKey(transfer.transferId,file.fileId);
    if(!this.session || !this.connected || !this.helloReceived || !this.isOnlinePeer(transfer.sourceDeviceId) || this.rtcReceives.has(key) || this.paused.has(key) || this.canceled.has(key))return;
    const controller=new AbortController(),api=new Api(this.baseUrl,this.session);
    this.rtcReceives.set(key,controller);this.uploadErrors.delete(key);this.render();
    let channel:RtcFileChannel|undefined,store:RtcFileStore|null=null,local:File|undefined,complete=false;
    try {
      await this.ensureRtc();if(generation!==this.generation || controller.signal.aborted)return;
      store=await receiveStorage(()=>this.ensureFileStore());if(!this.fileActive(key,controller,generation))return;
      const recovered=this.rtcLocalFiles.get(key) || await receiveStorage(()=>store!.get(key));
      if(!this.fileActive(key,controller,generation))return;
      if(recovered) {local=recovered;complete=true;}
      let offset=complete?file.size:await receiveStorage(()=>store!.open(key,file,Date.now()+86400000));
      if(!this.fileActive(key,controller,generation))return;
      const capability=(this.device(transfer.sourceDeviceId) as Device & {rtc?:{scopes:RtcScope[]}}|undefined)?.rtc;
      const automatic=!['lan','public'].includes(transfer.routePreference || 'auto');
      const offeredScopes:RtcScope[]=transfer.routePreference==='lan'?['lan']:transfer.routePreference==='public'?['public']:['lan','public'];
      const supported=offeredScopes.filter(scope=>capability?.scopes.includes(scope));
      const scopes=automatic?preferredScopes(supported,this.rtcProbes?.results || [],this.session.device.deviceId,transfer.sourceDeviceId):supported;
      const decision=new DirectConnectionBudget(automatic);
      let lastError:unknown=new Error('对方暂不支持直连');
      for(let index=0;index<scopes.length;index++) {
        const scope=scopes[index],latency=verifiedScopeLatency(this.rtcProbes?.results || [],this.session.device.deviceId,transfer.sourceDeviceId,scope);
        if(complete)break;if(decision.remaining()<=0 && latency===undefined)continue;
        if(generation!==this.generation || controller.signal.aborted)return;
        const duration=decision.window(scopes.length-index,latency!==undefined,latency),deadline=Date.now()+duration,attempt=new ConnectAttempt(controller.signal,duration);
        try {
          const {rtc}=await attempt.wait(api.request<{rtc:RtcView}>(`/transfers/${transfer.transferId}/files/${file.fileId}/rtc`,{attemptId:id(),scope,offset},'POST',attempt.signal));
          if(generation!==this.generation || controller.signal.aborted)return;
          if(attempt.signal.aborted)throw new DOMException('连接尝试已停止','AbortError');
          this.setFile(transfer.transferId,{...file,transport:'direct',rtc} as TransferFile);
          channel=new RtcFileChannel(api,rtc,'target',(this.info as ServerInfo & {rtc?:{iceServers:RTCIceServer[]}})?.rtc?.iceServers || [],attempt.signal,{deadline,opened:()=>attempt.opened()});
          this.rtcChannels.set(key,channel);this.render();
          const activeStore=store;
          await attempt.wait(channel.receive(file.size,async bytes=>{
            if(!this.fileActive(key,controller,generation))throw new DOMException('接收已停止','AbortError');
            offset=await receiveStorage(()=>activeStore.write(key,offset,bytes));
            if(!this.fileActive(key,controller,generation))throw new DOMException('接收已停止','AbortError');
            this.uploadProgress.set(key,offset);this.paintProgress(key,offset,file.size);
            return offset;
          },async()=>{
            if(!this.fileActive(key,controller,generation))throw new DOMException('接收已停止','AbortError');
            const received=await receiveStorage(()=>activeStore.finish(key));
            if(await digestFile(received,{signal:controller.signal})!==file.sha256){await activeStore.remove(key);throw new Error('文件校验不一致，请重新发送');}
            if(!this.fileActive(key,controller,generation))throw new DOMException('接收已停止','AbortError');
            await receiveStorage(()=>activeStore.confirm(key));local=received;complete=true;
          }));
        } catch(error) {
          if(error instanceof ReceiveStorageError)throw error;
          lastError=attempt.timedOut?new Error((scope==='lan'?'局域网':'公网')+'连接预算用尽'):error;
          if(channel && !controller.signal.aborted && !attempt.timedOut)void api.request(channel.path+'/fail',{error:errorText(error)},'POST',attempt.signal).catch(()=>{});
        } finally {
          await channel?.close();if(this.rtcChannels.get(key)===channel)this.rtcChannels.delete(key);channel=undefined;
          if(attempt.connected && !complete)decision.resumeAfterDisconnect();
          attempt.dispose();await store.close(key);
        }
        if(!complete && this.fileActive(key,controller,generation))offset=await receiveStorage(()=>store!.open(key,file,Date.now()+86400000));
      }
      if(generation!==this.generation || controller.signal.aborted)return;
      if(complete && local) {
        this.recordReceipt(key,store.receivedAt?.(key) || new Date().toISOString());
        this.rtcLocalFiles.set(key,local);this.rtcFileExpiry.set(key,store.expiry(key));this.uploadProgress.set(key,file.size);void this.fileLibrary.refresh();
        const {file:received}=await api.request<{file:TransferFile}>(`/transfers/${transfer.transferId}/files/${file.fileId}/received`,{transport:'direct'},'POST',controller.signal);
        if(!this.fileActive(key,controller,generation))return;this.setFile(transfer.transferId,received);this.uploadErrors.delete(key);return;
      }
      if(transfer.routePreference==='lan' || transfer.routePreference==='public')throw lastError;
      if(file.size>this.autoAcceptMaxBytes && !this.relayConfirmed.has(key))throw new Error('直连不可用；使用中继需确认');
      await store.close(key);
      const {file:relay}=await api.request<{file:TransferFile}>(`/transfers/${transfer.transferId}/files/${file.fileId}/relay`,{},'POST',controller.signal);
      if(!this.fileActive(key,controller,generation))return;this.setFile(transfer.transferId,relay);if(!file.relativePath)await store.remove(key);
    } catch(error) {
      if(this.fileActive(key,controller,generation)){if(error instanceof ReceiveStorageError)await this.reportReceiveError(transfer,file,error,controller,generation);else this.uploadErrors.set(key,errorText(error));}
    } finally {
      await channel?.close();await store?.close(key).catch(()=>{});
      if(generation===this.generation){if(this.rtcReceives.get(key)===controller)this.rtcReceives.delete(key);this.uploadProgress.delete(key);this.render();this.startReadyUploads();void this.selectIncomingRelays();void this.refresh();}
    }
  }
  async allowRelay(transferId:string,fileId:string) {
    const key=fileKey(transferId,fileId),transfer=this.transfers.find(t=>t.transferId===transferId),file=transfer?.files.find(f=>f.fileId===fileId);
    if(!transfer || !file || this.paused.has(key) || this.canceled.has(key) || this.fileRequests.has(key) || transfer.routePreference==='lan' || transfer.routePreference==='public')return;
    const generation=this.generation,controller=new AbortController();this.fileRequests.set(key,controller);
    this.relayConfirmed.add(key);this.uploadErrors.delete(key);
    try{const {file:relay}=await this.api.request<{file:TransferFile}>(`/transfers/${transferId}/files/${fileId}/relay`,{},'POST',controller.signal);
      if(!this.fileActive(key,controller,generation))return;this.setFile(transferId,relay);if(!file.relativePath)await this.rtcStore?.remove(key);this.render();await this.refresh();
    }finally{if(this.fileRequests.get(key)===controller)this.fileRequests.delete(key);}
  }
  rtcPeer(transfer:Transfer) {
    if(!this.rtcEnabled || !this.session || !this.connected || !this.helloReceived || transfer.routePreference==='relay')return false;
    const other=transfer.sourceDeviceId===this.session.device.deviceId?transfer.targetDeviceId:transfer.sourceDeviceId;
    const device=this.device(other);if(!device?.online || device.revoked)return false;
    const capability=(device as Device & {rtc?:{scopes:RtcScope[];expiresAt:string}}|undefined)?.rtc;
    return !!capability && Date.parse(capability.expiresAt)>Date.now() && capability.scopes.some(scope=>transfer.routePreference==='auto' || !transfer.routePreference || transfer.routePreference===scope);
  }
  requiresNative(transfer: Transfer) { return (transfer.routePreference==='lan' || transfer.routePreference==='public') && !this.rtcPeer(transfer); }
  async selectIncomingRelays() {
    if(this.receiveDirectoryChanging)return;
    const generation=this.generation;
    for(const transfer of this.transfers){
      if(generation!==this.generation || !this.session)return;
      if(transfer.targetDeviceId!==this.session.device.deviceId || Date.parse(transfer.expiresAt)<=Date.now())continue;
      for(const file of transfer.files){
        const key=fileKey(transfer.transferId,file.fileId);
        if(this.paused.has(key) || this.canceled.has(key) || this.fileRequests.has(key))continue;
        if(file.entryKind==='directory'){if(this.activeFileTransfers<this.transferConcurrency && file.status==='accepted' && !this.rtcLocalFiles.has(key) && !this.uploadErrors.has(key))void this.receiveDirectory(transfer,file);continue;}
        const liveRelay=this.info?.features?.relayStreaming && file.transport==='relay' &&
          (file.status==='ready' || file.size>0 && ['accepted','uploading'].includes(file.status));
        if(file.relativePath && file.status==='ready' || liveRelay){
          if(file.size>this.autoAcceptMaxBytes && !this.relayConfirmed.has(key)){this.uploadErrors.set(key,'使用中继需确认');continue;}
          if(this.activeFileTransfers<this.transferConcurrency && !this.uploadErrors.has(key) && !this.rtcLocalFiles.has(key))void this.receiveStructuredRelay(transfer,file);continue;
        }
        if(this.requiresNative(transfer) || !this.isOnlinePeer(transfer.sourceDeviceId))continue;
        if(!['accepted','uploading'].includes(file.status) || file.transport==='relay' || this.selectingRelays.has(key) || this.rtcReceives.has(key) || this.uploadErrors.has(key) || (this.relayRetryAt.get(key) || 0)>Date.now())continue;
        if(this.rtcPeer(transfer)) {if(this.activeFileTransfers<this.transferConcurrency)void this.receiveRtc(transfer,file);continue;}
        if(file.size>this.autoAcceptMaxBytes && !this.relayConfirmed.has(key)) {this.uploadErrors.set(key,'使用中继需确认');continue;}
        this.selectingRelays.add(key);
        const controller=new AbortController();this.fileRequests.set(key,controller);
        try{
          const result=await this.api.request<{file:TransferFile}>(`/transfers/${transfer.transferId}/files/${file.fileId}/relay`,{},'POST',controller.signal);
          if(!this.fileActive(key,controller,generation))continue;
          this.setFile(transfer.transferId,result.file);this.relayRetryAt.delete(key);
        }catch(error){
          if(!this.fileActive(key,controller,generation))continue;
          this.relayRetryAt.set(key,Date.now()+30000);this.toast('中继连接暂未完成，将重试：'+errorText(error),true);
        }finally{if(this.fileRequests.get(key)===controller)this.fileRequests.delete(key);if(generation===this.generation)this.selectingRelays.delete(key);}
      }
    }
    if(generation===this.generation)this.render();
  }
  async cancelFile(transferId: string,fileId: string) {
    const transfer=this.localTransfer(transferId),root=transfer?.files.find(file=>file.fileId===fileId);
    if(root && transfer && isFolderRoot(root)){
      for(const member of folderMembers(root,transfer.files))if(member.fileId!==fileId && !['received','canceled','rejected','expired'].includes(member.status))await this.cancelFile(transferId,member.fileId);
      if(root.status==='received')return;
    }
    const generation=this.generation;
    const key = fileKey(transferId,fileId);
    if(this.cancelRequests.has(key))return;
    this.canceled.add(key);this.paused.add(key);const closing=this.stopFile(key),store=this.rtcStore;this.uploadErrors.delete(key);
    const file=this.transfers.find(item=>item.transferId===transferId)?.files.find(item=>item.fileId===fileId);
    if(file)this.setFile(transferId,{...file,status:'canceled'});
    this.fileSources.delete(key);this.uploadProgress.delete(key);this.cancelRequests.add(key);this.render();
    const controller=new AbortController(),api=new Api(this.baseUrl,this.session);this.fileRequests.set(key,controller);
    void (async()=>{
      try{
        const {file:canceled}=await api.request<{file:TransferFile}>(`/transfers/${transferId}/files/${fileId}/cancel`,{},'POST',controller.signal);
        if(generation!==this.generation || controller.signal.aborted)return;
        this.setFile(transferId,canceled);this.rtcLocalFiles.delete(key);
        // Closing the native channel may drain a pending disk write; UI and the
        // cancel RPC above never wait for it. Delete only after that lease closes.
        await closing;
        await store?.close(key).catch(()=>{});await store?.remove(key).catch(()=>{});
      }catch(error){if(generation===this.generation && !controller.signal.aborted){this.uploadErrors.set(key,'本机已停止，取消通知失败');this.toast('本机已停止，取消通知失败，可重试',true);}}
      finally{if(this.fileRequests.get(key)===controller)this.fileRequests.delete(key);if(generation===this.generation){this.cancelRequests.delete(key);this.render();this.startReadyUploads();void this.selectIncomingRelays();}}
    })();
  }
  async download(transferId: string,fileId: string) {
    const generation = this.generation,key=fileKey(transferId,fileId);
    const item=this.localTransfer(transferId)?.files.find(file=>file.fileId===fileId);
    if(item?.entryKind==='directory'){const picker=(window as Window & {showDirectoryPicker?:(options?:unknown)=>Promise<FileSystemDirectoryHandle>}).showDirectoryPicker;if(!picker)throw new Error('此浏览器不能导出目录；可在文件库查看或转发');const target=await picker({id:'globalsend-export-folder',mode:'readwrite'});this.fileLibrary.service ||= new (await import('./library')).LocalFileLibrary();const entry=(await this.fileLibrary.service.list()).find(entry=>entry.key===key);if(!entry)throw new Error('本机文件夹已不存在');await exportFolderEntries(await this.fileLibrary.service.expand([entry.id]),target);return;}
    if(!this.transfers.some(transfer=>transfer.transferId===transferId)){
      const local=this.localFile(key);if(!local)throw new Error('本机文件已不存在，请在文件库刷新');
      const url=URL.createObjectURL(local),link=document.createElement('a');link.href=url;link.download=local.name;document.body.append(link);link.click();link.remove();window.setTimeout(()=>URL.revokeObjectURL(url),60000);return;
    }
    const transfer=this.transfers.find(t=>t.transferId===transferId),remote=transfer?.files.find(f=>f.fileId===fileId);
    if(this.rtcLocalFiles.has(key) || transfer?.targetDeviceId===this.session?.device.deviceId && remote?.transport==='direct') {
      const store=this.rtcStore,local=await store?.get(key);
      if(generation!==this.generation || store!==this.rtcStore)return;
      if(!local){this.rtcLocalFiles.delete(key);this.rtcFileExpiry.delete(key);this.render();throw new Error('文件已清理，可在本机文件库中刷新查看');}
      this.rtcLocalFiles.set(key,local);this.rtcFileExpiry.set(key,store!.expiry(key));
      const file=this.transfers.find(t=>t.transferId===transferId)?.files.find(f=>f.fileId===fileId);
      const url=URL.createObjectURL(local),link=document.createElement('a');link.href=url;link.download=local.name || file?.name || '';document.body.append(link);link.click();link.remove();
      setTimeout(()=>URL.revokeObjectURL(url),60000);this.handed.add(fileKey(transferId,fileId));this.render();return;
    }
    if(!transfer || Date.parse(transfer.expiresAt)<=Date.now())throw new Error('文件已过期，无法再从中心下载。已保存的文件不受影响。');
    const {downloadPath} = await this.api.request<{downloadPath:string}>(`/transfers/${transferId}/files/${fileId}/download-ticket`,{});
    if (generation !== this.generation) return;
    const link = document.createElement('a'); link.href = safeDownloadUrl(this.baseUrl,downloadPath); link.rel = 'noopener';
    link.download = ''; document.body.append(link); link.click(); link.remove();
    this.handed.add(fileKey(transferId,fileId)); this.render(); this.toast('已交给浏览器');
  }
  copy(text: string) {
    // This call occurs synchronously in the click handler, before any network awaits (Safari user activation).
    if (!navigator.clipboard?.writeText) { this.toast('请选择文字手动复制。',true); return; }
    navigator.clipboard.writeText(text).then(() => this.toast('已复制')).catch(() => this.toast('复制失败，请选择文字手动复制。',true));
  }
  expiryHtml(deadline: number) {
    return deadline-Date.now()<3600000?`<span class="expiry-soon">${expiryLabel(deadline)}</span>`:'';
  }
  joinError(error: ApiError) {
    if(error.code==='GROUP_KEY_RETIRED')return '此组密码已停用，请使用当前组密码。';
    if(error.status===429)return '操作太快，请稍后重试。';
    return error.message || '无法加入，请核对组密码后重试。';
  }
  changeServer() {
    const base = normalizeBaseUrl(this.serverDraft);
    if (this.uploads.size || this.rtcReceives.size || this.busy || this.pendingTexts.length || this.picked.length || this.text || this.stagedTexts.length || this.shared.dirty || [...this.textViews.values()].some(view=>view.busy || view.draft!==view.savedText)) {
      if (!confirm('切换会离开当前中心；未发送内容不会带到新中心。确定继续？')) return;
    }
    clearTimeout(this.deviceGraceTimer);this.recentDevices.clear();
    this.generation++; for (const controller of this.uploads.values()) controller.abort();this.stopRtc();
    this.clearFilePickers();
    clearTimeout(this.reconnectTimer); this.ws?.close();
    // Navigate first, then enroll on the destination origin. Never forward this center's bearer token.
    location.assign(`${base}/app/`);
  }
  render() {
    if(textSelectionActive(document)){this.textSelectionRenderPending=true;return;}
    // Detaching a focused textarea dismisses the software keyboard. Sync status
    // paints in place; apply other workspace updates after editing loses focus.
    if(!this.modal && this.shared.focusedActive){this.editorRenderPending=true;return;}
    this.textSelectionRenderPending=false;
    if(!this.queueSending && this.sendBatch && !this.sendBatch.matches(this.picked,this.stagedTexts))this.sendBatch=null;
    if(!this.modal && this.pendingReceipt && !this.shared.dirty){this.receipt=this.pendingReceipt;this.pendingReceipt=null;this.modal='receipt';}
    this.fileLibrary.capture();
    if(this.session)this.pruneLocal();
    if(this.formComposing?.isConnected || this.editorComposing && this.editorElement?.isConnected || this.viewedText()?.composing && this.viewedText()?.element?.isConnected || this.shared.composingActive){this.editorRenderPending=true;return;}
    this.syncViewedText();
    const openDetails = Array.from(document.querySelectorAll<HTMLDetailsElement>('details.advanced-join')).map(node=>node.open);
    const active = document.activeElement as HTMLInputElement|HTMLTextAreaElement|null;
    const focusId = active?.id;
    let selection: [number|null,number|null,'forward'|'backward'|'none'|null]|null = null;
    if (active && ['INPUT','TEXTAREA'].includes(active.tagName)) selection = [active.selectionStart,active.selectionEnd,active.selectionDirection];
    const scroll = document.querySelector('.dock-items')?.scrollTop || 0;
    const queueScroll=document.querySelector('.staged-list')?.scrollTop || 0,deviceScroll=document.querySelector('.target-devices')?.scrollTop || 0,historyScroll=document.querySelector('.history-items')?.scrollTop || 0;
    const editorScroll=this.editorElement?.scrollTop || 0;
    const readerScroll=this.viewedText()?.displayElement?.scrollTop || this.viewedText()?.element?.scrollTop || 0;
    const receiptScroll=document.querySelector('.receipt-batch-grid')?.scrollTop || 0;
    const existingReceipt=document.querySelector<HTMLElement>('.receipt-backdrop'),heldReceipt=this.modal==='receipt'?existingReceipt:null;
    if(existingReceipt && !heldReceipt)existingReceipt.remove();
    if(heldReceipt && heldReceipt.parentElement!==document.body)document.body.append(heldReceipt);
    if (this.loading) app.innerHTML = `<div class="loading-view"><span class="spinner"></span>连接中…</div>`;
    else if (!this.session) app.innerHTML = this.onboarding();
    else app.innerHTML = this.workspace() + (heldReceipt?'':this.modalHtml()) + this.cardMenuHtml();
    document.querySelector('#window-drop')?.classList.toggle('visible',this.windowDropVisible);
    if(heldReceipt)this.updateReceiptDom(heldReceipt);
    else if(this.modal==='receipt'){const receipt=document.querySelector('.receipt-backdrop');if(receipt)document.body.append(receipt);}
    this.mountEditor();this.mountTextViewer();this.mountAutoAcceptLimit();this.shared.mount();this.bind();this.fileLibrary.bind();this.mountPreviews();
    this.animateWorkspaceView();
    const modalKey=this.modal || '';
    const backdrop=document.querySelector<HTMLElement>('.modal-backdrop');
    if(modalKey!==this.renderedModalKey)this.modalOpenedAt=Date.now();
    const modalElapsed=Date.now()-this.modalOpenedAt;
    if(modalElapsed>=180){backdrop?.classList.add('motion-steady');backdrop?.querySelector<HTMLElement>('.modal')?.style.setProperty('animation','none');}
    else if(modalKey===this.renderedModalKey && !heldReceipt){
      backdrop?.style.setProperty('animation-delay',`-${modalElapsed}ms`);
      backdrop?.querySelector<HTMLElement>('.modal')?.style.setProperty('animation-delay',`-${modalElapsed}ms`);
    }
    if(this.modalClosing)backdrop?.classList.add('leaving');
    this.renderedModalKey=modalKey;
    if(this.modal==='receipt')this.paintReceiptReady();
    document.querySelectorAll<HTMLDetailsElement>('details.advanced-join').forEach((node,index)=>{if(openDetails[index])node.open=true;});
    if (focusId) {
      const next = document.getElementById(focusId) as HTMLInputElement|HTMLTextAreaElement|null;
      if (next) { next.focus({preventScroll:true}); if (selection && selection[0] !== null) { try { next.setSelectionRange(selection[0],selection[1],selection[2] || 'none'); } catch { /* Some inputs do not expose a text selection. */ } } }
    }
    const dock = document.querySelector('.dock-items'); if (dock) dock.scrollTop = scroll;
    const queue=document.querySelector('.staged-list');if(queue)queue.scrollTop=queueScroll;const deviceList=document.querySelector('.target-devices');if(deviceList)deviceList.scrollTop=deviceScroll;const history=document.querySelector('.history-items');if(history)history.scrollTop=historyScroll;
    if(this.editorElement)this.editorElement.scrollTop=editorScroll;
    const reader=this.viewedText()?.displayElement || this.viewedText()?.element;if(reader)reader.scrollTop=readerScroll;
    const receiptGrid=document.querySelector('.receipt-batch-grid');if(receiptGrid)receiptGrid.scrollTop=receiptScroll;
    if(this.modal==='receipt' && !document.querySelector('.receipt-modal')?.contains(document.activeElement))document.querySelector<HTMLElement>('.receipt-modal')?.focus({preventScroll:true});
    if(this.modal==='ip-addresses' && !document.querySelector('.ip-address-modal')?.contains(document.activeElement))document.querySelector<HTMLElement>('.ip-address-modal')?.focus({preventScroll:true});
  }
  onboarding() {
    return `<main class="onboarding"><header class="onboarding-header">${brand}<div class="row"><button class="icon-button quiet" data-action="settings" aria-label="设置">${icon('settings')}</button><button class="icon-button secondary" data-action="library" aria-label="本机文件库">${icon('folder')}</button></div></header><section class="pair-form panel"><h1>加入分组</h1><div class="connection-server"><span>服务器</span><div><code title="${e(this.baseUrl)}">${e(this.baseUrl)}</code><button class="quiet" type="button" data-action="server-modal">更换</button></div></div>
      ${this.startupError?`<div class="error-message" role="alert">${e(this.startupError)} <button data-action="reload" class="quiet">重试</button></div>`:''}
      <form id="enroll-form"><label class="field" for="group-key">组密码<span class="password-input"><input id="group-key" type="${this.showGroupKey?'text':'password'}" minlength="10" maxlength="256" autocomplete="off" spellcheck="false" autocapitalize="off" value="${e(this.groupKey)}" placeholder="至少 10 位" required><button type="button" class="password-eye" data-action="show-group-key" aria-label="${this.showGroupKey?'隐藏组密码':'显示组密码'}" aria-pressed="${this.showGroupKey}" title="${this.showGroupKey?'隐藏组密码':'显示组密码'}">${icon(this.showGroupKey?'eye-off':'eye')}</button></span></label><label class="field" for="device-name">设备名称<input id="device-name" maxlength="80" autocomplete="off" value="${e(this.deviceName)}" placeholder="${e(suggestedDeviceName(navigator))}"></label>
      <label class="preference-check"><input id="remember-device" type="checkbox" ${this.rememberDevice?'checked':''}>记住设备</label>
      ${this.pairError?`<div class="error-message" role="alert">${e(this.pairError)}</div>`:''}<button class="primary connect-button" type="submit" ${this.pairBusy || !this.info?'disabled':''}>${this.pairBusy?'连接中…':'连接'}</button>
      </form>
      </section></main>${this.modalHtml()}`;
  }
  convenienceHtml() {
    const notifications=this.notifications.state(),noticeReason=notifications.reason==='home-screen'?'添加到主屏幕后可开启':notifications.reason==='denied'?'请在浏览器设置中允许通知':notifications.reason==='insecure'?'需要 HTTPS':notifications.reason?'当前浏览器不支持':'';
    return `<section class="settings-card"><h3>收发</h3><div class="setting-row"><span>显示</span><button class="quiet" data-action="page-fullscreen">${e(this.pageDisplay.label)}</button></div>${this.pageDisplay.hint?`<p class="notification-reason" role="status">${e(this.pageDisplay.hint)}</p>`:''}<label class="setting-row"><span>接收通知${noticeReason?`<small class="notification-reason">${noticeReason}</small>`:''}</span><input data-web-notifications type="checkbox" ${notifications.enabled?'checked':''} ${!notifications.available || notifications.permission==='denied'?'disabled':''}></label><label class="setting-row"><span>记住设备</span><input id="remember-device" type="checkbox" ${this.rememberDevice?'checked':''}></label><label class="setting-row"><span>自动接收</span><input data-auto-accept type="checkbox" ${this.autoAccept?'checked':''}></label><label class="limit-field" for="auto-accept-limit">中继确认阈值 <span><input id="auto-accept-limit" type="number" min="0" step="1" value="${e(this.autoAcceptLimitDraft ?? String(this.autoAcceptMaxBytes/1048576))}" inputmode="numeric" aria-label="中继确认阈值 MiB"> MiB / 文件</span></label><label class="setting-row" for="file-route"><span>传输方式</span><select id="file-route" ${this.pendingOffer?'disabled':''}>${(['auto','lan','public','relay'] as const).map((route,index)=>`<option value="${route}" ${this.routePreference===route?'selected':''}>${['自动','仅局域网','仅公网直连','中继'][index]}</option>`).join('')}</select></label><label class="setting-row" for="transfer-concurrency"><span>传输并发</span><select id="transfer-concurrency">${Array.from({length:16},(_,index)=>index+1).map(value=>`<option value="${value}" ${this.transferConcurrency===value?'selected':''}>${value}</option>`).join('')}</select></label><button class="quiet" data-action="library">文件与自动清理</button></section>`;
  }
  deviceSettingsHtml() {
    const me=this.session!.device;
    
    return `<section class="settings-identity settings-card"><span class="device-icon">${platformIcon(me.platform)}</span><form id="device-name-form"><label for="device-display-name">设备名称</label><div class="settings-input-row"><input id="device-display-name" maxlength="80" autocomplete="off" value="${e(this.deviceNameDraft ?? me.name)}" required><button id="save-device-name" class="secondary" type="submit" ${this.deviceNameBusy?'disabled':''}>${this.deviceNameBusy?'保存中…':'保存'}</button></div><button class="quiet auto-device-name" type="button" data-action="auto-device-name" ${this.deviceNameBusy?'disabled':''}>自动命名</button>${this.deviceNameError?`<p class="settings-error" role="alert">${e(this.deviceNameError)}</p>`:''}</form></section>${localStorageSupported()?`<section class="settings-card"><h3>文件夹接收位置</h3><div class="settings-input-row"><span>${e(this.receiveDestination)}</span>${typeof (window as any).showDirectoryPicker==='function'?'<button class="secondary" data-action="receive-directory">选择目录</button>':''}${this.receiveDestination!=='浏览器文件库'?'<button class="quiet" data-action="receive-browser">恢复默认</button>':''}</div></section>`:''}${this.convenienceHtml()}`;
  }
  editorHtml(expanded = false) {
    return `<div class="editor-sheet ${expanded?'expanded':''}"><div class="editor-host" data-editor-host></div><div class="editor-tools"><span id="text-count">${characterCount(this.text)} 字符</span></div></div>`;
  }
  workspace() {
    return workspaceHtml(this);
  }
  deviceInner(device: Device,self = false) {
    return `<span class="device-icon">${platformIcon(device.platform)}</span><span class="device-info"><span class="device-name">${e(device.name)}</span><span class="device-subtitle"><span class="dot ${(self?this.connected:device.online && this.connected)?'live':''}"></span>${self?'当前设备':!this.connected?'状态未知':device.online?'在线':'离线'}${self?'<span class="self-label">本机</span>':''}</span>${!self && this.rtcProbes?.status(device.deviceId)?`<span class="rtc-probe-status">${e(this.rtcProbes.status(device.deviceId))}</span>`:''}</span>`;
  }
  incomingCount() { return this.receivedTexts().length + this.displayTransfers(false).reduce((total,transfer)=>total+this.visibleFiles(transfer).length,0); }
  dockHtml() {
    return dockHtml(this);
  }
  textItem(event: WireEvent,all: WireEvent[]) {
    const text=event.payload.text || '';
    const duplicate=all.some(other=>other.eventId!==event.eventId && other.cursor<event.cursor && other.payload.text===text);
    const long=text.length>220 || text.split('\n').length>4;
    return `<article class="dock-item"><div class="item-meta"><label class="dock-checkbox" for="select-${e(event.eventId)}"><input id="select-${e(event.eventId)}" type="checkbox" aria-label="选择 ${e(this.deviceLabel(event.sourceDeviceId))} ${time(event.createdAt)} 的文字" data-select="${e(event.eventId)}" ${this.selected.has(event.eventId)?'checked':''}></label><span>${e(this.deviceLabel(event.sourceDeviceId))}</span>${event.payload.clipboard?'<span class="clipboard-source">剪贴板</span>':''}${duplicate?'<span class="duplicate-label">重复</span>':''}${event.payload.editedAt?'<span class="edited-label">已修改</span>':''}<time class="time" title="${e(event.createdAt)}">${time(event.createdAt)}</time></div><button id="read-${e(event.eventId)}" type="button" data-read="${e(event.eventId)}" aria-label="查看收到的文字" class="text-content text-open ${long?'collapsed':''}">${e(text)}</button><div class="item-actions"><button id="copy-${e(event.eventId)}" class="copy-button" aria-label="复制 ${e(this.deviceLabel(event.sourceDeviceId))} 的文字" data-copy="${e(event.eventId)}">${icon('copy')} 复制</button><button class="quiet" data-hide-text="${e(event.eventId)}" aria-label="从接收坞移除此段文字">移除</button>${this.expiryHtml(localTextDeadline(event))}</div></article>`;
  }
  incomingTransferHtml(transfer: Transfer) {
    const files=folderCards(this.visibleFiles(transfer));
    const offered=Date.parse(transfer.expiresAt)>Date.now()?files.filter(file=>file.status==='offered'):[];
    const native=this.requiresNative(transfer),accepting=this.accepting.has(transfer.transferId);
    const large=offered.some(file=>file.size>this.autoAcceptMaxBytes);
    const count=offered.filter(file=>this.consent.get(fileKey(transfer.transferId,file.fileId))).length;
    return `<div class="incoming-batch" data-transfer="${e(transfer.transferId)}">${native?'<p class="target-note">此批文件仅限直连，但当前设备暂不支持。</p>':''}${files.map(file=>this.fileHtml(transfer,file,false)).join('')}${offered.length?`<div class="batch-actions">${native?`<button class="secondary" data-reject="${e(transfer.transferId)}" ${accepting?'disabled':''}>拒绝</button>`:`<button class="primary" data-accept="${e(transfer.transferId)}" aria-label="接收所选 ${count} 个文件" ${accepting?'disabled':''}>${accepting?'接收中…':'接收'+(offered.length>1?` ${count} 项`:'')}</button><span class="batch-note">${large && !this.rtcPeer(transfer)?`${formatBytes(offered.reduce((sum,file)=>sum+file.size,0))} · 中继，需手动接收`:offered.length>1?'未选中的文件将拒绝':''}</span>`}</div>`:''}</div>`;
  }
  fileHtml(transfer: Transfer,file: TransferFile,outgoing: boolean) {
    return fileCard(this,transfer,file,outgoing);
  }
  outgoingHtml() {
    const transfers=this.transfers.filter(transfer=>transfer.sourceDeviceId===this.session?.device.deviceId);
    const textEvents=this.events.filter(event=>event.type==='text.created' && event.sourceDeviceId===this.session?.device.deviceId).slice(-5).reverse();
    const active:string[]=[],finished:string[]=[];
    for(const transfer of transfers)for(const file of transfer.files){
      (['offered','accepted','uploading','failed'].includes(file.status)?active:finished).push(this.fileHtml(transfer,file,true));
    }
    const pending=this.pendingTexts.map(item=>`<div class="outgoing-item"><div class="text-content">${e(item.text.length>120?item.text.slice(0,120)+'…':item.text)}</div><p class="item-status ${item.error?'error':''}">${e(item.busy?'发送中…':item.error)}</p>${!item.busy?`<div class="item-actions"><button class="copy-button" data-text-retry="${e(item.eventId)}">重试</button><button class="quiet" data-text-remove="${e(item.eventId)}">取消</button></div>`:''}</div>`).join('');
    finished.push(...textEvents.map(event=>`<div class="outgoing-item"><button id="read-${e(event.eventId)}" type="button" class="text-content text-open" data-read="${e(event.eventId)}" aria-label="编辑已发送文字">${e((event.payload.text || '').slice(0,100))}${(event.payload.text || '').length>100?'…':''}</button><p class="item-status">${e(this.deviceLabel(event.targetDeviceId))} · ${this.events.some(ack=>ack.type==='text.received' && ack.payload.sourceEventId===event.eventId)?'已送达':'已发送'}${event.payload.editedAt?' · 已修改':''} · ${time(event.createdAt)}</p></div>`));
    if(!active.length && !pending && !finished.length)return '';
    return `<section class="transfer-list">${active.length || pending?`<h3>发送中</h3>${pending}${active.join('')}`:''}${finished.length?`<details class="recent-activity advanced-join"><summary>发送记录 <span>${finished.length}</span></summary>${finished.join('')}</details>`:''}</section>`;
  }
  modalHtml() {
    if(this.modal==='device-network')return this.deviceNetworkHtml();
    if(!this.modal)return '';
    if(this.modal==='ip-addresses')return `<div class="modal-backdrop"><section class="modal ip-address-modal" tabindex="-1" role="dialog" aria-modal="true" aria-labelledby="ip-address-title"><div class="modal-header"><h2 id="ip-address-title">本机地址</h2><button class="icon-button quiet" data-action="close-modal" aria-label="关闭地址列表">${icon('close')}</button></div><div class="ip-address-list">${this.ipSources.map(source=>`<section class="ip-address-source"><h3>${e(source.label)}</h3>${source.groups.map(group=>`<section class="ip-address-group"><h4>${group.label}</h4>${group.addresses.map(address=>`<button type="button" class="ip-address" data-stage-ip="${e(address)}"><code>${e(address)}</code>${icon('plus')}</button>`).join('')}</section>`).join('')}</section>`).join('')}${this.ipLoading?'<p class="muted" role="status">正在读取地址…</p>':!this.ipSources.length?`<p class="muted" role="status">${this.ipError || '浏览器未提供可用 IP 地址'}</p>`:''}</div></section></div>`;
    if(this.modal==='receipt')return this.receiptHtml();
    if(this.modal==='library')return this.fileLibrary.html();
    if(this.modal==='history')return historyHtml(this);
    if(this.modal==='file-preview'){
      const file=this.openedFile;if(!file)return '';
      const preview=this.previews.get(file.key);
      return `<div class="modal-backdrop"><section class="modal file-preview-modal" role="dialog" aria-modal="true" aria-labelledby="file-preview-title"><div class="modal-header"><h2 id="file-preview-title">${e(file.name)}</h2><button class="icon-button quiet" data-action="close-modal" aria-label="关闭预览">${icon('close')}</button></div><div class="large-file-preview">${preview?.url?`<img src="${e(preview.url)}" alt="${e(file.name)}">`:preview?.text!==undefined?`<pre>${linkifyHtml(preview.text)}</pre>`:this.previewHtml(file.key,file.name)}</div><details class="file-details"><summary>详情</summary><dl><dt>大小</dt><dd>${formatBytes(file.size)}</dd><dt>时间</dt><dd>${e(file.createdAt)}</dd><dt>设备</dt><dd>${e(file.source)}</dd><dt>连接</dt><dd>${e(file.route)}</dd><dt>状态</dt><dd>${e(file.status)}</dd></dl></details></section></div>`;
    }
    if(this.modal==='editor'){
      return `<div class="modal-backdrop"><section class="modal editor-modal" role="dialog" aria-modal="true" aria-labelledby="editor-title"><div class="modal-header"><h2 id="editor-title">添加文本</h2><button class="icon-button quiet" data-action="close-modal" aria-label="关闭文本输入">${icon('close')}</button></div>${this.editorHtml(true)}<div class="send-row"><span class="send-note">Ctrl / ⌘ + Enter 添加</span><button id="editor-send-button" class="primary" data-action="stage-text" data-text-send aria-keyshortcuts="Control+Enter Meta+Enter" ${!this.text.trim() || this.busy?'disabled':''}>添加</button></div></section></div>`;
    }
    if(this.modal==='reader'){
      const view=this.viewedText();if(!view)return '';
      const event=view.event,editable=this.canEditText(view);
      return `<div class="modal-backdrop"><section class="modal reader-modal" draggable="true" data-drag-text="${e(event.eventId)}" role="dialog" aria-modal="true" aria-labelledby="reader-title"><div class="modal-header"><div><h2 id="reader-title">${editable?'编辑已发送文字':'收到的文字'}</h2><p class="reader-meta">${editable?'发给 ':''}${e(this.deviceLabel(editable?event.targetDeviceId:event.sourceDeviceId))} · ${time(event.createdAt)}${event.payload.editedAt?' · 已修改':''}</p></div><button class="icon-button quiet" data-action="close-modal" aria-label="关闭文字">${icon('close')}</button></div><div class="editor-sheet"><div class="editor-host" data-reader-host></div><div class="web-link-list" data-reader-links></div><div class="editor-tools"><span id="reader-count">${characterCount(view.draft)} 字符</span><span>${editable?'Ctrl / ⌘ + Enter 保存':'只读'}</span></div></div><div class="reader-footer"><div class="item-actions"><button class="copy-button" data-action="copy-reader">${icon('copy')} 复制</button></div>${editable?'<button class="primary" data-action="save-reader" aria-keyshortcuts="Control+Enter Meta+Enter">保存</button>':''}</div>${editable?'<p id="reader-status" class="reader-status" role="status" aria-live="polite"></p>':''}</section></div>`;
    }
    return `<div class="modal-backdrop"><section class="modal settings-modal" role="dialog" aria-modal="true" aria-labelledby="modal-title"><div class="modal-header"><h2 id="modal-title">设置</h2><button class="icon-button quiet" data-action="close-modal" aria-label="关闭设置">${icon('close')}</button></div>
      ${this.appearance.html()}${this.session?this.deviceSettingsHtml()+this.groupsHtml():''}<section class="settings-card server-settings" data-server-settings><label class="settings-field-label" for="server-url">服务器地址</label><form id="server-form" class="server-change"><input id="server-url" type="url" aria-label="服务器地址" placeholder="https://send.example.com" value="${e(this.serverDraft)}"><button class="secondary" type="submit">前往</button></form></section>${this.session?`<div class="settings-footer"><button class="quiet" data-action="signout">断开服务器</button></div>`:''}</section></div>`;
  }
  bind() {
    const on = (selector: string,event: string,handler: (event: Event,node: HTMLElement)=>void) => document.querySelectorAll<HTMLElement>(selector).forEach(node=>{if(node.closest('.receipt-backdrop')){const key=selector+':'+event,bound=this.receiptBindings.get(node) || new Set<string>();if(bound.has(key))return;bound.add(key);this.receiptBindings.set(node,bound);}node.addEventListener(event,event=>handler(event,node));});
    on('[data-appearance-mode]','click',(_event,node)=>this.appearance.set({mode:node.dataset.appearanceMode as AppearanceMode}));
    on('[data-appearance-accent]','click',(_event,node)=>this.appearance.set({accent:node.dataset.appearanceAccent as AccentColor}));
    // Keep the title button alive until its click; a shared-editor blur can
    // otherwise replace the workspace between pointer-down and pointer-up.
    on('[data-action="ip-addresses"]','pointerdown',event=>{if(this.shared.focusedActive && !this.shared.composingActive)event.preventDefault();});
    on('.modal-backdrop','click',(event,node)=>{if(event.target===node){if(this.modal==='editor')this.toggleEditor(false);else this.closeModal();}});
    on('[data-action]','click',(_event,node)=> {
      const action = node.dataset.action;
      if(action==='ip-addresses')void this.openIpAddresses();
      if (action==='reload') location.reload();
      if (action==='settings' || action==='connection') this.openSettings();
      if (action==='server-modal') this.openSettings();
      if (action==='open-editor') {this.editingStagedId='';this.toggleEditor(true);}
      if (action==='stage-text') this.stageDraft();
      if(action==='clear-failed-sends')this.clearFailedSends();
      if(action==='retry-failed-sends')void this.retryFailedSends();
      if (action==='clipboard') void this.readClipboard();
      if (action==='dismiss-clipboard-suggestion') {this.clipboardSuggestion=null;this.clipboardSuggestionDismissed=true;this.render();}
      if (action==='send-queue') void this.sendQueue();
      if (action==='multi-send') {if(this.queueSending)return;this.multiSend=!this.multiSend;this.selectedTargets.clear();this.render();}
      if (action==='history') {this.contentView='sent';this.setMobileView('receive');this.render();}
      if (action==='pick-folder') void this.run(()=>this.pickFolder());
      if (action==='receive-directory') void this.run(()=>this.chooseReceiveDirectory());
      if (action==='receive-browser') void this.run(()=>this.changeReceiveDirectory());
      if (action==='close-modal' && this.modal==='editor') { this.toggleEditor(false);return; }
      if (action==='close-modal') this.closeModal();
      if(action==='receipt-grid'){this.receiptFocusId='';this.render();}
      
      if (action==='show-group-key') {
        const field=document.querySelector<HTMLInputElement>('#group-key');if(!field)return;
        const start=field.selectionStart,end=field.selectionEnd;this.showGroupKey=!this.showGroupKey;field.type=this.showGroupKey?'text':'password';
        node.innerHTML=icon(this.showGroupKey?'eye-off':'eye');node.setAttribute('aria-label',this.showGroupKey?'隐藏组密码':'显示组密码');node.setAttribute('title',this.showGroupKey?'隐藏组密码':'显示组密码');node.setAttribute('aria-pressed',String(this.showGroupKey));
        field.focus({preventScroll:true});field.setSelectionRange(start,end);
      }
      if (action==='signout') this.signOut();
      if (action==='auto-device-name')void this.useAutomaticDeviceName();
      if (action==='library')void this.openLibrary();
      if (action==='refresh') { this.connect(); void this.refreshDiscovery(); }
      if (action==='send') void (this.tab==='text'?this.sendText():this.sendFiles());
      if (action==='pick-files') this.openFilePicker();
      if (action==='pick-media') this.openFilePicker(undefined,true);
      if (action==='discard-offer') void this.run(()=>this.discardOffer());
      if (action==='copy-selected') this.copySelected();
      if(action==='receive-multi-select'){this.receiveSelecting=!this.receiveSelecting;this.selected.clear();this.contextMenu=null;window.getSelection?.()?.removeAllRanges();this.render();}
      if(action==='sent-multi-select'){this.sentSelecting=!this.sentSelecting;this.sentSelected.clear();this.contextMenu=null;window.getSelection?.()?.removeAllRanges();this.render();}
      if(action==='sent-select-all')this.toggleAllSent();
      if(action==='sent-delete-selected')this.deleteSelectedSent();
      if(action==='receive-select-all')this.toggleAllReceive();
      if(action==='receive-delete-selected')this.deleteSelectedReceive();
      if (action==='page-fullscreen')void this.pageDisplay.toggle();
      if (action==='select-all-texts') { const texts=this.receivedTexts();this.selected=this.selected.size===texts.length?new Set():new Set(texts.map(item=>item.eventId));this.render(); }
      if (action==='clear-dock') this.clearFinishedDock();
      if (action==='copy-reader') { const view=this.viewedText();if(view)this.copy(view.draft); }

      if (action==='save-reader') void this.saveViewedText();
    });
    on('#device-name-form','submit',event=>{event.preventDefault();void this.saveDeviceName();});
    on('#device-display-name','input',(_event,node)=>{this.deviceNameDraft=(node as HTMLInputElement).value;});
    on('#group-join-name','input',(_event,node)=>{this.groupJoinName=(node as HTMLInputElement).value;});
    on('#group-join-password','input',(_event,node)=>{this.groupJoinPassword=(node as HTMLInputElement).value;});
    on('#group-join-form','submit',event=>{event.preventDefault();void this.run(()=>this.joinAdditionalGroup());});
    on('[data-leave-group]','click',(_event,node)=>{void this.run(()=>this.leaveGroup(node.dataset.leaveGroup!));});
    on('[data-shared-group]','change',(_event,node)=>this.selectSharedGroup((node as HTMLSelectElement).value));
    on('#enroll-form','submit',event=>{event.preventDefault(); void this.enroll();});
    on('#remember-device','change',(_event,node)=>{this.rememberDevice=(node as HTMLInputElement).checked;this.saveSession();});
    on('[data-auto-accept]','change',(_event,node)=>this.setAutoAccept((node as HTMLInputElement).checked));
    on('[data-web-notifications]','change',(_event,node)=>{if((node as HTMLInputElement).checked)void this.notifications.requestEnable();else this.notifications.setEnabled(false);});
    on('#transfer-concurrency','change',(_event,node)=>{try{this.setTransferConcurrency(Number((node as HTMLSelectElement).value));}catch(error){this.toast(errorText(error),true);}});
    on('#file-route','change',(_event,node)=>{this.routePreference=(node as HTMLSelectElement).value as RoutePreference;rememberedSet(this.dockKey+':route',this.routePreference);this.render();});
    on('#server-form','submit',event=>{event.preventDefault(); try { this.changeServer(); } catch(error) { this.toast(errorText(error),true); }});
    on('[data-stage-ip]','click',(_event,node)=>this.stageIpAddress(node.dataset.stageIp!));
    on('#device-name','input',(_event,node)=>{this.deviceName=(node as HTMLInputElement).value;});
    on('#group-key','input',(_event,node)=>{this.groupKey=(node as HTMLInputElement).value;const button=document.querySelector<HTMLButtonElement>('[data-action="copy-group-key"]');if(button)button.disabled=!this.groupKey;});
    on('#server-url','input',(_event,node)=>{this.serverDraft=(node as HTMLInputElement).value;});
    on('[data-target-select]','change',(_event,node)=>{if(this.pendingOffer){this.toast('请先重试或放弃上次文件邀请。');this.render();return;}this.target=(node as HTMLSelectElement).value;this.render();});
    on('[data-target]','pointerdown',(event,node)=>{
      if(this.deviceHold!==null)clearTimeout(this.deviceHold);this.heldDevice='';
      const pointer=event as PointerEvent;if(pointer.button!==0)return;
      this.deviceHoldOrigin={x:pointer.clientX,y:pointer.clientY};
      this.deviceHold=setTimeout(()=>{this.deviceHold=null;this.heldDevice=node.dataset.target!;this.openDeviceNetwork(this.heldDevice);},500);
    });
    on('[data-target]','pointermove',(event)=>{const pointer=event as PointerEvent;if(pointer.buttons && this.deviceHold!==null && this.deviceHoldOrigin && Math.hypot(pointer.clientX-this.deviceHoldOrigin.x,pointer.clientY-this.deviceHoldOrigin.y)>12){clearTimeout(this.deviceHold);this.deviceHold=null;}});
    on('[data-target]','pointerup',()=>{if(this.deviceHold!==null){clearTimeout(this.deviceHold);this.deviceHold=null;}});
    on('[data-target]','pointercancel',()=>{if(this.deviceHold!==null){clearTimeout(this.deviceHold);this.deviceHold=null;}});
    on('[data-target]','contextmenu',(event,node)=>{event.preventDefault();if(this.deviceHold!==null)clearTimeout(this.deviceHold);this.deviceHold=null;this.openDeviceNetwork(node.dataset.target!);});
    on('[data-target]','click',(event,node)=>{const target=node.dataset.target!;if(this.heldDevice===target){event.preventDefault();this.heldDevice='';return;}this.target=target;if(this.multiSend){if(this.selectedTargets.has(target))this.selectedTargets.delete(target);else this.selectedTargets.add(target);this.render();}else void this.sendQueue([target]);});
    on('[data-action="refresh-device-network"]','click',()=>{void this.rtcProbes?.refreshPeer(this.networkDevice);});
    on('[data-tab]','click',(_event,node)=>{this.tab=node.dataset.tab as 'text'|'files';this.render();});
    on('[data-mobile-view-button]','click',(_event,node)=>this.setMobileDestination(node.dataset.mobileViewButton as 'send'|'receive'|'sent'|'library'));
    on('[data-content-view]','click',(_event,node)=>{const view=node.dataset.contentView as GlobalSend['contentView'];if(view==='library')void this.openLibrary();else{this.contentView=view;this.render();}});
    on('[data-queue-drop]','click',(event,node)=>{if(event.target!==node || this.queueSending)return;this.editingStagedId='';this.toggleEditor(true);});
    on('[data-queue-drop]','wheel',(event,node)=>{
      const wheel=event as WheelEvent;
      if(wheel.deltaX || !wheel.deltaY || node.scrollWidth<=node.clientWidth)return;
      const before=node.scrollLeft;
      node.scrollLeft+=wheel.deltaY*(wheel.deltaMode===1?16:wheel.deltaMode===2?node.clientWidth:1);
      if(node.scrollLeft!==before)event.preventDefault();
    });
    on('[data-filter]','click',(_event,node)=>{this.filter=node.dataset.filter as 'all'|'text'|'files';this.render();});
    on('[data-remove]','click',(_event,node)=>{if(this.pendingOffer){this.toast('请先重试或放弃上次文件邀请。');return;}this.picked.splice(Number(node.dataset.remove),1);this.render();});
    on('[data-select]','change',(_event,node)=>{if((node as HTMLInputElement).checked)this.selected.add(node.dataset.select!);else this.selected.delete(node.dataset.select!);this.render();});
    const dockItems=document.querySelector('.dock-items');
    if(this.receiveSelecting && dockItems){
      const cardFor=(event:Event)=>(event.target as Element).closest<HTMLElement>('[data-receive-key]');
      dockItems.addEventListener('click',event=>{const card=cardFor(event);if(!card)return;event.preventDefault();event.stopImmediatePropagation();if(this.heldCardKey===card.dataset.receiveKey){this.heldCardKey='';return;}this.toggleReceiveSelection(card.dataset.receiveKey!);},true);
      dockItems.addEventListener('keydown',event=>{const key=event as KeyboardEvent,card=cardFor(event);if(card && event.target===card && ['Enter',' '].includes(key.key)){event.preventDefault();event.stopImmediatePropagation();this.toggleReceiveSelection(card.dataset.receiveKey!);}},true);
      for(const type of ['contextmenu'])dockItems.addEventListener(type,event=>{if(!cardFor(event))return;event.preventDefault();event.stopImmediatePropagation();},true);
    }
    const sentItems=document.querySelector('.history-items');
    if(this.sentSelecting && sentItems){
      const cardFor=(event:Event)=>(event.target as Element).closest<HTMLElement>('[data-sent-key]');
      sentItems.addEventListener('click',event=>{const card=cardFor(event);if(!card)return;event.preventDefault();event.stopImmediatePropagation();if(this.heldCardKey===card.dataset.sentKey){this.heldCardKey='';return;}this.toggleSentSelection(card.dataset.sentKey!);},true);
      sentItems.addEventListener('keydown',event=>{const key=event as KeyboardEvent,card=cardFor(event);if(card && event.target===card && ['Enter',' '].includes(key.key)){event.preventDefault();event.stopImmediatePropagation();this.toggleSentSelection(card.dataset.sentKey!);}},true);
      for(const type of ['contextmenu'])sentItems.addEventListener(type,event=>{if(!cardFor(event))return;event.preventDefault();event.stopImmediatePropagation();},true);
    }
    on('[data-receive-key],[data-sent-key]','pointerdown',(event,node)=>{
      const pointer=event as PointerEvent;this.heldCardKey='';clearTimeout(this.cardHoldTimer);if(pointer.pointerType==='mouse' || (event.target as Element).closest('button,a,input,textarea,select'))return;
      const x=pointer.clientX,y=pointer.clientY,source=node.dataset.receiveKey || node.dataset.sentKey!;
      this.cardHoldTimer=window.setTimeout(()=>{this.heldCardKey=source;},450);
      const move=(event:PointerEvent)=>{if(Math.hypot(event.clientX-x,event.clientY-y)>12)clearTimeout(this.cardHoldTimer);};
      const finish=()=>{clearTimeout(this.cardHoldTimer);node.removeEventListener('pointermove',move);if(this.heldCardKey===source)window.setTimeout(()=>{if(!document.body.classList.contains('content-dragging'))this.render();},0);};
      node.addEventListener('pointermove',move);node.addEventListener('pointerup',finish,{once:true});node.addEventListener('pointercancel',finish,{once:true});
      node.addEventListener('click',event=>{if(this.heldCardKey===source){event.preventDefault();event.stopImmediatePropagation();this.heldCardKey='';}},{capture:true,once:true});
    });
    on('[data-copy]','click',(_event,node)=>{this.pruneLocal();const event=this.localEvent(node.dataset.copy!);if(event)this.copy(event.payload.text || '');else{this.toast('文字已过期。');this.render();}});
    on('[data-remove-staged]','click',(_event,node)=>{if(this.queueSending)return;this.stagedTexts.splice(Number(node.dataset.removeStaged),1);this.render();});
    on('[data-edit-staged]','click',(_event,node)=>{if(this.queueSending)return;const index=Number(node.dataset.editStaged),item=this.stagedTexts[index];if(!item || item.target)return;this.text=item.text;this.editingStagedId=item.id;this.toggleEditor(true);});
    on('[data-preview-file]','click',(_event,node)=>{const [transferId,fileId]=node.dataset.previewFile!.split(':');void this.run(()=>this.openFilePreview(transferId,fileId));});
    on('[data-open-text],[data-open-file]','keydown',(event,node)=>{const key=event as KeyboardEvent;if(event.target!==node || !['Enter',' '].includes(key.key))return;key.preventDefault();node.click();});
    on('.large-file-preview','dblclick',()=>{const key=this.openedFile?.key;if(!key)return;const preview=this.previews.get(key);if(preview?.url)window.open(preview.url,'_blank','noopener');else{const [transferId,fileId]=key.split(':');void this.run(()=>this.download(transferId,fileId));}});
    on('[data-copy-receipt]','click',(_event,node)=>{const receipt=this.receiptBatch.get(node.dataset.copyReceipt!) || this.receipt;if(receipt?.text!==undefined)void this.copy(receipt.text);});
    on('[data-copy-file]','click',(_event,node)=>{const key=node.dataset.copyFile!,source=this.localFile(key);void this.run(async()=>{const text=source?(await readLocalText(source)).text:this.previews.get(key)?.text;if(text!==undefined)this.copy(text);});});
    on('[data-prepare-receipt]','click',(_event,node)=>{void this.prepareReceiptDrag(node.dataset.prepareReceipt);});
    on('[data-view-receipt]','click',(event,node)=>{if((event.target as Element).closest('button,a') || window.getSelection?.()?.isCollapsed===false)return;this.receiptFocusId=node.dataset.viewReceipt!;this.render();});
    on('[data-receipt-menu]','click',(event,node)=>{event.stopPropagation();const rect=node.getBoundingClientRect();this.openCardMenu('receipt',node.dataset.receiptMenu!,rect.right-180,rect.bottom+4);});
    on('[data-drag-all]','dragstart',(event,node)=>this.beginBulkDrag(event,node));
    on('[data-drag-text],[data-drag-file],[data-drag-receipt],[data-drag-library]','dragstart',(event,node)=>this.beginContentDrag(event,node));
    on('[data-drag-text],[data-drag-file],[data-drag-receipt],[data-drag-library]','dragend',()=>{this.endContentDrag();this.render();});
    on('.content-card[data-drag-text],.content-card[data-drag-file]','contextmenu',(event,node)=>{if(isTextSelectionTarget(event.target))return;event.preventDefault();if(this.heldCardKey===(node.dataset.receiveKey || node.dataset.sentKey) || node.hasAttribute('data-receive-key') && this.receiveSelecting || node.hasAttribute('data-sent-key') && this.sentSelecting)return;const mouse=event as MouseEvent;this.openCardMenu(node.dataset.receiptId?'receipt':node.dataset.dragText?'text':'file',node.dataset.receiptId || node.dataset.dragText || node.dataset.dragFile!,mouse.clientX,mouse.clientY);});
    on('[data-card-menu]','click',(event,node)=>{event.stopPropagation();const card=node.closest<HTMLElement>('[data-drag-text],[data-drag-file]');if(!card)return;const rect=node.getBoundingClientRect();this.openCardMenu(card.dataset.dragText?'text':'file',card.dataset.dragText || card.dataset.dragFile!,rect.right-180,rect.bottom+4);});
    on('[data-card-command]','click',(_event,node)=>{void this.run(()=>this.cardCommand(node.dataset.cardCommand!));});
    on('[data-hide-text]','click',(_event,node)=>this.hideText(node.dataset.hideText!));
    on('[data-hide-file]','click',(_event,node)=>{const [transferId,fileId]=node.dataset.hideFile!.split(':');this.hideFile(transferId,fileId);});
    on('.dock-panel','keydown',event=>{const key=event as KeyboardEvent;if((key.ctrlKey || key.metaKey) && key.key==='Enter'){key.preventDefault();this.copySelected();}});
    on('.modal','keydown',(event,node)=>{
      const key=event as KeyboardEvent;
      if(key.isComposing || key.keyCode===229 || this.viewedText()?.composing || this.editorComposing)return;
      if(key.key==='Escape'){key.preventDefault();if(this.modal==='receipt' && this.receiptFocusId && this.receiptBatch.size>1){this.receiptFocusId='';this.render();}else node.querySelector<HTMLButtonElement>('[data-action="close-modal"]')?.click();}
      if(key.key==='Tab'){
        const focusable=Array.from(node.querySelectorAll<HTMLElement>('a[href],button:not(:disabled),input:not(:disabled),select:not(:disabled),textarea:not(:disabled),[tabindex="0"]')).filter(item=>item.getClientRects().length>0);
        if(!focusable.length)return;
        if(key.shiftKey && document.activeElement===focusable[0]){key.preventDefault();focusable[focusable.length-1].focus();}
        else if(!key.shiftKey && document.activeElement===focusable[focusable.length-1]){key.preventDefault();focusable[0].focus();}
      }
    });
    on('[data-expand]','click',(_event,node)=>{const key=node.dataset.expand!;if(this.expanded.has(key))this.expanded.delete(key);else this.expanded.add(key);this.render();});
    on('[data-consent]','change',(_event,node)=>{this.consent.set(node.dataset.consent!,(node as HTMLInputElement).checked);this.render();});
    on('[data-accept]','click',(_event,node)=>{void this.run(()=>this.acceptTransfer(node.dataset.accept!));});
    on('[data-reject]','click',(_event,node)=>{const transfer=this.transfers.find(item=>item.transferId===node.dataset.reject);if(transfer)void this.run(()=>this.acceptFiles(transfer,[],false));});
    on('[data-download]','click',(_event,node)=>{const [transferId,fileId]=node.dataset.download!.split(':');void this.run(()=>this.download(transferId,fileId));});
    on('[data-retry]','click',(_event,node)=>{const [transferId,fileId]=node.dataset.retry!.split(':');void this.run(()=>this.retryFile(transferId,fileId));});
    on('[data-use-relay]','click',(_event,node)=>{const [transferId,fileId]=node.dataset.useRelay!.split(':');void this.run(()=>this.allowRelay(transferId,fileId));});
    on('[data-pause]','click',(_event,node)=>{this.pauseFile(node.dataset.pause!);});
    on('[data-cancel]','click',(_event,node)=>{const [transferId,fileId]=node.dataset.cancel!.split(':');void this.run(()=>this.cancelFile(transferId,fileId));});
    on('[data-text-retry]','click',(_event,node)=>{void this.sendText(node.dataset.textRetry!);});
    on('[data-text-remove]','click',(_event,node)=>{this.pendingTexts=this.pendingTexts.filter(item=>item.eventId!==node.dataset.textRemove);this.render();});
  }
}

export type { GlobalSend };
void new GlobalSend().start();
