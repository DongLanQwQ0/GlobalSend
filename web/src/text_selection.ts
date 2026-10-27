const selectionSelector='textarea.selectable-text:not([readonly])';
export const isTextSelectionTarget=(target:EventTarget|null)=>
  !!(target as Element|null)?.closest?.(selectionSelector);
/** Hit the rendered character, not the rectangular text container. */
export function isTextSelectionPoint(event:{target:EventTarget|null;clientX?:number;clientY?:number}):boolean {
  if(!isTextSelectionTarget(event.target))return false;
  const element=(event.target as Element).closest(selectionSelector)!,document=element.ownerDocument;
  if(element.tagName==='TEXTAREA' && event.clientX!==undefined && event.clientY!==undefined){
    const field=element as HTMLTextAreaElement,style=document.defaultView!.getComputedStyle(field),rect=field.getBoundingClientRect();
    const x=event.clientX-rect.left-parseFloat(style.paddingLeft)+field.scrollLeft;
    const y=event.clientY-rect.top-parseFloat(style.paddingTop)+field.scrollTop;
    const height=parseFloat(style.lineHeight) || parseFloat(style.fontSize)*1.6,width=field.clientWidth-parseFloat(style.paddingLeft)-parseFloat(style.paddingRight);
    if(x<0 || y<0 || width<=0)return false;
    const canvas=document.createElement('canvas'),context=canvas.getContext('2d')!;context.font=style.font;
    const targetLine=Math.floor(y/height);let line=0,left=0;
    for(const character of field.value){if(character==='\n'){if(line===targetLine)return false;line++;left=0;continue;}const advance=context.measureText(character).width;if(left+advance>width && left>0){line++;left=0;}if(line>targetLine)return false;if(line===targetLine && x>=left && x<=left+advance)return !/\s/.test(character);left+=advance;}
    return false;
  }
  const caretDocument=document as Document & {caretPositionFromPoint?:(x:number,y:number)=>{offsetNode:Node;offset:number}|null;caretRangeFromPoint?:(x:number,y:number)=>Range|null};
  if(event.clientX===undefined || event.clientY===undefined || !document.createRange || !caretDocument.caretPositionFromPoint && !caretDocument.caretRangeFromPoint)return true;
  const position=caretDocument.caretPositionFromPoint?.(event.clientX,event.clientY),caret=position?null:caretDocument.caretRangeFromPoint?.(event.clientX,event.clientY);
  const node=position?.offsetNode || caret?.startContainer,offset=position?.offset ?? caret?.startOffset;
  if(!node || node.nodeType!==3 || offset===undefined || !element.contains(node))return false;
  const text=node.textContent || '';
  for(const index of [offset,offset-1]){
    if(index<0 || index>=text.length || /\s/.test(text[index]))continue;
    const range=document.createRange();range.setStart(node,index);range.setEnd(node,index+1);
    for(const rect of Array.from(range.getClientRects()))if(event.clientX>=rect.left && event.clientX<=rect.right && event.clientY>=rect.top && event.clientY<=rect.bottom)return true;
  }
  return false;
}
const states=new WeakMap<Document,{active:boolean;down:boolean;release:()=>void}>();
export function textSelectionActive(document:Document) {
  if(states.get(document)?.active)return true;
  const selection=document.defaultView?.getSelection?.();
  return !!selection && !selection.isCollapsed &&
    isTextSelectionTarget(selection.anchorNode?.nodeType===1?selection.anchorNode:selection.anchorNode?.parentElement || null);
}

/** Let the browser select text instead of dragging the containing card. */
export function enableTextSelection(document:Document,release=()=>{}) {
  const existing=states.get(document);if(existing){existing.release=release;return;}
  const state={active:false,down:false,release};states.set(document,state);
  const suspended=new Map<HTMLElement,string>();
  const activated=new Map<HTMLElement,string>();
  const restore=()=>{for(const [node,value] of [...suspended,...activated])node.setAttribute('draggable',value);suspended.clear();activated.clear();};
  document.addEventListener('pointerdown',event=>{
    restore();
    state.down=true;state.active=isTextSelectionPoint(event);
    if(!state.active){const card=(event.target as Element).closest<HTMLElement>('[data-drag-text],[data-drag-receipt],[data-drag-shared]');if(card && !card.closest('[data-multi-select="true"]')){activated.set(card,card.getAttribute('draggable') || 'false');card.setAttribute('draggable','true');}return;}
    let node=(event.target as Element).closest<HTMLElement>('[draggable="true"]');
    while(node){suspended.set(node,'true');node.setAttribute('draggable','false');node=node.parentElement?.closest<HTMLElement>('[draggable="true"]') || null;}
  });
  const finish=()=>{restore();state.down=false;state.active=false;setTimeout(()=>state.release(),0);};
  document.addEventListener('pointerup',finish);
  document.addEventListener('pointercancel',finish);
  document.addEventListener('selectionchange',()=>{if(!state.down)setTimeout(()=>state.release(),0);});
}
