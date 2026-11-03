import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdir,mkdtemp,rm} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {buildApp} from '../src/server.js';
import type {HTTPMethods} from 'fastify';

test('automatic text shares regular protocol limits on create, retry, edit and explicit forwarding',async()=>{
  const parent=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));
  await mkdir(parent,{recursive:true});
  const directory=await mkdtemp(join(parent,'clipboard-text115-server-'));
  const app=await buildApp({dataDir:directory,diskReserve:0,log:false});
  type Session={deviceToken:string;device:{deviceId:string}};
  async function call(method:string,path:string,body?:unknown,session?:Session){
    const response=await app.inject({method:method as HTTPMethods,url:'/api/v1'+path,
      headers:session?{authorization:'Bearer '+session.deviceToken}:{},
      ...(body===undefined?{}:{headers:{'content-type':'application/json',...(session?{authorization:'Bearer '+session.deviceToken}:{})},payload:JSON.stringify(body)})});
    return {status:response.statusCode,body:response.json()};
  }
  try {
    const sessions:Session[]=[];
    for(let i=0;i<4;i++)sessions.push((await call('POST','/devices/enroll',{
      name:'Fixture '+i,platform:'windows',groupKey:i===3?'clipboard-text115-other':'clipboard-text115-common',
    })).body);
    const [source,target,unselected,outsider]=sessions;
    const limit=(await call('GET','/info')).body.limits.maxTextLength;
    const longText='正文'.repeat(8000);
    assert.ok(Buffer.byteLength(longText)>8192);
    const first={eventId:'clipboard-115',targetDeviceId:target.device.deviceId,text:longText,clipboard:{}};
    const created=await call('POST','/texts',first,source);
    assert.equal(created.status,201,JSON.stringify(created.body));
    assert.deepEqual(created.body.event.payload.clipboard,{originDeviceId:source.device.deviceId,sourceEventId:first.eventId});
    assert.equal((await call('POST','/texts',first,source)).body.replayed,true);
    const maximum='x'.repeat(limit);
    assert.equal((await call('POST','/texts',{...first,eventId:'clipboard-max',text:maximum},source)).status,201);
    for(const automatic of [false,true]) {
      const tooLong=await call('POST','/texts',{eventId:'too-long-'+automatic,targetDeviceId:target.device.deviceId,text:maximum+'x',...(automatic?{clipboard:{}}:{})},source);
      assert.equal(tooLong.status,400);
    }
    const edited=await call('PATCH','/texts/'+first.eventId,{text:longText+' edited'},source);
    assert.equal(edited.status,200,JSON.stringify(edited.body));
    assert.equal(edited.body.event.payload.text,longText+' edited');
    assert.equal((await call('PATCH','/texts/'+first.eventId,{text:maximum+'x'},source)).status,400);
    const forwarded=await call('POST','/texts',{eventId:'clipboard-forward',targetDeviceId:unselected.device.deviceId,text:longText+' edited',clipboard:{sourceEventId:first.eventId}},target);
    assert.equal(forwarded.status,201,JSON.stringify(forwarded.body));
    assert.equal(forwarded.body.event.payload.clipboard.originDeviceId,source.device.deviceId);
    assert.equal((await call('POST','/texts',{...first,eventId:'cross-group',targetDeviceId:outsider.device.deviceId},source)).status,403);
    const createdEvents=(await call('GET','/events?after=0&limit=100',undefined,unselected)).body.events.filter((event:any)=>event.type==='text.created');
    assert.deepEqual(createdEvents.map((event:any)=>event.eventId),['clipboard-forward']);
    assert.deepEqual((await call('GET','/texts/latest',undefined,target)).body.documents,[]);
  } finally {await app.close();await rm(directory,{recursive:true,force:true});}
});
