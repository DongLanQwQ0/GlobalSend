import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, X509Certificate } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { once } from "node:events";
import WebSocket from "ws";
import { buildApp, type Options } from "../src/server.js";
import { RtcRegistry } from "../src/rtc.js";

const digest = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
const password = "1234567890";
const data = Buffer.from("123456");
const sdp = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";
const candidate = { candidate: "candidate:1 1 udp 1 2408:1234:5678:9abc::2 5432 typ host", sdpMid: "0", sdpMLineIndex: 0 };
async function fixture(options: Options = {}) {
  const root = fileURLToPath(new URL("../../artifacts/tmp/", import.meta.url));
  await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, "globalsend-discovery-"));
  let app: Awaited<ReturnType<typeof buildApp>>, origin = "";
  const sockets: WebSocket[] = [];
  async function start() {
    app = await buildApp({ dataDir: dir, diskReserve: 0, ...options });
    await app.listen({ host: "127.0.0.1", port: 0 });
    origin = `http://127.0.0.1:${(app.server.address() as any).port}`;
  }
  await start();
  async function call(method: string, path: string, body?: any, token?: string) {
    const response = await fetch(origin + "/api/v1" + path, { method, headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "content-type": Buffer.isBuffer(body) ? "application/octet-stream" : "application/json" } : {}),
    }, ...(body !== undefined ? { body: Buffer.isBuffer(body) ? new Uint8Array(body) : JSON.stringify(body) } : {}) });
    return { status: response.status, body: response.headers.get("content-type")?.includes("json") ? await response.json() as any : Buffer.from(await response.arrayBuffer()) };
  }
  async function enroll(name: string, groupKey = password) {
    const r = await call("POST", "/devices/enroll", { name, platform: "web", groupKey });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    return { token: r.body.deviceToken as string, id: r.body.device.deviceId as string, groupId: r.body.groupId as string, createdGroup: r.body.createdGroup as boolean };
  }
  async function connect(token: string) {
    const { body } = await call("POST", "/session/ws-ticket", {}, token);
    const socket = new WebSocket(origin.replace("http:", "ws:") + "/api/v1/ws?ticket=" + body.ticket, { origin });
    const messages: any[] = [];
    socket.on("message", value => messages.push(JSON.parse(String(value))));
    sockets.push(socket); await once(socket, "open");
    await eventually(() => messages.some(value => value.type === "hello"));
    return { socket, messages, async close() {
      if (socket.readyState === WebSocket.CLOSED) return;
      const closed = once(socket, "close"); socket.close(); await closed;
    } };
  }
  return { dir, call, enroll, connect, async restart(migrate?: () => void) {
    await app.close(); sockets.length = 0; migrate?.(); await start();
  }, async close() {
    await app.close(); await rm(dir, { recursive: true, force: true });
  } };
}
async function eventually(predicate: () => boolean | Promise<boolean>) {
  for (let i = 0; i < 100; i++) { if (await predicate()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("discovery state did not converge");
}

test("explicit RTC refresh broadcasts within the group while unchanged heartbeat stays quiet", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("sender"), b = await f.enroll("peer");
    const outsider = await f.enroll("outside", "other-refresh-group");
    const [aw, bw, ow] = await Promise.all([f.connect(a.token), f.connect(b.token), f.connect(outsider.token)]);
    const changes = (messages: any[]) => messages.filter(value => value.type === "devices.changed").length;
    const barrier = async () => Promise.all([aw, bw, ow].map(async link => {
      const pong = once(link.socket, "pong"); link.socket.ping("refresh-barrier"); await pong;
    }));
    assert.equal((await f.call("GET", "/info")).body.features.discoveryRefresh, true);
    assert.equal((await f.call("POST", "/devices/me/rtc", { scopes: ["lan", "public"] }, a.token)).status, 200);
    await barrier();
    const baseline = [changes(aw.messages), changes(bw.messages), changes(ow.messages)];
    await f.call("POST", "/devices/me/rtc", { scopes: ["lan", "public"] }, a.token);
    await barrier();
    assert.deepEqual([changes(aw.messages), changes(bw.messages), changes(ow.messages)], baseline);
    await f.call("POST", "/devices/me/rtc", { scopes: ["lan", "public"], refresh: true }, a.token);
    await barrier();
    assert.deepEqual([changes(aw.messages), changes(bw.messages), changes(ow.messages)],
      [baseline[0] + 1, baseline[1] + 1, baseline[2]]);
  } finally { await f.close(); }
});
async function peer(reissued = false) {
  const certificatePem = await readFile(new URL(reissued ? "./fixtures/peer-reissued-certificate.pem" : "./fixtures/peer-certificate.pem", import.meta.url), "utf8");
  return { candidates: ["https://192.168.50.3:53317", "https://[2408:1234:5678:9abc::3]:53317"], certificatePem, certificateSha256: digest(new X509Certificate(certificatePem).raw), push: true };
}
test("empty peer publication clears obsolete IPs and broadcasts the changed group", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("sender"), b = await f.enroll("peer");
    const aw = await f.connect(a.token), bw = await f.connect(b.token);
    const announcement = await peer();
    assert.equal((await f.call("POST", "/devices/me/peer", announcement, a.token)).status, 200);
    await eventually(() => bw.messages.some(message => message.type === "devices.changed"));
    const before = bw.messages.filter(message => message.type === "devices.changed").length;
    const removed = await f.call("POST", "/devices/me/peer", {...announcement, candidates: []}, a.token);
    assert.equal(removed.status, 200); assert.equal(removed.body.peer, null);
    await eventually(() => bw.messages.filter(message => message.type === "devices.changed").length > before);
    const devices = await f.call("GET", "/devices", undefined, b.token);
    assert.equal(devices.body.devices.find((device: any) => device.deviceId === a.id).peer, null);
  } finally { await f.close(); }
});
async function offer(f: Awaited<ReturnType<typeof fixture>>, a: {token: string}, b: {id: string; token: string}, transferId: string, files = ["f"]) {
  assert.equal((await f.call("POST", "/transfers", { transferId, targetDeviceId: b.id, files: files.map(fileId => ({ fileId, name: fileId, size: data.length, sha256: digest(data) })) }, a.token)).status, 201);
  await f.call("POST", `/transfers/${transferId}/accept`, { fileIds: files }, b.token);
  return `/transfers/${transferId}/files`;
}

test("ten-character group password is the only enrollment path; online discovery and old-token reconnect preserve history", async () => {
  const f = await fixture({ allowGroupCreation: false, maxGroups: 0, maxDevicesPerGroup: 0, bootstrapSecret: "retired-bootstrap-secret" });
  try {
    const info = (await f.call("GET", "/info")).body;
    assert.deepEqual(info.enrollment, { mode: "group-password", groupKey: true, legacyBootstrap: false, pairingCode: false, allowGroupCreation: true, minGroupKeyLength: 10 });
    assert.deepEqual(info.discovery, { onlineOnly: true, peerTtlSeconds: 1800 });
    assert.equal((await f.call("POST", "/devices/enroll", { name: "short", platform: "web", groupKey: "123456789" })).status, 400);
    assert.equal((await f.call("POST", "/devices/enroll", { name: "legacy", platform: "web", bootstrapSecret: "retired-bootstrap-secret" })).status, 410);
    const a = await f.enroll("A"), b = await f.enroll("B"), c = await f.enroll("C", "abcdefghij");
    assert.equal(a.createdGroup, true); assert.equal(b.createdGroup, false); assert.equal(a.groupId, b.groupId); assert.notEqual(a.groupId, c.groupId);
    assert.deepEqual((await f.call("GET", "/devices", undefined, a.token)).body.devices.map((d: any) => d.deviceId), [a.id]);
    assert.equal((await f.call("POST", "/devices/me/peer", await peer(), a.token)).body.error.code, "DEVICE_OFFLINE");
    assert.equal((await f.call("POST", "/devices/me/rtc", { scopes: ["lan"] }, a.token)).body.error.code, "DEVICE_OFFLINE");
    await Promise.all([f.connect(a.token), f.connect(b.token), f.connect(c.token)]);
    assert.deepEqual((await f.call("GET", "/devices", undefined, a.token)).body.devices.map((d: any) => d.deviceId).sort(), [a.id, b.id].sort());
    assert.equal((await f.call("POST", "/texts", { eventId: "cross", targetDeviceId: c.id, text: "no" }, a.token)).status, 403);
    assert.equal((await f.call("POST", "/pairing-codes", {}, a.token)).status, 410);
    assert.equal((await f.call("POST", "/devices/enroll", { name: "invite", platform: "web", pairingCode: "123456" })).status, 410);
    await f.call("POST", "/texts", { eventId: "history", targetDeviceId: b.id, text: "保留旧身份与历史" }, a.token);
    await f.restart(() => {
      // Simulate an already-enrolled v2 identity without creating a new token.
      const db = new DatabaseSync(join(f.dir, "globalsend.sqlite"));
      try { db.exec("DROP TABLE group_keys; DROP TABLE groups; PRAGMA user_version=2"); }
      finally { db.close(); }
    });
    const self = (await f.call("GET", "/devices", undefined, a.token)).body.devices;
    assert.equal(self.length, 1); assert.equal(self[0].deviceId, a.id); assert.equal(self[0].groupId, a.groupId); assert.equal(self[0].peer, null); assert.equal(self[0].rtc, null);
    assert.ok((await f.call("GET", "/events", undefined, a.token)).body.events.some((e: any) => e.eventId === "history"));
    await Promise.all([f.connect(a.token), f.connect(b.token)]);
    assert.equal((await f.call("GET", "/devices", undefined, b.token)).body.devices.length, 2);
  } finally { await f.close(); }
});

test("last socket removes IP and transient grants, multiple sockets preserve presence, and saved relay bytes remain", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("source"), b = await f.enroll("receiver");
    const a1 = await f.connect(a.token), a2 = await f.connect(a.token), bw = await f.connect(b.token);
    const announcement = await peer();
    await f.call("POST", "/devices/me/peer", announcement, a.token);
    for (const d of [a, b]) await f.call("POST", "/devices/me/rtc", { scopes: ["lan"] }, d.token);
    const reissued = await f.call("POST", "/devices/me/peer", await peer(true), a.token);
    assert.equal(reissued.status, 200, "an online token can refresh its current certificate without re-enrollment");
    const sql = new DatabaseSync(join(f.dir, "globalsend.sqlite"), { readOnly: true });
    assert.equal((sql.prepare("SELECT COUNT(*) n FROM peers").get() as any).n, 0, "new IPs never enter SQLite"); sql.close();
    const path = await offer(f, a, b, "presence", ["pull", "rtc", "saved"]);
    const grant = (await f.call("POST", `${path}/pull/direct-ticket`, {}, b.token)).body.ticket;
    await f.call("POST", `${path}/rtc/rtc`, { attemptId: "attempt", scope: "lan", offset: 0 }, b.token);
    await f.call("POST", `${path}/saved/relay`, {}, b.token);
    await f.call("PUT", `${path}/saved/chunks?offset=0`, data, a.token);
    await f.call("POST", `${path}/saved/complete`, {}, a.token);
    await a1.close();
    assert.equal((await f.call("GET", "/devices", undefined, b.token)).body.devices.find((d: any) => d.deviceId === a.id).peer.certificateSha256, reissued.body.peer.certificateSha256);
    assert.ok(!bw.messages.some(m => m.type === "presence" && m.deviceId === a.id && !m.online));
    await a2.close();
    await eventually(() => bw.messages.some(m => m.type === "presence" && m.deviceId === a.id && !m.online));
    assert.ok(bw.messages.some(m => m.type === "devices.changed"));
    assert.deepEqual((await f.call("GET", "/devices", undefined, b.token)).body.devices.map((d: any) => d.deviceId), [b.id]);
    assert.equal((await f.call("POST", `${path}/pull/direct-ticket`, {}, b.token)).body.error.code, "DEVICE_OFFLINE");
    assert.equal((await f.call("POST", "/direct-tickets/verify", { ticket: grant, transferId: "presence", fileId: "pull" }, a.token)).status, 401);
    assert.equal((await f.call("GET", `${path}/rtc/rtc/attempt`, undefined, b.token)).status, 410);
    const snapshot = (await f.call("GET", "/transfers/presence", undefined, b.token)).body.transfer;
    assert.equal(snapshot.files.find((v: any) => v.fileId === "pull").status, "accepted");
    assert.equal(snapshot.files.find((v: any) => v.fileId === "rtc").status, "accepted");
    assert.equal(snapshot.files.find((v: any) => v.fileId === "saved").status, "ready");
    const download = (await f.call("POST", `${path}/saved/download-ticket`, {}, b.token)).body;
    assert.deepEqual((await f.call("GET", download.downloadPath.slice("/api/v1".length))).body, data);
    await f.connect(a.token);
    let rediscovered = (await f.call("GET", "/devices", undefined, b.token)).body.devices.find((d: any) => d.deviceId === a.id);
    assert.equal(rediscovered.peer, null); assert.equal(rediscovered.rtc, null);
    await f.call("POST", "/devices/me/peer", announcement, a.token);
    rediscovered = (await f.call("GET", "/devices", undefined, b.token)).body.devices.find((d: any) => d.deviceId === a.id);
    assert.deepEqual(rediscovered.peer.candidates, announcement.candidates);
  } finally { await f.close(); }
});

test("recently offline same-group devices can receive queued texts and offers without retaining server IPs", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("source"), b = await f.enroll("receiver");
    await f.connect(a.token); const receiver = await f.connect(b.token);
    await f.call("POST", "/devices/me/peer", await peer(), b.token);
    await receiver.close();
    await eventually(async () => !(await f.call("GET", "/devices", undefined, a.token)).body.devices.some((device:any)=>device.deviceId===b.id));
    assert.equal((await f.call("POST", "/texts", {eventId:"grace-text",targetDeviceId:b.id,text:"离线后尝试"}, a.token)).status,201);
    for (const routePreference of ["auto", "lan", "public", "relay"]) {
      const result=await f.call("POST", "/transfers", {transferId:`grace-${routePreference}`,targetDeviceId:b.id,routePreference,files:[{fileId:"file",name:"queued.txt",size:data.length,sha256:digest(data)}]}, a.token);
      assert.equal(result.status,201,JSON.stringify(result.body));
      assert.equal(result.body.transfer.routePreference,routePreference);
      assert.equal(result.body.transfer.files[0].status,"offered");
    }
    await f.connect(b.token);
    const events=(await f.call("GET", "/events", undefined,b.token)).body.events;
    assert.ok(events.some((event:any)=>event.eventId==="grace-text"));
    const devices=(await f.call("GET", "/devices", undefined,a.token)).body.devices;
    const rediscovered=devices.find((device:any)=>device.deviceId===b.id);
    assert.equal(rediscovered.peer,null);assert.equal(rediscovered.rtc,null);
    const offers=(await f.call("GET", "/transfers", undefined,b.token)).body.transfers;
    assert.equal(offers.filter((offer:any)=>offer.transferId.startsWith("grace-")).length,4);
  } finally { await f.close(); }
});

test("published IPs and each RTC ICE upload expire at 30 minutes without deleting transfer metadata", async () => {
  let now = Date.now(); const start = now;
  const f = await fixture({ discoveryNow: () => now });
  try {
    const a = await f.enroll("source"), b = await f.enroll("receiver");
    await Promise.all([f.connect(a.token), f.connect(b.token)]);
    const published = await f.call("POST", "/devices/me/peer", await peer(), a.token);
    assert.equal(Date.parse(published.body.peer.expiresAt) - now, 1800000);
    for (const d of [a, b]) {
      const value = await f.call("POST", "/devices/me/rtc", { scopes: ["lan"] }, d.token);
      assert.equal(Date.parse(value.body.rtc.expiresAt) - now, 1800000);
    }
    const path = await offer(f, a, b, "ttl"), attempt = `${path}/f/rtc/one`;
    await f.call("POST", `${path}/f/rtc`, { attemptId: "one", scope: "lan", offset: 0 }, b.token);
    await f.call("POST", `${attempt}/description`, { type: "offer", sdp }, b.token);
    await f.call("POST", `${attempt}/description`, { type: "answer", sdp }, a.token);
    await f.call("POST", `${attempt}/candidate`, candidate, a.token);
    await f.call("POST", `${attempt}/candidate`, candidate, b.token);
    await f.call("POST", `${attempt}/started`, {}, b.token);
    now = start + 15 * 60000;
    await f.call("POST", `${attempt}/candidate`, candidate, b.token); // Same upload refreshes only this ICE entry.
    now = start + 29 * 60000;
    for (const d of [a, b]) await f.call("POST", "/devices/me/rtc", { scopes: ["lan"] }, d.token);
    assert.ok((await f.call("GET", "/devices", undefined, b.token)).body.devices.find((d: any) => d.deviceId === a.id).peer);
    now = start + 30 * 60000;
    assert.equal((await f.call("GET", "/devices", undefined, b.token)).body.devices.find((d: any) => d.deviceId === a.id).peer, null);
    const current = (await f.call("GET", attempt, undefined, b.token)).body.rtc;
    assert.equal(current.state, "streaming"); assert.equal(current.offer, null); assert.equal(current.answer, null);
    assert.deepEqual(current.candidates.source, []); assert.equal(current.candidates.target.length, 1);
    now = start + 45 * 60000;
    assert.deepEqual((await f.call("GET", attempt, undefined, b.token)).body.rtc.candidates.target, []);
    now = start + 60 * 60000;
    assert.equal((await f.call("GET", "/devices", undefined, b.token)).body.devices.find((d: any) => d.deviceId === a.id).rtc, null);
    assert.equal((await f.call("GET", attempt, undefined, b.token)).status, 410);
    assert.equal((await f.call("GET", "/transfers/ttl", undefined, a.token)).body.transfer.files[0].status, "accepted");
  } finally { await f.close(); }
});

test("RTC expiry removes stored address entries rather than just hiding serialized output", () => {
  let now = 1000; const rtc = new RtcRegistry(() => now);
  for (const d of ["a", "b"]) rtc.register(d, ["lan"]);
  const attempt = rtc.create({ transferId: "t", fileId: "f", attemptId: "one", sourceDeviceId: "a", targetDeviceId: "b", scope: "lan", offset: 0, transferExpires: 86400000 });
  rtc.describe(attempt, "b", "offer", sdp); rtc.describe(attempt, "a", "answer", sdp); rtc.candidate(attempt, "a", candidate); rtc.started(attempt, "b");
  now += 29 * 60000; for (const d of ["a", "b"]) rtc.register(d, ["lan"]);
  now += 60000; rtc.cleanup();
  assert.equal(attempt.state, "streaming"); assert.equal(attempt.candidates.source.length, 0); assert.equal(attempt.offer, null); assert.equal(attempt.answer, null);
});
