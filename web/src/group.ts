export function publicSession<T extends {deviceToken:string;device:unknown;groupId?:string;groups?:import('../../packages/protocol/src/index.ts').GroupMembership[];historyGroupId?:string}>(response: T): {deviceToken:string;device:T['device'];groupId?:string;groups?:import('../../packages/protocol/src/index.ts').GroupMembership[];historyGroupId?:string} {
  // Explicit projection prevents an enrollment response from persisting a group key or other join secrets.
  return {deviceToken:response.deviceToken,device:response.device,...(response.groupId ? {groupId:response.groupId} : {}),...(response.groups?{groups:response.groups}:{}),...(response.historyGroupId!==undefined?{historyGroupId:response.historyGroupId}:{})};
}

export function validateGroupKey(value: string): string {
  if (value.length < 10 || value.length > 256 || value.trim() !== value || /[\u0000-\u001f\u007f]/.test(value)) throw new Error('组密码需为 10–256 个字符，不含首尾空格或控制字符。');
  return value; // Do not normalize a joining credential: case and every character matter.
}
import type { Device, Transfer, WireEvent } from './model.ts';


/** New collections sever all links to a previous group's queue, sources, actions and secrets. */
export function emptyGroupData() {
  return {
    devices:[] as Device[], events:[] as WireEvent[], transfers:[] as Transfer[], cursor:0,target:'',text:'',
    picked:[] as File[],pendingTexts:[] as {eventId:string;targetDeviceId:string;text:string;error:string;busy:boolean}[],pendingOffer:null,
    fileSources:new Map<string,File>(),uploads:new Map<string,AbortController>(),hashes:new Set<AbortController>(),uploadErrors:new Map<string,string>(),uploadProgress:new Map<string,number>(),
    paused:new Set<string>(),handed:new Set<string>(),selected:new Set<string>(),expanded:new Set<string>(),consent:new Map<string,boolean>(),acked:new Set<string>(),hiddenItems:{} as Record<string,number>,readingEventId:'',expiredTextCount:0,
    resumeKey:'',busy:false,preparation:'',groupKey:'',showGroupKey:false,
  };
}
