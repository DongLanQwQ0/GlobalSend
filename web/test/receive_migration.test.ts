import test from 'node:test';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,readFile,writeFile} from 'node:fs/promises';
import {existsSync,readFileSync} from 'node:fs';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {DiskDirectory,diskWorkerFactory,indexedDBFixture} from './helpers/disk_opfs.ts';
import {defaultCleanup,cleanupMatches} from '../src/cleanup.ts';

const require=createRequire(import.meta.url),{build}=require('esbuild');
const code=(await build({entryPoints:[fileURLToPath(new URL('../src/rtc_storage.worker.ts',import.meta.url))],bundle:true,format:'iife',write:false,platform:'browser',logLevel:'silent'})).outputFiles[0].text;
async function fixture(){
  const parent=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));await mkdir(parent,{recursive:true});
  const path=await mkdtemp(join(parent,'web-receive-migration-'));
  const root=new DiskDirectory(join(path,'opfs')),idb=indexedDBFixture();
  function worker(scope?:string){
    const Worker=diskWorkerFactory(code,root,idb),native=new Worker('fixture'),pending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void}>();let counter=0;
    native.onmessage=({data}:any)=>{const waiter=pending.get(data.id)!;pending.delete(data.id);data.error?waiter.reject(Object.assign(new Error(data.error),{name:data.name})):waiter.resolve(data.result);};
    const call=(command:string,data:any={})=>new Promise<any>((resolve,reject)=>{const id=++counter;pending.set(id,{resolve,reject});native.postMessage({id,command,data});});
    const ready=call('init',{scope});return {call,ready};
  }
  return {path,root,worker};
}
async function save(worker:any,key:string,name:string,text:string,extra:Record<string,unknown>={}){
  const bytes=new TextEncoder().encode(text),data={key,name,size:bytes.length,sha256:'fixture',expires:Date.now()+86400000,...extra};
  assert.equal((await worker.call('open',data)).offset,0);await worker.call('write',{key,offset:0,bytes:bytes.buffer});
  await worker.call('finish',{key});await worker.call('confirm',{key});return data;
}

test('new cleanup defaults include only text/images through the inclusive 500 KB boundary',()=>{
  const rules=defaultCleanup();assert.deepEqual(rules.categories,['image','text']);assert.equal(rules.retentionHours,24);
  for(const name of ['photo.png','page.html']){
    assert.equal(cleanupMatches({name,size:500000},rules),true);assert.equal(cleanupMatches({name,size:500001},rules),false);
  }
  for(const name of ['video.mp4','song.mp3','file.zip','unknown.bin'])assert.equal(cleanupMatches({name,size:1},rules),false);
});

test('changing receive directory really moves old scopes, directory trees and paused prefixes; new files go straight there',async()=>{
  const f=await fixture(),one=f.worker('one'),two=f.worker('two');await one.ready;await two.ready;
  await save(one,'plain','readme.txt','hello');
  const folder={transferId:'tree',relativePath:'资料',key:'tree:root',name:'资料',size:0,entryKind:'directory'};
  await one.call('directory',folder);await one.call('directory',{...folder,key:'tree:empty',name:'空目录',relativePath:'资料/空目录'});
  await save(one,'tree:child','文字.txt','正文',{transferId:'tree',relativePath:'资料/sub/文字.txt'});
  const partial={key:'tree:partial',name:'resume.txt',size:6,sha256:'fixture',expires:Date.now()+86400000,transferId:'tree',relativePath:'资料/resume.txt'};
  await one.call('open',partial);await one.call('write',{key:partial.key,offset:0,bytes:new TextEncoder().encode('abc').buffer});await one.call('close',{key:partial.key});
  await save(two,'other','other.txt','second-scope');
  const before=(await one.call('get',{key:'plain'})).meta.receivedAt;
  const chosen=new DiskDirectory(join(f.path,'chosen'),true);await writeFile(join(chosen.path,'readme.txt'),'user file');
  const result=await one.call('destination-set',{id:'chosen',handle:chosen});assert.equal(result.moved,6);assert.equal(result.cleanupPending,false);
  assert.equal(readFileSync(join(chosen.path,'readme.txt'),'utf8'),'user file');assert.equal(readFileSync(join(chosen.path,'readme (1).txt'),'utf8'),'hello');
  assert.equal(readFileSync(join(chosen.path,'other.txt'),'utf8'),'second-scope');assert.ok(existsSync(join(chosen.path,'资料','空目录')));
  assert.equal(existsSync(join(f.root.path,'globalsend-received-v1','one','plain.data')),false);
  assert.equal(existsSync(join(f.root.path,'globalsend-received-v1','two','other.data')),false);
  assert.equal(existsSync(join(f.root.path,'globalsend-received-v1','one','received','资料')),false);
  assert.equal((await one.call('get',{key:'plain'})).meta.receivedAt,before);
  assert.equal((await one.call('open',partial)).offset,3);await one.call('write',{key:partial.key,offset:3,bytes:new TextEncoder().encode('def').buffer});await one.call('finish',{key:partial.key});await one.call('confirm',{key:partial.key});
  assert.equal(readFileSync(join(chosen.path,'资料','resume.txt'),'utf8'),'abcdef');
  await save(one,'tree:sibling','new.txt','new',{transferId:'tree',relativePath:'资料/sub/new.txt'});
  assert.equal(readFileSync(join(chosen.path,'资料','sub','new.txt'),'utf8'),'new');
  await save(one,'new-flat','direct.txt','direct');assert.equal(readFileSync(join(chosen.path,'direct.txt'),'utf8'),'direct');
  assert.equal(existsSync(join(f.root.path,'globalsend-received-v1','one','new-flat.data')),false);
  assert.equal((await one.call('destination-set',{id:'same',handle:chosen})).moved,0,'selecting the same physical directory does not duplicate received bytes');
  await writeFile(join(chosen.path,'资料','keep-user.txt'),'keep');
  const back=await one.call('destination-set',{});assert.equal(back.cleanupPending,false);assert.equal(back.moved,8);
  assert.equal(readFileSync(join(chosen.path,'资料','keep-user.txt'),'utf8'),'keep','only app-owned files move, not later user files');
  assert.equal(existsSync(join(chosen.path,'direct.txt')),false);assert.equal((await one.call('get',{key:'plain'})).meta.receivedAt,before);
  assert.equal(await (await one.call('get',{key:'plain'})).file.text(),'hello');
});

test('failed destination writes keep the original selection, metadata and bytes; active receives are not relocated',async()=>{
  const f=await fixture(),worker=f.worker('one');await worker.ready;await save(worker,'file','file.txt','original');
  const chosen=new DiskDirectory(join(f.path,'chosen'),true),get=chosen.getFileHandle.bind(chosen);
  chosen.getFileHandle=async(...args:any[])=>{const handle=await get(args[0],args[1]);handle.createWritable=async()=>{throw new Error('disk full');};return handle;};
  await assert.rejects(worker.call('destination-set',{id:'chosen',handle:chosen}),/disk full/);
  assert.equal((await worker.call('destination-get')).id,'opfs');assert.equal(await (await worker.call('get',{key:'file'})).file.text(),'original');
  assert.equal(existsSync(join(chosen.path,'file.txt')),false);
  await worker.call('open',{key:'active',name:'active.txt',size:3,sha256:'x',expires:Date.now()+86400000});
  await assert.rejects(worker.call('destination-set',{id:'chosen',handle:chosen}),/当前接收完成/);
  await worker.call('close',{key:'active'});
});

test('committed migration retries old-copy deletion after restart without reverting the new location',async()=>{
  const f=await fixture(),worker=f.worker('one');await worker.ready;
  const old=new DiskDirectory(join(f.path,'old'),true);await worker.call('destination-set',{id:'old',handle:old});await save(worker,'file','file.txt','durable');
  const remove=old.removeEntry.bind(old);old.removeEntry=async()=>{throw Object.assign(new Error('busy'),{name:'NoModificationAllowedError'});};
  const chosen=new DiskDirectory(join(f.path,'new'),true),result=await worker.call('destination-set',{id:'new',handle:chosen});
  assert.equal(result.cleanupPending,true);assert.equal(readFileSync(join(chosen.path,'file.txt'),'utf8'),'durable');
  assert.equal((await worker.call('destination-get')).id,'new');assert.equal(await (await worker.call('get',{key:'file'})).file.text(),'durable');
  const journal=join(f.root.path,'globalsend-received-v1','destination-migration.json');assert.equal(JSON.parse(await readFile(journal,'utf8')).phase,'commit');
  old.removeEntry=remove;const restarted=f.worker('one');await restarted.ready;
  assert.equal(existsSync(join(old.path,'file.txt')),false);assert.equal(existsSync(journal),false);
  assert.equal(await (await restarted.call('get',{key:'file'})).file.text(),'durable');
});


test('file reuse verifies existing bytes, refreshes one library entry and adds only a durable metadata reference',async()=>{
  const f=await fixture(),old=f.worker('old-scope'),current=f.worker('new-scope');await old.ready;await current.ready;
  const text='same content',sha256=createHash('sha256').update(text).digest('hex');
  await save(old,'old:file','first.txt',text,{sha256});
  const original=join(f.root.path,'globalsend-received-v1','old-scope','old%3Afile.data'),before=(await old.call('get',{key:'old:file'})).meta.receivedAt;
  await new Promise(resolve=>setTimeout(resolve,3));
  const next={key:'new:file',name:'second.txt',size:Buffer.byteLength(text),sha256,transferId:'new'};
  const reused=await current.call('reuse',next);assert.equal(await reused.file.text(),text);assert.ok(reused.receivedAt>before);
  assert.equal(existsSync(join(f.root.path,'globalsend-received-v1','new-scope','new%3Afile.data')),false,'no second file body');
  assert.equal(readFileSync(original,'utf8'),text);const library=(await current.call('library-list')).entries;assert.equal(library.length,1);assert.deepEqual(Array.from(library[0].aliases),['new:file']);
  assert.equal((await old.call('get',{key:'old:file'})).meta.receivedAt,reused.receivedAt);
  const restarted=f.worker('new-scope');await restarted.ready;assert.equal(await (await restarted.call('get',{key:'new:file'})).file.text(),text);
  const refs=await restarted.call('library-references',{keys:['old:file','new:file']});assert.equal(refs.entries.length,2);assert.ok(refs.entries.every((value:any)=>value.entry.receivedAt===reused.receivedAt));
  const chosen=new DiskDirectory(join(f.path,'chosen'),true),moved=await current.call('destination-set',{id:'chosen',handle:chosen});assert.equal(moved.moved,1);
  assert.equal(readFileSync(join(chosen.path,'first.txt'),'utf8'),text);assert.equal(await (await restarted.call('get',{key:'new:file'})).file.text(),text);
  await restarted.call('remove',{key:'new:file'});assert.equal((await current.call('library-list')).entries.length,0);assert.equal(existsSync(join(chosen.path,'first.txt')),false);
  await assert.rejects(old.call('get',{key:'old:file'}),{name:'NotFoundError'});
});

test('reuse never trusts a name, stale digest, deleted source, uncommitted prefix or another folder path',async()=>{
  const f=await fixture(),worker=f.worker('scope');await worker.ready;const sha256=createHash('sha256').update('good').digest('hex');
  await save(worker,'original','same.txt','good',{sha256});const data={key:'repeat',name:'same.txt',size:4,sha256};
  await writeFile(join(f.root.path,'globalsend-received-v1','scope','original.data'),'evil');
  assert.equal((await worker.call('reuse',data)).file,undefined,'same size/name metadata cannot hide changed bytes');
  await worker.call('remove',{key:'original'});assert.equal((await worker.call('reuse',data)).file,undefined);
  await save(worker,'folder:file','same.txt','good',{sha256,transferId:'folder',relativePath:'Folder/same.txt'});
  assert.equal((await worker.call('reuse',data)).file,undefined,'do not discard folder layout by reusing unrelated paths');
  await worker.call('open',{...data,key:'partial'});await worker.call('write',{key:'partial',offset:0,bytes:new TextEncoder().encode('good').buffer});await worker.call('finish',{key:'partial'});
  assert.equal((await worker.call('reuse',data)).file,undefined,'unconfirmed full-length prefixes are not saved files');
});
