import test from 'node:test';
import assert from 'node:assert/strict';
import {browserHostCandidates,groupIpAddresses,groupIpSources,literalIp} from '../src/ip_addresses.ts';

test('local address menu uses the four requested groups with literal deduplication',()=>{
  assert.deepEqual(groupIpAddresses(['2001:db8::2','8.8.8.8','fd00::1','192.168.0.10','10.0.0.1','192.168.0.2','10.0.0.1','::1']),[
    {label:'IPv4 内网',addresses:['10.0.0.1','192.168.0.2','192.168.0.10']},
    {label:'IPv4 公网',addresses:['8.8.8.8']},
    {label:'IPv6 内网',addresses:['fd00::1']},
    {label:'IPv6 公网',addresses:['2001:db8::2']},
  ]);
});
test('loopback literals are excluded including URLs, all 127/8 and mapped IPv6',()=>{
  for(const address of ['127.0.0.1','127.18.32.255','http://127.0.0.8:8787/','::1','[::1]:8787','https://[0:0:0:0:0:0:0:1]:443','::ffff:127.0.0.1','::ffff:7f12:2030'])assert.equal(literalIp(address),null,address);
  assert.deepEqual(literalIp('198.18.0.1'),{address:'198.18.0.1',group:0});
  assert.deepEqual(literalIp('::ffff:198.19.0.1'),{address:'::ffff:c613:1',group:2});
});
test('browser menu groups only disclosed candidate origins without inventing NIC or program names',()=>{
  assert.deepEqual(groupIpSources([
    'candidate:1 1 udp 1 10.0.0.2 1234 typ host',
    'candidate:2 1 udp 1 fd00::2 1234 typ host',
    'candidate:3 1 udp 1 1.2.3.4 1234 typ srflx',
    'candidate:4 1 udp 1 1.2.3.4 1235 typ srflx',
    'http://10.0.0.2:8787','candidate:5 1 udp 1 127.0.0.1 1234 typ host',
  ]),[
    {label:'浏览器本机',groups:[{label:'IPv4 内网',addresses:['10.0.0.2']},{label:'IPv6 内网',addresses:['fd00::2']}]},
    {label:'公网映射',groups:[{label:'IPv4 公网',addresses:['1.2.3.4']}]},
    {label:'已发布地址',groups:[{label:'IPv4 内网',addresses:['10.0.0.2']}]},
  ]);
});
test('URLs lose ports and brackets while scoped IPv6 and private mapped IPv4 remain usable',()=>{
  assert.deepEqual(literalIp('https://192.168.2.7:8787/peer'),{address:'192.168.2.7',group:0});
  assert.deepEqual(literalIp('https://[2001:0db8::1]:8787/peer'),{address:'2001:db8::1',group:3});
  assert.deepEqual(literalIp('[fe80::abcd%25wlan0]:8787'),{address:'fe80::abcd%wlan0',group:2});
  assert.deepEqual(literalIp('::ffff:192.168.1.2'),{address:'::ffff:c0a8:102',group:2});
});
test('ICE discovery accepts only real local or reflected IPs, not mDNS or relay addresses',()=>{
  assert.deepEqual(groupIpAddresses([
    'candidate:1 1 udp 1 192.168.0.3 5000 typ host',
    'candidate:2 1 udp 1 1.2.3.4 5001 typ srflx raddr 192.168.0.3 rport 5000',
    'candidate:3 1 udp 1 hidden.local 5002 typ host',
    'candidate:4 1 udp 1 9.8.7.6 5003 typ relay',
    'not-an-address','0.0.0.0','224.0.0.1','::','ff02::1','256.1.1.1',
  ]),[{label:'IPv4 内网',addresses:['192.168.0.3']},{label:'IPv4 公网',addresses:['1.2.3.4']}]);
  assert.deepEqual(groupIpAddresses(['hidden.local']),[]);
});
test('browser gathering uses no external ICE services and closes its peer after gathering',async()=>{
  const original=Object.getOwnPropertyDescriptor(globalThis,'RTCPeerConnection');let closed=0,options:unknown;
  class Peer {
    onicecandidate:any;
    constructor(value:unknown){options=value;}
    createDataChannel(){}
    async createOffer(){return {type:'offer',sdp:''};}
    async setLocalDescription(){this.onicecandidate({candidate:{candidate:'candidate:1 1 udp 1 10.0.0.2 1234 typ host'}});this.onicecandidate({candidate:null});}
    close(){closed++;}
  }
  Object.defineProperty(globalThis,'RTCPeerConnection',{configurable:true,value:Peer});
  try {assert.deepEqual(await browserHostCandidates(new AbortController().signal),['candidate:1 1 udp 1 10.0.0.2 1234 typ host']);assert.deepEqual(options,{iceServers:[]});assert.equal(closed,1);}
  finally {if(original)Object.defineProperty(globalThis,'RTCPeerConnection',original);else delete (globalThis as any).RTCPeerConnection;}
});
test('closing the address menu aborts its host gathering without leaking an RTC peer',async()=>{
  const original=Object.getOwnPropertyDescriptor(globalThis,'RTCPeerConnection');let closed=0;
  class Peer {createDataChannel(){}createOffer(){return new Promise(()=>{});}close(){closed++;}}
  Object.defineProperty(globalThis,'RTCPeerConnection',{configurable:true,value:Peer});
  try {const request=new AbortController(),pending=browserHostCandidates(request.signal);request.abort();assert.deepEqual(await pending,[]);assert.equal(closed,1);}
  finally {if(original)Object.defineProperty(globalThis,'RTCPeerConnection',original);else delete (globalThis as any).RTCPeerConnection;}
});
