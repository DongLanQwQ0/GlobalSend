import test from 'node:test';
import assert from 'node:assert/strict';
import {ViewportFrame} from '../src/mobile_viewport.ts';
import {PageDisplay} from '../src/page_display.ts';

test('one viewport frame follows both keyboard resize and Safari pan without double subtraction',()=>{
 const frame=new ViewportFrame();
 assert.deepEqual(frame.sample({width:390,layoutHeight:844,height:844,top:0,scale:1,editing:false}),{height:844,top:0,keyboard:false});
 assert.deepEqual(frame.sample({width:390,layoutHeight:844,height:430,top:190,scale:1,editing:true}),{height:430,top:190,keyboard:true});
 assert.deepEqual(frame.sample({width:390,layoutHeight:430,height:430,top:0,scale:1,editing:true}),{height:430,top:0,keyboard:true});
 assert.equal(frame.sample({width:390,layoutHeight:844,height:300,top:20,scale:2,editing:true}),null,'pinch zoom belongs to browser');
 assert.deepEqual(frame.sample({width:390,layoutHeight:844,height:844,top:0,scale:1,editing:false}),{height:844,top:0,keyboard:false});
});
test('browser toolbar shrink alone is not classified as an open keyboard',()=>{
 const frame=new ViewportFrame();frame.sample({width:390,layoutHeight:844,height:844,top:0,scale:1,editing:false});
 assert.equal(frame.sample({width:390,layoutHeight:844,height:750,top:0,scale:1,editing:true})?.keyboard,false);
 assert.equal(frame.sample({width:844,layoutHeight:390,height:390,top:0,scale:1,editing:true})?.keyboard,false,'orientation resets baseline');
});
test('fullscreen is user initiated, exits normally and gives an honest standalone fallback',async()=>{
 let calls=0,changed=0;const doc:any={addEventListener(){},documentElement:{async requestFullscreen(options:any){assert.equal(options.navigationUI,'hide');calls++;doc.fullscreenElement={};}},async exitFullscreen(){calls++;doc.fullscreenElement=null;}};
 const display=new PageDisplay(doc,{navigator:{},matchMedia:()=>({matches:false})} as any,()=>changed++);
 assert.equal(calls,0);await display.toggle();assert.equal(display.label,'退出全屏');assert.equal(calls,1);await display.toggle();assert.equal(calls,2);assert.equal(changed,2);
 const unsupported=new PageDisplay({addEventListener(){},documentElement:{}} as any,{navigator:{}} as any,()=>{});await unsupported.toggle();assert.match(unsupported.hint,/添加到主屏幕/);
 const rejected=new PageDisplay({...doc,fullscreenEnabled:false} as any,{navigator:{}} as any,()=>{});await rejected.toggle();assert.match(rejected.hint,/添加到主屏幕/);assert.equal(calls,2);
});
