import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { runInNewContext } from 'node:vm';
import { fileURLToPath } from 'node:url';
import { sortLocalFiles, filePreviewKind, readLocalText, validateLocalName } from '../src/library.ts';
import { cleanupDue, cleanupMatches, defaultCleanup } from '../src/cleanup.ts';

test('local library sorting does not mutate reception order and names sort naturally',()=>{
  const entries=[{id:'a',name:'文件10.txt',size:12,receivedAt:200},{id:'b',name:'文件2.txt',size:22,receivedAt:300},{id:'c',name:'文件1.txt',size:2,receivedAt:100}] as any;
  assert.deepEqual(sortLocalFiles(entries,'received').map(file=>file.id),['b','a','c']);
  assert.deepEqual(sortLocalFiles(entries,'oldest').map(file=>file.id),['c','a','b']);
  assert.deepEqual(sortLocalFiles(entries,'name').map(file=>file.id),['c','b','a']);
  assert.deepEqual(sortLocalFiles(entries,'size').map(file=>file.id),['b','a','c']);
  assert.deepEqual(entries.map((file:any)=>file.id),['a','b','c']);
});
test('text previews decode UTF8, UTF16 and GB18030 and identify truncated content',async()=>{
  const utf8=await readLocalText(new Blob(['收到的文件\n第二行']));assert.equal(utf8.text,'收到的文件\n第二行');assert.equal(utf8.truncated,false);
  const le=await readLocalText(new Blob([new Uint8Array([255,254,0x2d,0x4e,0x87,0x65])]));assert.equal(le.text,'中文');assert.equal(le.encoding,'utf-16le');
  const be=await readLocalText(new Blob([new Uint8Array([254,255,0x4e,0x2d,0x65,0x87])]));assert.equal(be.text,'中文');assert.equal(be.encoding,'utf-16be');
  const gb=await readLocalText(new Blob([new Uint8Array([0xd6,0xd0,0xce,0xc4])]));assert.equal(gb.text,'中文');assert.equal(gb.encoding,'gb18030');
  const large=await readLocalText(new Blob([new Uint8Array(8*1048576+1).fill(65)]));assert.equal(large.truncated,true);assert.equal(large.text.length,8*1048576);
  assert.equal(filePreviewKind({name:'unknown.txt',mimeType:''}),'text');assert.equal(filePreviewKind({name:'photo.PNG',mimeType:''}),'image');assert.equal(filePreviewKind({name:'shape.svg',mimeType:'image/svg+xml'}),'text');
  assert.equal(validateLocalName(' 文档.txt '),'文档.txt');assert.throws(()=>validateLocalName('../file.txt'));
});
test('truncated Chinese UTF8 and BOM text retain their encoding at an incomplete last character',async()=>{
  const chinese='中文'.repeat(1398103);
  for(const bom of ['', '\ufeff']) {
    const result=await readLocalText(new Blob([bom,chinese]));
    assert.equal(result.truncated,true);assert.equal(result.encoding,'utf-8');
    assert.equal(result.text,chinese.slice(0,Math.floor((8388608-(bom?3:0))/3)));
    assert.equal(result.text.includes('\ufffd'),false);
  }
});
test('cleanup uses category plus strict size and the configured age',()=>{
  const rules={...defaultCleanup(),retentionHours:2,categories:['image'] as const,sizeRule:'greater' as const,sizeMiB:1};
  assert.equal(cleanupMatches({name:'photo.png',size:1048576},rules as any),false);
  assert.equal(cleanupMatches({name:'photo.png',size:1048577},rules as any),true);
  assert.equal(cleanupMatches({name:'photo.txt',size:1048577},rules as any),false);
  assert.equal(cleanupDue({name:'photo.png',size:1048577,receivedAt:1000},rules as any,7200999),false);
  assert.equal(cleanupDue({name:'photo.png',size:1048577,receivedAt:1000},rules as any,7201000),true);
  assert.equal(cleanupMatches({name:'photo.png',size:1048576},{...rules,categories:['image'],sizeRule:'smaller'}),false);
});

const require=createRequire(import.meta.url),{build}=require('esbuild');
const compiled=await build({entryPoints:[fileURLToPath(new URL('../src/rtc_storage.worker.ts',import.meta.url))],bundle:true,format:'iife',write:false,platform:'browser',logLevel:'silent'});
class MemoryFile {
  name:string;kind='file';bytes=new Uint8Array(0);modified=0;locked=false;now:()=>number;
  constructor(name:string,now:()=>number){this.name=name;this.now=now;}
  async getFile(){return new File([this.bytes],this.name,{lastModified:this.modified});}
  async createSyncAccessHandle(){
    if(this.locked)throw Object.assign(new Error('locked'),{name:'NoModificationAllowedError'});this.locked=true;
    return {
      getSize:async()=>this.bytes.length,
      truncate:async(size:number)=>{const bytes=new Uint8Array(size);bytes.set(this.bytes.subarray(0,size));this.bytes=bytes;this.modified=this.now();},
      write:async(value:Uint8Array,{at}:{at:number})=>{if(at+value.length>this.bytes.length){const bytes=new Uint8Array(at+value.length);bytes.set(this.bytes);this.bytes=bytes;}this.bytes.set(value,at);this.modified=this.now();return value.length;},
      flush:async()=>{},close:async()=>{this.locked=false;},
    };
  }
}
class MemoryDirectory {
  name:string;kind='directory';items=new Map<string,MemoryDirectory|MemoryFile>();now:()=>number;
  constructor(name:string,now:()=>number){this.name=name;this.now=now;}
  async *values(){yield* this.items.values();}
  async getDirectoryHandle(name:string,options:{create?:boolean}={}) {
    if(!this.items.has(name) && options.create)this.items.set(name,new MemoryDirectory(name,this.now));
    const item=this.items.get(name);if(!item)throw Object.assign(new Error('missing'),{name:'NotFoundError'});return item as MemoryDirectory;
  }
  async getFileHandle(name:string,options:{create?:boolean}={}) {
    if(!this.items.has(name) && options.create)this.items.set(name,new MemoryFile(name,this.now));
    const item=this.items.get(name);if(!item)throw Object.assign(new Error('missing'),{name:'NotFoundError'});return item as MemoryFile;
  }
  async removeEntry(name:string){const item=this.items.get(name);if(!item)throw Object.assign(new Error('missing'),{name:'NotFoundError'});if(item instanceof MemoryFile && item.locked)throw Object.assign(new Error('locked'),{name:'NoModificationAllowedError'});this.items.delete(name);}
}
function workerFixture(root:MemoryDirectory,clock:()=>number) {
  let id=0;const pending=new Map<number,{resolve:(value:any)=>void;reject:(error:Error)=>void}>();
  const self:any={postMessage:({id,result,error,name}:any)=>{const p=pending.get(id)!;pending.delete(id);error?p.reject(Object.assign(new Error(error),{name})):p.resolve(result);}};
  runInNewContext(compiled.outputFiles[0].text,{self,navigator:{storage:{getDirectory:async()=>root}},Date:class extends Date{static now(){return clock();}},TextEncoder,Uint8Array,Map,Set,JSON,Error,Infinity,Promise,Number,String,decodeURIComponent,encodeURIComponent});
  return {call:(command:string,data:unknown={})=>new Promise<any>((resolve,reject)=>{const n=++id;pending.set(n,{resolve,reject});self.onmessage({data:{id:n,command,data}});})};
}
async function save(worker:ReturnType<typeof workerFixture>,key:string,name:string,size=4) {
  await worker.call('open',{key,name,size,mimeType:name.endsWith('.png')?'image/png':'text/plain',sha256:'a'.repeat(64),expires:Date.now()+86400000});
  await worker.call('write',{key,offset:0,bytes:new Uint8Array(size).buffer});await worker.call('finish',{key});await worker.call('confirm',{key});
}
test('worker library spans session scopes, renames metadata only, and excludes active or unmarked partial files',async()=>{
  let now=1700000000000;const root=new MemoryDirectory('root',()=>now),first=workerFixture(root,()=>now),second=workerFixture(root,()=>now),library=workerFixture(root,()=>now);
  await first.call('init',{scope:'one'});await save(first,'transfer:file','original.txt');
  await second.call('init',{scope:'two'});now+=1000;await save(second,'other:file','second.txt');
  await first.call('open',{key:'partial',name:'partial.txt',size:12,sha256:'b'.repeat(64),expires:now-1000});
  const app=await root.getDirectoryHandle('globalsend-received-v1'),one=await app.getDirectoryHandle('one');await one.getFileHandle('unmarked.data',{create:true});
  await library.call('init',{});const {entries}=await library.call('library-list');
  assert.equal(entries.length,2);assert.deepEqual(Array.from(entries,(entry:any)=>entry.scope).sort(),['one','two']);
  const original=entries.find((entry:any)=>entry.scope==='one'),data=await one.getFileHandle('transfer%3Afile.data');
  await library.call('library-rename',{id:original.id,name:'重命名.txt'});
  assert.equal((await library.call('library-get',{id:original.id})).entry.name,'重命名.txt');assert.equal(await one.getFileHandle('transfer%3Afile.data'),data);
  await library.call('library-remove',{id:original.id});assert.equal((await library.call('library-list')).entries.length,1);
  assert.equal((await one.getFileHandle('partial.data')).locked,true);assert.ok(await one.getFileHandle('unmarked.data'));
  await first.call('shutdown');await second.call('shutdown');
});
test('worker cleanup settings persist and apply category plus strict size across existing scopes',async()=>{
  let now=1700000000000;const root=new MemoryDirectory('root',()=>now),receiver=workerFixture(root,()=>now),library=workerFixture(root,()=>now);
  await receiver.call('init',{scope:'one'});await save(receiver,'large','large.png',1048577);await save(receiver,'equal','equal.png',1048576);await save(receiver,'text','text.txt',12);
  await receiver.call('open',{key:'partial',name:'partial.png',size:100,sha256:'b'.repeat(64),expires:now-1});
  now+=2*3600000;await library.call('init',{});
  await library.call('library-preferences',{value:{retentionHours:1,categories:['image'],sizeRule:'greater',sizeMiB:1}});
  assert.deepEqual(Array.from((await library.call('library-list')).entries,(entry:any)=>entry.name).sort(),['equal.png','text.txt']);
  const fresh=workerFixture(root,()=>now);await fresh.call('init',{});assert.equal((await fresh.call('library-preferences')).cleanup.retentionHours,1);
  await fresh.call('library-preferences',{value:{retentionHours:1,categories:['image'],sizeRule:'smaller',sizeMiB:1}});
  assert.deepEqual(Array.from((await fresh.call('library-list')).entries,(entry:any)=>entry.name).sort(),['equal.png','text.txt']);
  await receiver.call('shutdown');
});
test('legacy completed metadata retains its data and derives receipt time without treating unmarked files as saved',async()=>{
  let now=1700000000000;const root=new MemoryDirectory('root',()=>now),receiver=workerFixture(root,()=>now),library=workerFixture(root,()=>now);
  await receiver.call('init',{scope:'legacy'});await save(receiver,'old','old.txt');
  const app=await root.getDirectoryHandle('globalsend-received-v1'),scope=await app.getDirectoryHandle('legacy'),metaHandle=await scope.getFileHandle('old.json');
  const meta=JSON.parse(await (await metaHandle.getFile()).text());delete meta.receivedAt;delete meta.mimeType;
  metaHandle.bytes=new TextEncoder().encode(JSON.stringify(meta));now+=26*3600000;
  await library.call('init',{});await library.call('library-preferences',{value:{...defaultCleanup(),retentionHours:48}});
  const {entries}=await library.call('library-list');assert.equal(entries.length,1);assert.equal(entries[0].name,'old.txt');assert.equal(entries[0].receivedAt,1700000000000);
  assert.equal(entries[0].mimeType,'');assert.equal((await library.call('library-get',{id:entries[0].id})).file.size,4);
});
