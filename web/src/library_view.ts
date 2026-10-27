import { LocalFileLibrary, filePreviewKind, readLocalText, sortLocalFiles } from './library';
import type { LocalFileEntry, LibrarySort } from './library';
import type { Device } from './model';
import { escapeHtml as e, formatBytes, compactTime } from './model';
import { webLinkActions } from './web_links';
import { icon } from './icons';
import { localStorageSupported } from './storage';
import { defaultCleanup, FILE_CATEGORIES } from './cleanup';
import { exportFolderEntries } from './folder_export';
import type { CleanupPreferences, FileCategory } from './cleanup';

interface LibraryActions {
  changed():void;
  inventory(entries:LocalFileEntry[]):void;
  close():void;
  peers():Device[];
  signedIn():boolean;
  copy(text:string):void;
  stage(file:File):void;
  stageEntry?(entry:LocalFileEntry):Promise<void>;
  forward(entries:LocalFileEntry[],target:string):Promise<void>;
  pendingForward():boolean;
  discardForward():Promise<void>;
}
type Preview={entry:LocalFileEntry;kind:'image'|'text'|'file';url?:string;text?:string;truncated?:boolean;encoding?:string;paths?:string[]};
export class LocalLibraryView {
  service:LocalFileLibrary|null=null;
  entries:LocalFileEntry[]=[];
  sort:LibrarySort='received';
  selected=new Set<string>();
  editing=false;
  opened=false;
  loading=false;
  busy=false;
  error='';
  target='';
  renameId='';renameName='';
  private menuId='';
  private menuPosition={x:0,y:0};
  previewFile:Preview|null=null;
  cleanup:CleanupPreferences=defaultCleanup();
  cleanupDraft:CleanupPreferences=defaultCleanup();
  retentionValue='1';retentionUnit:'hours'|'days'='days';
  cleanupDirty=false;
  private actions:LibraryActions;
  private thumbnails=new Map<string,string>();
  private snippets=new Map<string,string>();
  private files=new Map<string,File>();
  private loadingThumbnails=new Set<string>();
  private token=0;
  private previewToken=0;
  private refreshing:Promise<void>|null=null;
  private pressTimer=0;
  private pressStart:{x:number;y:number}|null=null;
  private pressedId='';
  private textScroll=0;
  private textSelection:[number,number]=[0,0];
  constructor(actions:LibraryActions){this.actions=actions;}
  async references(keys:Set<string>) {
    if(!keys.size || !localStorageSupported() && !this.service)return null;
    this.service ||= new LocalFileLibrary();
    const entries=await this.service.list(),files=new Map<string,File>();
    await Promise.all(entries.filter(entry=>keys.has(entry.key)).map(async entry=>{
      try{files.set(entry.key,await this.service!.get(entry.id));}
      catch(error){if((error as Error).name!=='NotFoundError')throw error;}
    }));
    return {entries,files};
  }
  async open() {this.opened=true;this.error='';this.actions.changed();await this.refresh();}
  close() {
    this.opened=false;this.token++;this.previewToken++;this.cancelPress();
    for(const url of this.thumbnails.values())URL.revokeObjectURL(url);this.thumbnails.clear();
    this.loadingThumbnails.clear();this.closePreview();this.renameId='';this.menuId='';this.editing=false;this.selected.clear();this.refreshing=null;this.loading=false;
    this.files.clear();this.snippets.clear();
  }
  async refresh() {
    if(!this.opened)return;
    if(this.refreshing)return this.refreshing;
    const token=this.token;
    const refresh=(async()=>{
      this.loading=true;this.error='';this.actions.changed();
      try {
        if(!localStorageSupported() && !this.service)throw new Error('此浏览器暂不支持本机文件库');
        this.service ||= new LocalFileLibrary();
        const [entries,rules]=await Promise.all([this.service.list(),this.service.cleanupPreferences()]);if(token!==this.token || !this.opened)return;
        this.cleanup=rules;
        if(!this.cleanupDirty){this.cleanupDraft={...rules,categories:[...rules.categories]};this.retentionUnit=rules.retentionHours%24===0?'days':'hours';this.retentionValue=String(rules.retentionHours/(this.retentionUnit==='days'?24:1));}
        this.entries=entries;const ids=new Set(entries.map(entry=>entry.id));
        this.actions.inventory(entries);
        for(const id of this.selected)if(!ids.has(id))this.selected.delete(id);
        for(const [id,url] of this.thumbnails)if(!ids.has(id)){URL.revokeObjectURL(url);this.thumbnails.delete(id);}
        for(const id of this.files.keys())if(!ids.has(id))this.files.delete(id);
        if(this.previewFile && !ids.has(this.previewFile.entry.id))this.closePreview();
      } catch(error){if(token===this.token)this.error=error instanceof Error?error.message:'读取文件失败';}
      finally{if(token===this.token){this.loading=false;this.actions.changed();}}
    })();
    this.refreshing=refresh;try{await refresh;}finally{if(this.refreshing===refresh)this.refreshing=null;}
  }
  closePreview() {if(this.previewFile?.url)URL.revokeObjectURL(this.previewFile.url);this.previewFile=null;this.previewToken++;this.textScroll=0;this.textSelection=[0,0];}
  back() {
    if(this.menuId)this.menuId='';
    else if(this.previewFile)this.closePreview();
    else if(this.renameId)this.renameId='';
    else if(this.editing){this.editing=false;this.selected.clear();}
    else return false;
    this.actions.changed();return true;
  }
  async preview(id:string) {
    const entry=this.entries.find(item=>item.id===id);if(!entry || !this.service)return;
    this.closePreview();this.error='';const token=++this.previewToken;
    try {
      if(entry.entryKind==='directory'){
        const content=await this.service.expand([id]);if(token!==this.previewToken || !this.opened)return;
        this.previewFile={entry,kind:'file',paths:content.map(item=>item.entry.relativePath || item.entry.name)};this.actions.changed();return;
      }
      const file=await this.service.get(id),kind=filePreviewKind(entry);
      const preview:Preview={entry,kind};
      if(kind==='text')Object.assign(preview,await readLocalText(file));
      if(token!==this.previewToken || !this.opened)return;
      if(kind==='image')preview.url=URL.createObjectURL(file);
      this.previewFile=preview;
    } catch(error){if(token===this.previewToken)this.error=error instanceof Error?error.message:'无法预览文件';}
    if(token===this.previewToken)this.actions.changed();
  }
  enterEdit(id?:string) {this.closePreview();this.editing=true;if(id)this.selected.add(id);this.error='';this.actions.changed();}
  toggleSelection(id:string) {if(this.actions.pendingForward())return;this.selected.has(id)?this.selected.delete(id):this.selected.add(id);this.actions.changed();}
  selectedEntries(){return this.entries.filter(entry=>this.selected.has(entry.id));}
  renameSelected() {const entry=this.selectedEntries()[0];if(!entry || this.selected.size!==1)return;this.renameId=entry.id;this.renameName=entry.name;this.error='';this.actions.changed();}
  async saveRename() {
    if(!this.service || !this.renameId || this.busy)return;
    this.busy=true;this.error='';this.actions.changed();
    try {
      const entry=await this.service.rename(this.renameId,this.renameName);
      this.entries=this.entries.map(item=>item.id===entry.id?entry:item);this.renameId='';
      this.actions.inventory(this.entries);
      if(this.previewFile?.entry.id===entry.id)this.previewFile.entry=entry;
    } catch(error){this.error=error instanceof Error?error.message:'重命名失败';}
    finally{this.busy=false;this.actions.changed();}
  }
  async deleteSelected() {
    if(!this.service || this.busy || this.actions.pendingForward())return;
    this.busy=true;this.error='';this.actions.changed();
    try {
      for(const entry of this.selectedEntries()) {
        await this.service.remove(entry.id);this.entries=this.entries.filter(item=>item.id!==entry.id);this.selected.delete(entry.id);
        const url=this.thumbnails.get(entry.id);if(url)URL.revokeObjectURL(url);this.thumbnails.delete(entry.id);
      }
      this.renameId='';if(!this.entries.length)this.editing=false;
      this.actions.inventory(this.entries);
    } catch(error){this.error=error instanceof Error?error.message:'删除失败';}
    finally{this.busy=false;this.actions.changed();}
  }
  async forwardSelected() {
    if(this.busy || !this.actions.signedIn() || !this.selected.size)return;
    if(!this.actions.peers().some(device=>device.deviceId===this.target)){this.error='请选择在线设备';this.actions.changed();return;}
    this.busy=true;this.error='';this.actions.changed();
    try {await this.actions.forward(this.selectedEntries(),this.target);this.selected.clear();this.editing=false;}
    catch(error){this.error=error instanceof Error?error.message:'转发失败';}
    finally{this.busy=false;this.actions.changed();}
  }
  async download(id:string) {
    if(!this.service)return;
    try {
      const entry=this.entries.find(entry=>entry.id===id);
      if(entry?.entryKind==='directory'){
        const picker=(window as Window & {showDirectoryPicker?:(options?:unknown)=>Promise<FileSystemDirectoryHandle>}).showDirectoryPicker;
        if(!picker)throw new Error('此浏览器不能导出目录；可在文件库查看或转发');
        const target=await picker({id:'globalsend-export-folder',mode:'readwrite'});await exportFolderEntries(await this.service.expand([id]),target);return;
      }
      const file=await this.service.get(id),url=URL.createObjectURL(file),link=document.createElement('a');
      link.href=url;link.download=file.name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);
    }catch(error){this.error=error instanceof Error?error.message:'下载失败';this.actions.changed();}
  }
  async saveCleanup() {
    if(!this.service || this.busy)return;
    this.busy=true;this.error='';this.actions.changed();
    try {
      this.cleanup=await this.service.setCleanupPreferences({...this.cleanupDraft,retentionHours:Number(this.retentionValue)*(this.retentionUnit==='days'?24:1)});
      this.cleanupDirty=false;await this.refresh();
    }catch(error){this.error=error instanceof Error?error.message:'清理设置未保存';}
    finally{this.busy=false;this.actions.changed();}
  }
  private cleanupLabel() {
    if(!this.cleanup.categories.length)return '不自动清理';
    if(this.cleanup.categories.length!==FILE_CATEGORIES.length || this.cleanup.sizeRule!=='any')return '按规则清理';
    return `保留 ${this.cleanup.retentionHours%24===0?`${this.cleanup.retentionHours/24} 天`:`${this.cleanup.retentionHours} 小时`}`;
  }
  fileForDrag(id:string){return this.files.get(id);}
  private date(value:number){return compactTime(value);}
  html(embedded=false) {
    const peers=this.actions.peers(),pending=this.actions.pendingForward();
    if(!peers.some(device=>device.deviceId===this.target) && !pending)this.target=peers[0]?.deviceId || '';
    const preview=this.previewFile;
    return `${embedded?'':'<div class="modal-backdrop">'}<section class="${embedded?'embedded-library':'modal'} file-library-modal" ${embedded?'':'role="dialog" aria-modal="true"'} aria-labelledby="library-title"><div class="${embedded?'library-pane-header':'modal-header'}"><div><h2 id="library-title" ${embedded && !preview?'class="sr-only"':''}>${preview?e(preview.entry.name):'本机文件'}</h2><p class="library-subtitle">${preview?`${formatBytes(preview.entry.size)} · ${this.date(preview.entry.receivedAt)}`:`${this.entries.length} 项`}</p></div>${embedded?'':`<button class="icon-button quiet" data-library-action="close" aria-label="关闭文件库">${icon('close')}</button>`}</div>
    ${this.error?`<p class="library-error" role="alert">${e(this.error)}</p>`:''}
    ${preview?this.previewHtml(preview):`${this.toolbarHtml(peers,pending)}${this.renameId?`<form id="library-rename-form" class="library-rename-form"><label class="field" for="library-rename-name">文件名<input id="library-rename-name" value="${e(this.renameName)}" maxlength="255" required></label><button class="primary" type="submit" ${this.busy?'disabled':''}>保存</button><button class="quiet" type="button" data-library-action="cancel-rename">取消</button></form>`:''}
    ${this.loading && !this.entries.length?'<div class="library-empty">读取中…</div>':!this.entries.length?'<div class="library-empty">暂无已保存文件</div>':`<div class="library-grid">${sortLocalFiles(this.entries,this.sort).map(entry=>this.cardHtml(entry)).join('')}</div>`}
    ${this.cleanupHtml()}`}${this.menuId?`<div class="content-menu" role="menu" style="left:${this.menuPosition.x}px;top:${this.menuPosition.y}px">${[['preview','详情'],['download','下载'],['requeue','加入待发送'],['rename','重命名'],['delete','删除']].map(([action,label])=>`<button data-library-command="${action}" role="menuitem">${label}</button>`).join('')}</div>`:''}</section>${embedded?'':'</div>'}`;
  }
  private cleanupHtml() {
    const labels=['图片','视频','音频','文本','压缩包','其他'];
    return `<details class="advanced-join library-cleanup settings-card"><summary>自动清理 <span class="cleanup-value">${this.cleanupLabel()}</span></summary><form id="library-cleanup-form"><label class="library-retention" for="library-retention">保留时长<span><input id="library-retention" type="number" min="1" step="1" inputmode="numeric" value="${e(this.retentionValue)}" required><select id="library-retention-unit" aria-label="保留时长单位"><option value="days" ${this.retentionUnit==='days'?'selected':''}>天</option><option value="hours" ${this.retentionUnit==='hours'?'selected':''}>小时</option></select></span></label><div class="library-categories" aria-label="清理类别">${FILE_CATEGORIES.map((category,index)=>`<label><input type="checkbox" data-library-category="${category}" ${this.cleanupDraft.categories.includes(category)?'checked':''}>${labels[index]}</label>`).join('')}</div><label class="library-cleanup-size" for="library-size-rule">文件大小<span><select id="library-size-rule"><option value="any" ${this.cleanupDraft.sizeRule==='any'?'selected':''}>不限</option><option value="greater" ${this.cleanupDraft.sizeRule==='greater'?'selected':''}>大于</option><option value="smaller" ${this.cleanupDraft.sizeRule==='smaller'?'selected':''}>小于</option></select><input id="library-size-mib" type="number" min="0" step="any" inputmode="decimal" aria-label="清理大小 MiB" value="${this.cleanupDraft.sizeMiB}" ${this.cleanupDraft.sizeRule==='any'?'disabled':''}><span>MiB</span></span></label><div class="library-cleanup-footer"><p>只清理符合规则的过期文件，不影响下载副本。</p><button class="secondary" type="submit" ${this.busy?'disabled':''} ${this.cleanupDirty?'':'hidden'}>保存</button></div></form></details>`;
  }
  private toolbarHtml(peers:Device[],pending:boolean) {
    const count=this.selected.size;
    return `<div class="library-toolbar"><label class="toolbar-field" for="library-sort"><span>排序</span><select id="library-sort" data-library-sort aria-label="文件排序"><option value="received" ${this.sort==='received'?'selected':''}>最新接收</option><option value="oldest" ${this.sort==='oldest'?'selected':''}>最早接收</option><option value="name" ${this.sort==='name'?'selected':''}>名称</option><option value="size" ${this.sort==='size'?'selected':''}>大小</option></select></label><button class="quiet" data-library-action="refresh" aria-label="刷新文件库" ${this.loading?'disabled':''}>${icon('retry')}</button><button class="secondary" data-library-action="edit" ${this.busy || pending || !this.entries.length?'disabled':''}>${this.editing?'完成':'编辑'}</button></div>
    ${this.editing?`<div class="library-selection"><span>已选 ${count} 项</span><button class="quiet" data-library-action="select-all">${count===this.entries.length?'取消全选':'全选'}</button><div class="item-actions"><button class="quiet" data-library-action="rename" ${count!==1 || this.busy || pending?'disabled':''}>重命名</button><button class="quiet danger" data-library-action="delete" ${!count || this.busy || pending?'disabled':''}>删除</button></div>${this.actions.signedIn()?`<div class="library-forward"><label class="toolbar-field" for="library-target"><span>转发到</span><select id="library-target" data-library-target aria-label="转发到在线设备" ${!peers.length || this.busy || pending?'disabled':''}>${!peers.length?'<option value="">暂无在线设备</option>':peers.map(device=>`<option value="${e(device.deviceId)}" ${this.target===device.deviceId?'selected':''}>${e(device.name)}</option>`).join('')}</select></label><button class="primary" data-library-action="forward" ${!count || !this.target || this.busy?'disabled':''}>${this.busy?'处理中…':pending?'重试转发':'转发'}</button>${pending?'<button class="quiet" data-library-action="discard-forward">取消</button>':''}</div>`:''}</div>`:''}`;
  }
  private cardHtml(entry:LocalFileEntry) {
    const url=this.thumbnails.get(entry.id),kind=filePreviewKind(entry),selected=this.selected.has(entry.id);
    return `<article tabindex="0" role="${this.editing?'checkbox':'button'}" class="library-card ${kind==='image'?'image-card':''} ${selected?'selected':''}" data-library-id="${e(entry.id)}" data-drag-library="${e(entry.id)}" draggable="${!this.editing}" aria-label="${this.editing?'选择':'查看'} ${e(entry.name)}" ${this.editing?`aria-checked="${selected}"`:''} aria-disabled="${this.busy || this.actions.pendingForward()}">${this.editing?'':`<button class="icon-button quiet card-menu-button" data-library-menu="${e(entry.id)}" aria-label="更多">···</button>`}<span class="library-card-preview ${kind==='image'?'image':''}">${url?`<img src="${e(url)}" loading="lazy" decoding="async" alt="">`:this.snippets.has(entry.id)?`<span class="file-text-preview">${e(this.snippets.get(entry.id)!.slice(0,500))}</span>`:icon(entry.entryKind==='directory'?'folder':kind==='text'?'text':'file')}${this.editing?`<span class="library-select-dot">${selected?icon('check'):''}</span>`:''}</span><span class="library-card-name" title="${e(entry.name)}">${e(entry.name)}</span><span class="library-card-detail">${entry.entryKind==='directory'?'文件夹':formatBytes(entry.size)}<time>${this.date(entry.receivedAt)}</time></span></article>`;
  }
  private previewHtml(preview:Preview) {
    return `<div class="library-preview-tools"><button class="quiet" data-library-action="back">‹ 文件库</button><button class="copy-button" data-library-action="download">${icon('down')} 下载</button>${preview.kind==='text'?`<button class="copy-button" data-library-action="copy">${icon('copy')} 复制</button>`:''}</div>${preview.entry.entryKind==='directory'?`<div class="folder-preview" style="overflow:auto"><ul>${(preview.paths || []).map(path=>`<li>${e(path)}</li>`).join('')}</ul></div>`:preview.kind==='image'?`<div class="library-image-preview"><img src="${e(preview.url)}" alt="${e(preview.entry.name)}"></div>`:preview.kind==='text'?`<div class="editor-sheet library-text-sheet"><textarea id="library-text" class="text-input" readonly spellcheck="false" aria-label="文件内容">${e(preview.text)}</textarea><div class="web-link-list">${webLinkActions(preview.text || '')}</div><div class="editor-tools"><span>${e(preview.encoding?.toUpperCase())}${preview.truncated?' · 仅预览前 8 MiB':''}</span><span>只读</span></div></div>`:`<div class="library-empty">${icon('file')}<p>此文件暂不支持预览</p></div>`}`;
  }
  capture() {const field=document.querySelector<HTMLTextAreaElement>('#library-text');if(field){this.textScroll=field.scrollTop;this.textSelection=[field.selectionStart,field.selectionEnd];}}
  bind() {
    if(!this.opened)return;
    const root=document.querySelector('.file-library-modal');if(!root)return;
    root.querySelectorAll<HTMLElement>('[data-library-menu]').forEach(node=>node.addEventListener('click',event=>{event.stopPropagation();const rect=node.getBoundingClientRect();this.menuId=node.dataset.libraryMenu!;this.menuPosition={x:Math.max(8,Math.min(rect.right-184,window.innerWidth-192)),y:Math.min(rect.bottom+4,window.innerHeight-250)};this.actions.changed();}));
    root.querySelectorAll<HTMLElement>('[data-library-command]').forEach(node=>node.addEventListener('click',()=>{const id=this.menuId;this.menuId='';const action=node.dataset.libraryCommand;if(action==='preview')void this.preview(id);if(action==='download')void this.download(id);if(action==='requeue'){const entry=this.entries.find(entry=>entry.id===id),file=this.files.get(id);if(entry && this.actions.stageEntry)void this.actions.stageEntry(entry).catch(error=>{this.error=error.message;this.actions.changed();});else if(file)this.actions.stage(file);}if(action==='rename'){this.editing=true;this.selected=new Set([id]);this.renameSelected();}if(action==='delete'){this.selected=new Set([id]);void this.deleteSelected();}this.actions.changed();}));
    root.querySelectorAll<HTMLElement>('[data-library-action]').forEach(node=>node.addEventListener('click',()=>{
      const action=node.dataset.libraryAction;
      if(action==='close'){this.close();this.actions.close();}
      if(action==='refresh')void this.refresh();
      if(action==='edit'){this.editing=!this.editing;this.selected.clear();this.renameId='';this.actions.changed();}
      if(action==='rename')this.renameSelected();
      if(action==='select-all'){this.selected=this.selected.size===this.entries.length?new Set():new Set(this.entries.map(entry=>entry.id));this.actions.changed();}
      if(action==='delete')void this.deleteSelected();
      if(action==='forward')void this.forwardSelected();
      if(action==='discard-forward')void this.actions.discardForward().then(()=>{this.error='';this.actions.changed();}).catch(error=>{this.error=error.message;this.actions.changed();});
      if(action==='cancel-rename'){this.renameId='';this.actions.changed();}
      if(action==='back'){this.closePreview();this.actions.changed();}
      if(action==='copy' && this.previewFile?.text!==undefined)this.actions.copy(this.previewFile.text);
      if(action==='download' && this.previewFile)void this.download(this.previewFile.entry.id);
    }));
    root.querySelector<HTMLSelectElement>('[data-library-sort]')?.addEventListener('change',event=>{this.sort=(event.target as HTMLSelectElement).value as LibrarySort;this.actions.changed();});
    root.querySelector<HTMLSelectElement>('[data-library-target]')?.addEventListener('change',event=>{this.target=(event.target as HTMLSelectElement).value;});
    root.querySelector<HTMLInputElement>('#library-rename-name')?.addEventListener('input',event=>{this.renameName=(event.target as HTMLInputElement).value;});
    root.querySelector('#library-rename-form')?.addEventListener('submit',event=>{event.preventDefault();void this.saveRename();});
    root.querySelector('#library-cleanup-form')?.addEventListener('submit',event=>{event.preventDefault();void this.saveCleanup();});
    const dirty=()=>{this.cleanupDirty=true;const button=root.querySelector<HTMLButtonElement>('#library-cleanup-form button[type=submit]');if(button){button.disabled=false;button.hidden=false;button.textContent='保存';}};
    root.querySelector<HTMLInputElement>('#library-retention')?.addEventListener('input',event=>{this.retentionValue=(event.target as HTMLInputElement).value;dirty();});
    root.querySelector<HTMLSelectElement>('#library-retention-unit')?.addEventListener('change',event=>{this.retentionUnit=(event.target as HTMLSelectElement).value as 'hours'|'days';dirty();});
    root.querySelector<HTMLSelectElement>('#library-size-rule')?.addEventListener('change',event=>{this.cleanupDraft.sizeRule=(event.target as HTMLSelectElement).value as CleanupPreferences['sizeRule'];const input=root.querySelector<HTMLInputElement>('#library-size-mib');if(input)input.disabled=this.cleanupDraft.sizeRule==='any';dirty();});
    root.querySelector<HTMLInputElement>('#library-size-mib')?.addEventListener('input',event=>{this.cleanupDraft.sizeMiB=Number((event.target as HTMLInputElement).value);dirty();});
    root.querySelectorAll<HTMLInputElement>('[data-library-category]').forEach(node=>node.addEventListener('change',()=>{const category=node.dataset.libraryCategory as FileCategory;this.cleanupDraft.categories=node.checked?[...this.cleanupDraft.categories,category]:this.cleanupDraft.categories.filter(value=>value!==category);dirty();}));
    root.querySelectorAll<HTMLElement>('[data-library-id]').forEach(node=>{
      const id=node.dataset.libraryId!;
      node.addEventListener('click',event=>{if((event.target as Element).closest('button') || this.busy || this.actions.pendingForward())return;if(this.pressedId===id){this.pressedId='';return;}this.editing?this.toggleSelection(id):void this.preview(id);});
      node.addEventListener('keydown',event=>{const key=event as KeyboardEvent;if(event.target===node && ['Enter',' '].includes(key.key)){event.preventDefault();node.click();}});
      node.addEventListener('contextmenu',event=>{event.preventDefault();this.enterEdit(id);});
      node.addEventListener('pointerdown',event=>{if(this.busy || this.actions.pendingForward())return;this.pressedId='';this.cancelPress();this.pressStart={x:event.clientX,y:event.clientY};this.pressTimer=window.setTimeout(()=>{this.pressedId=id;this.enterEdit(id);},450);});
      node.addEventListener('pointermove',event=>{if(this.pressStart && Math.hypot(event.clientX-this.pressStart.x,event.clientY-this.pressStart.y)>12)this.cancelPress();});
      for(const event of ['pointerup','pointercancel','pointerleave'])node.addEventListener(event,()=>this.cancelPress());
    });
    root.addEventListener('keydown',event=>{const key=event as KeyboardEvent;if(!key.isComposing && key.keyCode!==229 && key.key==='Escape'){event.preventDefault();event.stopPropagation();if(!this.back()){this.close();this.actions.close();}}});
    root.querySelector('.library-image-preview')?.addEventListener('dblclick',()=>{if(this.previewFile)void this.download(this.previewFile.entry.id);});
    const field=root.querySelector<HTMLTextAreaElement>('#library-text');if(field){field.scrollTop=this.textScroll;field.setSelectionRange?.(...this.textSelection);}
    void this.loadThumbnails();
  }
  private cancelPress(){clearTimeout(this.pressTimer);this.pressTimer=0;this.pressStart=null;}
  private async loadThumbnails() {
    const token=this.token,service=this.service;if(!service || this.previewFile)return;
    let changed=false;
    let missing=false;
    await Promise.all(this.entries.filter(entry=>!this.files.has(entry.id) && !this.loadingThumbnails.has(entry.id)).map(async entry=>{
      this.loadingThumbnails.add(entry.id);
      try{const file=await service.get(entry.id),kind=filePreviewKind(entry);const snippet=kind==='text'?(await readLocalText(file.slice(0,4096))).text:undefined;if(token===this.token && this.opened && this.entries.some(item=>item.id===entry.id)){this.files.set(entry.id,file);if(kind==='image')this.thumbnails.set(entry.id,URL.createObjectURL(file));if(snippet!==undefined)this.snippets.set(entry.id,snippet);changed=true;}}
      catch(error){if((error as Error).name==='NotFoundError')missing=true;}
      finally{this.loadingThumbnails.delete(entry.id);}
    }));
    if(changed && token===this.token)this.actions.changed();
    if(missing && token===this.token)void this.refresh();
  }
}
