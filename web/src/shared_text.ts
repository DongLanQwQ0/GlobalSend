import { Api, ApiError } from './api';
import { escapeHtml as e } from './model';
import { icon } from './icons';
import { SharedEditHistory } from './shared_history';
import type { EditSnapshot } from './shared_history';

export interface SharedDocument {text:string;revision:number;updatedAt:string;updatedBy:string;mutationId?:string}
/** One live group note, separate from drafts and the operating-system clipboard. */
export class SharedGroupEditor {
  document:SharedDocument={text:'',revision:0,updatedAt:'',updatedBy:''};
  draft='';dirty=false;conflict=false;saving=false;error='';loaded=false;
  private field:HTMLTextAreaElement|null=null;
  private composing=false;
  private timer=0;
  private epoch=0;
  private busyMutation='';
  private history=new SharedEditHistory();
  private last:EditSnapshot={text:'',start:0,end:0,direction:'none',scrollTop:0};
  private before:EditSnapshot|null=null;
  private compositionBefore:EditSnapshot|null=null;
  private compositionTail:EditSnapshot|null=null;
  private compositionRecorded=false;
  constructor(private api:()=>Api,private changed:()=>void){}
  get composingActive(){return this.composing && !!this.field?.isConnected;}
  get focusedActive(){return !!this.field?.isConnected && document.activeElement===this.field;}
  reset(){this.epoch++;clearTimeout(this.timer);this.field=null;this.composing=false;this.document={text:'',revision:0,updatedAt:'',updatedBy:''};this.draft='';this.dirty=false;this.conflict=false;this.saving=false;this.error='';this.loaded=false;this.busyMutation='';this.history.clear();this.replaceText('');}
  html(enabled:boolean,maxLength:number){return `<section class="shared-note"><div class="section-label"><h3>共享文本</h3><span id="shared-status" role="status">${e(enabled?this.status():'中心升级后可用')}</span><div class="shared-edit-tools"><button class="icon-button quiet" type="button" data-shared-action="undo" aria-label="撤销" title="撤销（Ctrl / ⌘ + Z）" aria-keyshortcuts="Control+z Meta+z" ${enabled && this.canUndo?'':'disabled'}>${icon('undo')}</button><button class="icon-button quiet" type="button" data-shared-action="redo" aria-label="重做" title="重做（Ctrl / ⌘ + Y 或 Shift + Z）" aria-keyshortcuts="Control+y Meta+y Control+Shift+z Meta+Shift+z" ${enabled && this.canRedo?'':'disabled'}>${icon('redo')}</button></div></div><div data-shared-host data-drag-shared="true" draggable="true" data-enabled="${enabled}" data-max="${maxLength}"></div><div id="shared-conflict" class="shared-conflict" ${this.conflict?'':'hidden'}><span>另一设备已更新</span><button class="secondary" data-shared-action="remote">使用最新内容</button><button class="secondary" data-shared-action="mine">保留我的内容</button></div><button id="shared-retry" class="quiet" data-shared-action="retry" ${this.error && !this.conflict?'':'hidden'}>重试同步</button></section>`;}
  status(){return this.conflict?'未同步 · 内容冲突':this.error?'未同步':'';}
  get canUndo(){return this.history.canUndo && !this.composing && !this.field?.disabled;}
  get canRedo(){return this.history.canRedo && !this.composing && !this.field?.disabled;}
  private snapshot():EditSnapshot {
    const field=this.field,text=field?.value ?? this.draft;
    return {text,start:field?.selectionStart ?? 0,end:field?.selectionEnd ?? 0,direction:field?.selectionDirection || 'none',scrollTop:field?.scrollTop || 0};
  }
  private replaceText(text:string,record=false){
    const position=this.snapshot();this.before=null;this.compositionBefore=null;this.compositionTail=null;this.compositionRecorded=false;
    this.draft=text;
    if(this.field){this.field.value=text;this.field.setSelectionRange(Math.min(position.start,text.length),Math.min(position.end,text.length),position.direction);this.field.scrollTop=position.scrollTop;}
    this.last=this.snapshot();if(record)this.history.record(position,this.last);
  }
  private edited(){this.draft=this.field!.value;this.dirty=this.draft!==this.document.text;this.error='';if(!this.dirty)this.conflict=false;}
  private restore(value:EditSnapshot){
    this.before=null;this.compositionTail=null;this.draft=value.text;
    if(this.field){this.field.value=value.text;this.field.focus({preventScroll:true});this.field.setSelectionRange(value.start,value.end,value.direction);this.field.scrollTop=value.scrollTop;}
    this.dirty=this.draft!==this.document.text;this.error='';if(!this.dirty)this.conflict=false;
    this.last=this.snapshot();this.paint();this.schedule();
  }
  undo(){if(!this.canUndo)return;const value=this.history.undo(this.snapshot());if(value)this.restore(value);}
  redo(){if(!this.canRedo)return;const value=this.history.redo(this.snapshot());if(value)this.restore(value);}

  mount(){
    const host=document.querySelector<HTMLElement>('[data-shared-host]');if(!host)return;
    if(!this.field){
      const field=document.createElement('textarea');field.id='shared-group-text';field.className='selectable-text';field.draggable=false;field.placeholder='组内设备共同编辑';field.setAttribute('aria-label','组内共享文本');field.rows=5;
      field.addEventListener('beforeinput',event=>{
        if(this.composing || event.isComposing)return;
        if(event.inputType==='historyUndo' || event.inputType==='historyRedo'){event.preventDefault();event.inputType==='historyUndo'?this.undo():this.redo();return;}
        this.before=this.snapshot();
      });
      field.addEventListener('input',event=>{
        const after=this.snapshot(),type=(event as InputEvent).inputType;
        this.edited();
        if(!this.composing){
          if(this.compositionTail && type==='insertFromComposition')this.history.amend(this.compositionTail,after,this.compositionRecorded);
          else this.history.record(this.before || this.last,after);
          this.last=after;this.before=null;this.compositionTail=null;this.compositionRecorded=false;
        }
        this.paint();this.schedule();
      });
      field.addEventListener('keydown',event=>{
        if(this.composing || event.isComposing || event.keyCode===229 || event.altKey || !(event.ctrlKey || event.metaKey))return;
        const key=event.key.toLowerCase(),redo=key==='y' && !event.shiftKey || key==='z' && event.shiftKey;
        if(key!=='z' && !redo)return;
        event.preventDefault();event.stopPropagation();redo?this.redo():this.undo();
      });
      field.addEventListener('compositionstart',()=>{this.compositionBefore=this.snapshot();this.before=null;this.compositionTail=null;this.composing=true;clearTimeout(this.timer);this.paint();});
      field.addEventListener('compositionend',()=>{
        this.composing=false;this.edited();const after=this.snapshot(),before=this.compositionBefore || this.last;this.compositionRecorded=this.history.record(before,after);this.last=after;this.compositionBefore=null;this.before=null;this.compositionTail=before;
        this.paint();this.schedule();this.changed();
      });
      field.addEventListener('blur',()=>window.setTimeout(()=>this.changed(),0));
      this.field=field;
    }
    const field=this.field;field.disabled=host.dataset.enabled!=='true';field.maxLength=Number(host.dataset.max);if(field.value!==this.draft && !this.composing)this.replaceText(this.draft);host.append(field);
    document.querySelectorAll<HTMLButtonElement>('[data-shared-action]').forEach(button=>{if(['undo','redo'].includes(button.dataset.sharedAction || ''))button.onpointerdown=event=>event.preventDefault();button.onclick=()=>{
      if(button.dataset.sharedAction==='undo'){this.undo();return;}
      if(button.dataset.sharedAction==='redo'){this.redo();return;}
      if(button.dataset.sharedAction==='remote'){this.replaceText(this.document.text,true);this.dirty=false;this.conflict=false;this.error='';this.paint();}
      else {this.conflict=false;this.error='';void this.save();}
    };});this.paint();
  }
  private paint(){for(const [action,enabled] of [['undo',this.canUndo],['redo',this.canRedo]] as const){const button=document.querySelector<HTMLButtonElement>('[data-shared-action="'+action+'"]');if(button)button.disabled=!enabled;}const status=document.querySelector('#shared-status');if(status && !this.field?.disabled)status.textContent=this.status();document.querySelector<HTMLElement>('#shared-conflict')?.toggleAttribute('hidden',!this.conflict);document.querySelector<HTMLElement>('#shared-retry')?.toggleAttribute('hidden',!this.error || this.conflict);}
  private schedule(){clearTimeout(this.timer);if(this.dirty && !this.conflict && !this.composing)this.timer=window.setTimeout(()=>void this.save(),400);}
  receive(value:SharedDocument){
    if(value.revision<this.document.revision)return;
    const old=this.document,hadDocument=this.loaded;
    this.document=value;this.loaded=true;
    if(this.busyMutation && value.mutationId===this.busyMutation){this.paint();return;}
    if(this.dirty || this.composing){if(value.text!==old.text && value.text!==this.draft){this.conflict=true;clearTimeout(this.timer);}else if(value.text===this.draft)this.dirty=false;}
    else if(this.draft!==value.text)this.replaceText(value.text,hadDocument);
    this.paint();
  }
  async refresh(){const epoch=this.epoch;try {const value=await this.api().request<SharedDocument>('/group/shared-text');if(epoch===this.epoch){this.receive(value);this.error='';this.paint();}}catch(error){if(epoch===this.epoch){this.error=error instanceof Error?error.message:'同步失败';this.paint();}}}
  async save(){
    if(!this.dirty || this.saving || this.conflict || this.composing || this.field?.disabled)return;
    const epoch=this.epoch,text=this.draft,baseRevision=this.document.revision,mutationId=crypto.randomUUID();this.saving=true;this.busyMutation=mutationId;this.paint();
    try {
      const value=await this.api().request<SharedDocument>('/group/shared-text',{text,baseRevision,mutationId},'PUT');if(epoch!==this.epoch)return;
      if(value.revision>=this.document.revision)this.document=value;
      this.loaded=true;this.dirty=this.draft!==this.document.text;this.error='';
      if(this.document.revision>value.revision && this.dirty)this.conflict=true;
    }catch(error){if(epoch!==this.epoch)return;if(error instanceof ApiError && error.status===409){this.conflict=true;await this.refresh();}else this.error=error instanceof Error?error.message:'同步失败';}
    finally {if(epoch===this.epoch){this.saving=false;this.busyMutation='';this.paint();if(this.dirty && !this.error)this.schedule();this.changed();}}
  }
}
