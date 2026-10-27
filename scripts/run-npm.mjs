import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { localEnvironment } from './local-environment.mjs';

// npm lifecycle commands supply their own CLI path. Keep setup/build/test on
// that same npm version while anchoring every child output to this checkout.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const [project, ...args] = process.argv.slice(2);
if (!['server', 'web'].includes(project) || !args.length) {
  throw new Error('Usage: run-npm.mjs server|web <npm arguments>');
}
if (!process.env.npm_execpath) throw new Error('Run through the root npm scripts.');
const logs = resolve(root, 'artifacts', 'logs', `npm-${project}`);
const child = spawn(process.execPath, [process.env.npm_execpath, `--logs-dir=${logs}`, ...args], {
  cwd: resolve(root, project),
  env: { ...localEnvironment(root), npm_config_logs_dir: logs },
  stdio: 'inherit', windowsHide: true,
});
child.once('error', error => { console.error(error.message); process.exitCode = 1; });
child.once('exit', code => { process.exitCode = code ?? 1; });
