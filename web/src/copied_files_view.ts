import type { CopiedFilesReceiver } from './copied_files';
import { escapeHtml as e } from './model.ts';
import { icon } from './icons.ts';

export function copiedFilesHtml(receiver:CopiedFilesReceiver,leading=''){
  const cards=receiver.references.map(({id,item,offer,state,error,localKey})=>{
    const busy=state==='pending' || state==='sending';
    return `<article class="copied-file-reference${busy?' pending':''}${state==='failed'?' failed':''}" data-copied-reference="${e(id)}" ${localKey?`draggable="true" data-drag-file="${e(localKey)}"`:""}><button class="copied-file-pull" data-action="pull-copied-file" data-copied-id="${e(id)}" ${busy?'disabled':''} aria-label="${localKey?"打开":"拉取"} ${e(item.name)}">${icon(item.kind==='directory'?'folder':'file')}<span><strong>${e(item.name)}</strong><small title="${e(error)}">${busy?'正在准备':state==='failed'?'拉取失败':e(offer.sourceName)}</small></span></button><span class="copied-file-action" aria-hidden="true">${icon(state==='received'?'open':state==='failed'?'refresh':'down')}</span><button class="icon-button quiet" data-action="dismiss-copied-file" data-copied-id="${e(id)}" aria-label="忽略此条目">${icon('close')}</button></article>`;
  }).join('');
  return (cards || leading?`<div class="copied-file-list" aria-label="共享内容">${leading}${cards}</div>`:'')+(receiver.error?`<div class="copied-file-error" role="status">${e(receiver.error)}<button class="quiet" data-action="refresh-copied-files">重试</button></div>`:'');
}
