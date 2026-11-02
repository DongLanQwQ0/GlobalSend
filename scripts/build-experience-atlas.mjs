import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { baseline, platforms, groups, modules, features, journeys, decisions, pending } from '../docs/experience/catalog.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = join(root, 'docs/experience');
const output = join(root, 'web/public/experience/index.html');
const { build } = createRequire(join(root, 'web/package.json'))('esbuild');
const icons = await build({ entryPoints: [join(root, 'web/src/icons.ts')], bundle: true, format: 'iife', globalName: 'GlobalSendIcons', write: false, minify: true });
const data = { baseline, platforms, groups, modules, features, journeys, decisions, pending };
const ids = new Set(features.map(feature => feature.id));
if (ids.size !== features.length) throw new Error('Duplicate feature id');
for (const feature of features) {
  if (!groups.some(group => group.id === feature.group)) throw new Error(`Unknown group: ${feature.id}`);
  if (!feature.support.every(id => platforms.some(platform => platform.id === id))) throw new Error(`Unknown platform: ${feature.id}`);
  for (const path of feature.sources) await stat(join(root, 'docs', path));
}
for (const item of [...modules, ...journeys, ...decisions]) {
  if (!item.ids.every(id => ids.has(id))) throw new Error(`Unknown reference: ${item.name || item.title}`);
}
const [template, css, app] = await Promise.all(['index.template.html','style.css','app.js'].map(name => readFile(join(source,name),'utf8')));
const iconLicense = await readFile(join(root,'web/public/licenses/material-symbols.txt'),'utf8');
let html = template.replace('/* ATLAS_CSS */', css)
  .replace('/* ATLAS_ICONS */', () => icons.outputFiles[0].text)
  .replace('/* ATLAS_DATA */', () => JSON.stringify(data).replace(/</g,'\\u003c'))
  .replace('/* ATLAS_APP */', () => app);
if (/\/\* ATLAS_/.test(html)) throw new Error('Unfilled atlas template');
html = html.replace('</body>', () => `<template id="material-symbols-license">${iconLicense.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}</template>\n</body>`);
await mkdir(join(root,'web/public/experience'), {recursive:true});
await writeFile(output,html);
console.log(`${features.length} features · ${platforms.length} platforms · standalone page: ${output}`);
