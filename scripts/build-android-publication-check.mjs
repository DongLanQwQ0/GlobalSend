import {spawn} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
const root=fileURLToPath(new URL('../',import.meta.url));
const out=join(root,'client/build/publication-check');
for(const part of ['classes','dex','tmp'])await mkdir(join(out,part),{recursive:true});
const sdk='F:/Android/Sdk',java='D:/Minecraft/java21',tools=join(sdk,'build-tools/36.0.0');
const android=join(sdk,'platforms/android-36/android.jar');
const env={...process.env,TEMP:join(out,'tmp'),TMP:join(out,'tmp')};
async function run(exe,args){const p=spawn(exe,args,{cwd:out,env,windowsHide:true,stdio:'inherit'});await new Promise((resolve,reject)=>{p.on('error',reject);p.on('exit',code=>code===0?resolve():reject(new Error(`${exe}: ${code}`)));});}
await writeFile(join(out,'AndroidManifest.xml'),`<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.globalsend.publicationcheck" android:versionCode="1" android:versionName="1.0">
<uses-sdk android:minSdkVersion="30" android:targetSdkVersion="36"/>
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
<application android:label="GlobalSend publication check" android:debuggable="true" android:allowBackup="false" android:theme="@android:style/Theme.Material.Light.NoActionBar">
<activity android:name="dev.globalsend.globalsend.ReceivedFilePublicationActivity" android:exported="true"/>
</application></manifest>`);
await run(join(java,'bin/javac.exe'),['-encoding','UTF-8','--release','17','-classpath',android,'-d',join(out,'classes'),join(root,'client/android/app/src/main/java/dev/globalsend/globalsend/ReceivedFilePublication.java'),join(root,'client/tool/android/ReceivedFilePublicationActivity.java')]);
await run(join(java,'bin/jar.exe'),['--create','--file',join(out,'check.jar'),'-C',join(out,'classes'),'.']);
await run(join(java,'bin/java.exe'),['-cp',join(tools,'lib/d8.jar'),'com.android.tools.r8.D8','--min-api','30','--lib',android,'--output',join(out,'dex'),join(out,'check.jar')]);
await run(join(tools,'aapt2.exe'),['link','--manifest',join(out,'AndroidManifest.xml'),'-I',android,'-o',join(out,'unsigned.apk')]);
await run(join(java,'bin/jar.exe'),['--update','--file',join(out,'unsigned.apk'),'-C',join(out,'dex'),'classes.dex']);
await run(join(tools,'zipalign.exe'),['-f','4',join(out,'unsigned.apk'),join(out,'aligned.apk')]);
await run(join(java,'bin/java.exe'),['-jar',join(tools,'lib/apksigner.jar'),'sign','--ks',join(process.env.USERPROFILE,'.android/debug.keystore'),'--ks-pass','pass:android','--key-pass','pass:android','--out',join(out,'publication-check.apk'),join(out,'aligned.apk')]);
console.log(join(out,'publication-check.apk'));
