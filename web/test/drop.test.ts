import test from 'node:test';
import assert from 'node:assert/strict';
import {parseHTML} from 'linkedom';
import {acceptsWindowDrop,droppedText,WindowDropFeedback,dropTargetAt,DropFeedback} from '../src/drop.ts';

test('drop feedback identifies the actual device and excludes the clipboard suggestion',()=>{
  const {document}=parseHTML('<main><section data-queue-drop><article class="clipboard-suggestion"><button id="suggestion">剪贴板</button></article><span id="queue">待发</span></section><div class="target-devices"><button data-target="peer"><span id="device">设备</span></button><button data-target="busy" disabled><span id="busy">发送中</span></button></div><header>GlobalSend</header></main>');
  assert.deepEqual(dropTargetAt(document.querySelector('#device')),{kind:'device',deviceId:'peer'});
  assert.deepEqual(dropTargetAt(document.querySelector('#busy')),{kind:'blocked'});
  assert.deepEqual(dropTargetAt(document.querySelector('#suggestion')),{kind:'blocked'});
  assert.deepEqual(dropTargetAt(document.querySelector('#queue')),{kind:'queue'});
  assert.deepEqual(dropTargetAt(document.querySelector('.target-devices')),{kind:'window'});
});

test('device and queue feedback replace window feedback immediately without transient child-leave resets',async()=>{
  const states:unknown[]=[],feedback=new DropFeedback(target=>states.push(target));
  feedback.enter({kind:'window'});feedback.leave();feedback.enter({kind:'device',deviceId:'peer'});
  await new Promise(resolve=>setTimeout(resolve,120));assert.deepEqual(states,[{kind:'window'},{kind:'device',deviceId:'peer'}]);
  feedback.enter({kind:'queue'});feedback.enter({kind:'blocked'});feedback.leave();
  await new Promise(resolve=>setTimeout(resolve,120));assert.equal(states.at(-1),null);
  feedback.enter({kind:'device',deviceId:'peer'});feedback.leave();feedback.reset();const count=states.length;
  await new Promise(resolve=>setTimeout(resolve,120));assert.equal(states.length,count);
});

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
