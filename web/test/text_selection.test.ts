import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import { enableTextSelection, isTextSelectionTarget, textSelectionActive } from '../src/text_selection.ts';

test('read-only text stays draggable while an actual editor retains native selection',()=>{
  const {document,Event}=parseHTML('<article draggable="true" data-drag-text="one"><div class="selectable-text">只读正文</div><textarea class="selectable-text">可编辑正文</textarea><span id="blank">空白区域</span></article>').window;
  enableTextSelection(document);
  const card=document.querySelector('article')!,text=document.querySelector('div')!;
  assert.equal(isTextSelectionTarget(text),false);
  text.dispatchEvent(new Event('pointerdown',{bubbles:true}));
  assert.equal(textSelectionActive(document),false);
  assert.equal(card.getAttribute('draggable'),'true');
  document.dispatchEvent(new Event('pointerup'));
  document.querySelector('textarea')!.dispatchEvent(new Event('pointerdown',{bubbles:true}));
  assert.equal(textSelectionActive(document),true);
  assert.equal(card.getAttribute('draggable'),'false');
  document.dispatchEvent(new Event('pointerup'));
  assert.equal(textSelectionActive(document),false);
  assert.equal(card.getAttribute('draggable'),'true');
  document.querySelector('#blank')!.dispatchEvent(new Event('pointerdown',{bubbles:true}));
  assert.equal(card.getAttribute('draggable'),'true');
});
