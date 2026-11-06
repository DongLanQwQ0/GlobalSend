import { spawn } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { localEnvironment } from './local-environment.mjs';

// Root lifecycle scripts move between pnpm subprojects while anchoring every
// child output to this checkout. pnpm supplies its own CLI path through
// npm_execpath when it runs these scripts, so the child uses the same version.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const [project, ...args] = process.argv.slice(2);
if (!['server', 'web'].includes(project) || !args.length) {
  throw new Error('Usage: run-pnpm.mjs server|web <pnpm arguments>');
}
const env = localEnvironment(root);
// Test fixtures allocate their own project-local roots. Development-server
// deployment paths must not redirect isolated fixture bytes into live state.
if (args[0] === 'test') { delete env.DATA_DIR; delete env.RELAY_DIR; }
const cli = process.env.npm_execpath;
const child = cli
  ? spawn(process.execPath, [cli, ...args], {
    cwd: resolve(root, project), env, stdio: 'inherit', windowsHide: true,
  })
  : spawn('pnpm', args, {
    cwd: resolve(root, project), env, stdio: 'inherit',
    shell: process.platform === 'win32',
  });
child.once('error', error => { console.error(error.message); process.exitCode = 1; });
child.once('exit', code => { process.exitCode = code ?? 1; });
