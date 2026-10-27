import { buildApp } from '../../server/src/server.ts';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawn } from 'node:child_process';
import { createRequire } from 'node:module';

// Real compiled Windows app + real local center. All identities, messages and
// files are synthetic; the user's running app and its data are never opened.
const root = fileURLToPath(new URL('../../', import.meta.url));
const executable = resolve(process.argv[2]);
const parent = join(root, 'artifacts/tmp/workspace-live-windows');
await mkdir(parent, { recursive: true });
const work = await mkdtemp(join(parent, 'run-'));
const state = join(work, 'native-state');
await mkdir(join(state, 'vault'), { recursive: true });
const app = await buildApp({ dataDir: join(work, 'center'), diskReserve: 0 });
await app.listen({ host: '127.0.0.1', port: 0 });
const base = `http://127.0.0.1:${app.server.address().port}`;
const call = async (method, path, body, token) => {
  const response = await app.inject({ method, url: `/api/v1${path}`,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(Buffer.isBuffer(body) ? { 'content-type': 'application/octet-stream' } : {}) },
    ...(body !== undefined ? { payload: body } : {}) });
  if (response.statusCode >= 400) throw new Error(`${method} ${path}: ${response.statusCode} ${response.body}`);
  return response.json();
};
const enroll = name => call('POST', '/devices/enroll', {
  name, platform: 'other', groupKey: 'workspace-local-ui-fixture',
});
const info = await call('GET', '/info'), windows = await enroll('隔离 Windows 验收'), phone = await enroll('测试手机');
// These hashes are the application's profile/vault key contract, not artifact
// integrity checks. DPAPI protects only a newly created local-fixture token.
const hash = value => createHash('sha256').update(value).digest('hex');
const profileKey = hash(`${base}\n${info.instanceId}`);
await writeFile(join(state, 'profiles.json'), JSON.stringify([{
  baseUrl: base, instanceId: info.instanceId, deviceId: windows.device.deviceId,
  name: windows.device.name, groupId: windows.groupId, cursor: 0,
  autoReceive: true, sendRoutePreference: 'relay', receiveRoutePreference: 'relay',
}]));
await writeFile(join(state, 'recent-center.json'), JSON.stringify({ profileKey }));
execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
  'Add-Type -AssemblyName System.Security; $bytes=[Text.Encoding]::UTF8.GetBytes($env:GS_FIXTURE_TOKEN); $sealed=[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser); [IO.File]::WriteAllBytes($env:GS_FIXTURE_VAULT,$sealed)'],
  { windowsHide: true, env: { ...process.env, GS_FIXTURE_TOKEN: windows.deviceToken,
    GS_FIXTURE_VAULT: join(state, 'vault', hash(`token_${profileKey}`) + '.bin') } });

const require = createRequire(new URL('../../server/package.json', import.meta.url));
const WebSocket = require('ws');
const ticket = await call('POST', '/session/ws-ticket', {}, phone.deviceToken);
const socket = new WebSocket(base.replace('http:', 'ws:') + '/api/v1/ws?ticket=' + ticket.ticket, { origin: base });
await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
for (const text of ['来自测试手机的文字。\n这条消息可查看、复制和拖出。', '共享与发送分开。\n确认后才加入待发送列表。']) {
  await call('POST', '/texts', { eventId: randomUUID(), targetDeviceId: windows.device.deviceId, text }, phone.deviceToken);
}
await call('PUT', '/group/shared-text', { text: '本地隔离验收\n可在组内共同编辑。', baseRevision: 0, mutationId: randomUUID() }, phone.deviceToken);
const files = await Promise.all(['mountains.png', 'index.html'].map(async name => {
  const bytes = await readFile(join(root, 'client/build/workspace-ui-fixtures', name));
  return { fileId: randomUUID(), name, bytes, size: bytes.length,
    mimeType: name.endsWith('.png') ? 'image/png' : 'text/html', sha256: hash(bytes) };
}));
const transferId = randomUUID();
await call('POST', '/transfers', { transferId, targetDeviceId: windows.device.deviceId,
  routePreference: 'relay', files: files.map(({ bytes, ...wire }) => wire) }, phone.deviceToken);
let uploading = false;
const timer = setInterval(async () => {
  if (uploading) return;
  uploading = true;
  try {
    const { transfer } = await call('GET', `/transfers/${transferId}`, undefined, phone.deviceToken);
    for (const file of transfer.files.filter(file => file.status === 'accepted')) {
      const source = files.find(source => source.fileId === file.fileId);
      await call('PUT', `/transfers/${transferId}/files/${file.fileId}/chunks?offset=0`, source.bytes, phone.deviceToken);
      await call('POST', `/transfers/${transferId}/files/${file.fileId}/complete`, {}, phone.deviceToken);
    }
    if (transfer.files.every(file => file.status === 'received')) {
      clearInterval(timer);
      await writeFile(join(work, 'received.json'), JSON.stringify({ transferId, files: transfer.files.map(({ name, size, status }) => ({ name, size, status })) }, null, 2));
      console.log('Received: both real files saved by the compiled Windows client.');
    }
  } catch (error) { console.error(String(error)); }
  finally { uploading = false; }
}, 300);

const child = spawn(executable, [], { cwd: dirname(executable), windowsHide: false,
  env: { ...process.env, GLOBALSEND_DATA_DIR: state }, stdio: ['ignore', 'pipe', 'pipe'] });
const output = [];
child.stdout.on('data', value => output.push(String(value)));
child.stderr.on('data', value => output.push(String(value)));
const metadata = { work, base, state, executable, pid: child.pid, ownFixtureOnly: true };
await writeFile(join(parent, 'current.json'), JSON.stringify(metadata, null, 2));
console.log(JSON.stringify(metadata));
let closing = false;
async function close() {
  if (closing) return;
  closing = true; clearInterval(timer); socket.close();
  child.kill();
  await writeFile(join(work, 'native-output.log'), output.join(''));
  await app.close(); process.exit(0);
}
child.once('error', error => { console.error(error.message); void close(); });
child.once('exit', () => void close());
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => void close());
process.stdin.setEncoding('utf8');
process.stdin.on('data', text => { if (text.trim() === 'stop') void close(); });
