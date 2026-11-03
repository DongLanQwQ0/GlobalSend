import test from 'node:test';
import assert from 'node:assert/strict';
import {DeviceUsage,recordAcceptedDeviceSend} from '../src/device_usage.ts';
import {RecentDevices} from '../src/recent_devices.ts';
import type {Device} from '../src/model.ts';

test('device frequency persists, deduplicates groups/retries, ignores names, and keeps ties stable',()=>{
  let saved:string|null=null;
  const usage=new DeviceUsage(()=>saved,value=>saved=value);
  recordAcceptedDeviceSend('/texts','POST',{targetDeviceId:'b',eventId:'1'},usage);
  recordAcceptedDeviceSend('/texts','POST',{targetDeviceId:'b',eventId:'1'},usage);
  recordAcceptedDeviceSend('/transfers','POST',{targetDeviceId:'c',transferId:'1'},usage);
  recordAcceptedDeviceSend('/texts','POST',{targetDeviceId:'c',eventId:'1'},usage);
  recordAcceptedDeviceSend('/texts','POST',{targetDeviceId:'a',eventId:'auto',clipboard:{}},usage);
  recordAcceptedDeviceSend('/transfers','POST',{targetDeviceId:'a',transferId:'auto',clipboard:true},usage);
  recordAcceptedDeviceSend('/transfers','POST',{targetDeviceId:'a',transferId:'pull',copiedFile:{}},usage);
  recordAcceptedDeviceSend('/texts/1','PATCH',{targetDeviceId:'a',eventId:'edit'},usage);
  const peers=['a','b','c','b'].map(deviceId=>({deviceId,name:'Same'}));
  const restored=new DeviceUsage(()=>saved);
  assert.deepEqual(restored.rank(peers).map(x=>x.deviceId),['c','b','a']);
  restored.record('a','/texts:2');assert.deepEqual(restored.rank(peers).map(x=>x.deviceId),['c','a','b']);
});
test('rank never revives expired devices or changes the existing offline grace',()=>{
  const usage=new DeviceUsage();usage.record('b','text:1');
  const recent=new RecentDevices();let peers=recent.merge([],['a','b'].map(deviceId=>({deviceId,online:true} as Device)),1000);
  peers=recent.merge(peers,[{deviceId:'a',online:true} as Device],2000);
  assert.deepEqual(usage.rank(peers.filter(x=>recent.available(x,3000))).map(x=>x.deviceId),['b','a']);
  assert.deepEqual(usage.rank(peers.filter(x=>recent.available(x,32000))).map(x=>x.deviceId),['a']);
});
