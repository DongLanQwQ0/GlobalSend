import test from 'node:test';
import assert from 'node:assert/strict';
import {ClipboardSlot} from '../src/clipboard_slot.ts';
test('latest source replaces the single persisted receiver slot and receive disabling is independent',()=>{
 let stored='';const slot=new ClipboardSlot(()=>stored,value=>stored=value);
 assert.equal(slot.receive({id:'a',source:'one',at:'2026-01-01',text:'first'}),true);
 assert.equal(slot.receive({id:'b',source:'two',at:'2026-01-02',text:'second'}),true);
 assert.equal(slot.current?.text,'second');assert.equal(slot.receive({id:'old',source:'one',at:'2026-01-01',text:'old'}),false);
 slot.setEnabled(false);assert.equal(slot.receive({id:'c',source:'three',at:'2026-01-03',text:'ignored'}),false);
 const restored=new ClipboardSlot(()=>stored,value=>stored=value);assert.equal(restored.current,null);restored.setEnabled(true);assert.equal(restored.current?.text,'second');restored.clear();assert.equal(restored.current,null);
});
