import { escapeHtml as e } from './model.ts';

export interface WebLink { start:number;end:number;label:string;url:string }
export function findWebLinks(text:string):WebLink[] {
  const links:WebLink[]=[];
  for(const match of text.matchAll(/(?:https?:\/\/|www\.)[^\s<>"'，。；！？、【】《》“”‘’（）]+/gi)) {
    let label=match[0].replace(/[.,;:!?]+$/,'');
    for(const [open,close] of [['(',')'],['[',']'],['{','}']])
      while(label.endsWith(close) && label.split(close).length>label.split(open).length)label=label.slice(0,-1);
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
