(() => {
  'use strict';
  const { platforms, groups, modules, features, journeys, decisions, pending } = window.ATLAS_DATA;
  const state = { platform: 'windows', mode: 'proposed', group: 'all', query: '', onlySupported: false, journey: 'quick' };
  const $ = selector => document.querySelector(selector);
  const escape = value => String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
  const icon = name => name === 'search'
    ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><circle cx="10.5" cy="10.5" r="7"/><path d="m16 16 5 5"/></svg>'
    : GlobalSendIcons.icon(name);
  const byId = id => features.find(feature => feature.id === id);
  const platform = () => platforms.find(item => item.id === state.platform);
  const related = ids => `<div class="related">${ids.map(id => `<button data-feature="${id}">${escape(byId(id).name)} ↗</button>`).join('')}</div>`;
  const hotspot = (id, body, className = '') => `<button class="hotspot ${className}" data-feature="${id}" aria-label="查看${escape(byId(id).name)}">${body}</button>`;
  const mockButton = (id, label, name) => `<button data-feature="${id}">${icon(name)}${label}</button>`;
  const draft = () => `<div class="mock-label"><span>待发送 · 1</span><button data-feature="compose">＋ 文件</button></div><div class="mock-draft">${hotspot('compose', `${icon('file')}<span>讨论稿.md</span>`, 'mini-card')}${hotspot('suggestions', `${icon('copy')}<span>剪贴板<br>点按添加</span>`, 'mini-card suggest')}</div>`;
  const deviceArea = () => `<div class="mock-label"><span>设备 · 2</span><button data-feature="discovery">刷新　多选</button></div><div class="mock-devices">${hotspot('device',`${icon('phone')}<span>手机</span>`,'mock-device')}${hotspot('drop',`${icon('tablet')}<span>iPad</span>`,'mock-device')}</div>${state.mode === 'proposed' ? hotspot('clipboard',state.platform === 'windows' ? '设备自动化　同步 / 文件引用　→' : '设备共享　最新同步 / 文件引用　→','mock-ref') : ''}`;
  const sharedArea = () => `${hotspot('shared-text','<strong>组内共享　↶　↷</strong>在这里共同编辑…','mock-shared')}${hotspot('references',`${icon('folder')}<span>项目资料　·　${state.mode === 'proposed' ? '远程引用，点击拉取' : '来自电脑'}</span>`,'mock-ref')}`;
  function contentPanel() {
    return `<section class="mock-panel"><div class="mock-nav">${mockButton('receive','接收','down')}${mockButton('history','已发送','history')}${mockButton('library','文件库','folder')}</div>${hotspot('clipboard',`${icon('copy')}<strong>最新同步</strong>　这一份保持最新`,'mock-slot')}<div class="mock-label"><span>2 项</span><button data-feature="library">筛选　多选</button></div><div class="mock-grid">${hotspot('preview','<p>把手里的内容，<br>直接交给设备。</p><small>手机 · 14:30</small>','mock-file')}${hotspot('receive',`<div class="mock-picture">${icon('image')}</div><small>iPad · 14:28</small>`,'mock-file')}</div></section>`;
  }
  function desktopMap() {
    const web = state.platform === 'web';
    const actions = state.mode === 'proposed'
      ? `${mockButton('compose','文本','text')}${mockButton('suggestions','剪贴板','copy')}${mockButton('compose','文件','file')}`
      : `${mockButton('compose','文本','text')}${mockButton('suggestions','剪贴板','copy')}`;
    return `<div class="window"><div class="window-bar"><div class="window-title"><i></i><span class="window-brand">GlobalSend${web ? ' / Web' : ''}</span></div><div class="mock-actions">${actions}${mockButton('discovery','','link')}${mockButton('appearance','','settings')}</div></div><div class="mock-body"><section class="mock-panel">${draft()}${deviceArea()}${sharedArea()}</section>${contentPanel()}</div></div>`;
  }
  function phoneMap() {
    const android = state.platform === 'android';
    return `<div class="mobile-workspace"><div class="phone"><div class="window"><div class="window-bar"><span class="window-brand">GlobalSend</span><div class="mock-actions">${mockButton('discovery','','link')}${mockButton('appearance','','settings')}</div></div><div class="mock-body"><div class="mock-split">${mockButton('compose','文本','text')}${mockButton('suggestions','剪贴板','copy')}${mockButton('folder','文件','file')}${mockButton('share','媒体','image')}</div><section class="mock-panel">${draft()}</section><div style="margin-top:12px">${deviceArea()}</div>${sharedArea()}</div><div class="mock-nav">${mockButton('device','发送','arrow')}${mockButton('receive','接收','down')}${mockButton('history','历史','history')}${mockButton('library','文件','folder')}</div></div></div><div class="side-scene"><h4>${android ? '应用外：悬浮暂存坞' : '应用外：系统分享'}</h4>${android ? `<div class="dock-demo"><div class="dock-cards">${hotspot('android-shelf',`${icon('image')}<span>本地图片</span>`,'mini-card')}${hotspot('references',`${icon('folder')}<span>远程引用</span>`,'mini-card')}</div><div class="dock-controls">${mockButton('android-shelf','1','down')}${mockButton('android-shelf','1','folder')}${mockButton('drop','','drag')}</div></div><div class="dock-handle"><i></i></div>` : `<div class="share-demo">${icon('file')}<div class="mock-split">${mockButton('share','GlobalSend','arrow')}${mockButton('device','指定设备','phone')}</div></div>`}<p>${android ? '接收与暂存分开。<br>双击空白回应用；<br>悬停2秒转设备投递。' : '系统分享导入待发送。<br>系统决定设备建议，<br>不模拟Android悬浮窗。'}</p>${hotspot(android ? 'android-shelf' : 'share', '查看操作说明 ↗', 'text-button')}</div></div>`;
  }
  function renderLayout() {
    const p = platform();
    $('#platform-intro').innerHTML = `<h3>${escape(p.name)} · ${escape(p.context)}</h3><p>${escape(p.summary)}</p>`;
    $('#workspace').innerHTML = ['android','ios'].includes(p.id) ? phoneMap() : desktopMap();
    const notes = state.mode === 'current'
      ? [['分散的配置','同步和文件复制推送从设置进入，目标选择远离设备卡。'],['混合的状态','共享文本、文件引用、建议和自动槽位需要被分别理解。'],['不同的系统边界',p.constraint]]
      : [['高频动作不躲藏','内容 → 设备。拖着内容时，设备卡就是发送入口。'],['配置跟着目标走','设备相关自动化提供就近入口，仍保存到同一份设置。'],['状态各有位置',p.constraint]];
    $('#map-notes').innerHTML = notes.map(([title,text],i) => `<div class="map-note"><span>0${i+1}</span><div><strong>${escape(title)}</strong><p>${escape(text)}</p></div></div>`).join('');
    document.querySelector('.layout-caption').innerHTML = `<span>${state.mode === 'current' ? '当前入口示意' : '建议布局 · 尚未实施'}</span>点击区域查看功能。${p.id === 'ipados' ? '此为宽屏示意；窄窗口仍按实际空间适配。' : ''}示意设备和文件不是实际数据。`;
    $('#workspace').classList.remove('enter');
    requestAnimationFrame(() => $('#workspace').classList.add('enter'));
  }
  function supportLabel(feature) {
    if (!feature.support.includes(state.platform)) return '本平台无此原生能力';
    if (feature.sourceOnly) return feature.sourceOnly.includes(state.platform) ? '可作为来源与接收端' : '可接收 · 来源为 Windows';
    return state.platform === 'web' && feature.id === 'suggestions' ? '剪贴板建议可用' : '本平台已实现';
  }
  function renderCatalog() {
    const q = state.query.trim().toLowerCase();
    const list = features.filter(feature =>
      (state.group === 'all' || feature.group === state.group) &&
      (!state.onlySupported || feature.support.includes(state.platform)) &&
      (!q || [feature.name, feature.description, feature.current, feature.proposed, ...feature.steps, ...Object.values(feature.differences || {})].join(' ').toLowerCase().includes(q))
    );
    $('#catalog-count').textContent = `${platform().name} · ${list.length} / ${features.length} 项`;
    $('#feature-list').innerHTML = list.map(feature => `<button class="feature-card ${feature.support.includes(state.platform) ? '' : 'unavailable'}" data-feature="${feature.id}"><span class="feature-icon">${icon(feature.icon)}</span><div><h3>${escape(feature.name)}</h3><p>${escape(feature.description)}</p><span class="badge">${supportLabel(feature)}</span></div><span class="arrow-icon">↗</span></button>`).join('');
    $('#empty').hidden = list.length > 0;
    document.querySelectorAll('[data-group]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.group === state.group)));
  }
  function renderJourney() {
    const journey = journeys.find(item => item.id === state.journey);
    const steps = journey.platformSteps?.[state.platform] || journey.steps;
    $('#journey-tabs').innerHTML = journeys.map((item,i) => `<button role="tab" id="journey-${item.id}" aria-controls="journey-body" aria-selected="${item.id === state.journey}" tabindex="${item.id === state.journey ? 0 : -1}" data-journey="${item.id}"><span>0${i+1}</span>${escape(item.name)}</button>`).join('');
    $('#journey-body').setAttribute('aria-labelledby', `journey-${journey.id}`);
    $('#journey-body').innerHTML = `<h3>${escape(journey.goal)}</h3><ol class="journey-steps">${steps.map((step,i) => `<li><b>${i+1}</b><span>${escape(step)}</span></li>`).join('')}</ol>${related(journey.ids)}<p class="small-meta">${escape(platform().name)}：${escape(platform().constraint)}</p>`;
  }
  function renderComparison() {
    const rows = [
      ['自动监听本机复制','文字 / 截图','无持续监听来源','无持续监听来源','无持续监听来源','无持续监听来源'],
      ['接收自动同步槽位','支持','支持','支持','支持','支持'],
      ['系统图片写入','保留','关闭','关闭','保留','按宿主与授权'],
      ['文件复制推送来源','支持','仅接收引用','仅接收引用','仅接收引用','仅接收引用'],
      ['未下载引用拖放','原生提供方','原生提供方','原生提供方¹','原生提供方¹','先拉取再拖'],
      ['应用外中转','独立接收坞','悬浮暂存坞','系统分享 / 前台','系统分享 / 多任务','保持网页打开'],
      ['后台持续接收','托盘核心','服务 / 系统调度','不保证','前台 / 多任务','不保证关页接收'],
      ['更新安装','完整包自动替换¹','系统确认¹','手动签名IPA','手动签名IPA','刷新已部署网页'],
    ];
    $('#comparison').innerHTML = `<div class="table-scroll"><table><caption class="small-meta" style="text-align:left;padding:12px">实现能力对照，不等同于所有第三方应用已验收</caption><thead><tr><th scope="col">能力</th>${platforms.map(p=>`<th scope="col">${p.name}</th>`).join('')}</tr></thead><tbody>${rows.map(row=>`<tr>${row.map((cell,i)=>i===0?`<th scope="row">${cell}</th>`:`<td>${cell}</td>`).join('')}</tr>`).join('')}</tbody></table></div><p class="small-meta">¹ 提供方或流程已有实现/检查，真实系统场景仍见“待验收项”。iOS与iPadOS共用IPA，但不能共用一份实机结论。</p>`;
  }
  function renderDecisions() {
    $('#decision-list').innerHTML = decisions.map(item=>`<article class="decision"><span class="decision-priority">${item.priority}</span><div><h3>${escape(item.title)}</h3><p>${escape(item.reason)}</p></div><div class="decision-change"><strong>建议这样调整</strong><p>${escape(item.change)}</p><small>保留：${escape(item.keep)}</small>${related(item.ids)}</div></article>`).join('');
    $('#pending-list').innerHTML = pending.map(item=>`<article class="pending"><span>${escape(item.platform)}</span><div><h3>${escape(item.item)}</h3><span class="status">${escape(item.state)}</span><p>${escape(item.next)}</p></div></article>`).join('');
  }
  function renderModules() {
    $('#module-list').innerHTML = modules.map(item=>`<article class="module-card" data-module="${item.id}"><div class="module-heading"><span>${icon(item.icon)}</span><small>${escape(item.english)}</small></div><h3>${escape(item.name)}</h3><p class="module-purpose">${escape(item.purpose)}</p><p class="module-scene">${escape(item.scene)}</p><div class="module-primary"><span>主任务</span><strong>${escape(item.primary)}</strong></div><ul>${item.owns.map(text=>`<li>${escape(text)}</li>`).join('')}</ul><details><summary>生命周期与交接</summary><dl><dt>内容如何保留</dt><dd>${escape(item.lifecycle)}</dd><dt>何时回主界面</dt><dd>${escape(item.handoff)}</dd><dt>空间与形态</dt><dd>${escape(item.geometry)}</dd></dl></details><p class="module-rule">${escape(item.rule)}</p>${related(item.ids)}</article>`).join('');
  }
  let closing = false;
  let closeAnimationHandler;
  function openDetail(id) {
    const feature = byId(id);
    if (!feature) return;
    const p = platform(), supported = feature.support.includes(p.id);
    $('#detail-eyebrow').textContent = `${p.name} / ${groups.find(group => group.id === feature.group).name}`;
    const difference = feature.differences?.[p.id] || (supported ? '保持统一的内容与状态语义；具体系统操作按当前平台能力执行。' : '此平台没有对应原生能力。请使用本平台已有的收发、系统分享或前台页面。');
    $('#detail-body').innerHTML = `<div class="detail-icon">${icon(feature.icon)}</div><h2 id="detail-title">${escape(feature.name)}</h2><p class="detail-description">${escape(feature.description)}</p><div class="detail-platform"><strong>${escape(p.name)} · ${supportLabel(feature)}</strong><p>${escape(difference)}</p></div><div class="entry-compare"><div><h3>现有入口</h3><p>${escape(feature.current)}</p></div><div><h3>建议入口 · 待讨论</h3><p>${escape(feature.proposed)}</p></div></div><section class="detail-section"><h3>怎么用</h3><ol>${feature.steps.map(step=>`<li>${escape(step)}</li>`).join('')}</ol></section>${feature.note ? `<div class="detail-note">${escape(feature.note)}</div>` : ''}${feature.evidence ? `<p class="detail-evidence">验收依据：${escape(feature.evidence)}</p>` : '<p class="detail-evidence">实现与检查依据见下方文档；本页不新增实机验收结论。</p>'}<section class="detail-section"><h3>依据与进一步说明</h3><div class="sources">${feature.sources.map(source=>`<a href="https://github.com/DongLanQwQ0/GlobalSend/blob/490c5a3/docs/${encodeURI(source)}" target="_blank" rel="noopener">${escape(source)} ↗</a>`).join('')}</div></section>`;
    const dialog = $('#feature-dialog');
    closing = false; dialog.classList.remove('closing');
    if (!dialog.open) dialog.showModal();
    dialog.scrollTop = 0;
    $('#close-detail').focus({preventScroll:true});
  }
  function closeDetail() {
    const dialog = $('#feature-dialog');
    if (!dialog.open || closing) return;
    closing = true;
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) { dialog.close(); closing = false; return; }
    dialog.classList.add('closing');
    closeAnimationHandler = event => {
      if (event.target !== dialog || event.animationName !== 'modal-out' || event.pseudoElement) return;
      dialog.removeEventListener('animationend',closeAnimationHandler);
      closeAnimationHandler = undefined;
      dialog.close();
    };
    dialog.addEventListener('animationend',closeAnimationHandler);
  }
  function selectPlatform(id, focus = false) {
    state.platform = id;
    $('#catalog-platform').value = id;
    document.querySelectorAll('[data-platform]').forEach(button=>{
      button.setAttribute('aria-selected', String(button.dataset.platform === id));
      button.tabIndex = button.dataset.platform === id ? 0 : -1;
    });
    if (focus) $(`[data-platform="${id}"]`).focus();
    renderLayout(); renderCatalog(); renderJourney();
  }
  $('#platforms').innerHTML = platforms.map(p=>`<button role="tab" data-platform="${p.id}" aria-selected="${state.platform === p.id}" aria-controls="layout" tabindex="${state.platform === p.id ? 0 : -1}">${icon(p.icon)}${p.name}</button>`).join('');
  $('#catalog-platform').innerHTML = platforms.map(p=>`<option value="${p.id}">${p.name}</option>`).join('');
  $('#catalog-platform').addEventListener('change', event=>selectPlatform(event.target.value));
  $('#group-tabs').innerHTML = [{id:'all',name:'全部'},...groups].map(group=>`<button data-group="${group.id}" aria-pressed="${group.id === state.group}">${group.name}</button>`).join('');
  document.querySelectorAll('[data-icon]').forEach(node=>{ node.innerHTML = icon(node.dataset.icon); });
  $('#close-detail').innerHTML = icon('close');
  document.addEventListener('click', event => {
    const target = event.target.closest('button');
    if (!target) return;
    if (target.dataset.platform) selectPlatform(target.dataset.platform);
    if (target.dataset.mode) {
      state.mode = target.dataset.mode;
      document.querySelectorAll('[data-mode]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.mode===state.mode)));
      renderLayout();
    }
    if (target.dataset.feature) openDetail(target.dataset.feature);
    if (target.dataset.group) { state.group=target.dataset.group; renderCatalog(); }
    if (target.dataset.journey) { state.journey=target.dataset.journey; renderJourney(); $(`[data-journey="${state.journey}"]`).focus({preventScroll:true}); }
  });
  $('#search').addEventListener('input', event => { state.query = event.target.value; renderCatalog(); });
  $('#only-supported').addEventListener('change', event => { state.onlySupported = event.target.checked; renderCatalog(); });
  $('#reset-filter').addEventListener('click', () => { state.query=''; state.group='all'; $('#search').value=''; renderCatalog(); $('#search').focus(); });
  $('#close-detail').addEventListener('click', closeDetail);
  $('#feature-dialog').addEventListener('close', () => {
    if (closeAnimationHandler) $('#feature-dialog').removeEventListener('animationend',closeAnimationHandler);
    closeAnimationHandler=undefined;
    $('#feature-dialog').classList.remove('closing');
    closing=false;
  });
  $('#feature-dialog').addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    event.preventDefault(); event.stopPropagation(); closeDetail();
  });
  $('#feature-dialog').addEventListener('cancel', event => { event.preventDefault(); closeDetail(); });
  let backdropStart = false;
  $('#feature-dialog').addEventListener('pointerdown', event=>{
    const rect=event.currentTarget.getBoundingClientRect();
    backdropStart = event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom;
  });
  $('#feature-dialog').addEventListener('click', event=>{
    const rect=event.currentTarget.getBoundingClientRect();
    if (backdropStart && (event.clientX<rect.left || event.clientX>rect.right || event.clientY<rect.top || event.clientY>rect.bottom)) closeDetail();
    backdropStart=false;
  });
  document.addEventListener('keydown',event=>{
    if (event.key==='/' && !$('#feature-dialog').open && !['INPUT','TEXTAREA'].includes(document.activeElement.tagName)) { event.preventDefault(); $('#search').focus(); }
    const tab=event.target.closest('[role="tab"]');
    if (!tab || !['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
    const parent=tab.closest('[role="tablist"]'), tabs=[...parent.querySelectorAll('[role="tab"]')];
    let index=tabs.indexOf(tab);
    index=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+(event.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;
    event.preventDefault();
    if (tabs[index].dataset.platform) selectPlatform(tabs[index].dataset.platform,true);
    else { state.journey=tabs[index].dataset.journey; renderJourney(); $(`[data-journey="${state.journey}"]`).focus(); }
  });
  const observer=new IntersectionObserver(entries=>{
    const active=entries.filter(entry=>entry.isIntersecting).sort((a,b)=>a.boundingClientRect.top-b.boundingClientRect.top)[0];
    if (!active) return;
    document.querySelectorAll('.rail nav a').forEach(link=>link.classList.toggle('active',link.hash===`#${active.target.id}`));
  },{rootMargin:'-5% 0px -65% 0px'});
  document.querySelectorAll('main>.section').forEach(section=>observer.observe(section));
  renderModules(); renderLayout(); renderCatalog(); renderJourney(); renderComparison(); renderDecisions();
})();
