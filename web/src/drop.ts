/** Inspect formats during protected dragover; read payloads only during drop. */
export function acceptsWindowDrop(transfer:DataTransfer|null):boolean {
  return !!transfer && (Array.from(transfer.types).some(type=>
    ['files','text/plain','text/uri-list','text/html','text'].includes(type.toLowerCase())) || !!transfer.files?.length);
}

/** Call synchronously from drop: the browser closes its data store afterwards. */
export function droppedText(transfer:DataTransfer):Promise<string> {
  const plain=transfer.getData('text/plain') || transfer.getData('Text');
  const uri=transfer.getData('text/uri-list');
  const html=transfer.getData('text/html');
  const strings=Array.from(transfer.items || []).filter(item=>item.kind==='string' &&
    ['text/plain','text/uri-list','text/html'].includes(item.type.toLowerCase())).map(item=>({
      type:item.type.toLowerCase(),value:new Promise<string>(resolve=>item.getAsString(resolve)),
    }));
  return (async()=>{
    if(plain.trim())return plain;
    const captured=await Promise.all(strings.map(async item=>({type:item.type,value:await item.value})));
    const text=captured.find(item=>item.type==='text/plain')?.value;
    if(text?.trim())return text;
    const links=(uri || captured.find(item=>item.type==='text/uri-list')?.value || '').split(/\r?\n/)
      .map(line=>line.trim()).filter(line=>line && !line.startsWith('#')).join('\n');
    if(links)return links;
    const markup=html || captured.find(item=>item.type==='text/html')?.value;
    if(!markup)return '';
    // Inert parsing: never mount dragged HTML in the live app.
    const doc=new DOMParser().parseFromString(markup,'text/html');
    doc.querySelectorAll('script,style').forEach(node=>node.remove());
    doc.querySelectorAll('br').forEach(node=>node.replaceWith('\n'));
    doc.querySelectorAll('p,div,li').forEach(node=>node.append('\n'));
    return doc.body.textContent?.trim() || '';
  })();
}

/** Native OLE emits null-relatedTarget leaves between children. Delay only exit,
 * not entry, and cancel it on the next dragover instead of flickering the layer. */
export class WindowDropFeedback {
  private leaving:ReturnType<typeof setTimeout>|undefined;
  private show:(visible:boolean)=>void;
  constructor(show:(visible:boolean)=>void){this.show=show;}
  enter(){this.cancelLeave();this.show(true);}
  leave(){this.cancelLeave();this.leaving=setTimeout(()=>{this.leaving=undefined;this.show(false);},100);}
  reset(){this.cancelLeave();this.show(false);}
  private cancelLeave(){if(this.leaving!==undefined)clearTimeout(this.leaving);this.leaving=undefined;}
}
