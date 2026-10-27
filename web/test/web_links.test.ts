import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import { findWebLinks, linkifyHtml, webLinkActions } from '../src/web_links.ts';

test('URLs retain query, parentheses and IPv6 while trailing punctuation stays text',()=>{
  const text='打开（https://example.com/a_(b)?q=1&x=2）。\nwww.example.com，http://[2408::1]:8787/globalsend/。';
  const links=findWebLinks(text);
  assert.deepEqual(links.map(link=>link.label),['https://example.com/a_(b)?q=1&x=2','www.example.com','http://[2408::1]:8787/globalsend/']);
  assert.equal(links[1].url,'https://www.example.com/');
  for(const link of links)assert.equal(text.slice(link.start,link.end),link.label);
  assert.deepEqual(findWebLinks('javascript:alert(1) file:///C:/test https://'),[]);
});
test('link rendering keeps the original text and uses real browser anchors',()=>{
  const text='<img src=x onerror=alert(1)> https://example.com/?q=1&x=2，www.example.com';
  const {document}=parseHTML(`<div id="text">${linkifyHtml(text)}</div>`).window;
  assert.equal(document.querySelector('#text')!.textContent,text);
  assert.equal(document.querySelector('img'),null);
  const links=document.querySelectorAll('a');assert.equal(links.length,2);
  assert.equal(links[0].getAttribute('href'),'https://example.com/?q=1&x=2');
  assert.equal(links[0].getAttribute('target'),'_blank');
  assert.equal(links[0].getAttribute('rel'),'noopener noreferrer');
  const actions=webLinkActions('https://example.com https://example.com www.example.com');
  assert.equal(parseHTML(actions).document.querySelectorAll('a').length,2);
});
