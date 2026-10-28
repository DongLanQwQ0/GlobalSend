/** Keep the same center hotspot for text, images and batch drag previews. */
export function centeredDragImage(event:DragEvent,ghost:HTMLElement){
  if(!event.dataTransfer)return;
  ghost.ownerDocument.body.append(ghost);
  const bounds=ghost.getBoundingClientRect();
  const x=bounds.width/2,y=bounds.height/2;
  ghost.style.left=Math.max(0,event.clientX-x)+'px';
  ghost.style.top=Math.max(0,event.clientY-y)+'px';
  event.dataTransfer.setDragImage(ghost,x,y);
  setTimeout(()=>ghost.remove(),0);
}
