import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// Rebuild a hidden, synthetic peer without replacing a GlobalSend binary.
// Durable sources live in client/tool; everything generated stays in build/.
const root = fileURLToPath(new URL('../', import.meta.url));
const transfer = process.argv.includes('--transfer');
const reachability = process.argv.includes('--reachability');
const probeName = reachability ? 'rtc_reachability_probe' : transfer ? 'rtc_transfer_probe' : 'rtc_probe';
const project = join(root, reachability ? 'client/build/rtc-reachability-probe' : transfer ? 'client/build/rtc-transfer-probe' : 'client/build/rtc-probe');
const flutter = process.env.FLUTTER_ROOT || 'E:/Programs/flutter';
const dart = join(flutter, 'bin/cache/dart-sdk/bin/dart.exe');
const snapshot = join(flutter, 'bin/cache/flutter_tools.snapshot');
const temporary = join(root, 'artifacts/tmp/rtc-probe-build');
await mkdir(temporary, { recursive: true });
const env = { ...process.env, PUB_CACHE: process.env.PUB_CACHE || 'F:/Caches/PubCache',
  TEMP: temporary, TMP: temporary, CI: 'true', FLUTTER_SUPPRESS_ANALYTICS: 'true' };
async function run(args, cwd = root) {
  const child = spawn(dart, [snapshot, ...args], { cwd, env, windowsHide: true, stdio: 'inherit' });
  await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('exit', code => code === 0 ? resolve() : reject(new Error(`flutter ${args[0]} exited ${code}`)));
  });
}
try { await access(join(project, 'windows/runner/flutter_window.cpp')); }
catch { await run(['create', '--platforms=windows', '--no-pub', '--project-name', probeName, project]); }
await writeFile(join(project, 'pubspec.yaml'), `name: ${probeName}
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.13.2
dependencies:
  flutter:
    sdk: flutter
  ${transfer || reachability ? 'globalsend:\n    path: ../..' : 'flutter_webrtc: 1.6.2+hotfix.4'}
flutter:
  uses-material-design: false
`);
await writeFile(join(project, 'lib/probe_main.dart'), await readFile(join(root,
  reachability ? 'client/tool/rtc_reachability_probe.dart' : transfer ? 'client/tool/rtc_transfer_probe.dart' : 'client/tool/rtc_probe_main.dart')));
const runnerPath = join(project, 'windows/runner/flutter_window.cpp');
let runner = await readFile(runnerPath, 'utf8');
runner = runner.replace(/  flutter_controller_->engine\(\)->SetNextFrameCallback\(\[&\]\(\) \{\s*this->Show\(\);\s*\}\);/, '  // Synthetic transport fixture: keep its window hidden.');
if (runner.includes('this->Show()')) throw new Error('Unrecognized runner template: cannot guarantee hidden probe');
await writeFile(runnerPath, runner);
const cmakePath = join(project, 'windows/CMakeLists.txt');
let cmake = await readFile(cmakePath, 'utf8');
if (!cmake.includes('target_compile_options(flutter_webrtc_plugin PRIVATE /utf-8)')) {
  cmake = cmake.replace('include(flutter/generated_plugins.cmake)',
    'include(flutter/generated_plugins.cmake)\ntarget_compile_options(flutter_webrtc_plugin PRIVATE /utf-8)');
  await writeFile(cmakePath, cmake);
}
await run(['pub', 'get'], project);
await run(['build', 'windows', '--release', '--no-pub', '--target=lib/probe_main.dart'], project);
console.log(reachability ? 'Built hidden production reachability consumer.' : transfer ? 'Built hidden production-transport consumer.' : 'Built hidden echo probe. Run: node web/tool/probe_webrtc_native.mjs');
