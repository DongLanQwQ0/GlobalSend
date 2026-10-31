import { buildApp } from '../../server/src/server.ts';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, mkdtemp, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const root = fileURLToPath(new URL('../../', import.meta.url));
const parent = join(root, 'artifacts/tmp/background-receive-runtime'); await mkdir(parent, { recursive: true });
const work = await mkdtemp(join(parent, 'run-'));
const app = await buildApp({ dataDir: join(work, 'center'), diskReserve: 0 });
const call = async (method, path, payload, token) => {
  const response = await app.inject({ method, url: '/api/v1' + path,
    headers: { ...(token ? { authorization: 'Bearer ' + token } : {}), ...(Buffer.isBuffer(payload) ? { 'content-type': 'application/octet-stream' } : {}) },
    ...(payload !== undefined ? { payload } : {}) });
  if (response.statusCode >= 400) throw new Error(response.body);
  return response.json();
};
let sender;
let endpoint = '', ordinal = 0;
const jobs = new Map();
app.get('/fixture/state', async () => ({
  devices: (await call('GET', '/devices', undefined, sender.deviceToken)).devices.map(({ deviceId, name, online }) => ({ deviceId, name, online })),
  transfers: (await call('GET', '/transfers', undefined, sender.deviceToken)).transfers,
  jobs: [...jobs.values()].map(({ transferId, error, sent }) => ({ transferId, error, sent })),
}));
async function target() {
  const { devices } = await call('GET', '/devices', undefined, sender.deviceToken);
  const receiver = devices.find(device => device.deviceId !== sender.device.deviceId);
  if (!receiver) throw new Error('The acceptance phone is not online');
  return receiver.deviceId;
}
app.post('/fixture/text', async request => {
  const text = request.body?.text || `后台接收文字 ${++ordinal}`;
  const result = await call('POST', '/texts', { eventId: randomUUID(), targetDeviceId: await target(), text }, sender.deviceToken);
  return { text, eventId: result.event.eventId };
});
app.post('/fixture/file', async request => {
  const size = request.body?.size || 1048576, delayMs = request.body?.delayMs ?? 120;
  const bytes = request.body?.text ? Buffer.from(request.body.text, 'utf8') : Buffer.alloc(size);
  if (!request.body?.text) for (let i = 0; i < size; i++) bytes[i] = i % 251;
  const transferId = randomUUID(), fileId = randomUUID(), name = request.body?.name || `后台文件-${++ordinal}.bin`;
  await call('POST', '/transfers', { transferId, targetDeviceId: await target(), routePreference: 'relay', files: [
    { fileId, name, size: bytes.length, mimeType: request.body?.mimeType || 'application/octet-stream', sha256: createHash('sha256').update(bytes).digest('hex') },
  ] }, sender.deviceToken);
  const job = { transferId, sent: 0, error: '' }; jobs.set(transferId, job);
  void (async () => {
    try {
      for (;;) {
        const { transfer } = await call('GET', '/transfers/' + transferId, undefined, sender.deviceToken);
        if (transfer.files[0].status === 'accepted') break;
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      for (let offset = 0; offset < bytes.length; offset += 32768) {
        await call('PUT', `/transfers/${transferId}/files/${fileId}/chunks?offset=${offset}`, bytes.subarray(offset, offset + 32768), sender.deviceToken);
        job.sent = Math.min(bytes.length, offset + 32768);
        await new Promise(resolve => setTimeout(resolve, delayMs));
      }
      await call('POST', `/transfers/${transferId}/files/${fileId}/complete`, {}, sender.deviceToken);
    } catch (error) { job.error = String(error); }
  })();
  return { transferId, fileId, name, size: bytes.length };
});
await app.listen({ host: '127.0.0.1', port: 0 });
sender = await call('POST', '/devices/enroll', { name: '后台验收电脑', platform: 'other', groupKey: 'background-ui-fixture' });
endpoint = `http://127.0.0.1:${app.server.address().port}`;
const require = createRequire(new URL('../../server/package.json', import.meta.url));
const WebSocket = require('ws'), ticket = await call('POST', '/session/ws-ticket', {}, sender.deviceToken);
const socket = new WebSocket(endpoint.replace('http:', 'ws:') + '/api/v1/ws?ticket=' + ticket.ticket, { origin: endpoint });
await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
const metadata = { endpoint, emulatorCenter: endpoint.replace('127.0.0.1', '10.0.2.2'), work, appId: 'dev.globalsend.backgroundprobe' };
await writeFile(join(parent, 'current.json'), JSON.stringify(metadata, null, 2));
console.log(JSON.stringify(metadata));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => void app.close().then(() => process.exit(0)));
