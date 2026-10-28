import {spawnSync} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import {resolve,join} from 'node:path';
const root=resolve(import.meta.dirname,'../../..');
const out=join(root,'artifacts/tmp/android-shelf-acceptance');
const java='D:/Minecraft/java21/bin',tools='F:/Android/Sdk/build-tools/36.0.0';
const android='F:/Android/Sdk/platforms/android-36/android.jar';
for(const dir of ['classes','dex','tmp'])await mkdir(join(out,dir),{recursive:true});
const manifest=join(out,'AndroidManifest.xml');
await writeFile(manifest,`<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.globalsend.shelfacceptance" android:versionCode="1" android:versionName="1.0"><uses-sdk android:minSdkVersion="30" android:targetSdkVersion="36"/><application android:label="GlobalSend shelf acceptance" android:theme="@android:style/Theme.Material.Light.NoActionBar" android:debuggable="true" android:allowBackup="false"><activity android:name=".ShelfAcceptanceActivity" android:exported="true"/></application></manifest>`);
function run(exe,args){const result=spawnSync(exe,args,{cwd:out,env:{...process.env,TEMP:join(out,'tmp'),TMP:join(out,'tmp')},windowsHide:true,stdio:'inherit'});if(result.error)throw result.error;if(result.status!==0)throw new Error(exe+' failed '+result.status);}
run(join(java,'javac.exe'),['-encoding','UTF-8','--release','17','-classpath',android,'-d',join(out,'classes'),join(import.meta.dirname,'ShelfAcceptanceActivity.java')]);
run(join(java,'jar.exe'),['--create','--file',join(out,'classes.jar'),'-C',join(out,'classes'),'.']);
run(join(java,'java.exe'),['-cp',join(tools,'lib/d8.jar'),'com.android.tools.r8.D8','--min-api','30','--lib',android,'--output',join(out,'dex'),join(out,'classes.jar')]);
run(join(tools,'aapt2.exe'),['link','--manifest',manifest,'-I',android,'-o',join(out,'unsigned.apk')]);
run(join(java,'jar.exe'),['--update','--file',join(out,'unsigned.apk'),'-C',join(out,'dex'),'classes.dex']);
run(join(tools,'zipalign.exe'),['-f','4',join(out,'unsigned.apk'),join(out,'aligned.apk')]);
run(join(java,'java.exe'),['-jar',join(tools,'lib/apksigner.jar'),'sign','--ks',join(process.env.USERPROFILE,'.android/debug.keystore'),'--ks-pass','pass:android','--key-pass','pass:android','--out',join(out,'shelf-acceptance.apk'),join(out,'aligned.apk')]);
console.log(join(out,'shelf-acceptance.apk'));
