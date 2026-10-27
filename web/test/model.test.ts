import test from 'node:test';
import assert from 'node:assert/strict';
import { compactTime, baseFromLocation, centerWebSocketUrl, suggestedDeviceName, escapeHtml, formatBytes, mergeEvents, normalizeBaseUrl, safeDownloadUrl, storageKey } from '../src/model.ts';
import type { WireEvent } from '../src/model.ts';
import {applyTextDocuments} from '../src/model.ts';
import { digestFile } from '../src/files.ts';
import { emptyGroupData, publicSession, validateGroupKey } from '../src/group.ts';

const event = (eventId: string,cursor: number,text = '重复文字'): WireEvent => ({
  eventId,cursor,protocolVersion:1,type:'text.created',sourceDeviceId:'source',targetDeviceId:'target',
  createdAt:'2026-10-24T00:00:00Z',expiresAt:'2030-01-01T00:00:00Z',payload:{text},
});

test('manual repeated text remains independent; transport replay stays idempotent',() => {
  const first = event('a',1), manualRepeat = event('b',2);
  const merged = mergeEvents([first],[first,manualRepeat],Date.parse('2026-10-24'));
  assert.deepEqual(merged.map(item=>item.eventId),['a','b']);
  assert.equal(merged[0].payload.text,merged[1].payload.text);
});
test('expiry filters both old state and incoming notifications',() => {
  const expired = {...event('old',1),expiresAt:'2026-10-23T00:00:00Z'};
  assert.deepEqual(mergeEvents([expired],[event('new',3)],Date.parse('2026-10-24')).map(item=>item.eventId),['new']);
});
test('canonical versions update all delivery cards and offline snapshots without stale rollback',()=>{
  const a=event('a',1,'old'),b={...event('b',2,'old'),targetDeviceId:'other'};
  const current=applyTextDocuments([a,b],[{contentId:'content',sourceEventIds:['a','b'],revision:3,text:'latest',editedAt:'today'}]);
  assert.deepEqual(current.map(row=>row.payload.text),['latest','latest']);
  const stale:WireEvent={...event('update',8),type:'text.updated',payload:{contentId:'content',sourceEventIds:['a'],sourceEventId:'a',revision:2,text:'stale',editedAt:'yesterday'}};
  assert.deepEqual(mergeEvents(current,[stale]).filter(row=>row.type==='text.created').map(row=>row.payload.text),['latest','latest']);
  const next={...stale,eventId:'update-new',cursor:9,payload:{...stale.payload,revision:4,text:'newest'}};
  assert.deepEqual(mergeEvents(current,[next]).filter(row=>row.type==='text.created').map(row=>row.payload.text),['newest','newest']);
});
test('events are cursor ordered, including out-of-order websocket notifications',() => {
  assert.deepEqual(mergeEvents([event('c',3)],[event('a',1),event('b',2)],Date.parse('2026-10-24')).map(item=>item.cursor),[1,2,3]);
});

test('edited text updates its existing card across out-of-order notifications and replay',() => {
  const original=event('original',1,'第一版');
  const first:WireEvent={...event('edit-first',2),type:'text.updated',payload:{sourceEventId:'original',text:'第二版',editedAt:'2026-10-24T01:00:00Z'}};
  const last:WireEvent={...event('edit-last',3),type:'text.updated',payload:{sourceEventId:'original',text:'第三版',editedAt:'2026-10-24T02:00:00Z'}};
  const merged=mergeEvents([original,last],[first,original],Date.parse('2026-10-24'));
  assert.equal(merged.filter(item=>item.type==='text.created').length,1);
  assert.equal(merged.find(item=>item.eventId==='original')!.payload.text,'第三版');
  assert.equal(original.payload.text,'第一版');
  const replay=mergeEvents(merged,[first,original],Date.parse('2026-10-24'));
  assert.equal(replay.find(item=>item.eventId==='original')!.payload.text,'第三版');
});
test('untrusted text cannot inject DOM markup',() => {
  assert.equal(escapeHtml('<img src=x onerror="alert(1)"> & \'x\''),'&lt;img src=x onerror=&quot;alert(1)&quot;&gt; &amp; &#39;x&#39;');
});
test('server normalization preserves prefix case and IPv6, permits local development only',() => {
  assert.equal(normalizeBaseUrl('https://EXAMPLE.com:443/Send/'),'https://example.com/Send');
  assert.equal(normalizeBaseUrl('https://[2001:db8::1]:8443/send/'),'https://[2001:db8::1]:8443/send');
  assert.equal(normalizeBaseUrl('http://127.0.0.1:8787'),'http://127.0.0.1:8787');
  for (const bad of ['http://example.com','https://user:pass@example.com','https://example.com?a=1','https://example.com/#a','javascript:alert(1)']) assert.throws(()=>normalizeBaseUrl(bad));
});
test('same origin with different base paths and reinstalls have separate storage keys',() => {
  assert.notEqual(storageKey('https://example.com/a','instance'),storageKey('https://example.com/b','instance'));
  assert.notEqual(storageKey('https://example.com','one'),storageKey('https://example.com','two'));
});
test('hosted app derives base prefix while Vite root stays at origin',() => {
  assert.equal(baseFromLocation({origin:'https://example.com',pathname:'/Send/app/'}),'https://example.com/Send');
  assert.equal(baseFromLocation({origin:'http://localhost:5173',pathname:'/'}),'http://localhost:5173');
  assert.equal(baseFromLocation({origin:'https://example.com',pathname:'/apple/'}),'https://example.com');
  for(const pathname of ['/globalsend/app','/globalsend/app/'])assert.equal(baseFromLocation({origin:'https://123.207.180.163',pathname}),'https://123.207.180.163/globalsend');
  assert.equal(centerWebSocketUrl('https://123.207.180.163/globalsend','one-use-ticket'),'wss://123.207.180.163/globalsend/api/v1/ws?ticket=one-use-ticket');
  assert.equal(centerWebSocketUrl('http://127.0.0.1:8787','local-ticket'),'ws://127.0.0.1:8787/api/v1/ws?ticket=local-ticket');
});
test('automatic device names use available browser family information without pretending to know system names',()=>{
  assert.equal(suggestedDeviceName({userAgent:'Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)',maxTouchPoints:5}),'iPad');
  assert.equal(suggestedDeviceName({userAgent:'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)',maxTouchPoints:5}),'iPad');
  assert.equal(suggestedDeviceName({userAgent:'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15)',maxTouchPoints:0}),'Mac');
  assert.equal(suggestedDeviceName({userAgent:'Mozilla/5.0 (Linux; Android 15; V2307A) AppleWebKit/537.36 Chrome/130'}),'Android 手机');
  assert.equal(suggestedDeviceName({userAgent:'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Edg/130'}),'Windows 电脑');
  assert.equal(suggestedDeviceName({userAgent:'Reduced browser UA',userAgentData:{platform:'Android'}}),'Android 手机');
  assert.equal(suggestedDeviceName({userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)'}),'iPhone');
  assert.equal(suggestedDeviceName({userAgent:'Unknown'}),'浏览器');
});
test('download links cannot escape center or prefix',() => {
  assert.equal(safeDownloadUrl('https://example.com/base','/api/v1/downloads/abc-123'),'https://example.com/base/api/v1/downloads/abc-123');
  for (const path of ['//evil.test/file','/api/v1/downloads/../secrets','/api/v1/downloads/%2e%2e','/api/v1/downloads/a?evil=1','/api/v1/downloads/a\\b']) assert.throws(()=>safeDownloadUrl('https://example.com',path));
});
test('sizes include zero byte files',() => {
  assert.equal(formatBytes(0),'0 B'); assert.equal(formatBytes(1024),'1.0 KiB'); assert.equal(formatBytes(1048576),'1.0 MiB');
});
test('incremental transfer integrity digest agrees with known SHA-256 vectors',async () => {
  assert.equal(await digestFile(new Blob([])),'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  assert.equal(await digestFile(new Blob(['abc']),{blockSize:1}),'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});
test('large source reads remain bounded to 1 MiB even with oversized server chunk configuration',async () => {
  const reads: number[] = [];
  class TrackedBlob extends Blob {
    slice(start = 0,end = this.size) { reads.push(Math.min(end,this.size)-start); return super.slice(start,end); }
    arrayBuffer(): Promise<ArrayBuffer> { throw new Error('Whole source must never be read'); }
  }
  const source = new TrackedBlob([new Uint8Array(2 * 1048576 + 5)]);
  await digestFile(source,{blockSize:16 * 1048576});
  assert.deepEqual(reads,[1048576,1048576,5]);
});
test('digest can be canceled before reading file data',async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(digestFile(new Blob(['abc']),{signal:controller.signal}),{name:'AbortError'});
});

test('group key exactness is retained: no trimming or normalization',() => {
  const key = 'Case-Sensitive-Key-012345';
  assert.equal(validateGroupKey(key),key);
  assert.notEqual(validateGroupKey(key),validateGroupKey(key.toLowerCase()));
  for (const bad of ['too-short',' '+key,key+' ',key+'\n',key+'\u0000','a'.repeat(257)]) assert.throws(()=>validateGroupKey(bad));
  assert.equal(validateGroupKey('a'.repeat(10)).length,10);
  assert.equal(validateGroupKey('a'.repeat(256)).length,256);
});
test('session persistence projection excludes group and bootstrap secrets',() => {
  const response = {deviceToken:'device-token',device:{deviceId:'device-one'},groupId:'group-one',groupKey:'DO-NOT-PERSIST',bootstrapSecret:'PRIVATE',createdGroup:true};
  const stored = publicSession(response);
  assert.deepEqual(stored,{deviceToken:'device-token',device:{deviceId:'device-one'},groupId:'group-one'});
  assert.ok(!JSON.stringify(stored).includes('DO-NOT-PERSIST'));
  assert.ok(!JSON.stringify(stored).includes('PRIVATE'));
});
test('legacy sessions without group metadata remain usable',() => {
  assert.deepEqual(publicSession({deviceToken:'legacy-token',device:{deviceId:'old-device'}}),{deviceToken:'legacy-token',device:{deviceId:'old-device'}});
});

test('same-center sign-out clears the previous group queue, cursor, drafts and download action state',() => {
  const previous = {
    ...emptyGroupData(),
    devices:[{deviceId:'group-A-device'}],events:[event('group-A-private-text',99)],transfers:[{transferId:'group-A-file'}],
    cursor:99,target:'group-A-device',text:'private draft',pendingTexts:[{text:'unsent private text'}],pendingOffer:{transferId:'old-offer'},
    handed:new Set(['old-transfer:old-file']),fileSources:new Map([['old-file',{name:'private source'}]]),
    selected:new Set(['old-text']),consent:new Map([['old-file',true]]),groupKey:'old-group-key',
  };
  Object.assign(previous,emptyGroupData()); // The exact reset used by GlobalSend.signOut().
  assert.deepEqual(previous.devices,[]);assert.deepEqual(previous.events,[]);assert.deepEqual(previous.transfers,[]);
  assert.equal(previous.cursor,0);assert.equal(previous.target,'');assert.equal(previous.text,'');
  assert.deepEqual(previous.pendingTexts,[]);assert.equal(previous.pendingOffer,null);
  assert.equal(previous.handed.size,0);assert.equal(previous.fileSources.size,0);assert.equal(previous.selected.size,0);assert.equal(previous.consent.size,0);
  assert.equal(previous.groupKey,'');
});


test('compact card time includes date only before yesterday',()=>{
  const now=new Date(2026,9,26,15,30);
  assert.equal(compactTime(new Date(2026,9,26,10,3).getTime(),now),'10:03');
  assert.equal(compactTime(new Date(2026,9,25,23,8).getTime(),now),'23:08');
  assert.equal(compactTime(new Date(2026,9,24,9,5).getTime(),now),'10/24 09:05');
});
