import { normalizeBaseUrl as normalizeProtocolBase } from '../../packages/protocol/src/index.ts';
import type { Device, Event as ProtocolEvent } from '../../packages/protocol/src/index.ts';
export type { ServerInfo, Device, FileStatus, TransferFile, Transfer } from '../../packages/protocol/src/index.ts';
import type { FileStatus } from '../../packages/protocol/src/index.ts';
export interface Session { deviceToken: string; device: Device; groupId?: string }
export interface WireEvent extends ProtocolEvent {
  payload: { text?: string; sourceEventId?: string; editedAt?: string; transferId?: string; deviceId?: string; clipboard?:{originDeviceId:string;sourceEventId:string} };
}
export interface StoredState { cursor: number; events: WireEvent[]; hidden?: Record<string,number>; receivedAt?:Record<string,string> }

export function escapeHtml(value: unknown): string {
  return String(value ?? '').replace(/[&<>"']/g, (char) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]!));
}
export function formatBytes(size: number): string {
  if (size === 0) return '0 B';
  const unit = Math.min(3, Math.max(0, Math.floor(Math.log(size) / Math.log(1024))));
  return `${(size / 1024 ** unit).toFixed(unit === 0 ? 0 : 1)} ${['B','KiB','MiB','GiB'][unit]}`;
}
/** Match the native rune count: Unicode code points, not UTF-16 units or bytes. */
export function characterCount(text:string):number { return [...text].length; }
/** Today and yesterday show only the clock; older days include their date. */
export function compactTime(value:string|number,now=new Date()):string {
  const date=new Date(value),start=new Date(now.getFullYear(),now.getMonth(),now.getDate()-1);
  const clock=new Intl.DateTimeFormat('zh-CN',{hour:'2-digit',minute:'2-digit',hour12:false}).format(date);
  return date>=start?clock:new Intl.DateTimeFormat('zh-CN',{month:'2-digit',day:'2-digit'}).format(date)+' '+clock;
}
export function normalizeBaseUrl(raw: string): string {
  const url = new URL(raw.trim());
  if (url.username || url.password || url.search || url.hash) throw new Error('服务器地址不能包含账号、查询参数或 # 片段。');
  const loopback = ['localhost','127.0.0.1','[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) throw new Error('请使用 HTTPS 地址；HTTP 仅用于本机开发。');
  return normalizeProtocolBase(raw,loopback);
}
export function baseFromLocation(location: Pick<Location,'origin'|'pathname'>): string {
  const index = location.pathname.lastIndexOf('/app');
  const base = index >= 0 && /^\/app(?:\/|$)/.test(location.pathname.slice(index)) ? location.pathname.slice(0,index) : '';
  return location.origin + base;
}
/** Browser-visible device family, not the private system-assigned device name. */
export function suggestedDeviceName(browser:{userAgent:string;maxTouchPoints?:number;platform?:string;userAgentData?:{platform?:string}}):string {
  const ua=browser.userAgent,platform=browser.userAgentData?.platform || browser.platform || '';
  if(/iPad/i.test(ua) || /Macintosh/i.test(ua) && (browser.maxTouchPoints || 0)>1)return 'iPad';
  if(/iPhone|iPod/i.test(ua))return 'iPhone';
  if(/Android/i.test(ua+' '+platform))return 'Android 手机';
  if(/Windows|Win32|Win64/i.test(ua+' '+platform))return 'Windows 电脑';
  if(/CrOS/i.test(ua))return 'Chromebook';
  if(/Macintosh|MacIntel|Mac OS|macOS/i.test(ua+' '+platform))return 'Mac';
  if(/Linux|X11/i.test(ua+' '+platform))return 'Linux 电脑';
  return '浏览器';
}
export function centerWebSocketUrl(baseUrl:string,ticket:string):string {
  const url=new URL(`${baseUrl}/api/v1/ws`);url.protocol=url.protocol==='https:'?'wss:':'ws:';url.searchParams.set('ticket',ticket);return url.href;
}
export function storageKey(baseUrl: string, instanceId: string): string {
  return `globalsend:v1:${baseUrl}:${instanceId}`;
}
export function mergeEvents(current: WireEvent[], incoming: WireEvent[], now = Date.now()): WireEvent[] {
  const map = new Map<string, WireEvent>();
  for (const event of [...current, ...incoming]) {
    if (Date.parse(event.expiresAt) > now) map.set(event.eventId, event);
  }
  const ordered=[...map.values()].sort((a,b) => a.cursor-b.cursor);
  for(const update of ordered) {
    if(update.type!=='text.updated')continue;
    const original=map.get(update.payload.sourceEventId || '');
    if(original?.type==='text.created' && original.sourceDeviceId===update.sourceDeviceId) {
      map.set(original.eventId,{...original,payload:{...original.payload,text:update.payload.text,editedAt:update.payload.editedAt}});
    }
  }
  return ordered.map(event=>map.get(event.eventId)!).slice(-1500);
}
export function safeDownloadUrl(baseUrl: string, path: string): string {
  if (!/^\/api\/v1\/downloads\/[a-zA-Z0-9_-]+$/.test(path)) throw new Error('服务器返回了无效的下载地址。');
  return baseUrl + path;
}
export const statusLabel: Record<FileStatus,string> = {
  offered:'等待接收',accepted:'等待发送',uploading:'传输中',ready:'已就绪',received:'已确认',
  rejected:'已拒绝',canceled:'已取消',failed:'失败',expired:'已过期',
};
