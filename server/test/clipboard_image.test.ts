import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdir,mkdtemp,rm} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../src/server.js';

test('clipboard images use normal transfers with center-stamped origin, explicit target and durable retry metadata',async()=>{
  const root=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));await mkdir(root,{recursive:true});
  const directory=await mkdtemp(join(root,'clipboard-image101-'));
  let app=await buildApp({dataDir:directory,diskReserve:0,log:false});
  await app.listen({host:'127.0.0.1',port:0});
  async function call(method:string,path:string,body?:unknown,token?:string){
    const response=await fetch(`http://127.0.0.1:${(app.server.address() as any).port}/api/v1${path}`,{method,
      headers:{...(token?{authorization:'Bearer '+token}:{}),...(body===undefined?{}:{'content-type':'application/json'})},
      ...(body===undefined?{}:{body:JSON.stringify(body)})});
    return {status:response.status,body:await response.json() as any};
  }
  try {
    const devices=[];
    for(let i=0;i<3;i++)devices.push((await call('POST','/devices/enroll',{name:'Same name',platform:'windows',groupKey:'clipboard-image101-test'})).body);
    const [source,target,unselected]=devices;
    assert.equal((await call('GET','/info')).body.features.clipboardImages,true);
    const body={transferId:'image-event',targetDeviceId:target.device.deviceId,clipboard:true,
      files:[{fileId:'image-file',name:'screenshot.png',size:3,mimeType:'image/png',sha256:'a'.repeat(64)}]};
    const offered=await call('POST','/transfers',body,source.deviceToken);
    assert.equal(offered.status,201,JSON.stringify(offered.body));
    const expected={originDeviceId:source.device.deviceId,sourceEventId:body.transferId};
    assert.deepEqual(offered.body.transfer.clipboard,expected);
    assert.equal((await call('POST','/transfers',body,source.deviceToken)).body.replayed,true);
    assert.equal((await call('GET','/transfers',undefined,unselected.deviceToken)).body.transfers.length,0);
    assert.equal((await call('POST','/transfers',{...body,clipboard:false},source.deviceToken)).status,400);
    assert.equal((await call('POST','/transfers',{...body,transferId:'not-an-image',files:[{...body.files[0],mimeType:'text/plain'}]},source.deviceToken)).status,400);
    await app.close();app=await buildApp({dataDir:directory,diskReserve:0,log:false});await app.listen({host:'127.0.0.1',port:0});
    const received=(await call('GET','/transfers',undefined,target.deviceToken)).body.transfers;
    assert.deepEqual(received[0].clipboard,expected);
    const plain=await call('POST','/transfers',{transferId:'plain-file',targetDeviceId:target.device.deviceId,files:[{...body.files[0],fileId:'plain-file'}]},source.deviceToken);
    assert.equal(plain.status,201);assert.equal(plain.body.transfer.clipboard,undefined);
  } finally {await app.close();await rm(directory,{recursive:true,force:true});}
});
