import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// Default download for modern Android phones, without split APK version-code
// prefixes. The universal option retains ARMv7 and x86_64 compatibility.
const universal=process.argv.includes('--universal');
const requested=process.argv.find(value=>value.startsWith('--abi='))?.slice(6) || 'arm64-v8a';
const targets={'arm64-v8a':'android-arm64','armeabi-v7a':'android-arm','x86_64':'android-x64'};
if(!(requested in targets) || process.argv.slice(2).some(value=>value!=='--universal' && !value.startsWith('--abi=')) || universal && process.argv.some(value=>value.startsWith('--abi=')))throw new Error('Usage: node scripts/build-android.mjs [--abi=arm64-v8a|armeabi-v7a|x86_64 | --universal]');
const root=fileURLToPath(new URL('../',import.meta.url));
const sdk=process.env.FLUTTER_ROOT || 'E:/Programs/flutter';
const temporary=join(root,'client/build/tmp');await mkdir(temporary,{recursive:true});
const env={...process.env,PUB_CACHE:process.env.PUB_CACHE || 'F:/Caches/PubCache',
  GRADLE_USER_HOME:process.env.GRADLE_USER_HOME || 'F:/Android/GradleCache',
  ANDROID_HOME:process.env.ANDROID_HOME || 'F:/Android/Sdk',
  JAVA_HOME:process.env.JAVA_HOME || 'D:/Minecraft/java21',TEMP:temporary,TMP:temporary,
  FLUTTER_SUPPRESS_ANALYTICS:'true'};
delete env.ORG_GRADLE_PROJECT_globalsendAbi;
const args=[join(sdk,'bin/cache/flutter_tools.snapshot'),'build','apk','--release','--no-pub',
  '--android-project-arg=globalsendCompressNative=true',
  ...(universal?[]:['--target-platform',targets[requested],`--android-project-arg=globalsendAbi=${requested}`,'--android-project-arg=disable-abi-filtering=true'])];
const child=spawn(join(sdk,'bin/cache/dart-sdk/bin/dart.exe'),args,{cwd:join(root,'client'),env,windowsHide:true,stdio:'inherit'});
child.on('error',error=>{console.error(error.message);process.exitCode=1;});
child.on('exit',code=>{process.exitCode=code ?? 1;});
