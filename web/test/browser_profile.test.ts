import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile,readdir} from 'node:fs/promises';

test('all browser tools use the same persistent identity and normal awaited shutdown',async()=>{
  const folder=new URL('../tool/',import.meta.url);
  const files=(await readdir(folder)).filter(name=>name.endsWith('.mjs') && name!=='browser_profile.mjs');
  let launchers=0;
  for(const name of files){
    const source=await readFile(new URL(name,folder),'utf8');
    assert.doesNotMatch(source,/Target\.createBrowserContext|--incognito|--inprivate|--guest/,name);
    assert.doesNotMatch(source,/browser\??\.kill\(/,name);
    if(!source.includes('--user-data-dir='))continue;
    launchers++;
    assert.match(source,/from '\.\/browser_profile\.mjs'/,name);
    assert.match(source,/launchSharedBrowser\(/,name);
    assert.match(source,/await closeSharedBrowser\(browser\)/,name);
    assert.doesNotMatch(source,/\bbrowser\s*=\s*spawn\(/,name);
  }
  assert.ok(launchers>=16);
});
