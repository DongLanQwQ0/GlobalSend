import test from 'node:test';
import assert from 'node:assert/strict';
import {completeFolderParts,directoryParts} from '../src/folder.ts';
import {prepareFolderSend,emptyFileHash} from '../src/folder_send.ts';

test('folder manifests keep original files, Unicode roots, implied parents and empty directories without ZIP',async()=>{
  const source=new File(['original'],'正文.txt'),parts=completeFolderParts('我的资料',[{path:'我的资料/空目录/'},{path:'我的资料/sub/正文.txt',file:source}]);
  assert.deepEqual(parts.map(entry=>entry.path),['我的资料/','我的资料/空目录/','我的资料/sub/','我的资料/sub/正文.txt']);
  const selection=new File([],'我的资料',{type:'inode/directory'}),hashed:File[]=[];
  const result=await prepareFolderSend([selection],file=>file===selection?parts:undefined,async file=>{hashed.push(file);return 'a'.repeat(64);});
  assert.equal(result.metadata.length,4);assert.deepEqual(result.metadata.map(file=>file.entryKind),['directory','directory','directory','file']);
  assert.equal(result.metadata[0].sha256,emptyFileHash);assert.equal(result.metadata[0].size,0);assert.equal(result.metadata[3].relativePath,'我的资料/sub/正文.txt');
  assert.equal(result.sources[3],source);assert.deepEqual(hashed,[source]);assert.equal(result.metadata.some(file=>file.name.endsWith('.zip')),false);
});
test('directory picker enumerates actual empty directory handles, including an entirely empty root',async()=>{
  const empty:any={name:'空目录',kind:'directory',async *values(){}};
  const root:any={name:'资料',kind:'directory',async *values(){yield empty;}};
  assert.deepEqual(await directoryParts(root),[{path:'资料/'},{path:'资料/空目录/'}]);
  assert.deepEqual(await directoryParts(empty),[{path:'空目录/'}]);
});
test('structured sends allow more than 32 entries but reject over 10000 before reading sources',async()=>{
  const folder=new File([],'root'),file=new File(['x'],'x');let hashes=0;
  const parts=completeFolderParts('root',Array.from({length:70},(_,i)=>({path:`root/${i}.txt`,file})));
  assert.equal((await prepareFolderSend([folder],()=>parts,async()=>{hashes++;return 'b'.repeat(64);})).metadata.length,71);
  assert.equal(hashes,70);hashes=0;
  await assert.rejects(prepareFolderSend([folder],()=>Array.from({length:10001},()=>({path:'root/x',file})),async()=>{hashes++;return '';}),/10000/);assert.equal(hashes,0);
  await assert.rejects(prepareFolderSend(Array(33).fill(file),()=>undefined,async()=>''),/32/);
});
