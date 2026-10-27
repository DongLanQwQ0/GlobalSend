import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { localEnvironment } from './local-environment.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const environment = localEnvironment(root);
const children = [];
let stopping = false;

function stop(code = 0) {
  if (stopping) return;
  stopping = true;
  for (const child of children) {
    if (!child.pid || child.exitCode !== null) continue;
    if (process.platform === 'win32') {
      // Only terminate process trees started by this launcher (npm + its dev server).
      spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
    } else {
      try { process.kill(-child.pid, 'SIGTERM'); } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
    }
  }
  process.exitCode = code;
}

for (const project of ['server', 'web']) {
  // shell:true is needed for npm.cmd on Windows. Arguments are fixed, never user input.
  const child = spawn('npm', ['run', 'dev'], {
    cwd: resolve(root, project), stdio: 'inherit', shell: process.platform === 'win32',
    detached: process.platform !== 'win32',
    env: {
      ...environment,
      GLOBALSEND_DEV: '1',
      npm_config_logs_dir: resolve(root, 'artifacts', 'logs', `npm-${project}`),
    },
  });
  children.push(child);
  child.on('error', (error) => { console.error(`${project}: ${error.message}`); stop(1); });
  child.on('exit', (code) => { if (!stopping) stop(code ?? 1); });
}

process.on('SIGINT', () => stop());
process.on('SIGTERM', () => stop());
