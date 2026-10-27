import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { localEnvironment } from './local-environment.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
if (args.some(argument => argument !== '--release')) {
  throw new Error('Usage: npm run client:windows [-- --release]');
}
if (process.platform !== 'win32') {
  throw new Error('This launcher is for the Windows client.');
}
const configuration = args.includes('--release') ? 'Release' : 'Debug';
const executable = resolve(root, 'client', 'build', 'windows', 'x64', 'runner', configuration, 'globalsend.exe');
if (!existsSync(executable)) {
  console.error(`${configuration} client is not built. Build that configuration when builds are permitted; this launcher never builds or substitutes another configuration.`);
  process.exitCode = 1;
} else {
  const child = spawn(executable, [], {
    cwd: dirname(executable), env: localEnvironment(root), stdio: 'inherit',
  });
  child.on('error', error => { console.error(error.message); process.exitCode = 1; });
  child.on('exit', code => { process.exitCode = code ?? 1; });
}
