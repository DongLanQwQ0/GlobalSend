import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../src/server.js';
const hash=(value:string)=>createHash('sha256').update(value).digest('hex');

test('folder metadata and ordinary resumable bytes persist without ZIP or a 32-entry ceiling',async()=>{
 const root=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));await mkdir(root,{recursive:true});const dir=await mkdtemp(join(root,'folder-center-'));
 let app=await buildApp({dataDir:dir,diskReserve:0,log:false});
 const call=async(method:any,path:string,body?:any,token?:string)=>{const r=await app.inject({method,url:'/api/v1'+path,headers:{...(token?{authorization:'Bearer '+token}:{}),...(Buffer.isBuffer(body)?{'content-type':'application/octet-stream'}:{})},payload:body});return {status:r.statusCode,body:r.headers['content-type']?.includes('json')?r.json():r.rawPayload};};
 try{
  const a=(await call('POST','/devices/enroll',{name:'Sender',platform:'windows',groupKey:'folder-transfer-test'})).body;
  const b=(await call('POST','/devices/enroll',{name:'Receiver',platform:'android',groupKey:'folder-transfer-test'})).body;
  const files=[{fileId:'root',name:'资料',size:0,mimeType:'inode/directory',sha256:hash(''),relativePath:'资料',entryKind:'directory'}, {fileId:'empty',name:'空目录',size:0,mimeType:'inode/directory',sha256:hash(''),relativePath:'资料/空目录',entryKind:'directory'}, ...Array.from({length:70},(_,i)=>({fileId:'f'+i,name:'note'+i+'.txt',size:6,sha256:hash('abcdef'),relativePath:'资料/sub/note'+i+'.txt',entryKind:'file'}))];
  const body={transferId:'folder',targetDeviceId:b.device.deviceId,files,routePreference:'relay'};
  assert.equal((await call('POST','/transfers',body,a.deviceToken)).body.error.code,'RECEIVER_UPGRADE_REQUIRED');
  assert.equal((await call('POST','/devices/me/capabilities',{folderTransfer:true},b.deviceToken)).body.device.folderTransfer,true);
  const offered=await call('POST','/transfers',body,a.deviceToken);assert.equal(offered.status,201,JSON.stringify(offered.body));assert.equal(offered.body.transfer.files.length,72);
  assert.equal((await call('POST','/transfers',body,a.deviceToken)).body.replayed,true);
  assert.equal((await call('POST','/transfers/folder/accept',{fileIds:files.map(f=>f.fileId)},b.deviceToken)).status,200);
  assert.equal((await call('POST','/transfers/folder/files/root/received',{},b.deviceToken)).body.file.status,'received');
  assert.equal((await call('PUT','/transfers/folder/files/f0/chunks?offset=0',Buffer.from('abc'),a.deviceToken)).body.file.offset,3);
  await app.close();app=await buildApp({dataDir:dir,diskReserve:0,log:false});
  const restored=(await call('GET','/transfers/folder',undefined,b.deviceToken)).body.transfer;assert.equal(restored.files[2].relativePath,'资料/sub/note0.txt');assert.equal(restored.files[2].offset,3);assert.equal(restored.files[1].entryKind,'directory');
  assert.equal((await call('PUT','/transfers/folder/files/f0/chunks?offset=3',Buffer.from('def'),a.deviceToken)).body.file.offset,6);
  assert.equal((await call('POST','/transfers/folder/files/f0/complete',{},a.deviceToken)).status,200);
  assert.equal((await call('POST','/transfers/folder/files/f0/received',{},b.deviceToken)).status,200);
  const invalid={...body,transferId:'invalid',files:[{...files[2],relativePath:'../note0.txt'}]};assert.equal((await call('POST','/transfers',invalid,a.deviceToken)).body.error.code,'INVALID_RELATIVE_PATH');
  const ordinary={transferId:'ordinary',targetDeviceId:b.device.deviceId,files:[{fileId:'legacy',name:'old.zip',size:0,sha256:hash('')}]};assert.equal((await call('POST','/transfers',ordinary,a.deviceToken)).status,201);
  assert.equal((await call('GET','/info')).body.features.folderTransfer,true);
 }finally{await app.close();}
});
