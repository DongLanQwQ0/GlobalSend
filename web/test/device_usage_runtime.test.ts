import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {runInNewContext} from 'node:vm';
import {parseHTML} from 'linkedom';
const source=await readFile(new URL('../src/main.ts',import.meta.url),'utf8');
const {build}=createRequire(import.meta.url)('esbuild');
const code=(await build({stdin:{contents:source.replace('void new GlobalSend().start();','export {GlobalSend,Api,deviceUsage,RecentDevices};'),resolveDir:fileURLToPath(new URL('../src/',import.meta.url)),loader:'ts'},bundle:true,format:'cjs',platform:'browser',write:false,loader:{'.css':'empty'},logLevel:'silent'})).outputFiles[0].text;
test('production Api and all shared peer lists rank accepted use and survive browser restart without counting failure or auto clipboard',async()=>{
  const storage=new Map<string,string>();let fail=false;
  function runtime(){
    const {window,document}=parseHTML('<main id="app"></main>');const module={exports:{}} as {exports:any};
    runInNewContext(code,{module,exports:module.exports,window,document,console,URL,Blob,File,TextEncoder,TextDecoder,AbortController,DOMException,setTimeout,clearTimeout,
      localStorage:{getItem:(key:string)=>storage.get(key) ?? null,setItem:(key:string,value:string)=>storage.set(key,value)},
      fetch:async()=>({ok:!fail,status:fail?503:201,json:async()=>fail?{error:{code:'FIXTURE',message:'synthetic failure'}}:{}})});
    const exports=module.exports;
    const c=Object.assign(Object.create(exports.GlobalSend.prototype),{session:{device:{deviceId:'self'}},devices:['self','a','b','b'].map(deviceId=>({deviceId,name:'Same',online:true})),recentDevices:new exports.RecentDevices(),connected:true,helloReceived:true});
    return {c,api:new exports.Api('https://fixture.invalid')};
  }
  const {c,api}=runtime();
  fail=true;await assert.rejects(api.request('/texts',{targetDeviceId:'b',eventId:'1',text:'fixture'}));
  assert.deepEqual([...c.peers()].map(x=>x.deviceId),['a','b']);
  fail=false;await api.request('/texts',{targetDeviceId:'b',eventId:'1',text:'fixture'});
  await api.request('/texts',{targetDeviceId:'b',eventId:'1',text:'fixture'});
  await api.request('/texts',{targetDeviceId:'a',eventId:'auto',text:'fixture',clipboard:{}});
  assert.deepEqual([...c.peers()].map(x=>x.deviceId),['b','a']);
  const restarted=runtime();
  assert.deepEqual([...restarted.c.onlinePeers()].map(x=>x.deviceId),['b','a']);
  await restarted.api.request('/transfers',{targetDeviceId:'a',transferId:'1',files:[]});
  assert.deepEqual([...restarted.c.peers()].map(x=>x.deviceId),['a','b']);
});
