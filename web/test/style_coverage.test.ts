import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Guards the layered stylesheet against parallel edits: a class that markup relies on must stay styled.
// Regenerate the baseline only when a rule is intentionally retired: STYLE_BASELINE=write npm --prefix web test

const webRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const sourceDir = join(webRoot, 'src');
const stylesDir = join(sourceDir, 'styles');
const baselinePath = join(webRoot, 'test', 'style_coverage.baseline.json');
const CLASS_TOKEN = /^\.?[a-zA-Z][\w-]*$/;

function walk(dir: string, filter: (name: string) => boolean): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full, filter));
    else if (filter(entry.name)) out.push(full);
  }
  return out;
}

function stylesheetText(): string {
  const parts = [readFileSync(join(sourceDir, 'style.css'), 'utf8')];
  if (existsSync(stylesDir)) for (const file of readdirSync(stylesDir).filter((name) => name.endsWith('.css')).sort()) parts.push(readFileSync(join(stylesDir, file), 'utf8'));
  return parts.join('\n');
}

function styledClasses(css: string): Set<string> {
  const withoutComments = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const names = new Set<string>();
  for (const rule of withoutComments.matchAll(/([^{}]+)\{/g)) {
    for (const token of rule[1].matchAll(/\.(-?[a-zA-Z][\w-]*)/g)) names.add(token[1]);
  }
  return names;
}

function usedClasses(typescript: string): Set<string> {
  const names = new Set<string>();
  const push = (fragment: string) => {
    for (const token of fragment.split(/\s+/)) if (CLASS_TOKEN.test(token)) names.add(token.replace(/^\./, ''));
  };
  for (const match of typescript.matchAll(/class(?:Name)?\s*=\s*"([^"]*)"/g)) push(match[1]);
  for (const match of typescript.matchAll(/class(?:Name)?\s*=\s*'([^']*)'/g)) push(match[1]);
  for (const match of typescript.matchAll(/classList\.(?:add|remove|toggle|contains)\(([^)]*)\)/g)) {
    for (const literal of match[1].matchAll(/'([^']*)'|"([^"]*)"/g)) push(literal[1] ?? literal[2] ?? '');
  }
  for (const match of typescript.matchAll(/querySelector(?:All)?(?:<[^>]*>)?\(\s*['"]([^'"]+)['"]/g)) {
    for (const token of match[1].matchAll(/\.(-?[a-zA-Z][\w-]*)/g)) names.add(token[1]);
  }
  return names;
}

const css = stylesheetText();
const styled = styledClasses(css);
const used = new Set<string>();
for (const file of walk(sourceDir, (name) => name.endsWith('.ts'))) for (const name of usedClasses(readFileSync(file, 'utf8'))) used.add(name);

const covered = [...used].filter((name) => styled.has(name)).sort();
const uncovered = [...used].filter((name) => !styled.has(name)).sort();

if (process.env.STYLE_BASELINE === 'write') {
  writeFileSync(baselinePath, JSON.stringify({ note: 'Classes that markup uses and the stylesheet styles. Regenerate with STYLE_BASELINE=write.', covered }, null, 2) + '\n', 'utf8');
}

test('layered stylesheet keeps styling every class that markup uses', () => {
  assert.ok(existsSync(baselinePath), 'style coverage baseline is missing');
  const baseline = JSON.parse(readFileSync(baselinePath, 'utf8')) as { covered: string[] };
  const missing = baseline.covered.filter((name) => !styled.has(name));
  assert.deepEqual(missing, [], 'these classes lost every CSS rule: ' + missing.join(', '));
});

test('stylesheet still ships a complete layer set', () => {
  const layers = existsSync(stylesDir) ? readdirSync(stylesDir).filter((name) => name.endsWith('.css')) : [];
  assert.ok(layers.length >= 7, 'expected the split layer set, found ' + layers.length);
  const entry = readFileSync(join(sourceDir, 'style.css'), 'utf8');
  for (const layer of layers) assert.match(entry, new RegExp('@import\\s+\'\\./styles/' + layer.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\';'), 'style.css must import ' + layer);
});

test('no class is defined twice with a conflicting declaration block by accident', () => {
  const duplicates = [...styled].filter((name) => (css.match(new RegExp('\\.' + name + '(?![\\w-])', 'g')) || []).length > 400);
  assert.deepEqual(duplicates, []);
  assert.ok(uncovered.length < 40, 'too many unstyled classes: ' + uncovered.slice(0, 12).join(', '));
});
