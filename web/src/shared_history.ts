export interface EditSnapshot {
  text:string;start:number;end:number;direction:'forward'|'backward'|'none';scrollTop:number;
}
type Selection=Omit<EditSnapshot,'text'>;
type Edit={at:number;removed:string;inserted:string;before:Selection;after:Selection};
const selection=({start,end,direction,scrollTop}:EditSnapshot):Selection=>({start,end,direction,scrollTop});

/** One continuous document history, including applied remote changes. */
export class SharedEditHistory {
  private past:Edit[]=[];
  private future:Edit[]=[];
  get canUndo(){return this.past.length>0;}
  get canRedo(){return this.future.length>0;}
  clear(){this.past=[];this.future=[];}
  record(before:EditSnapshot,after:EditSnapshot){
    if(before.text===after.text)return false;
    let at=0,endBefore=before.text.length,endAfter=after.text.length;
    while(at<endBefore && at<endAfter && before.text[at]===after.text[at])at++;
    while(endBefore>at && endAfter>at && before.text[endBefore-1]===after.text[endAfter-1]){endBefore--;endAfter--;}
    this.past.push({at,removed:before.text.slice(at,endBefore),inserted:after.text.slice(at,endAfter),before:selection(before),after:selection(after)});
    this.future=[];
    return true;
  }
  amend(before:EditSnapshot,after:EditSnapshot,recorded:boolean){if(recorded)this.past.pop();this.record(before,after);}
  undo(current:EditSnapshot){
    const edit=this.past.pop();if(!edit)return null;
    this.future.push(edit);
    return {...edit.before,text:current.text.slice(0,edit.at)+edit.removed+current.text.slice(edit.at+edit.inserted.length)};
  }
  redo(current:EditSnapshot){
    const edit=this.future.pop();if(!edit)return null;
    this.past.push(edit);
    return {...edit.after,text:current.text.slice(0,edit.at)+edit.inserted+current.text.slice(edit.at+edit.removed.length)};
  }
}
