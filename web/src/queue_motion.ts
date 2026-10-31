/** Queue DOM is rebuilt for progress updates; keep each entry's arrival clock. */
export class QueueMotion {
  private readonly entered=new Map<string,number>();
  private readonly duration:number;
  private readonly visible:(node:HTMLElement)=>boolean;
  constructor(duration=170,visible=(node:HTMLElement)=>node.getClientRects().length>0) {
    this.duration=duration;
    this.visible=visible;
  }
  apply(root:ParentNode,identities:Iterable<string>,now=Date.now()) {
    const current=new Set(identities);
    for(const key of this.entered.keys())if(!current.has(key))this.entered.delete(key);
    for(const node of root.querySelectorAll<HTMLElement>('[data-queue-entry]')) {
      const key=node.dataset.queueEntry!;
      if(!current.has(key) || !this.visible(node))continue;
      if(!this.entered.has(key))this.entered.set(key,now);
      const elapsed=now-this.entered.get(key)!;
      if(elapsed>=this.duration)continue;
      node.classList.add('queue-appear');
      node.style.animationDelay=`-${elapsed}ms`;
    }
  }
}
