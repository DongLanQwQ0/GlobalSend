import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {parseHTML} from 'linkedom';
import {CopiedFilesReceiver} from '../src/copied_files.ts';
import {copiedFilesHtml} from '../src/copied_files_view.ts';

const source=await readFile(new URL('../src/main.ts',import.meta.url),'utf8');
const startup='void new GlobalSend().start();';
assert.ok(source.includes(startup));
const {build}=createRequire(import.meta.url)('esbuild');
// Execute production methods, omitting only automatic application startup.
const code=(await build({stdin:{contents:source.replace(startup,'export { GlobalSend };'),resolveDir:fileURLToPath(new URL('../src/',import.meta.url)),loader:'ts'},bundle:true,format:'cjs',write:false,platform:'browser',loader:{'.css':'empty'},logLevel:'silent'})).outputFiles[0].text;

test('production receipt inventory uses folder final member and historical receipt time, not discovery time',()=>{
 const {document,window}=parseHTML('<html><body><main id="app"></main></body></html>');
 const module={exports:{}} as {exports:any};
 runInNewContext(code,{module,exports:module.exports,document,window,console,URL,Blob,File,TextEncoder,TextDecoder,setTimeout,clearTimeout});
 const prototype=module.exports.GlobalSend.prototype;
 const receiver=new CopiedFilesReceiver(async<T>()=>({}) as T,()=>{});
 receiver.offers=[{sourceDeviceId:'source',sourceName:'same name',offerId:'batch',groupId:'group',createdAt:'2026-01-01',items:[{id:'a',name:'older folder',kind:'directory'},{id:'b',name:'newer.txt',kind:'file'}]}];
 const file=(fileId:string,name:string,relativePath='',entryKind='file')=>({fileId,name,relativePath,entryKind,status:'received',receivedAt:'2026-01-01T00:00:00Z'});
 const folder={transferId:'folder',sourceDeviceId:'source',targetDeviceId:'self',copiedFile:{offerId:'batch',itemId:'a'},createdAt:'2026-01-01',files:[file('root','older folder','older folder','directory'),file('empty','empty','older folder/empty','directory'),file('last','last.txt','older folder/last.txt')]};
 const ordinary={transferId:'file',sourceDeviceId:'source',targetDeviceId:'self',copiedFile:{offerId:'batch',itemId:'b'},createdAt:'2026-01-01',files:[file('root','newer.txt')]};
 const saved={
  'folder:root':'2026-01-01T00:00:10Z','folder:empty':'2026-01-01T00:00:15Z','folder:last':'2026-01-01T00:00:30Z','file:root':'2026-01-01T00:00:20Z',
 };
 const fixture:any={copiedFiles:receiver,session:{device:{deviceId:'self'}},localHistory:{scopes:[{transfers:[folder],receivedAt:saved}]},transfers:[ordinary],receivedAt:{},localFile:()=>new File(['actual local bytes'],'file'),receiptTime:prototype.receiptTime};
 prototype.rememberReferenceFiles.call(fixture);
 assert.deepEqual(receiver.references.map(ref=>ref.item.id),['a','b']);
 assert.equal(receiver.references[0].completedAtMillis,Date.parse(saved['folder:last']));
 // Polling / reversed history discovery cannot change the completion order.
 fixture.localHistory.scopes[0].transfers=[ordinary];fixture.transfers=[folder];prototype.rememberReferenceFiles.call(fixture);
 const cards=parseHTML('<body>'+copiedFilesHtml(receiver)+'</body>').document;
 assert.deepEqual([...cards.querySelectorAll('strong')].map(node=>node.textContent),['older folder','newer.txt']);
 assert.equal(cards.querySelectorAll('[data-drag-file]').length,2);
 // A directory remains remote until its final member is genuinely local.
 const pending=new CopiedFilesReceiver(async<T>()=>({}) as T,()=>{});pending.offers=receiver.offers;
 fixture.copiedFiles=pending;fixture.localFile=(key:string)=>key==='folder:last'?null:new File(['data'],'file');
 prototype.rememberReferenceFiles.call(fixture);
 assert.equal(pending.references.find(ref=>ref.item.id==='a')?.state,'');
 assert.equal(pending.references.find(ref=>ref.item.id==='b')?.state,'received');
});
