/** One visible frame: never subtract a keyboard inset from an already resized viewport. */
export interface ViewportSample {width:number;layoutHeight:number;height:number;top:number;scale:number;editing:boolean;}
export class ViewportFrame {
  private width=0;
  private baseline=0;
  keyboard=false;
  sample(value:ViewportSample){
    if(value.scale!==1)return null; // Pinch zoom remains entirely browser-controlled.
    if(Math.abs(value.width-this.width)>80){this.baseline=0;this.keyboard=false;}
    this.width=value.width;
    this.baseline=Math.max(this.baseline,value.layoutHeight,value.height+value.top);
    const smaller=this.baseline-value.height>Math.max(100,Math.min(160,this.baseline*.22));
    this.keyboard=smaller && (value.editing || this.keyboard);
    if(!this.keyboard && !value.editing)this.baseline=Math.max(value.layoutHeight,value.height+value.top);
    return {height:value.height,top:Math.max(0,value.top),keyboard:this.keyboard};
  }
}

export function editableField(value:Element|null):value is HTMLInputElement|HTMLTextAreaElement {
  if(!value?.matches('input,textarea'))return false;
  const field=value as HTMLInputElement|HTMLTextAreaElement;
  return !field.disabled && !field.readOnly && (field.tagName==='TEXTAREA' || ['text','search','url','email','tel','password','number'].includes((field as HTMLInputElement).type));
}

/** Scroll only a real inner pane; scrollIntoView would also pan the whole page. */
export function revealField(field:HTMLElement,doc:Document,win:Window,top:number,height:number){
  for(let parent=field.parentElement;parent && parent!==doc.body && parent!==doc.documentElement;parent=parent.parentElement){
    const style=win.getComputedStyle(parent);
    if(!/(auto|scroll)/.test(style.overflowY) || parent.scrollHeight<=parent.clientHeight)continue;
    const box=parent.getBoundingClientRect(),input=field.getBoundingClientRect(),start=Math.max(top+8,box.top+8),end=Math.min(top+height-8,box.bottom-8);
    if(input.top<start)parent.scrollTop-=start-input.top;
    else if(input.bottom>end)parent.scrollTop+=Math.min(input.bottom-end,input.top-start);
  }
  if(field.tagName!=='TEXTAREA' || field.clientWidth===0)return;
  const textarea=field as HTMLTextAreaElement,style=win.getComputedStyle(field),mirror=doc.createElement('div'),caret=doc.createElement('span');
  Object.assign(mirror.style,{position:'fixed',left:'-10000px',top:'0',visibility:'hidden',pointerEvents:'none',boxSizing:'border-box',width:field.clientWidth+'px',padding:style.padding,border:'0',whiteSpace:'pre-wrap',overflowWrap:'break-word',font:style.font,lineHeight:style.lineHeight,letterSpacing:style.letterSpacing,tabSize:style.tabSize,direction:style.direction});
  mirror.textContent=textarea.value.slice(0,textarea.selectionEnd);caret.textContent='\u200b';mirror.append(caret);doc.body.append(mirror);
  const line=parseFloat(style.lineHeight)||parseFloat(style.fontSize)*1.5,start=caret.offsetTop,end=start+line,padTop=parseFloat(style.paddingTop)||0,padBottom=parseFloat(style.paddingBottom)||0;
  if(start<textarea.scrollTop+padTop)textarea.scrollTop=Math.max(0,start-padTop);
  else if(end>textarea.scrollTop+textarea.clientHeight-padBottom)textarea.scrollTop=Math.min(Math.max(0,textarea.scrollHeight-textarea.clientHeight),end-textarea.clientHeight+padBottom);
  mirror.remove();
}

export class MobileViewport {
  private frame=new ViewportFrame();
  private pending=false;
  private win:Window;private doc:Document;
  constructor(win:Window,doc:Document){
    this.win=win;this.doc=doc;
    const update=()=>this.schedule();
    win.visualViewport?.addEventListener('resize',update);win.visualViewport?.addEventListener('scroll',update);
    win.addEventListener('resize',update);
    for(const type of ['focusin','focusout','input','selectionchange'])doc.addEventListener(type,update);
    this.update();
  }
  private schedule(){if(this.pending)return;this.pending=true;const run=()=>{this.pending=false;this.update();};if(this.win.requestAnimationFrame)this.win.requestAnimationFrame(run);else this.win.setTimeout(run,0);}
  private update(){
    const viewport=this.win.visualViewport,field=this.doc.activeElement,height=viewport?.height || this.win.innerHeight,width=viewport?.width || this.win.innerWidth;
    if(!height || !width)return;
    const result=this.frame.sample({width,layoutHeight:this.win.innerHeight,height,top:viewport?.offsetTop || 0,scale:viewport?.scale || 1,editing:editableField(field)});if(!result)return;
    const root=this.doc.documentElement;
    root.style.setProperty('--app-viewport-height',result.height+'px');root.style.setProperty('--app-viewport-top',result.top+'px');root.classList.toggle('keyboard-open',result.keyboard);
    if(editableField(field) && typeof this.win.getComputedStyle==='function')revealField(field,this.doc,this.win,result.top,result.height);
  }
}
