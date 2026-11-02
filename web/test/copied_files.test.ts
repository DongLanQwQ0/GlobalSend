import test from 'node:test';
import assert from 'node:assert/strict';
import { CopiedFilesReceiver } from '../src/copied_files.ts';
import { copiedFilesHtml } from '../src/copied_files_view.ts';
import { parseHTML } from 'linkedom';
import type { CopiedFileOffer, CopiedFilePull } from '../../packages/protocol/src/index.ts';

const offer:CopiedFileOffer={sourceDeviceId:'source',sourceName:'DongLan',offerId:'batch',groupId:'group',createdAt:'2026-11-01T00:00:00Z',items:[{id:'folder',name:'Course files',kind:'directory'}]};
const response=(state:CopiedFilePull['state']):CopiedFilePull=>({sourceDeviceId:'source',targetDeviceId:'self',offerId:'batch',requestId:'request',groupId:'group',itemIds:['folder'],state});

test('shared reference card keeps pull, dismiss and pending/failure states distinct',async()=>{
  const client=new CopiedFilesReceiver(async<T>()=>({offers:[offer]}) as T,()=>{});
  await client.refresh();
  const markup=()=>parseHTML('<html><body>'+copiedFilesHtml(client)+'</body></html>').document;
  let doc=markup();
  assert.equal(doc.querySelector('strong')!.textContent,'Course files');
  assert.equal(doc.querySelector('small')!.textContent,'DongLan');
  assert.equal(doc.querySelector('[data-action="pull-copied-file"]')!.hasAttribute('disabled'),false);
  assert.ok(doc.querySelector('[data-action="dismiss-copied-file"]'));
  client.receive(response('pending'));doc=markup();
  assert.ok(doc.querySelector('.copied-file-reference.pending'));
  assert.ok(doc.querySelector('[data-action="pull-copied-file"]')!.hasAttribute('disabled'));
  assert.equal(doc.querySelector('small')!.textContent,'正在准备');
  client.receive({...response('failed'),error:'offline'});doc=markup();
  assert.ok(doc.querySelector('.copied-file-reference.failed'));
  assert.equal(doc.querySelector('small')!.textContent,'拉取失败');
  assert.equal(doc.querySelector('[data-action="pull-copied-file"]')!.hasAttribute('disabled'),false);
});
test('references are metadata-only; explicit click pulls once; fast socket result beats pending HTTP reply',async()=>{
  const calls:{path:string;body:unknown}[]=[];
  let release!:(pull:CopiedFilePull)=>void;
  const client=new CopiedFilesReceiver(async<T>(path:string,body?:unknown)=>{
    calls.push({path,body});return (path==='/clipboard/files'?{offers:[offer]}:await new Promise<CopiedFilePull>(resolve=>release=resolve)) as T;
  },()=>{},()=> 'request');
  await client.refresh();assert.equal(client.references.length,1);assert.equal(calls.length,1);assert.equal(client.references[0].item.kind,'directory');
  const click=client.pull(client.references[0].id);await client.pull(client.references[0].id);assert.equal(calls.length,2);assert.equal(client.references[0].state,'pending');
  assert.deepEqual(calls[1],{path:'/clipboard/files/source/pull',body:{offerId:'batch',requestId:'request',itemIds:['folder']}});
  client.receive(response('sent'));release(response('pending'));await click;assert.equal(client.references[0].state,'sending');
  client.dismiss(client.references[0].id);assert.equal(client.references.length,0);assert.equal(calls.length,2);
});
test('session replacement cannot restore stale offers or an old request status',async()=>{
  let release!:(value:unknown)=>void;
  const client=new CopiedFilesReceiver(async<T>()=>await new Promise(resolve=>release=resolve) as T,()=>{});
  const first=client.refresh();client.reset();release({offers:[offer]});await first;assert.deepEqual(client.references,[]);
  client.receive(response('sent'));assert.deepEqual(client.references,[]);
});
test('event refresh coalesces bursts but rechecks after in-flight responses, and failures remain retryable',async()=>{
  let requests=0,release!:(value:unknown)=>void;
  const client=new CopiedFilesReceiver(async<T>()=>{
    requests++;return (requests===1?await new Promise(resolve=>release=resolve):{offers:[]}) as T;
  },()=>{});
  const first=client.refresh(),second=client.refresh();void client.refresh();assert.equal(requests,1);
  release({offers:[offer]});await Promise.all([first,second]);assert.equal(requests,2);assert.deepEqual(client.references,[]);
  const failing=new CopiedFilesReceiver(async<T>(path:string)=>{if(path==='/clipboard/files')return {offers:[offer]} as T;throw new Error('source disconnected');},()=>{},()=> 'failed');
  await failing.refresh();await failing.pull(failing.references[0].id);assert.equal(failing.references[0].state,'failed');assert.equal(failing.references[0].error,'source disconnected');
});


test('only completed exact references become local draggable content and deletion allows another pull',async()=>{
 let calls=0;const client=new CopiedFilesReceiver(async<T>(path:string,body?:unknown)=>{if(path==='/clipboard/files')return {offers:[offer]} as T;calls++;return {...response('sent'),...(body as object)} as T;},()=>{});
 await client.refresh();const ref=client.references[0];await client.pull(ref.id);assert.equal(ref.localKey,undefined);
 client.remember('source',{offerId:'batch',itemId:'folder'},'transfer:root');
 assert.equal(client.references[0].state,'received');await client.pull(ref.id);assert.equal(calls,1);
 const {document}=parseHTML('<body>'+copiedFilesHtml(client)+'</body>');assert.equal(document.querySelector('[data-drag-file]')?.getAttribute('data-drag-file'),'transfer:root');
 client.reconcile(()=>false);assert.equal(client.references[0].localKey,undefined);await client.pull(ref.id);assert.equal(calls,2);
});

test('completed copies promote by receipt time, never progress or rediscovery, in the actual card list',async()=>{
 const multi={...offer,items:[{id:'a',name:'old.pdf',kind:'file' as const},{id:'b',name:'recent folder',kind:'directory' as const},{id:'c',name:'pending.pdf',kind:'file' as const}]};
 const client=new CopiedFilesReceiver(async<T>()=>({offers:[multi]}) as T,()=>{});
 await client.refresh();
 const names=()=>{const {document}=parseHTML('<body>'+copiedFilesHtml(client)+'</body>');return [...document.querySelectorAll('strong')].map(node=>node.textContent);};
 assert.deepEqual(names(),['old.pdf','recent folder','pending.pdf']);
 client.receive({...response('sending'),itemIds:['c']});
 assert.deepEqual(names(),['old.pdf','recent folder','pending.pdf']);
 client.remember('source',{offerId:'batch',itemId:'b'},'transfer:b',200);
 client.remember('source',{offerId:'batch',itemId:'a'},'transfer:a',100);
 assert.deepEqual(names(),['recent folder','old.pdf','pending.pdf']);
 client.remember('source',{offerId:'batch',itemId:'a'},'transfer:a',900);
 await client.pull('copied:source:batch:a');await client.refresh();
 assert.deepEqual(names(),['recent folder','old.pdf','pending.pdf']);
 assert.equal(client.references.find(ref=>ref.item.id==='a')?.completedAtMillis,100);
 const restored=new CopiedFilesReceiver(async<T>()=>({offers:[multi]}) as T,()=>{});
 // Restoring local inventory in reverse discovery order keeps the receipt order.
 restored.remember('source',{offerId:'batch',itemId:'b'},'transfer:b',200);
 restored.remember('source',{offerId:'batch',itemId:'a'},'transfer:a',100);
 await restored.refresh();assert.deepEqual(restored.references.map(ref=>ref.item.id),['b','a','c']);
 client.reconcile(key=>key!=='transfer:a');
 client.remember('source',{offerId:'batch',itemId:'a'},'new-transfer:a',300);
 assert.deepEqual(names(),['old.pdf','recent folder','pending.pdf']);
 assert.equal(client.references.length,3);
});
