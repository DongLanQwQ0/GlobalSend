import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,readdir,stat} from 'node:fs/promises';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {DiskDirectory,diskWorkerFactory,indexedDBFixture} from './helpers/disk_opfs.ts';

const {build}=createRequire(import.meta.url)('esbuild');
const code=(await build({entryPoints:[fileURLToPath(new URL('../src/rtc_storage.worker.ts',import.meta.url))],bundle:true,format:'iife',write:false,platform:'browser'})).outputFiles[0].text;
const hash=(text:string)=>createHash('sha256').update(text).digest('hex');
async function fixture(){
  const base=fileURLToPath(new URL('../../artifacts/tmp/',import.meta.url));await mkdir(base,{recursive:true});
  const work=await mkdtemp(join(base,'flat-receive-')),root=new DiskDirectory(join(work,'opfs'));
  const Factory=diskWorkerFactory(code,root,indexedDBFixture());
  const worker=()=>{
    const w=new Factory('fixture');let id=0;const pending=new Map<number,any>();
    w.onmessage=({data})=>{const p=pending.get(data.id);pending.delete(data.id);data.error?p.reject(Object.assign(new Error(data.error),{name:data.name})):p.resolve(data.result);};
    return {call:(command:string,data:unknown={})=>new Promise<any>((resolve,reject)=>{pending.set(++id,{resolve,reject});w.postMessage({id,command,data});})};
  };
  return {work,root,worker,received:join(root.path,'globalsend-received-v1','received')};
}
async function write(w:ReturnType<Awaited<ReturnType<typeof fixture>>['worker']>,key:string,name:string,text:string,extra={}){
  await w.call('open',{key,name,size:Buffer.byteLength(text),sha256:hash(text),expires:Date.now()+86400000,...extra});
  const bytes=new TextEncoder().encode(text);await w.call('write',{key,offset:0,bytes:bytes.buffer});await w.call('finish',{key});await w.call('confirm',{key});
}

test('ordinary Web receives use one final named directory across scopes, preserve collisions and resume in place',async()=>{
  const f=await fixture(),a=f.worker();await a.call('init',{scope:'one'});
  await mkdir(f.received,{recursive:true});await writeFile(join(f.received,'note.txt'),'user');
  await write(a,'transfer:id','note.txt','first');
  const b=f.worker();await b.call('init',{scope:'two'});await write(b,'second:id','note.txt','second');
  assert.equal(await readFile(join(f.received,'note.txt'),'utf8'),'user');
  assert.equal(await readFile(join(f.received,'note (1).txt'),'utf8'),'first');
  assert.equal(await readFile(join(f.received,'note (2).txt'),'utf8'),'second');
  await b.call('open',{key:'partial',name:'resume.txt',size:4,sha256:hash('ABCD'),expires:Date.now()+86400000});
  await b.call('write',{key:'partial',offset:0,bytes:new TextEncoder().encode('AB').buffer});await b.call('shutdown');
  assert.equal(await readFile(join(f.received,'resume.txt'),'utf8'),'AB');
  const restarted=f.worker();await restarted.call('init',{scope:'two'});
  assert.equal((await restarted.call('open',{key:'partial',name:'resume.txt',size:4,sha256:hash('ABCD'),expires:Date.now()+86400000})).offset,2);
  await restarted.call('write',{key:'partial',offset:2,bytes:new TextEncoder().encode('CD').buffer});await restarted.call('finish',{key:'partial'});await restarted.call('confirm',{key:'partial'});
  assert.equal(await readFile(join(f.received,'resume.txt'),'utf8'),'ABCD');
  assert.ok((await readdir(join(f.root.path,'globalsend-received-v1','two'))).every(name=>name.endsWith('.json')));
  await a.call('shutdown');await restarted.call('shutdown');
});

test('Web startup migrates registered old bytes and folder trees, retains aliases and partial offsets, and ignores unregistered files',async()=>{
  const f=await fixture(),app=join(f.root.path,'globalsend-received-v1'),scope=join(app,'old');await mkdir(join(scope,'received','资料','empty'),{recursive:true});
  await mkdir(f.received,{recursive:true});await writeFile(join(f.received,'old.txt'),'user');
  const now=Date.now(),base={size:4,sha256:hash('ABCD'),complete:true,receivedAt:now,expires:now+86400000};
  const meta=async(key:string,data:unknown)=>writeFile(join(scope,encodeURIComponent(key)+'.json'),JSON.stringify({key,...base,...data as object}));
  await writeFile(join(scope,'legacy%3Aid.data'),'ABCD');await meta('legacy:id',{name:'old.txt'});
  await writeFile(join(scope,'partial.data'),'AB');await meta('partial',{name:'resume.txt',complete:false});
  await writeFile(join(scope,'unmarked.data'),'keep');
  await meta('root',{name:'资料',entryKind:'directory',relativePath:'资料',transferId:'tree',destinationId:'opfs',storagePath:'资料',size:0});
  await meta('empty',{name:'empty',entryKind:'directory',relativePath:'资料/empty',transferId:'tree',destinationId:'opfs',storagePath:'资料/empty',size:0});
  await writeFile(join(scope,'received','资料','child.txt'),'ABCD');await meta('child',{name:'child.txt',relativePath:'资料/child.txt',transferId:'tree',destinationId:'opfs',storagePath:'资料/child.txt'});
  await mkdir(join(app,'alias'),{recursive:true});await writeFile(join(app,'alias','copy.json'),JSON.stringify({key:'copy',...base,name:'old.txt',alias:{scope:'old',key:'legacy:id'}}));
  const w=f.worker();await w.call('init',{scope:'old'});
  assert.equal(await readFile(join(f.received,'old (1).txt'),'utf8'),'ABCD');assert.equal(await readFile(join(f.received,'old.txt'),'utf8'),'user');
  assert.equal(await readFile(join(f.received,'资料','child.txt'),'utf8'),'ABCD');assert.ok((await stat(join(f.received,'资料','empty'))).isDirectory());
  assert.equal(await readFile(join(scope,'unmarked.data'),'utf8'),'keep');
  await assert.rejects(readFile(join(scope,'legacy%3Aid.data')),error=>(error as NodeJS.ErrnoException).code==='ENOENT');
  assert.equal((await w.call('open',{key:'partial',name:'resume.txt',size:4,sha256:hash('ABCD'),expires:now+86400000})).offset,2);await w.call('shutdown');
  assert.equal(await (await w.call('library-get',{id:'alias/copy'})).file.text(),'ABCD');
  const reused=await w.call('reuse',{key:'repeated',name:'same.txt',size:4,sha256:hash('ABCD')});assert.equal(await reused.file.text(),'ABCD');
  assert.equal((await readdir(f.received)).includes('same.txt'),false,'reuse does not create another payload');
  const again=f.worker();await again.call('init',{scope:'old'});assert.equal(await (await again.call('get',{key:'legacy:id'})).file.text(),'ABCD');
  assert.equal((await readdir(f.received)).some(name=>name==='old (2).txt'),false,'restart does not migrate a second time');
  await again.call('shutdown');
});


test('automatic clipboard bytes remain private across restart, ordinary cleanup and receive-directory migration',async()=>{
 const f=await fixture(),w=f.worker();await w.call('init',{scope:'clipboard'});await mkdir(f.received,{recursive:true});
 await write(w,'slot:image','screenshot.png','actual clipboard bytes',{ephemeral:true});
 assert.equal((await readdir(f.received)).includes('screenshot.png'),false);
 assert.equal((await w.call('library-list')).entries.length,0);
 assert.equal(await (await w.call('get',{key:'slot:image'})).file.text(),'actual clipboard bytes');
 const privateMeta=join(f.root.path,'globalsend-received-v1','clipboard','slot%3Aimage.json'),meta=JSON.parse(await readFile(privateMeta,'utf8'));meta.receivedAt=Date.now()-10*86400000;await writeFile(privateMeta,JSON.stringify(meta));
 await w.call('cleanup');assert.equal(await (await w.call('get',{key:'slot:image'})).file.text(),'actual clipboard bytes');
 await mkdir(join(f.work,'selected'),{recursive:true});const destination=new DiskDirectory(join(f.work,'selected'));await w.call('destination-set',{handle:destination,id:'picked'});
 assert.equal((await readdir(destination.path)).includes('screenshot.png'),false);
 await w.call('shutdown');const restarted=f.worker();await restarted.call('init',{scope:'clipboard'});
 assert.equal(await (await restarted.call('get',{key:'slot:image'})).file.text(),'actual clipboard bytes');
 assert.equal((await restarted.call('library-list')).entries.length,0);
 await restarted.call('clipboard-release',{key:'slot:image'});await assert.rejects(restarted.call('get',{key:'slot:image'}),error=>(error as Error).name==='NotFoundError');
 await write(restarted,'ordinary','kept.png','ordinary bytes');await restarted.call('clipboard-release',{key:'ordinary'});assert.equal(await (await restarted.call('get',{key:'ordinary'})).file.text(),'ordinary bytes');await restarted.call('shutdown');
});
