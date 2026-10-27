import { buildApp } from '../../server/src/server.ts';
import { resolve, join } from 'node:path';

const root = resolve(process.argv[2]);
const app = await buildApp({ dataDir: join(root, 'center'), relayDir: join(root, 'relay'), bootstrapSecret: process.env.GLOBALSEND_TEST_BOOTSTRAP, diskReserve: 0, log: false });
await app.listen({ host: '127.0.0.1', port: 0 });
const address = app.server.address();
console.log(JSON.stringify({ url: `http://127.0.0.1:${address.port}` }));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => void app.close().then(() => process.exit(0)));
