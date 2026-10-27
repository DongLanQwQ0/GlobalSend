import { browserProfile, launchSharedBrowser, closeSharedBrowser } from './browser_profile.mjs';
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { buildApp } from '../../server/src/server.ts';

// Reuse the existing browser identity; only fixture data and reports are per-run.
const root = fileURLToPath(new URL('../../', import.meta.url));
const parent = join(root, 'artifacts/tmp/compact-actions');
await mkdir(parent, { recursive: true });
const run = await mkdtemp(join(parent, 'run-'));
const site = join(run, 'site');
await mkdir(site);
const source = await readFile(join(root, 'web/src/main.ts'), 'utf8');
const { build } = createRequire(import.meta.url)('esbuild');
const output = await build({ stdin: {
  contents: source.replace('void new GlobalSend().start();', 'const c=new GlobalSend();window.__client=c;c.ensureRtc=async()=>{};await c.start();'),
  resolveDir: join(root, 'web/src'), sourcefile: 'compact-actions.ts', loader: 'ts',
}, bundle: true, platform: 'browser', format: 'esm', write: false, loader: { '.css': 'empty' } });
await writeFile(join(site, 'fixture.js'), output.outputFiles[0].text);
await writeFile(join(site, 'style.css'), await readFile(join(root, 'web/src/style.css')));
await writeFile(join(site, 'index.html'), '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="./style.css"><div id="app"></div><input type="file" id="file-input" hidden multiple><input type="file" id="resume-file" hidden><div id="toasts"></div><script type="module" src="./fixture.js"></script></html>');
const reservation = createServer();
await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
const port = reservation.address().port;
await new Promise(resolve => reservation.close(resolve));
const base = `http://127.0.0.1:${port}/globalsend`;
const center = await buildApp({ dataDir: join(run, 'center'), relayDir: join(run, 'relay'), staticDir: site, publicBaseUrl: base, diskReserve: 0, production: false, log: false });
await center.listen({ host: '127.0.0.1', port });
const browser = launchSharedBrowser('C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe', ['--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--disable-component-update', '--remote-debugging-port=0', `--user-data-dir=${browserProfile}`, 'about:blank'], { windowsHide: true, stdio: 'ignore', env: { ...process.env, TEMP: parent, TMP: parent } });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function poll(action, accept, timeout = 15000) {
  const end = Date.now() + timeout; let value;
  while (Date.now() < end) { value = await action(); if (accept(value)) return value; await delay(30); }
  throw new Error('Deadline: ' + JSON.stringify(value));
}
let socket, closePage;
try {
  const address = await poll(async () => { try { return (await readFile(join(browserProfile, 'DevToolsActivePort'), 'utf8')).trim().split(/\r?\n/); } catch {} }, Boolean);
  socket = new WebSocket(`ws://127.0.0.1:${address[0]}${address[1]}`);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  let sequence = 0; const pending = new Map();
  socket.addEventListener('message', event => { const value = JSON.parse(event.data), call = pending.get(value.id); if (call) { pending.delete(value.id); value.error ? call.reject(new Error(value.error.message)) : call.resolve(value.result); } });
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => { const id = ++sequence; pending.set(id, { resolve, reject }); socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })); });
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const page = (method, params = {}) => send(method, params, sessionId);
  const evaluate = async expression => { const value = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }); if (value.exceptionDetails) throw new Error(JSON.stringify(value.exceptionDetails)); return value.result.value; };
  closePage = async () => { await evaluate("(()=>{const c=window.__client;if(c){c.stagedTexts=[];c.shared.dirty=false;c.busy=false;}})()").catch(() => {}); await send('Target.closeTarget', { targetId }); };
  await page('Page.enable'); await page('Runtime.enable');
  await page('Emulation.setFocusEmulationEnabled', { enabled: true });
  await page('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'no-preference' }] });
  await page('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await page('Page.navigate', { url: base + '/app/' });
  await poll(() => evaluate('!!window.__client && !window.__client.loading'), Boolean);
  await evaluate("(async()=>{const c=window.__client;c.groupKey='compact-actions-browser';await c.enroll();Object.defineProperty(navigator,'clipboard',{configurable:true,value:{read:async()=>[],writeText:async t=>window.__copied=t}});})()");
  await poll(() => evaluate('window.__client.connected && window.__client.shared.loaded'), Boolean);
  const result = [];
  for (const width of [360, 390, 430]) {
    await page('Emulation.setDeviceMetricsOverride', { width, height: 844, deviceScaleFactor: 1, mobile: true });
    const layout = await evaluate(`(()=>{const items=[...document.querySelectorAll('.mobile-file-actions button')],rects=items.map(node=>node.getBoundingClientRect());return {labels:items.map(node=>node.textContent),sameRow:rects.every(r=>Math.abs(r.top-rects[0].top)<1),minHeight:Math.min(...rects.map(r=>r.height)),fits:rects.every(r=>r.left>=0&&r.right<=innerWidth),overflow:document.documentElement.scrollWidth>innerWidth,nav:[...document.querySelectorAll('.mobile-view-tabs button')].map(node=>node.textContent),selected:document.querySelector('.mobile-view-tabs [aria-selected=true]')?.id};})()`);
    assert.deepEqual(layout.labels, ['文本', '剪贴板', '文件', '媒体']);
    assert.equal(layout.sameRow, true); assert.ok(layout.minHeight >= 44); assert.equal(layout.fits, true); assert.equal(layout.overflow, false);
    assert.deepEqual(layout.nav, ['发送', '接收', '历史', '文件']); assert.equal(layout.selected, 'mobile-send-tab');
    result.push({ width, ...layout });
    if (width === 390) {
      const image = await page('Page.captureScreenshot', { format: 'jpeg', quality: 78, captureBeyondViewport: false });
      await writeFile(join(root, 'artifacts/screenshots/web-mobile-actions-one-row.raw.jpg'), Buffer.from(image.data, 'base64'));
    }
  }
  await evaluate("window.__client.stagedTexts=[{id:'preserved-draft',text:'切换后保留的草稿'}];window.__client.render()");
  const transitions = [];
  for (const view of ['receive', 'sent', 'library', 'send', 'sent', 'receive', 'send']) {
    const point = await evaluate(`(()=>{const r=document.querySelector('#mobile-${view}-tab').getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    for (const type of ['mousePressed', 'mouseReleased']) await page('Input.dispatchMouseEvent', { type, ...point, button: 'left', buttons: type === 'mousePressed' ? 1 : 0, clickCount: 1 });
    await delay(45);
    const state = await evaluate(`(()=>{const c=window.__client,target=document.querySelector('${view === 'send' ? '#send-panel' : '#receive-panel'}');return{selected:document.querySelector('.mobile-view-tabs [aria-selected=true]')?.id,key:c.workspaceViewKey,animations:target.getAnimations().map(a=>({state:a.playState,time:a.currentTime})),draft:c.stagedTexts.map(x=>x.text),duplicateTabs:getComputedStyle(document.querySelector('.content-tabs')).display!=='none'};})()`);
    assert.equal(state.selected, `mobile-${view}-tab`);
    assert.equal(state.key, view);
    assert.deepEqual(state.draft, ['切换后保留的草稿']);
    assert.equal(state.duplicateTabs, false);
    assert.ok(state.animations.some(animation => animation.state === 'running' && animation.time > 0), JSON.stringify({ view, state }));
    transitions.push({ view, ...state });
  }
  await writeFile(join(run, 'result.json'), JSON.stringify({ result, transitions }, null, 2));
  console.log(JSON.stringify({ run, result, transitions }));
} finally { await closePage?.().catch(() => {}); socket?.close(); await closeSharedBrowser(browser); await center.close(); }
