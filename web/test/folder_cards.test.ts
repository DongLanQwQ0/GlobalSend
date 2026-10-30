import test from 'node:test';
import assert from 'node:assert/strict';
import {folderCards,folderMembers,summarizeFolder} from '../src/folder_cards.ts';
import {folderLibraryEntries} from '../src/library.ts';
import type {TransferFile} from '../src/model.ts';
const file=(id:string,path:string,directory=false,status:TransferFile['status']='offered',size=0):TransferFile=>({fileId:id,name:path.split('/').pop() || id,relativePath:path,entryKind:directory?'directory':'file',status,size,offset:0,attemptId:'one',errorCode:null,mimeType:directory?'inode/directory':'text/plain',sha256:''});
test('a 2000-file tree is one card without modifying its manifest; separate roots and loose files remain',()=>{
  const files=[...Array.from({length:2000},(_,i)=>file('f'+i,'资料/sub/'+i+'.txt',false,'offered',10)),file('sub','资料/sub',true),file('root','资料',true),file('empty','空目录',true),file('loose','')];
  const cards=folderCards(files);
  assert.equal(cards.length,3);assert.equal(cards[0].fileId,'root');assert.equal(cards[0].size,20000);
  assert.equal(files.length,2004);assert.equal(files.at(-3)!.size,0);
  assert.equal(folderMembers(files.at(-3)!,files).length,2002);
});
test('folder progress and completion include leaves, not just directory creation',()=>{
  const root=file('root','资料',true,'received'),child=file('child','资料/a.txt',false,'uploading',100);
  const members=[root,child];
  let card=summarizeFolder(root,members,()=>40);assert.equal(card.offset,40);assert.equal(card.status,'uploading');
  child.status='failed';child.errorCode='DISK_FULL';card=summarizeFolder(root,members);assert.equal(card.status,'failed');assert.equal(card.errorCode,'DISK_FULL');
  child.status='received';card=summarizeFolder(root,members);assert.equal(card.status,'received');assert.equal(card.offset,100);assert.equal(root.size,0);
});
test('library exposes a single folder without discarding the index used by forwarding and cleanup',()=>{
  const entries=[file('root','资料',true),file('leaf','资料/a.txt',false,'received',20)].map(item=>({id:item.fileId,scope:'scope',key:item.fileId,transferId:'t',name:item.name,size:item.size,relativePath:item.relativePath,entryKind:item.entryKind,mimeType:item.mimeType,receivedAt:1,expiresAt:2}));
  const cards=folderLibraryEntries(entries);assert.equal(cards.length,1);assert.equal(cards[0].size,20);assert.equal(entries.length,2);assert.equal(entries[0].size,0);
});
