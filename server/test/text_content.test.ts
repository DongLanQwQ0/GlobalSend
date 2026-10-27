import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join} from 'node:path';
import {randomUUID} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {buildApp} from '../src/server.ts';

test('identical texts share revisions across deliveries, merge on edit, and catch up after event expiry and restart',async()=>{
  const root=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));await mkdir(root,{recursive:true});
  const dataDir=await mkdtemp(join(root,'text-content-'));
  let app=await buildApp({dataDir,log:false,diskReserve:0,webEnabled:false});
  async function request(path:string,session:any,body?:any,method=body?'POST':'GET') {
    const response=await app.inject({url:'/api/v1'+path,method:method as any,headers:session?{authorization:'Bearer '+session.deviceToken}:{},...(body?{payload:body}:{})});
    assert.ok(response.statusCode<300,response.body);return response.json();
  }
  try{
    const enroll=(name:string,groupKey='same-texts-group-key')=>request('/devices/enroll',null,{name,platform:'web',groupKey});
    const [a,b,c,d,other]=await Promise.all(['a','b','c','d'].map(name=>enroll(name)).concat(enroll('other','unrelated-group-password')));
    const send=(session:any,to:any,text:string,eventId=randomUUID())=>request('/texts',session,{eventId,targetDeviceId:to.device.deviceId,text});
    const ab=(await send(a,b,'first')).event,ac=(await send(a,c,'first')).event,db=(await send(d,b,'first')).event;
    assert.equal(ab.payload.contentId,ac.payload.contentId);assert.equal(ab.payload.contentId,db.payload.contentId);
    const update=(await request('/texts/'+ab.eventId,a,{text:'edited'},'PATCH')).event;
    assert.equal(update.payload.revision,2);
    for(const session of [a,b,c,d]){const {documents}=await request('/texts/latest',session);assert.equal(documents.length,1);assert.equal(documents[0].text,'edited');assert.equal(documents[0].revision,2);}
    assert.equal((await request('/texts/latest',other)).documents.length,0);
    // Retrying the original send remains idempotent after editing its shared content.
    const replay=await send(a,b,'first',ab.eventId);assert.equal(replay.replayed,true);assert.equal(replay.event.payload.text,'edited');
    const second=(await send(a,b,'second')).event;
    await request('/texts/'+second.eventId,a,{text:'edited'},'PATCH');
    assert.equal((await request('/texts/latest',a)).documents.length,1);
    await request('/texts/'+ac.eventId,a,{text:'last-confirmed'},'PATCH');
    assert.equal((await request('/texts/latest',d)).documents[0].text,'last-confirmed');
    const before=(await request('/texts/latest',b)).documents[0];
    assert.ok(before.sourceEventIds.includes(ab.eventId));assert.ok(before.sourceEventIds.includes(db.eventId));
    await app.close();
    const dbFile=new DatabaseSync(join(dataDir,'globalsend.sqlite'));dbFile.exec('DELETE FROM events');dbFile.close();
    app=await buildApp({dataDir,log:false,diskReserve:0,webEnabled:false});
    assert.deepEqual((await request('/texts/latest',b)).documents,[before]);
    const forbidden=await app.inject({url:'/api/v1/texts/'+ac.eventId,method:'PATCH',headers:{authorization:'Bearer '+b.deviceToken},payload:{text:'not-owner'}});
    assert.equal(forbidden.statusCode,404);
  }finally{await app.close();}
});
