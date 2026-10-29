import { escapeHtml as e } from './model.ts';

export interface WebLink { start:number;end:number;label:string;url:string }
export function findWebLinks(text:string):WebLink[] {
  const links:WebLink[]=[];
  const candidate=/(?:https?:\/\/|www\.)[^\s<>"'，。；！？、【】《》“”‘’（）]+/iy;
  const proseAfterHost=/^(?:\[[0-9a-z:.%_-]+\]|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}|(?:\d{1,3}\.){3}\d{1,3}|localhost)(?::\d+)?(?=[\u3400-\u9fff\uf900-\ufaff])/i;
  for(const start of text.matchAll(/(?:https?:\/\/|www\.)/gi)) {
    if(links.length && start.index!<links.at(-1)!.end)continue;
    candidate.lastIndex=start.index!;const match=candidate.exec(text);if(!match)continue;
    let label=match[0];
    // Do not let Chinese prose become part of an ASCII hostname. Unicode
    // after a path/query delimiter, and actual IDN hosts, are left alone.
    const authorityStart=/^www\./i.test(label)?0:label.indexOf('://')+3;
    const authority=label.slice(authorityStart).split(/[/?#]/)[0],boundary=proseAfterHost.exec(authority);
    if(boundary)label=label.slice(0,authorityStart+boundary[0].length);
    let before:string;
    do {
      before=label;label=label.replace(/[.,;:!?]+$/,'');
      for(const [open,close] of [['(',')'],['[',']'],['{','}']])
        while(label.endsWith(close) && label.split(close).length>label.split(open).length)label=label.slice(0,-1);
    }while(label!==before);
    try {
      const url=new URL(/^www\./i.test(label)?'https://'+label:label);
      if(!['http:','https:'].includes(url.protocol) || !url.hostname)continue;
      links.push({start:match.index!,end:match.index!+label.length,label,url:url.href});
    } catch { /* Not a complete web address. */ }
  }
  return links;
}
const anchor=(link:WebLink,label=link.label)=>`<a class="web-link" href="${e(link.url)}" target="_blank" rel="noopener noreferrer">${e(label)}</a>`;
export function linkifyHtml(text:string) {
  let offset=0,html='';
  for(const link of findWebLinks(text)){html+=e(text.slice(offset,link.start))+anchor(link);offset=link.end;}
  return html+e(text.slice(offset));
}
export function webLinkActions(text:string,firstOnly=false) {
  const links=[...new Map(findWebLinks(text).map(link=>[link.url,link])).values()];
  if(firstOnly)return links.length?anchor(links[0],'打开网址'):'';
  return links.map(link=>anchor(link,links.length===1?'打开网址':new URL(link.url).host)).join('');
}
