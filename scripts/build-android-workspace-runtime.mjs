import { spawn } from 'node:child_process';
import { copyFile, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// UI-only counterpart to the existing isolated JNI consumer. This APK has no
// network permission and never installs over the user's GlobalSend package.
const root=fileURLToPath(new URL('../',import.meta.url));
const build=join(root,'client/build/workspace-android-runtime');
const java=process.env.JAVA_HOME||'D:/Minecraft/java21';
const sdk=process.env.ANDROID_HOME||'F:/Android/Sdk';
const tools=join(sdk,'build-tools/36.0.0');
const flutter=process.env.FLUTTER_ROOT||'E:/Programs/flutter';
const temporary=join(build,'tmp');
await mkdir(temporary,{recursive:true});
const env={...process.env,TEMP:temporary,TMP:temporary};
const source=join(build,'src/dev/globalsend/globalsend');
const classes=join(build,'classes'),dex=join(build,'dex');
for(const path of [source,classes,dex])await mkdir(path,{recursive:true});
const snapshots=[];
const reuse=process.argv.includes('--reuse-production') ? JSON.parse(await readFile(join(build,'production-snapshot.json'),'utf8')).sources : null;
for(const name of ['DockCoordinator','DockShareProvider','ReceiveDirectory','ReceivedFilePublication','SendFolderArchive','ReceiveNotifications','ReceiveNotificationCopyReceiver']){
  const path=`client/android/app/src/main/java/dev/globalsend/globalsend/${name}.java`;
  if(reuse){snapshots.push(reuse.find(item=>item.source===path));}
  else {await copyFile(join(root,path),join(source,name+'.java'));
    const info=await stat(join(root,path));snapshots.push({source:path,bytes:info.size,modified:info.mtime.toISOString()});}
}
for(const name of ['WorkspaceRuntimeActivity','WorkspaceDocumentsProvider','WorkspaceNotificationActivity'])await copyFile(join(root,'client/tool/android',name+'.java'),join(source,name+'.java'));
await writeFile(join(source,'MainActivity.java'),'package dev.globalsend.globalsend; public final class MainActivity extends android.app.Activity {}\n');
await writeFile(join(build,'AndroidManifest.xml'),`<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.globalsend.workspaceprobe" android:versionCode="1" android:versionName="1.0">
 <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36"/>
 <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
 <application android:label="GlobalSend UI runtime" android:theme="@android:style/Theme.Material.Light.NoActionBar" android:debuggable="true" android:allowBackup="false">
  <activity android:name="dev.globalsend.globalsend.WorkspaceRuntimeActivity" android:exported="true">
  </activity>
  <activity android:name="dev.globalsend.globalsend.WorkspaceNotificationActivity" android:exported="true" android:launchMode="singleTop">
   <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
  </activity>
  <provider android:name="dev.globalsend.globalsend.WorkspaceDocumentsProvider" android:authorities="dev.globalsend.workspaceprobe.documents" android:exported="true" android:grantUriPermissions="true" android:permission="android.permission.MANAGE_DOCUMENTS">
   <intent-filter><action android:name="android.content.action.DOCUMENTS_PROVIDER"/></intent-filter>
  </provider>
  <provider android:name="dev.globalsend.globalsend.DockShareProvider" android:authorities="dev.globalsend.workspaceprobe.dock-files" android:exported="false" android:grantUriPermissions="true"/>
  <receiver android:name="dev.globalsend.globalsend.ReceiveNotificationCopyReceiver" android:exported="false"/>
 </application>
</manifest>`);
async function run(executable,args){
  const child=spawn(executable,args,{cwd:build,env,windowsHide:true,stdio:'inherit'});
  await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(new Error(executable+' exited '+code)));});
}
const android=join(sdk,'platforms/android-36/android.jar'),flutterJar=join(flutter,'bin/cache/artifacts/engine/android-arm64/flutter.jar');
await run(join(java,'bin/javac.exe'),['-J-Duser.language=en','-encoding','UTF-8','--release','17','-classpath',android+';'+flutterJar,'-d',classes,...snapshots.map(item=>join(source,item.source.split('/').pop())),join(source,'WorkspaceRuntimeActivity.java'),join(source,'WorkspaceDocumentsProvider.java'),join(source,'WorkspaceNotificationActivity.java'),join(source,'MainActivity.java')]);
await run(join(java,'bin/jar.exe'),['--create','--file',join(build,'consumer.jar'),'-C',classes,'.']);
await run(join(java,'bin/java.exe'),['-cp',join(tools,'lib/d8.jar'),'com.android.tools.r8.D8','--min-api','24','--lib',android,'--output',dex,join(build,'consumer.jar'),flutterJar]);
await run(join(tools,'aapt2.exe'),['link','--manifest',join(build,'AndroidManifest.xml'),'-I',android,'-o',join(build,'consumer-unsigned.apk')]);
await run(join(java,'bin/jar.exe'),['--update','--file',join(build,'consumer-unsigned.apk'),'-C',dex,'classes.dex']);
await run(join(tools,'zipalign.exe'),['-f','4',join(build,'consumer-unsigned.apk'),join(build,'consumer-aligned.apk')]);
await run(join(java,'bin/java.exe'),['-jar',join(tools,'lib/apksigner.jar'),'sign','--ks',process.env.ANDROID_DEBUG_KEYSTORE||join(process.env.USERPROFILE,'.android/debug.keystore'),'--ks-pass','pass:android','--key-pass','pass:android','--out',join(build,'workspace-runtime.apk'),join(build,'consumer-aligned.apk')]);
await writeFile(join(build,'production-snapshot.json'),JSON.stringify({builtAt:new Date().toISOString(),package:'dev.globalsend.workspaceprobe',networkPermission:false,sources:snapshots},null,2));
console.log('UI-only Android runtime consumer:',join(build,'workspace-runtime.apk'));
