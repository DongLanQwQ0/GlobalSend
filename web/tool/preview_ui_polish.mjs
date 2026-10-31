import { browserProfile as sharedBrowserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';

// Visual evidence for the ui/polish layer set: real main.ts, real stylesheet layers,
// synthetic state only. Reuses the established persistent browser profile, runs serially.

const require = createRequire(import.meta.url);
const { build } = require('esbuild');
const root = fileURLToPath(new URL('../../', import.meta.url));
const stylesDir = join(root, 'web/src/styles');
const screenshots = join(root, 'artifacts/screenshots');
const reports = join(root, 'artifacts/reports');
await mkdir(screenshots, { recursive: true });
await mkdir(reports, { recursive: true });

const source = await readFile(join(root, 'web/src/main.ts'), 'utf8');
const bootstrap = 'void new GlobalSend().start();';
assert.equal(source.split(bootstrap).length, 2, 'bootstrap anchor moved');

const state = [
  'const c = new GlobalSend(); window.__preview = c;',
  'const now = new Date().toISOString();',
  'const expiresAt = new Date(Date.now() + 3600000).toISOString();',
  'const file = (id, name, type, status, size) => ({fileId:id, name, mimeType:type, size:size||40000, offset:0, status, sha256:"0".repeat(64), attemptId:"a", transport:"relay"});',
  'window.__apply = () => {',
  '  c.loading = false; c.connected = true; c.helloReceived = true;',
  "  c.info = {protocolVersion:1, instanceId:'visual-fixture', name:'GlobalSend', limits:{maxTextLength:100000,maxFileSize:2000000000,ttlSeconds:86400}, features:{relay:true,direct:true,rtcDataChannels:true,groupSharedText:true,fileReuse:true,folderReuse:true,multiGroup:true}, rtc:{iceServers:[]}};",
  "  c.session = {deviceToken:'synthetic-only', device:{deviceId:'self', name:'DongLan', platform:'web'}, groupId:'fixture'}; c.api.session = c.session;",
  "  c.devices = [{deviceId:'phone',name:'我的手机',platform:'android',online:true},{deviceId:'ipad',name:'iPad',platform:'web',online:true},{deviceId:'laptop',name:'办公室笔记本',platform:'windows',online:false}];",
  "  c.target = 'phone';",
  '  c.ensureRtc = async () => {}; c.ensureFolderCapability = async () => {}; c.refresh = async () => {};',
  '  c.startReadyUploads = () => {}; c.selectIncomingRelays = async () => {};',
  '  c.notifications.notify = async () => false;',
  '  c.transfers = [',
  "    {transferId:'incoming', sourceDeviceId:'phone', targetDeviceId:'self', routePreference:'auto', createdAt:now, expiresAt, files:[file('photo','湖畔黄昏.png','image/png','received'), file('upload','课堂笔记.txt','text/plain','accepted',20000), file('other','项目资料.zip','application/zip','received')]},",
  "    {transferId:'outgoing', sourceDeviceId:'self', targetDeviceId:'phone', createdAt:now, expiresAt, routePreference:'auto', files:[file('failed','周报.md','text/markdown','failed')]}",
  '  ];',
  '};',
  'window.__apply();',
].join('\n');

const compiled = await build({
  stdin: { contents: source.replace(bootstrap, state), resolveDir: join(root, 'web/src'), sourcefile: 'ui-polish-visual.ts', loader: 'ts' },
  bundle: true, platform: 'browser', format: 'esm', write: false, loader: { '.css': 'empty' },
});

// UI_POLISH_BASELINE=1 renders the same pages with the pre-split monolith (8f9ca8c) for a before/after.
const baseline = process.env.UI_POLISH_BASELINE === '1';
const entry = baseline
  ? execFileSync('git', ['show', '8f9ca8c:web/src/style.css'], { cwd: root, encoding: 'utf8' })
  : await readFile(join(root, 'web/src/style.css'), 'utf8');
const prefix = baseline ? 'ui-baseline-' : 'ui-polish-';
const html = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
  + '<link rel="stylesheet" href="/style.css"></head><body><div id="app"></div>'
  + '<input id="file-input" type="file" hidden multiple><input id="resume-file" type="file" hidden>'
  + '<div id="toasts" role="status" aria-live="polite"></div>'
  + '<script type="module" src="/fixture.js"></script></body></html>';

const server = createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  response.setHeader('cache-control', 'no-store');
  if (path === '/fixture.js') {
    response.setHeader('content-type', 'text/javascript');
    return response.end(compiled.outputFiles[0].text);
  }
  if (path === '/style.css') {
    response.setHeader('content-type', 'text/css');
    return response.end(entry);
  }
  if (!baseline && path.startsWith('/styles/')) {
    response.setHeader('content-type', 'text/css');
    try {
      return response.end(await readFile(join(stylesDir, path.slice(8).replace(/[^\w.-]/g, '')), 'utf8'));
    } catch {
      response.statusCode = 404;
      return response.end('');
    }
  }
  response.setHeader('content-type', 'text/html');
  return response.end(html);
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const origin = 'http://127.0.0.1:' + server.address().port;

const edge = process.env.GLOBALSEND_HEADLESS_BROWSER || 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const browser = launchSharedBrowser(edge, ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  '--disable-extensions', '--disable-background-networking', '--disable-component-update',
  '--remote-debugging-port=0', '--user-data-dir=' + sharedBrowserProfile, 'about:blank'],
  { windowsHide: true, stdio: ['ignore', 'ignore', 'ignore'] });

const delay = (ms) => new Promise((done) => setTimeout(done, ms));
let socket;
try {
  let address;
  for (let i = 0; i < 150 && !address; i += 1) {
    try { address = (await readFile(join(sharedBrowserProfile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/); }
    catch { await delay(100); }
  }
  assert.ok(address, 'headless browser did not start');
  socket = new WebSocket('ws://127.0.0.1:' + address[0] + address[1]);
  await new Promise((done, fail) => { socket.addEventListener('open', done, { once: true }); socket.addEventListener('error', fail, { once: true }); });

  let nextId = 0;
  const calls = new Map();
  socket.addEventListener('message', (event) => {
    const reply = JSON.parse(event.data);
    const pending = calls.get(reply.id);
    if (!pending) return;
    calls.delete(reply.id);
    reply.error ? pending.fail(new Error(reply.error.message)) : pending.done(reply.result);
  });
  const send = (method, params = {}, sessionId) => new Promise((done, fail) => {
    const id = ++nextId;
    calls.set(id, { done, fail });
    socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const target = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId: target.targetId, flatten: true });
  const page = (method, params) => send(method, params, sessionId);
  const evaluate = async (expression) => {
    const result = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails).slice(0, 400));
    return result.result.value;
  };
  await page('Page.enable');
  await page('Runtime.enable');
  await page('Page.navigate', { url: origin + '/' });
  for (let i = 0; i < 200; i += 1) {
    if (await evaluate('Boolean(window.__preview)')) break;
    await delay(50);
  }
  assert.equal(await evaluate('Boolean(window.__preview)'), true, 'fixture never booted');

  await evaluate('(() => { const canvas = document.createElement("canvas"); canvas.width = 640; canvas.height = 400; const ctx = canvas.getContext("2d"); const g = ctx.createLinearGradient(0,0,640,400); g.addColorStop(0,"#cfe0d2"); g.addColorStop(.55,"#7fae9a"); g.addColorStop(1,"#1d5c4a"); ctx.fillStyle = g; ctx.fillRect(0,0,640,400); ctx.fillStyle = "rgba(255,255,255,.85)"; ctx.beginPath(); ctx.arc(470,110,46,0,Math.PI*2); ctx.fill(); return new Promise((done) => canvas.toBlob((blob) => { window.__preview.fileSources.set("incoming:photo", new File([blob], "湖畔黄昏.png", {type:"image/png"})); done(true); }, "image/png")); })()');

  const evidence = [];
  const capture = async (name, width, height, mobile) => {
    await page('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile });
    await evaluate('document.fonts.ready.then(() => true)');
    await delay(160);
    const probe = await evaluate('(() => ({overflow: document.documentElement.scrollWidth > innerWidth + 1, width: innerWidth, height: innerHeight, theme: document.documentElement.dataset.theme, cards: document.querySelectorAll(".content-card,.card,.panel").length, buttons: document.querySelectorAll("button").length, shadows: [...document.querySelectorAll("button,.panel,.content-card,.modal")].filter((node) => getComputedStyle(node).boxShadow !== "none").length}))()');
    assert.equal(probe.overflow, false, name + ' overflows horizontally at ' + width);
    const shot = await page('Page.captureScreenshot', { format: 'jpeg', quality: 86, captureBeyondViewport: false });
    const file = join(screenshots, prefix + name + '.jpg');
    await writeFile(file, Buffer.from(shot.data, 'base64'));
    evidence.push({ name, width, height, file: file.slice(root.length).replace(/\\/g, '/'), ...probe });
    return probe;
  };

  const setState = async (expression) => evaluate('(() => { const c = window.__preview; ' + expression + ' c.render(); return true; })()');
  const setTheme = async (mode) => evaluate('(() => { window.__preview.appearance.set({mode:"' + mode + '"}); return document.documentElement.dataset.theme; })()');

  await setTheme('light');
  await setState('c.session = null; c.api.session = null; c.connected = false; c.helloReceived = false; c.devices = []; c.transfers = [];');
  await capture('connect-light', 1440, 900, false);
  await capture('connect-mobile', 390, 844, true);
  await setTheme('dark');
  await capture('connect-dark', 1440, 900, false);

  await evaluate('(() => { window.__apply(); return true; })()');
  await setTheme('light');
  await setState('c.contentView = "receive"; c.mobileView = "receive"; c.modal = null;');
  await capture('receive-light', 1440, 900, false);
  await capture('receive-tablet', 1024, 768, false);
  await capture('receive-mobile', 390, 844, true);
  await setTheme('dark');
  await capture('receive-dark', 1440, 900, false);
  await capture('receive-mobile-dark', 390, 844, true);

  await setTheme('light');
  await setState('c.contentView = "sent"; c.modal = null;');
  await capture('sent-light', 1440, 900, false);
  await setState('c.contentView = "library"; c.modal = null;');
  await capture('library-light', 1440, 900, false);
  await setState('c.contentView = "receive"; c.modal = "settings";');
  await capture('settings-light', 1440, 900, false);
  await setTheme('dark');
  await capture('settings-dark', 1440, 900, false);

  // Clipboard candidate at the Windows default window size: an unconfirmed suggestion card
  // next to an already staged item, which must stay a square card inside the two-column queue.
  await setState('c.contentView = "receive"; c.mobileView = "receive"; c.modal = null; c.clipboardSuggestion = "text"; c.stagedTexts = [{id:"staged-verified", text:"已确认：这条文本已经加入待发送队列。"}];');
  await capture('clipboard-950', 950, 650, false);
  await capture('clipboard-390', 390, 844, true);

  await writeFile(join(reports, 'ui-polish-visual.json'), JSON.stringify({ capturedAt: new Date().toISOString(), origin, evidence }, null, 2));
  console.log(JSON.stringify({ ok: true, shots: evidence.length, widths: [...new Set(evidence.map((item) => item.width))], themes: [...new Set(evidence.map((item) => item.theme))] }));
} finally {
  socket?.close();
  await closeSharedBrowser(browser);
  await new Promise((done) => server.close(done));
}
