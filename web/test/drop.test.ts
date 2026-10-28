import test from 'node:test';
import assert from 'node:assert/strict';
import {acceptsWindowDrop,droppedText,WindowDropFeedback} from '../src/drop.ts';

test('drop snapshots text and callback-only strings inside the readable event',async()=>{
  let readable=true;const calls:string[]=[];
  const plain=droppedText({getData(type:string){assert.equal(readable,true);calls.push(type);return type==='text/plain'?'  正文\n原样  ':'';},items:[]} as any);readable=false;
  assert.equal(await plain,'  正文\n原样  ');assert.ok(calls.includes('text/uri-list'));
  readable=true;const callback=droppedText({getData(){assert.equal(readable,true);return '';},items:[{kind:'string',type:'text/plain',getAsString(done:any){assert.equal(readable,true);queueMicrotask(()=>done('跨程序文本'));}}]} as any);readable=false;
  assert.equal(await callback,'跨程序文本');
});

test('drop feedback cancels transient native child leaves and hides on a real exit or cancellation',async()=>{
  const states:boolean[]=[],feedback=new WindowDropFeedback(value=>states.push(value));
  feedback.enter();feedback.leave();await new Promise(resolve=>setTimeout(resolve,20));feedback.enter();
  await new Promise(resolve=>setTimeout(resolve,120));assert.equal(states.includes(false),false);
  feedback.leave();await new Promise(resolve=>setTimeout(resolve,120));assert.equal(states.at(-1),false);
  feedback.enter();feedback.leave();feedback.reset();const count=states.length;await new Promise(resolve=>setTimeout(resolve,120));assert.equal(states.length,count);
  assert.equal(acceptsWindowDrop({types:['Files'],files:[]} as any),true);assert.equal(acceptsWindowDrop({types:['text/uri-list'],files:[]} as any),true);
});
