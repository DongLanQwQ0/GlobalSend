import test from 'node:test';
import assert from 'node:assert/strict';
import { imageContainer, imageFileMetadata, imageFileName } from '../src/image_file_name.ts';
import { prepareFolderSend } from '../src/folder_send.ts';

const png=Uint8Array.from([137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82]);

test('real File .pic uses PNG container over misleading MIME and retains source bytes',async()=>{
  const file=new File([png],'977.pic',{type:'image/jpeg',lastModified:1234});
  const result=await imageFileMetadata(file);
  assert.deepEqual(result,{name:'977.png',mimeType:'image/png'});
  assert.equal(file.name,'977.pic');
  assert.equal(file.lastModified,1234);
  assert.deepEqual(new Uint8Array(await file.arrayBuffer()),png);
  assert.equal(imageFileName('Photo.PNG','png'),'Photo.PNG');
  assert.equal(imageFileName('Photo.jpeg','jpg'),'Photo.jpeg');
  assert.equal(imageFileName('report.final','png'),'report.final.png');
  assert.equal(imageFileName('Photo','png'),'Photo.png');
  assert.deepEqual(await imageFileMetadata(new File(['hello'],'notes.txt')),{name:'notes.txt',mimeType:'application/octet-stream'});
});

test('HEIC/AVIF headers and provider MIME supply correct standalone suffixes',async()=>{
  const header=(major:string,compatible:string)=>Uint8Array.from([0,0,0,24,...Buffer.from('ftyp'+major),0,0,0,0,...Buffer.from(compatible)]);
  assert.deepEqual(imageContainer(header('heic','mif1')),{mimeType:'image/heic',extension:'heic'});
  assert.deepEqual(imageContainer(header('mif1','avif')),{mimeType:'image/avif',extension:'avif'});
  assert.equal(imageContainer(header('mp42','isom')),null);
  assert.deepEqual(await imageFileMetadata(new File([], '来自剪贴板',{type:'image/heic'})),{name:'来自剪贴板.heic',mimeType:'image/heic'});
});

test('actual send preparation normalizes only standalone metadata and keeps original folder structure',async()=>{
  const image=new File([png],'977.pic',{type:'application/octet-stream'});
  const digestCalls:File[]=[];
  const digest=async(file:File)=>{digestCalls.push(file);return 'fixture-hash';};
  const single=await prepareFolderSend([image],()=>undefined,digest);
  assert.deepEqual(single.metadata,[{name:'977.png',mimeType:'image/png',size:png.length,sha256:'fixture-hash'}]);
  assert.equal(single.sources[0],image);
  const folder=new File([],'Album',{type:'inode/directory'});
  const structured=await prepareFolderSend([folder],()=>[{path:'Album/'},{path:'Album/977.pic',file:image}],digest);
  assert.equal(structured.metadata[1].name,'977.pic');
  assert.equal(structured.metadata[1].relativePath,'Album/977.pic');
  assert.equal(structured.sources[1],image);
  assert.deepEqual(digestCalls,[image,image]);
});
