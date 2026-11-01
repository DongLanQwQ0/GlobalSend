import {escapeHtml as e} from './model.ts';
import {icon} from './icons.ts';
import {userGuides} from './user_guide_content.ts';

export function userGuideHtml(selected=0):string {
  const guide=userGuides.web;
  const topic=Math.max(0,Math.min(guide.sections.length-1,selected));
  const section=guide.sections[topic];
  return `<div class="modal-backdrop"><section class="modal user-guide-modal" role="dialog" aria-modal="true" aria-labelledby="user-guide-title" tabindex="-1"><div class="modal-header"><h2 id="user-guide-title">使用指南</h2><button class="icon-button quiet" data-action="close-modal" aria-label="关闭使用指南">${icon('close')}</button></div><p class="user-guide-platform">${e(guide.name)}</p><p class="user-guide-intro">${e(guide.intro)}</p><div class="user-guide-topics" aria-label="教程主题">${guide.sections.map((item,index)=>`<button type="button" class="quiet ${index===topic?'selected':''}" data-guide-topic="${index}" aria-pressed="${index===topic}">${e(item.title)}</button>`).join('')}</div><section class="user-guide-section" aria-live="polite" aria-atomic="true"><h3>${e(section.title)}</h3><ol>${section.steps.map(step=>`<li>${e(step)}</li>`).join('')}</ol></section></section></div>`;
}
