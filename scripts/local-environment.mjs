import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

// Development state stays in this checkout. Explicit deployment overrides win.
export function localEnvironment(root, inherited = process.env) {
  const temp = resolve(root, 'artifacts', 'tmp');
  mkdirSync(temp, { recursive: true });
  return {
    ...inherited,
    TEMP: temp,
    TMP: temp,
    TMPDIR: temp,
    npm_config_logs_dir: resolve(root, 'artifacts', 'logs', 'npm-root'),
    DATA_DIR: inherited.DATA_DIR || resolve(root, 'artifacts', 'local-center', 'data'),
    RELAY_DIR: inherited.RELAY_DIR || resolve(root, 'artifacts', 'local-center', 'relay'),
    STATIC_DIR: inherited.STATIC_DIR || resolve(root, 'web', 'dist'),
    GLOBALSEND_DATA_DIR: inherited.GLOBALSEND_DATA_DIR || resolve(root, 'artifacts', 'native-state'),
  };
}
