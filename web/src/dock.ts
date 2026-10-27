import type { WireEvent } from './model.ts';

export const LOCAL_TEXT_RETENTION_MS = 24 * 60 * 60 * 1000;
export type HiddenItems = Record<string,number>;

export function dockScopeKey(centerKey: string,deviceId: string,groupId?: string): string {
  return `${centerKey}:dock:${encodeURIComponent(deviceId)}:${encodeURIComponent(groupId || 'legacy')}`;
}
export function textItemKey(eventId: string): string { return `text:${eventId}`; }
export function fileItemKey(transferId: string,fileId: string): string { return `file:${transferId}:${fileId}`; }
export function localTextDeadline(event: WireEvent): number {
  return Math.min(Date.parse(event.expiresAt),Date.parse(event.createdAt) + LOCAL_TEXT_RETENTION_MS);
}
export function visibleLocalEvents(events: WireEvent[],hidden: HiddenItems,now = Date.now()): WireEvent[] {
  return events.filter(event => {
    if (Date.parse(event.expiresAt) <= now) return false;
    if (event.type !== 'text.created') return true;
    return localTextDeadline(event) > now && !(hidden[textItemKey(event.eventId)] > now);
  });
}
export function expiryLabel(deadline: number,now = Date.now()): string {
  const remaining = deadline-now;
  if (remaining <= 0) return '已过期';
  if (remaining < 60000) return '即将过期';
  if (remaining < 3600000) return `${Math.ceil(remaining/60000)} 分钟后过期`;
  return `${Math.ceil(remaining/3600000)} 小时后过期`;
}
