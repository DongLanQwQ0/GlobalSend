import { constants } from 'node:fs';
import { chmod, copyFile, lstat, mkdir, mkdtemp, readdir, realpath, rename, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const help = `Offline local-center backup (Node 24)

Stop the center yourself and keep it stopped until this command finishes.
  npm run backup:local -- --server-stopped --data-dir <data> --relay-dir <relay>

Both source directories must be explicit, to avoid backing up a different
instance. Relative sources resolve from the project root. A new private
backups/<timestamp>/ directory is created inside this project. Existing
backups and source files are never replaced. Config and external secrets
are not included; retain the matching deployment config separately.
`;

function contains(parent, child) {
  const path = relative(parent, child);
  return path === '' || (!isAbsolute(path) && path !== '..' && !path.startsWith(`..${sep}`));
}

async function sourceDirectory(value) {
  const path = resolve(root, value);
  if (!(await lstat(path)).isDirectory()) {
    throw new Error('Each source must be a real directory, not a symbolic link.');
  }
  return realpath(path);
}

// Reject symbolic links/junctions and special files rather than copying data
// outside the chosen directories. Copy WAL/SHM and all other regular files too.
async function copyDirectory(source, target, exclude) {
  await mkdir(target, { mode: 0o700 });
  let files = 0;
  for (const name of await readdir(source)) {
    const from = join(source, name), to = join(target, name);
    if (from === exclude) continue;
    const info = await lstat(from);
    if (info.isDirectory()) {
      files += await copyDirectory(from, to, exclude);
    } else if (info.isFile()) {
      await copyFile(from, to, constants.COPYFILE_EXCL);
      // POSIX permissions are private even when the source had broader access.
      await chmod(to, 0o600);
      files += 1;
    } else {
      throw new Error('Backup sources contain a symbolic link or unsupported file; backup aborted.');
    }
  }
  return files;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === '--help') {
    console.log(help);
    return;
  }
  const options = new Map();
  let stopped = false;
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--server-stopped' && !stopped) {
      stopped = true;
    } else if (['--data-dir', '--relay-dir'].includes(arg) && !options.has(arg)) {
      const value = args[++index];
      if (!value || value.startsWith('--')) throw new Error(help);
      options.set(arg, value);
    } else {
      throw new Error(help);
    }
  }
  if (!stopped || !options.has('--data-dir') || !options.has('--relay-dir')) throw new Error(help);

  const data = await sourceDirectory(options.get('--data-dir'));
  const relay = await sourceDirectory(options.get('--relay-dir'));
  if (contains(relay, data)) throw new Error('Relay directory must not contain the data directory.');
  // The script does not open SQLite, acquire locks, checkpoint, or alter source
  // files. --server-stopped is an operator assertion, not a process detector.
  const database = await lstat(join(data, 'globalsend.sqlite'));
  if (!database.isFile()) throw new Error('Data directory has no regular globalsend.sqlite file.');

  const backupPath = join(root, 'backups');
  // Resolve an existing parent before creating anything to catch junctions too.
  let backupRoot;
  try {
    const info = await lstat(backupPath);
    if (!info.isDirectory()) throw new Error('backups must be a real directory.');
    backupRoot = await realpath(backupPath);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    backupRoot = join(await realpath(root), 'backups');
  }
  if (contains(data, backupRoot) || contains(relay, backupRoot) || contains(backupRoot, data) || contains(backupRoot, relay)) {
    throw new Error('Backup directory and source directories must not overlap.');
  }
  await mkdir(backupRoot, { recursive: true, mode: 0o700 });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const partial = await mkdtemp(join(backupRoot, `${stamp}.incomplete-`));
  await chmod(partial, 0o700);
  const destination = partial.replace('.incomplete-', '-');
  try {
    // server's original default nests relay under data; export it once as
    // relay/, rather than duplicating every potentially large file in data/.
    const dataFiles = await copyDirectory(data, join(partial, 'data'), relay);
    const relayFiles = await copyDirectory(relay, join(partial, 'relay'));
    await writeFile(join(partial, 'manifest.json'), `${JSON.stringify({
      format: 'globalsend-offline-backup', version: 1,
      createdAt: new Date().toISOString(), serverStopped: true,
      originalDirectories: { data, relay },
      dataFiles, relayFiles,
      includes: ['data/', 'relay/'],
      excludes: ['deployment configuration', 'external secrets', 'TLS proxy data'],
    }, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    // Publish only after every copy succeeds. Interrupted/failed copies retain
    // the .incomplete suffix and must never be used for recovery.
    await rename(partial, destination);
    console.log(`Backup saved: ${destination}`);
    console.log('Keep the matching app version, configuration and external secrets separately.');
    console.log('Restore to the original data/relay paths; stored relay paths are absolute.');
  } catch (error) {
    console.error(`Incomplete backup retained at: ${partial}`);
    throw error;
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
