import test from 'node:test';
import assert from 'node:assert/strict';
import { CopiedFilesReceiver } from '../src/copied_files.ts';
import type { CopiedFileOffer, CopiedFilePull } from '../../packages/protocol/src/index.ts';

const offer:CopiedFileOffer={sourceDeviceId:'source',sourceName:'DongLan',offerId:'batch',groupId:'group',createdAt:'2026-11-01T00:00:00Z',items:[{id:'folder',name:'Course files',kind:'directory'}]};
const response=(state:CopiedFilePull['state']):CopiedFilePull=>({sourceDeviceId:'source',targetDeviceId:'self',offerId:'batch',requestId:'request',groupId:'group',itemIds:['folder'],state});
test('references are metadata-only; explicit click pulls once; fast socket result beats pending HTTP reply',async()=>{
  const calls:{path:string;body:unknown}[]=[];
  let release!:(pull:CopiedFilePull)=>void;
  const client=new CopiedFilesReceiver(async<T>(path:string,body?:unknown)=>{
    calls.push({path,body});return (path==='/clipboard/files'?{offers:[offer]}:await new Promise<CopiedFilePull>(resolve=>release=resolve)) as T;
  },()=>{},()=> 'request');
  await client.refresh();assert.equal(client.references.length,1);assert.equal(calls.length,1);assert.equal(client.references[0].item.kind,'directory');
  const click=client.pull(client.references[0].id);await client.pull(client.references[0].id);assert.equal(calls.length,2);assert.equal(client.references[0].state,'pending');
  assert.deepEqual(calls[1],{path:'/clipboard/files/source/pull',body:{offerId:'batch',requestId:'request',itemIds:['folder']}});
  client.receive(response('sent'));release(response('pending'));await click;assert.equal(client.references[0].state,'sent');
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
