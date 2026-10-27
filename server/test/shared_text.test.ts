import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import WebSocket from 'ws';
import { buildApp } from '../src/server.js';

async function fixture() {
  const root = fileURLToPath(new URL('../../artifacts/tmp/', import.meta.url));
  await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, 'shared-text-'));
  let app = await buildApp({ dataDir: dir, diskReserve: 0 });
  await app.listen({ host: '127.0.0.1', port: 0 });
  function origin() { return `http://127.0.0.1:${(app.server.address() as any).port}`; }
  async function call(method: string, path: string, body?: unknown, token?: string) {
    const res = await fetch(origin() + '/api/v1' + path, { method,
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body !== undefined ? { 'content-type': 'application/json' } : {}) },
      ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
    return { status: res.status, body: await res.json() as any };
  }
  async function enroll(name: string, groupKey = 'shared-workspace-password') {
    const res = await call('POST', '/devices/enroll', { name, platform: 'web', groupKey });
    assert.equal(res.status, 201);
    return { id: res.body.device.deviceId as string, token: res.body.deviceToken as string };
  }
  async function connect(token: string) {
    const ticket = (await call('POST', '/session/ws-ticket', {}, token)).body.ticket;
    const socket = new WebSocket(origin().replace('http:', 'ws:') + '/api/v1/ws?ticket=' + ticket, { origin: origin() });
    const messages: any[] = [];
    socket.on('message', value => messages.push(JSON.parse(String(value))));
    await once(socket, 'open');
    return { messages, async close() { const done = once(socket, 'close'); socket.close(); await done; } };
  }
  async function restart() {
    await app.close(); app = await buildApp({ dataDir: dir, diskReserve: 0 });
    await app.listen({ host: '127.0.0.1', port: 0 });
  }
  return { call, enroll, connect, restart, async close() { await app.close(); await rm(dir, { recursive: true, force: true }); } };
}

test('group text broadcasts both directions, survives reconnect/restart and does not create message history', async () => {
  const f = await fixture();
  try {
    const a = await f.enroll('Windows'), b = await f.enroll('Android');
    const ws = await f.connect(b.token);
    assert.equal((await f.call('GET', '/info')).body.features.groupSharedText, true);
    assert.deepEqual((await f.call('GET', '/group/shared-text', undefined, a.token)).body,
      { text: '', revision: 0, updatedAt: '', updatedBy: '', mutationId: '' });
    const first = await f.call('PUT', '/group/shared-text', { text: '共同编辑\n第一行', baseRevision: 0, mutationId: 'first' }, a.token);
    assert.equal(first.status, 200); assert.equal(first.body.revision, 1); assert.equal(first.body.updatedBy, a.id);
    for (let i = 0; i < 50 && !ws.messages.some(x => x.type === 'sharedText.updated'); i++)
      await new Promise(resolve => setTimeout(resolve, 10));
    assert.deepEqual(ws.messages.find(x => x.type === 'sharedText.updated'), { type: 'sharedText.updated', ...first.body });
    const second = await f.call('PUT', '/group/shared-text', { text: '手机修改', baseRevision: 1, mutationId: 'second' }, b.token);
    assert.equal(second.body.revision, 2);
    assert.deepEqual((await f.call('GET', '/group/shared-text', undefined, a.token)).body, second.body);
    assert.deepEqual((await f.call('GET', '/events', undefined, a.token)).body.events, []);
    assert.deepEqual((await f.call('GET', '/transfers', undefined, a.token)).body.transfers, []);
    await ws.close(); await f.restart();
    assert.deepEqual((await f.call('GET', '/group/shared-text', undefined, a.token)).body, second.body);
    const cleared = await f.call('PUT', '/group/shared-text', { text: '', baseRevision: 2, mutationId: 'clear' }, a.token);
    assert.equal(cleared.body.text, ''); assert.equal(cleared.body.revision, 3);
  } finally { await f.close(); }
});

test('concurrent edits return latest document, retrying the same mutation does not duplicate edits', async () => {
  const f = await fixture();
  try {
    const a = await f.enroll('first'), b = await f.enroll('second');
    const body = { text: '先保存的内容', baseRevision: 0, mutationId: 'unique' };
    const first = await f.call('PUT', '/group/shared-text', body, a.token);
    assert.deepEqual((await f.call('PUT', '/group/shared-text', body, a.token)).body, first.body);
    const conflict = await f.call('PUT', '/group/shared-text', { text: '保留的草稿', baseRevision: 0, mutationId: 'second' }, b.token);
    assert.equal(conflict.status, 409); assert.equal(conflict.body.error.code, 'SHARED_TEXT_CONFLICT');
    assert.deepEqual(conflict.body.current, first.body);
    const resolved = await f.call('PUT', '/group/shared-text', { text: '保留的草稿', baseRevision: 1, mutationId: 'second' }, b.token);
    assert.equal(resolved.body.revision, 2); assert.equal(resolved.body.text, '保留的草稿');
  } finally { await f.close(); }
});

test('shared workspace is scoped to group password and ordinary authenticated access', async () => {
  const f = await fixture();
  try {
    const a = await f.enroll('first'), outside = await f.enroll('outside', 'other-workspace-password');
    assert.equal((await f.call('GET', '/group/shared-text')).status, 401);
    await f.call('PUT', '/group/shared-text', { text: '本组内容', baseRevision: 0, mutationId: 'a' }, a.token);
    assert.equal((await f.call('GET', '/group/shared-text', undefined, outside.token)).body.text, '');
    await f.call('PUT', '/group/shared-text', { text: '另一组', baseRevision: 0, mutationId: 'b' }, outside.token);
    assert.equal((await f.call('GET', '/group/shared-text', undefined, a.token)).body.text, '本组内容');
  } finally { await f.close(); }
});
