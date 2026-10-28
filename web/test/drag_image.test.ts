import test from 'node:test';
import assert from 'node:assert/strict';
import {parseHTML} from 'linkedom';
import {centeredDragImage} from '../src/drag_image.ts';

test('drag images use their measured center for text, images and batches',()=>{
 for(const [width,height] of [[184,140],[212,85],[100,100]]){
  const {document}=parseHTML('<html><body></body></html>');
  const ghost=document.createElement('div');
  ghost.getBoundingClientRect=()=>({width,height}) as any;
  let offset:number[]=[];
  centeredDragImage({clientX:450,clientY:320,dataTransfer:{setDragImage:(node:HTMLElement,x:number,y:number)=>{
   assert.equal(node,ghost);assert.equal(ghost.parentNode,document.body);offset=[x,y];
  }}} as any,ghost as any);
  assert.deepEqual(offset,[width/2,height/2]);
  assert.equal(ghost.style.left,(450-width/2)+'px');assert.equal(ghost.style.top,(320-height/2)+'px');
 }
});
