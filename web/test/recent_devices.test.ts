import test from 'node:test';
import assert from 'node:assert/strict';
import { RecentDevices } from '../src/recent_devices.ts';
import type { Device } from '../src/model.ts';

const phone={deviceId:'phone',name:'手机',online:true,platform:'android',revoked:false,createdAt:'',peer:{candidates:['https://[2408::1]:8788']},rtc:{scopes:['public']}} as Device;
test('offline grace preserves last metadata, expires exactly at 30s and repeated snapshots never extend it',()=>{
  const recent=new RecentDevices();let devices=recent.merge([],[phone],1000);
  devices=recent.merge(devices,[],2000);
  assert.equal(devices[0].online,false);assert.deepEqual(devices[0].peer,phone.peer);
  assert.equal(recent.available(devices[0],31999),true);
  devices=recent.merge(devices,[],31000);assert.equal(recent.deadlines.get('phone'),32000);
  assert.equal(recent.available(devices[0],32000),false);assert.deepEqual(recent.merge(devices,[],32000),[]);
});
test('offline startup history never gains grace; reconnect replaces one record and reset clears scope',()=>{
  const recent=new RecentDevices();let devices=recent.merge([],[{...phone,online:false}],1000);
  assert.equal(recent.available(devices[0],1000),false);assert.equal(devices[0].peer,null);
  devices=recent.merge(devices,[phone],2000);devices=recent.merge(devices,[],3000);
  devices=recent.merge(devices,[{...phone,name:'新名称'}],4000);
  assert.equal(devices.length,1);assert.equal(devices[0].name,'新名称');assert.equal(recent.deadlines.size,0);
  devices=recent.merge(devices,[],5000);assert.equal(recent.deadlines.get('phone'),35000);
  assert.deepEqual(recent.merge(devices,[{...phone,revoked:true}],6000),[]);
  recent.clear();assert.equal(recent.deadlines.size,0);
});
