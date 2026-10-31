import { spawn } from 'node:child_process';
import { access, copyFile, cp, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// Existing project tooling, isolated package and project tree. A debug build
// permits run-as to read only synthetic acceptance state; never ship this APK.
const root = fileURLToPath(new URL('../', import.meta.url));
const center = process.argv[2];
const publication = process.argv.includes('--publication');
if (!/^http:\/\/10\.0\.2\.2:\d+$/.test(center || '')) throw new Error('Provide the isolated host-center URL for the emulator.');
const project = join(root, 'client/build/background-android-probe');
const sdk = process.env.FLUTTER_ROOT || 'E:/Programs/flutter';
const temporary = join(root, 'artifacts/tmp/background-android-probe-build');
await mkdir(temporary, { recursive: true }); await mkdir(project, { recursive: true });
const env = { ...process.env, PUB_CACHE: 'F:/Caches/PubCache', GRADLE_USER_HOME: 'F:/Android/GradleCache',
  ANDROID_HOME: 'F:/Android/Sdk', JAVA_HOME: 'D:/Minecraft/java21', TEMP: temporary, TMP: temporary,
  CI: 'true', FLUTTER_SUPPRESS_ANALYTICS: 'true' };
async function flutter(args) {
  const child = spawn(join(sdk, 'bin/cache/dart-sdk/bin/dart.exe'), [join(sdk, 'bin/cache/flutter_tools.snapshot'), ...args],
    { cwd: project, env, windowsHide: true, stdio: 'inherit' });
  await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', code => code === 0 ? resolve() : reject(new Error('Flutter exited ' + code))); });
}
try { await access(join(project, 'android/gradlew.bat')); }
catch { await flutter(['create', '--platforms=android', '--android-language=java', '--org=dev.globalsend', '--project-name=background_receive_probe', '--no-pub', '.']); }
let pub = await readFile(join(root, 'client/pubspec.yaml'), 'utf8');
pub = pub.replace(/^name: globalsend/m, 'name: background_receive_probe').replace(/^dependencies:\r?\n/m, 'dependencies:\n  globalsend:\n    path: ../..\n');
await writeFile(join(project, 'pubspec.yaml'), pub);
await cp(join(root, 'client/assets'), join(project, 'assets'), { recursive: true });
await copyFile(join(root, 'client/tool/background_receive_probe.dart'), join(project, 'lib/main.dart'));
await cp(join(root, 'client/android/app/src/main/java/dev'), join(project, 'android/app/src/main/java/dev'), { recursive: true });
await cp(join(root, 'client/android/app/src/main/res'), join(project, 'android/app/src/main/res'), { recursive: true });
for (const path of ['build.gradle.kts', 'settings.gradle.kts', 'gradle.properties'])
  await copyFile(join(root, 'client/android', path), join(project, 'android', path));
let gradle = await readFile(join(root, 'client/android/app/build.gradle.kts'), 'utf8');
gradle = gradle.replace('applicationId = "dev.globalsend.globalsend"', `applicationId = "dev.globalsend.${publication ? 'publicationprobe' : 'backgroundprobe'}"`);
await writeFile(join(project, 'android/app/build.gradle.kts'), gradle);
let manifest = await readFile(join(root, 'client/android/app/src/main/AndroidManifest.xml'), 'utf8');
manifest = manifest.replace('android:label="GlobalSend"', 'android:label="GlobalSend 后台验收"').replaceAll(/android:name="\.(\w+)"/g, 'android:name="dev.globalsend.globalsend.$1"');
await writeFile(join(project, 'android/app/src/main/AndroidManifest.xml'), manifest);
const sources = [];
for (const name of ['NativeReceiveRuntime', 'MainActivity', 'BackgroundReceiveService', 'BackgroundReceiveBridge', 'BackgroundReceiveRestart', 'DockCoordinator', 'ReceiveDirectory', 'ReceiveNotifications', 'ReceiveNotificationBridge']) {
  const path = `client/android/app/src/main/java/dev/globalsend/globalsend/${name}.java`;
  const metadata = await stat(join(root, path));
  sources.push({ path, bytes: metadata.size, modified: metadata.mtime.toISOString() });
}
await writeFile(join(project, 'production-snapshot.json'), JSON.stringify({ center, createdAt: new Date().toISOString(), sources }, null, 2));
await flutter(['pub', 'get', '--offline']);
await flutter(['build', 'apk', '--debug', '--no-pub', '--target-platform=android-x64',
  '--dart-define=GLOBALSEND_BACKGROUND_FIXTURE_CENTER=' + center,
  ...(publication ? ['--dart-define=GLOBALSEND_PUBLICATION_FIXTURE=true'] : []),
  '--android-project-arg=globalsendAbi=x86_64', '--android-project-arg=disable-abi-filtering=true', '--android-project-arg=globalsendCompressNative=true']);
console.log('Background acceptance APK:', join(project, 'build/app/outputs/flutter-apk/app-debug.apk'));
