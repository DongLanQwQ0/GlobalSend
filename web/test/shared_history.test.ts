import test from 'node:test';
import assert from 'node:assert/strict';
import {SharedEditHistory} from '../src/shared_history.ts';
import type {EditSnapshot} from '../src/shared_history.ts';

const state=(text:string,start=text.length,end=start,direction:EditSnapshot['direction']='none'):EditSnapshot=>({text,start,end,direction,scrollTop:12});
test('local history reverses only changed spans and restores replacement selections',()=>{
  const history=new SharedEditHistory(),before=state('你好😀世界',2,4,'backward'),after=state('你好🌍世界',4);
  history.record(before,after);assert.equal(history.canUndo,true);assert.deepEqual(history.undo(after),before);assert.equal(history.canUndo,false);assert.equal(history.canRedo,true);assert.deepEqual(history.redo(before),after);
});
test('new local edits clear redo while an unchanged input does not',()=>{
  const history=new SharedEditHistory(),a=state('a'),ab=state('ab');history.record(a,ab);history.undo(ab);history.record(a,a);assert.equal(history.canRedo,true);history.record(a,state('ac'));assert.equal(history.canRedo,false);assert.equal(history.undo(state('ac'))!.text,'a');
});
test('a composition final input amends the same transaction instead of splitting or corrupting it',()=>{
  const history=new SharedEditHistory(),before=state('原文'),intermediate=state('原文中'),after=state('原文中文。');const recorded=history.record(before,intermediate);history.amend(before,after,recorded);assert.deepEqual(history.undo(after),before);assert.equal(history.canUndo,false);assert.deepEqual(history.redo(before),after);
});
test('synchronized changes remain undoable along with earlier local edits',()=>{
  const history=new SharedEditHistory();history.record(state('原文'),state('本地'));history.record(state('本地'),state('远端'));
  assert.equal(history.undo(state('远端'))!.text,'本地');assert.equal(history.undo(state('本地'))!.text,'原文');
  assert.equal(history.redo(state('原文'))!.text,'本地');assert.equal(history.redo(state('本地'))!.text,'远端');
  history.record(state('远端'),state('远端'));assert.equal(history.undo(state('远端'))!.text,'本地');
});
test('switching to another document explicitly resets its history',()=>{
  const history=new SharedEditHistory();history.record(state('原文'),state('本地'));history.clear();
  assert.equal(history.canUndo,false);assert.equal(history.canRedo,false);
});
