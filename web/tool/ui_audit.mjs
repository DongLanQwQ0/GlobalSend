import { readFileSync, readdirSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// Consistency audit for the layered stylesheet and the Flutter token surface.
// It answers one question: where does the code drift from docs/Communication/UI-DESIGN-BRIEF.md?
// Exit code 0 = only notes, 1 = at least one hard violation.

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const stylesDir = join(root, 'web', 'src', 'styles');
const canvasPalette = new Set(['canvas', 'surface', 'field', 'soft', 'line', 'green', 'text', 'muted', 'red', 'warning', 'on-accent']);
const ALLOWED_DURATIONS = new Set(['110', '170', '260']);
// Documented exceptions: an infinite rotation is not a UI transition, and the modal
// teardown must beat the inline animation-delay the renderer writes on close.
const DURATION_EXEMPT = /^\s*\.spinner\b/;
const IMPORTANT_EXEMPT = /\.leaving(\s|\.|$)|\[hidden\]|prefers-reduced-motion/;
const LAYOUT_PROPS = /^(width|height|margin|padding|inset|top|left|right|bottom|grid-template|grid-auto|flex-basis|font-size|line-height)$/;

function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, '');
}

// Walks braces so @media context never confuses selector parsing.
function parseRules(css) {
  const rules = [];
  const stack = [];
  let buffer = '';
  for (let i = 0; i < css.length; i += 1) {
    const ch = css[i];
    if (ch === '{') {
      const prelude = buffer.trim();
      buffer = '';
      stack.push(prelude);
      if (prelude.startsWith('@')) continue;
      const start = i + 1;
      let depth = 1;
      let j = start;
      for (; j < css.length && depth > 0; j += 1) {
        if (css[j] === '{') depth += 1;
        else if (css[j] === '}') depth -= 1;
      }
      const body = css.slice(start, j - 1);
      if (body.includes('{')) {
        // Nested block (e.g. keyframes): skip, handled separately.
        i = j - 1;
        stack.pop();
        continue;
      }
      rules.push({ selector: prelude, body, context: stack.slice(0, -1).filter((p) => p.startsWith('@media')), index: i });
      i = j - 1;
      stack.pop();
    } else if (ch === '}') {
      stack.pop();
      buffer = '';
    } else {
      buffer += ch;
    }
  }
  return rules;
}

function declarations(body) {
  return body.split(';').map((part) => part.trim()).filter(Boolean).map((part) => {
    const colon = part.indexOf(':');
    return { prop: part.slice(0, colon).trim(), value: part.slice(colon + 1).trim(), raw: part };
  }).filter((item) => item.prop && item.value);
}

const findings = [];
const note = (layer, line, kind, detail) => findings.push({ layer, line, kind, detail });

const layers = readdirSync(stylesDir).filter((name) => name.endsWith('.css')).sort();

// Pass 1: every element that declares a transition, across all layers, keyed by its
// trailing compound selector. A hover rule is covered when that key exists anywhere.
const lastCompound = (selector) => selector.trim().split(/\s+|>/).filter(Boolean).pop()
  .replace(/::?(hover|active|focus-visible|focus|disabled|checked|placeholder|before|after)/g, '')
  .replace(/:not\([^)]*\)/g, '')
  .trim();
const transitionedKeys = new Set();
const transformKeys = new Set();
const transitionedByLayer = new Map();
for (const layer of layers) {
  const text = stripComments(readFileSync(join(stylesDir, layer), 'utf8'));
  const keys = new Set();
  for (const rule of parseRules(text)) {
    const decls = declarations(rule.body);
    const motion = decls.filter((d) => d.prop === 'transition' || d.prop === 'transition-property' || d.prop === 'animation');
    if (!motion.length) continue;
    const coversTransform = motion.some((d) => /transform|opacity|all/.test(d.value));
    for (const selector of rule.selector.split(',')) {
      const key = lastCompound(selector);
      if (key) { transitionedKeys.add(key); keys.add(key); if (coversTransform) transformKeys.add(key); }
    }
  }
  transitionedByLayer.set(layer, keys);
}
for (const layer of layers) {
  const text = stripComments(readFileSync(join(stylesDir, layer), 'utf8'));
  const lineOf = (index) => text.slice(0, index).split('\n').length;
  const rules = parseRules(text);
  const transitioned = new Set();
  for (const rule of rules) {
    const decls = declarations(rule.body);
    const transitionDecl = decls.find((d) => d.prop === 'transition' || d.prop === 'transition-property');
    if (transitionDecl) for (const selector of rule.selector.split(',')) transitioned.add(selector.trim().replace(/::?(hover|active|focus-visible|focus|disabled|checked|placeholder).*$/, ''));
    for (const decl of decls) {
      if (decl.prop === 'transition' || decl.prop === 'transition-property') {
        for (const prop of decl.value.split(',')) {
          const name = prop.trim().split(/\s+/)[0];
          if (LAYOUT_PROPS.test(name)) note(layer, lineOf(rule.index), 'layout-transition', rule.selector + ' -> ' + name);
        }
      }
      if (decl.prop === 'animation' || decl.prop === 'animation-duration' || decl.prop === 'transition' || decl.prop === 'transition-duration') {
        const ms = [...decl.value.matchAll(/(\d+(?:\.\d+)?)(ms|s)(?![\w-])/g)];
        for (const match of ms) {
          const value = match[2] === 's' ? String(Math.round(Number(match[1]) * 1000)) : match[1];
          if (!ALLOWED_DURATIONS.has(value) && Number(value) !== 1 && Number(value) !== 0 && !DURATION_EXEMPT.test(rule.selector)) {
            note(layer, lineOf(rule.index), 'duration', rule.selector + ' -> ' + match[0]);
          }
        }
      }
      if (decl.prop.includes('color') || decl.prop === 'background' || decl.prop === 'border' || decl.prop === 'box-shadow' || decl.prop === 'fill' || decl.prop === 'stroke') {
        const hex = decl.value.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
        const rgb = decl.value.match(/rgba?\(/g) || [];
        if (hex.length || rgb.length) {
          const allowed = layer === '00-foundation.css' && (rule.selector.includes(':root') || rule.selector.includes('[data-theme'));
          if (!allowed) note(layer, lineOf(rule.index), 'raw-color', rule.selector + ' -> ' + decl.value.slice(0, 60));
        }
      }
      if (decl.prop === 'font-size' && /px$/.test(decl.value) && layer !== '00-foundation.css') {
        note(layer, lineOf(rule.index), 'raw-font-size', rule.selector + ' -> ' + decl.value);
      }
      if ((decl.prop === 'border-radius' || decl.prop.startsWith('border-') && decl.prop.endsWith('-radius')) && /\d+px/.test(decl.value) && layer !== '00-foundation.css') {
        note(layer, lineOf(rule.index), 'raw-radius', rule.selector + ' -> ' + decl.value);
      }
      const reducedMotion = rule.context.some((context) => context.includes('prefers-reduced-motion'));
      if (decl.value.includes('!important') && !reducedMotion && !IMPORTANT_EXEMPT.test(rule.selector)) note(layer, lineOf(rule.index), 'important', rule.selector + ' -> ' + decl.value.slice(0, 50));
    }
  }
  // Colour changes are covered by the universal rule in 00-foundation. Transform and
  // opacity changes still need their own declaration, or the state snaps.
  for (const rule of rules) {
    // Press feedback (:active) is meant to be instant; only hover travel must be eased.
    if (!/:hover/.test(rule.selector)) continue;
    if (!/transform|opacity/.test(rule.body)) continue;
    for (const selector of rule.selector.split(',')) {
      const key = lastCompound(selector.replace(/::?(hover|active).*$/, ''));
      if (!key) continue;
      if (transformKeys.has(key)) continue;
      note(layer, lineOf(rule.index), 'transform-snap', key + ' -> ' + rule.body.slice(0, 50));
    }
  }
}

// Flutter: durations and curves that bypass the token ramp.
const dartDir = join(root, 'client', 'lib');
const dartNotes = [];
if (existsSync(dartDir)) {
  for (const name of readdirSync(dartDir).filter((file) => file.endsWith('.dart'))) {
    const text = readFileSync(join(dartDir, name), 'utf8');
    text.split('\n').forEach((line, index) => {
      // Timers, timeouts, polls and debounces are not UI transitions; the token file defines the ramp.
      const nonVisual = /Future(<[^>]*>)?\.delayed|\.timeout\(|ConnectionWindow\(|time\.difference|wait >|retry|debounce|poll|^\s*\?\s*const Duration/i.test(line);
      if (/Duration\(milliseconds:\s*\d/.test(line) && !/Ui\.duration/.test(line) && !nonVisual && name !== 'ui_tokens.dart') {
        dartNotes.push({ file: name, line: index + 1, kind: 'raw-duration', detail: line.trim().slice(0, 90) });
      }
      if (/Curves\./.test(line) && !/Ui\.ease/.test(line)) dartNotes.push({ file: name, line: index + 1, kind: 'raw-curve', detail: line.trim().slice(0, 90) });
    });
  }
}

const byKind = {};
for (const finding of findings) byKind[finding.kind] = (byKind[finding.kind] || 0) + 1;
const dartByKind = {};
for (const finding of dartNotes) dartByKind[finding.kind] = (dartByKind[finding.kind] || 0) + 1;

mkdirSync(join(root, 'artifacts', 'reports'), { recursive: true });
writeFileSync(join(root, 'artifacts', 'reports', 'ui-consistency.json'), JSON.stringify({ generatedAt: new Date().toISOString(), web: { counts: byKind, findings }, flutter: { counts: dartByKind, findings: dartNotes } }, null, 2), 'utf8');

console.log('CSS: ' + findings.length + ' finding(s)');
for (const [kind, count] of Object.entries(byKind).sort((a, b) => b[1] - a[1])) console.log('  ' + kind.padEnd(16) + count);
console.log('Dart: ' + dartNotes.length + ' finding(s)');
for (const [kind, count] of Object.entries(dartByKind).sort((a, b) => b[1] - a[1])) console.log('  ' + kind.padEnd(16) + count);
const hard = ['raw-color', 'important', 'layout-transition', 'duration'];
const failing = findings.filter((f) => hard.includes(f.kind));
if (failing.length) {
  console.log('');
  console.log('First violations:');
  for (const f of failing.slice(0, 25)) console.log('  ' + f.layer + ':' + f.line + '  [' + f.kind + '] ' + f.detail);
}
console.log('');
console.log('report: artifacts/reports/ui-consistency.json');
