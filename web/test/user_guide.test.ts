import assert from 'node:assert/strict';
import {test} from 'node:test';
import {parseHTML} from 'linkedom';
import {userGuideHtml} from '../src/user_guide.ts';
import {userGuides} from '../src/user_guide_content.ts';

test('Web guide shows one task at a time with accessible topic buttons',()=>{
  const {document}=parseHTML(userGuideHtml(1));
  assert.equal(document.querySelector('[role="dialog"]')?.getAttribute('aria-labelledby'),'user-guide-title');
  assert.equal(document.querySelector('[aria-pressed="true"]')?.getAttribute('data-guide-topic'),'1');
  assert.equal(document.querySelectorAll('.user-guide-section').length,1);
  assert.equal(document.querySelector('.user-guide-section h3')?.textContent,'剪贴板与拖放');
  assert.equal(document.querySelectorAll('.user-guide-section li').length,userGuides.web.sections[1].steps.length);
  assert.ok(document.querySelector('[data-action="close-modal"]'));
});

test('Guides distinguish Android dock, iPad sharing and Web restrictions',()=>{
  const content=(key:keyof typeof userGuides)=>JSON.stringify(userGuides[key]);
  assert.match(content('android'),/悬停 1 秒/);
  assert.match(content('android'),/3 秒/);
  assert.match(content('android'),/30 秒/);
  assert.match(content('ipad'),/系统决定/);
  assert.match(content('windows'),/文件复制推送/);
  assert.match(content('web'),/不能由网页强制永久隐藏/);
  assert.doesNotMatch(content('web'),/开启悬浮窗/);
  assert.equal(parseHTML(userGuideHtml(999)).document.querySelector('[aria-pressed="true"]')?.getAttribute('data-guide-topic'),String(userGuides.web.sections.length-1));
});
