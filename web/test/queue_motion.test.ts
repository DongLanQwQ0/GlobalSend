import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseHTML} from 'linkedom';
import {QueueMotion} from '../src/queue_motion.ts';

test('new queue entries enter once; rebuilds continue the same animation and removed entries may return',()=>{
  const {document}=parseHTML('<main></main>');const root=document.querySelector('main')!;
  const motion=new QueueMotion(170,()=>true);
  const render=(keys:string[],now:number)=>{root.innerHTML=keys.map(key=>`<article data-queue-entry="${key}"></article>`).join('');motion.apply(root,keys,now);return Array.from(root.children) as unknown as HTMLElement[];};
  let [old]=render(['text:one'],0);assert.ok(old.classList.contains('queue-appear'));
  [old]=render(['text:one'],80);assert.equal(old.style.animationDelay,'-80ms');
  const [fresh,retained]=render(['text:two','text:one'],200);
  assert.ok(fresh.classList.contains('queue-appear'));assert.ok(!retained.classList.contains('queue-appear'));
  render([],300);[old]=render(['text:one'],400);assert.equal(old.style.animationDelay,'-0ms');
});
test('an entry hidden on another page starts when it is actually displayed',()=>{
  const {document}=parseHTML('<main><article data-queue-entry="file:one"></article></main>');
  const root=document.querySelector('main')!;let visible=false;const motion=new QueueMotion(170,()=>visible);
  motion.apply(root,['file:one'],0);assert.ok(!root.firstElementChild!.classList.contains('queue-appear'));
  visible=true;motion.apply(root,['file:one'],5000);assert.equal((root.firstElementChild as unknown as HTMLElement).style.animationDelay,'-0ms');
});
