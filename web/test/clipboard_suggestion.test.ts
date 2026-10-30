import {test} from 'node:test';
import assert from 'node:assert/strict';
import {clipboardSuggestion} from '../src/clipboard_suggestion.ts';

test('clipboard suggestions use existing permission and metadata, never requesting access', async () => {
  let reads = 0;
  const clipboard = {read: async () => {reads++; return [{types: ['image/png', 'text/plain']}];}};
  assert.equal(await clipboardSuggestion({permissions: {query: async () => ({state: 'prompt'})}, clipboard}), null);
  assert.equal(reads, 0);
  assert.equal(await clipboardSuggestion({permissions: {query: async () => ({state: 'granted'})}, clipboard}), 'image');
  assert.equal(reads, 1);
  assert.equal(await clipboardSuggestion({clipboard}), null);
  assert.equal(await clipboardSuggestion({permissions: {query: async () => {throw new TypeError('unsupported');}}, clipboard}), null);
});
