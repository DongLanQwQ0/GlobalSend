import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { localEnvironment } from './local-environment.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const entry = resolve(root, 'server', 'dist', 'index.js');
if (!existsSync(entry)) {
  console.error('Center build is missing. Run npm run build when builds are permitted.');
  process.exitCode = 1;
} else {
  Object.assign(process.env, localEnvironment(root));
  process.chdir(resolve(root, 'server'));
  // The center owns signal handling; no extra shell or orphan server process.
  await import(pathToFileURL(entry).href);
}
