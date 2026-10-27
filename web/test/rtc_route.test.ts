import test from 'node:test';
import assert from 'node:assert/strict';
import { ConnectAttempt, DirectConnectionBudget, preferredScopes } from '../src/rtc_route.ts';

test('automatic decision shares one second across LAN and public instead of spending it twice',()=>{
  let now=1000;const budget=new DirectConnectionBudget(true,()=>now);
  assert.equal(budget.window(2),500);now+=520;assert.equal(budget.window(1),480);now+=480;assert.equal(budget.remaining(),0);
});
test('forced direct route keeps its direct-only connection window and a later disconnection gets a fresh decision',()=>{
  let now=1000;const forced=new DirectConnectionBudget(false,()=>now);assert.equal(forced.window(1),15000);now+=16000;assert.equal(forced.remaining(),0);forced.resumeAfterDisconnect();assert.equal(forced.remaining(),15000);
});
test('only current successful probe evidence can prioritize public over known-failed LAN',()=>{
  const now=Date.now(),result=(scope:'lan'|'public',success:boolean,expiresAt=new Date(now+1000).toISOString())=>({scope,success,expiresAt,initiatorDeviceId:'self',responderDeviceId:'peer'});
  assert.deepEqual(preferredScopes(['lan','public'],[result('public',true)],'self','peer',now),['lan','public']);
  assert.deepEqual(preferredScopes(['lan','public'],[result('public',true),result('lan',false)],'self','peer',now),['public','lan']);
  assert.deepEqual(preferredScopes(['lan','public'],[result('public',true),result('lan',true)],'self','peer',now),['lan','public']);
  assert.deepEqual(preferredScopes(['lan','public'],[result('public',true,new Date(now-1).toISOString()),result('lan',false)],'self','peer',now),['lan','public']);
});
test('connect timeout really aborts its signal and late signaling cannot win the canceled attempt',async()=>{
  const parent=new AbortController(),attempt=new ConnectAttempt(parent.signal,10);let finish!:(value:number)=>void;
  const work=new Promise<number>(resolve=>{finish=resolve;});
  await assert.rejects(attempt.wait(work),{name:'AbortError'});assert.equal(attempt.signal.aborted,true);assert.equal(attempt.timedOut,true);finish(12);await Promise.resolve();assert.equal(attempt.connected,false);attempt.dispose();
});
test('opening the data channel cancels only its connection deadline, not parent cancellation',async()=>{
  const parent=new AbortController(),attempt=new ConnectAttempt(parent.signal,5);attempt.opened();
  await new Promise(resolve=>setTimeout(resolve,15));assert.equal(attempt.signal.aborted,false);assert.equal(attempt.connected,true);
  const pending=attempt.wait(new Promise<void>(()=>{}));parent.abort();await assert.rejects(pending,{name:'AbortError'});assert.equal(attempt.signal.aborted,true);attempt.dispose();
});
