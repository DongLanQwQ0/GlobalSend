import test from 'node:test';
import assert from 'node:assert/strict';
import {parseHTML} from 'linkedom';
import {AppearancePreferences,appearancePalette,parseAppearance,accentColors} from '../src/appearance.ts';

test('light green default and persisted mode/accent restore independently',()=>{
 assert.deepEqual(parseAppearance(null),{mode:'light',accent:'green'});
 assert.deepEqual(parseAppearance('{"mode":"dark","accent":"blue"}'),{mode:'dark',accent:'blue'});
 assert.deepEqual(parseAppearance('{"mode":"old","accent":"unknown"}'),{mode:'light',accent:'green'});
});
test('switching themes updates surfaces and controls without remounting editors or tinting images',()=>{
 const {document}=parseHTML('<html><body><textarea id="draft">未发送内容</textarea><img id="photo" src="photo.jpg"><div id="settings"></div></body></html>');
 let saved:string|null=null;
 const preferences=new AppearancePreferences(document as any,()=>saved,raw=>{saved=raw;});
 document.querySelector('#settings')!.innerHTML=preferences.html();
 const editor=document.querySelector('#draft'),photo=document.querySelector('#photo');
 preferences.set({mode:'dark',accent:'blue'});
 assert.equal(document.documentElement.dataset.theme,'dark');
 assert.equal(document.documentElement.style.getPropertyValue('--green'),'#9ecaff');
 assert.equal(document.querySelector('[data-appearance-mode=dark]')!.getAttribute('aria-pressed'),'true');
 assert.equal(document.querySelector('#draft'),editor);assert.equal(editor!.textContent,'未发送内容');
 assert.equal(document.querySelector('#photo'),photo);assert.equal(photo!.getAttribute('style'),null);
 assert.equal(document.querySelectorAll('[data-appearance-accent][aria-pressed=true]').length,1);
 const restored=new AppearancePreferences(document as any,()=>saved,()=>{});
 assert.deepEqual(restored.value,{mode:'dark',accent:'blue'});
 preferences.set({mode:'neutral'});assert.equal(appearancePalette(preferences.value).canvas,'#e9eaec');
});
test('all non-green accents recolor the former green fields while keeping page neutrals stable',()=>{
 for(const mode of ['light','dark'] as const){
  const green=appearancePalette({mode,accent:'green'});
  for(const accent of accentColors.filter(color=>color!=='green')){
   const palette=appearancePalette({mode,accent});
   assert.notEqual(palette.field,green.field,accent);
   assert.equal(palette.canvas,green.canvas);assert.equal(palette.muted,green.muted);
  }
 }
});
