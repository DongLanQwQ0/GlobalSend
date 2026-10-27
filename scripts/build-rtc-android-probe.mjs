import { spawn } from 'node:child_process';
import { access, copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

// Separate app ID and build tree: never install over the user's GlobalSend.
// Snapshot the production Dart transport and Android bridge at build time.
const root=fileURLToPath(new URL('../',import.meta.url));
const project=join(root,'client/build/rtc-android-probe');
const sdk=process.env.FLUTTER_ROOT || 'E:/Programs/flutter';
const temporary=join(root,'artifacts/tmp/rtc-android-probe-build');
await mkdir(temporary,{recursive:true});
const env={...process.env,PUB_CACHE:process.env.PUB_CACHE || 'F:/Caches/PubCache',
  GRADLE_USER_HOME:process.env.GRADLE_USER_HOME || 'F:/Android/GradleCache',
  ANDROID_HOME:process.env.ANDROID_HOME || 'F:/Android/Sdk',
  JAVA_HOME:process.env.JAVA_HOME || 'D:/Minecraft/java21',TEMP:temporary,TMP:temporary,
  CI:'true',FLUTTER_SUPPRESS_ANALYTICS:'true'};
async function flutter(args){
  const child=spawn(join(sdk,'bin/cache/dart-sdk/bin/dart.exe'),[join(sdk,'bin/cache/flutter_tools.snapshot'),...args],
    {cwd:project,env,windowsHide:true,stdio:'inherit'});
  await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(new Error('Flutter exited '+code)));});
}
await mkdir(project,{recursive:true});
try{await access(join(project,'android/gradlew.bat'));}
catch{await flutter(['create','--platforms=android','--android-language=java','--org=dev.globalsend','--project-name=rtc_jni_probe','--no-pub','.']);}
await writeFile(join(project,'pubspec.yaml'),`name: rtc_jni_probe
publish_to: none
version: 1.0.0+1
environment:
  sdk: ^3.13.2
dependencies:
  flutter:
    sdk: flutter
  globalsend:
    path: ../..
flutter:
  uses-material-design: false
`);
const sources=[];
async function snapshot(from,to){
  await copyFile(join(root,from),join(project,to));
  const metadata=await stat(join(root,from));sources.push({source:from,bytes:metadata.size,modified:metadata.mtime.toISOString()});
}
for(const name of ['api','rtc_transport','rtc_connection','rtc_candidates'])await snapshot(`client/lib/${name}.dart`,`lib/${name}.dart`);
let main=await readFile(join(root,'client/tool/rtc_transfer_probe.dart'),'utf8');
main=main.replaceAll("package:globalsend/",'');
main="import 'package:crypto/crypto.dart';\n"+main;
main=main.replace("var state = 'idle', progress = 0, error = '';","var state = 'idle', progress = 0, error = '', destinationHash = '';");
main=main.replace("await action();\n        state = 'done';","await action();\n        destinationHash = (await sha256.bind(destination.openRead()).first).toString();\n        state = 'done';");
main=main.replace("'destination': destination.path,","'destination': destination.path,\n              'destinationHash': destinationHash,");
main=main.replace('final root = Directory(args.single)..createSync(recursive: true);',
  "final root = Directory.systemTemp.createTempSync('globalsend-rtc-jni-');");
main=main.replace('HttpServer.bind(InternetAddress.loopbackIPv4, 0)','HttpServer.bind(InternetAddress.loopbackIPv4, 47080)');
await writeFile(join(project,'lib/probe_main.dart'),main);
const java='android/app/src/main/java/dev/globalsend/globalsend';await mkdir(join(project,java),{recursive:true});
for(const name of ['RtcDataBridge','RtcRuntime','RtcCellularLease','RtcNetworkPolicy','PassiveRtcNetworkDetector']){
  await snapshot(`client/android/app/src/main/java/dev/globalsend/globalsend/${name}.java`,`${java}/${name}.java`);
}
await writeFile(join(project,java,'ProbeActivity.java'),`package dev.globalsend.globalsend;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
public final class ProbeActivity extends FlutterActivity {
  private RtcDataBridge bridge;
  @Override public void configureFlutterEngine(FlutterEngine engine) {
    super.configureFlutterEngine(engine);
    bridge=new RtcDataBridge(this,engine.getDartExecutor().getBinaryMessenger());
  }
  @Override public void cleanUpFlutterEngine(FlutterEngine engine) {
    if(bridge!=null){bridge.dispose();bridge=null;}
    super.cleanUpFlutterEngine(engine);
  }
}
`);
for(const path of ['build.gradle.kts','settings.gradle.kts','gradle.properties'])await copyFile(join(root,'client/android',path),join(project,'android',path));
let gradle=await readFile(join(root,'client/android/app/build.gradle.kts'),'utf8');
gradle=gradle.replaceAll('dev.globalsend.globalsend','dev.globalsend.rtcprobe');
await writeFile(join(project,'android/app/build.gradle.kts'),gradle);
await writeFile(join(project,'android/app/src/main/AndroidManifest.xml'),`<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">
  <uses-permission android:name="android.permission.INTERNET"/>
  <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
  <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE"/>
  <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" tools:node="remove"/>
  <uses-permission android:name="android.permission.BLUETOOTH" tools:node="remove"/>
  <application android:label="GlobalSend RTC JNI probe" android:name="android.app.Application" android:usesCleartextTraffic="true">
    <activity android:name="dev.globalsend.globalsend.ProbeActivity" android:exported="true" android:theme="@style/LaunchTheme" android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode" android:hardwareAccelerated="true">
      <meta-data android:name="io.flutter.embedding.android.NormalTheme" android:resource="@style/NormalTheme"/>
      <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
    </activity>
    <meta-data android:name="flutterEmbedding" android:value="2"/>
  </application>
</manifest>
`);
await writeFile(join(project,'production-snapshot.json'),JSON.stringify({createdAt:new Date().toISOString(),sources},null,2));
await flutter(['pub','get']);
await flutter(['build','apk','--release','--no-pub','--target=lib/probe_main.dart','--target-platform=android-x64',
  '--android-project-arg=globalsendAbi=x86_64','--android-project-arg=disable-abi-filtering=true','--android-project-arg=globalsendCompressNative=true']);
console.log('Separate Android JNI consumer:',join(project,'build/app/outputs/flutter-apk/app-release.apk'));
