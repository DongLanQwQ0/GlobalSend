import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, readdir } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { once } from "node:events";
import { DatabaseSync } from "node:sqlite";
import WebSocket from "ws";
import { buildApp } from "../src/server.js";

const sdp = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";
const candidate = { candidate: "candidate:1 1 udp 1 2408:1234:5678:9abc::3 5432 typ host", sdpMid: "0", sdpMLineIndex: 0 };
async function eventually(predicate: () => boolean | Promise<boolean>) {
  for (let i = 0; i < 100; i++) { if (await predicate()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.fail("probe signaling did not converge");
}
async function fixture() {
  const root = fileURLToPath(new URL("../../artifacts/tmp/", import.meta.url)); await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, "globalsend-rtc-probes-")); let now = Date.now();
  const app = await buildApp({ dataDir: dir, diskReserve: 0, discoveryNow: () => now });
  await app.listen({ host: "127.0.0.1", port: 0 });
  const origin = `http://127.0.0.1:${(app.server.address() as any).port}`, sockets: WebSocket[] = [];
  async function call(method: string, path: string, body?: unknown, token?: string) {
    const response = await fetch(origin + "/api/v1" + path, { method, headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body !== undefined ? { "content-type": "application/json" } : {}),
    }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, body: await response.json() as any };
  }
  async function connect(token: string) {
    const ticket = (await call("POST", "/session/ws-ticket", {}, token)).body.ticket;
    const socket = new WebSocket(origin.replace("http:", "ws:") + "/api/v1/ws?ticket=" + ticket, { origin }), messages: any[] = [];
    socket.on("message", value => messages.push(JSON.parse(String(value)))); sockets.push(socket);
    await once(socket, "open"); await eventually(() => messages.some(value => value.type === "hello"));
    return { socket, messages, async close() { if (socket.readyState === WebSocket.CLOSED) return; const done = once(socket, "close"); socket.close(); await done; } };
  }
  async function enroll(name: string, platform = "web", groupKey = "probe-group-password") {
    const response = await call("POST", "/devices/enroll", { name, platform, groupKey }); assert.equal(response.status, 201);
    const value = { id: response.body.device.deviceId as string, token: response.body.deviceToken as string, ws: await connect(response.body.deviceToken) };
    assert.equal((await call("POST", "/devices/me/rtc", { scopes: ["lan", "public"] }, value.token)).status, 200);
    return value;
  }
  async function foreground(d: { token: string }, value = true) { return call("POST", "/devices/me/rtc-probes/presence", { foreground: value }, d.token); }
  async function pair() { const devices = [await enroll("first"), await enroll("second")].sort((a, b) => a.id < b.id ? -1 : 1); for (const d of devices) await foreground(d); return devices; }
  function counts() {
    const db = new DatabaseSync(join(dir, "globalsend.sqlite"), { readOnly: true });
    try { return Object.fromEntries(["events", "transfers", "files", "peers"].map(table => [table, (db.prepare(`SELECT COUNT(*) n FROM ${table}`).get() as any).n])); }
    finally { db.close(); }
  }
  return { dir, call, enroll, connect, foreground, pair, counts, advance(ms: number) { now += ms; }, async close() { await app.close(); await rm(dir, { recursive: true, force: true }); } };
}

test("dedicated RTC probe negotiates between foreground peers without transfer, history or relay side effects", async () => {
  const f = await fixture();
  try {
    const [a, b] = await f.pair(), outsider = await f.enroll("same-group observer"); await f.foreground(outsider);
    const info = (await f.call("GET", "/info")).body; assert.equal(info.features.rtcProbes, true);
    const before = f.counts();
    const snapshot = (await f.call("GET", "/devices/me/rtc-probes", undefined, a.token)).body;
    assert.equal(snapshot.presence.foreground, true); assert.deepEqual(snapshot.peers.find((v: any) => v.deviceId === b.id).scopes, ["lan", "public"]);
    await new Promise(resolve => setTimeout(resolve, 20)); outsider.ws.messages.length = 0;
    const created = await f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId: "probe", scope: "lan" }, a.token);
    assert.equal(created.status, 200); assert.equal(created.body.probe.initiatorDeviceId, a.id); assert.equal(created.body.probe.responderDeviceId, b.id);
    assert.equal(created.body.probe.offer, null);
    const path = "/rtc-probes/probe";
    assert.equal((await f.call("POST", path + "/description", { type: "offer", sdp }, a.token)).status, 200);
    assert.equal((await f.call("POST", path + "/description", { type: "answer", sdp }, b.token)).status, 200);
    for (const d of [a, b]) assert.equal((await f.call("POST", path + "/candidate", candidate, d.token)).status, 200);
    assert.equal((await f.call("POST", path + "/candidate", candidate, a.token)).body.probe.candidates.initiator.length, 1);
    const view = (await f.call("GET", path, undefined, b.token)).body.probe;
    assert.deepEqual(view.candidates.initiator, [candidate]); assert.deepEqual(view.candidates.responder, [candidate]);
    const completed = await f.call("POST", path + "/complete", { elapsedMs: 12.5 }, a.token);
    assert.equal(completed.status, 200); assert.equal(completed.body.result.success, true); assert.equal(completed.body.result.elapsedMs, 12.5);
    assert.equal((await f.call("GET", path, undefined, b.token)).status, 410);
    assert.equal((await f.call("GET", "/devices/me/rtc-probes", undefined, b.token)).body.results[0].attemptId, "probe");
    await eventually(() => b.ws.messages.some(v => v.type === "rtc.probes.changed"));
    assert.equal(outsider.ws.messages.some(v => v.type === "rtc.probes.changed"), false, "probe signaling notifies only the participants");
    assert.deepEqual(f.counts(), before); assert.deepEqual(await readdir(join(f.dir, "relay")), []);
  } finally { await f.close(); }
});

test("probe admission follows group, foreground, Web participation, unique initiator and single-session contract", async () => {
  const f = await fixture();
  try {
    const [a, b] = await f.pair(), c = await f.enroll("same-group third"), cross = await f.enroll("cross", "web", "other-probe-password");
    assert.equal((await f.call("POST", `/devices/${cross.id}/rtc-probes`, { attemptId: "cross", scope: "lan" }, a.token)).status, 403);
    assert.equal((await f.call("POST", `/devices/${a.id}/rtc-probes`, { attemptId: "wrong-init", scope: "lan" }, b.token)).body.error.code, "PROBE_INITIATOR");
    await f.foreground(b, false);
    assert.equal((await f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId: "background", scope: "lan" }, a.token)).body.error.code, "PROBE_BACKGROUND");
    await f.foreground(b);
    await f.call("POST", "/devices/me/rtc", { scopes: ["lan"] }, b.token);
    assert.equal((await f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId: "scope", scope: "public" }, a.token)).body.error.code, "RTC_UNAVAILABLE");
    const native = [await f.enroll("Windows", "windows"), await f.enroll("Android", "android")].sort((x, y) => x.id < y.id ? -1 : 1);
    for (const d of native) await f.foreground(d);
    assert.equal((await f.call("POST", `/devices/${native[1].id}/rtc-probes`, { attemptId: "native", scope: "lan" }, native[0].token)).body.error.code, "PROBE_UNAVAILABLE");
    const create = () => f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId: "bound", scope: "lan" }, a.token);
    assert.equal((await create()).status, 200); assert.equal((await create()).status, 200, "same create retries reuse the session");
    assert.equal((await f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId: "second", scope: "lan" }, a.token)).body.error.code, "PROBE_BUSY");
    const path = "/rtc-probes/bound";
    assert.equal((await f.call("GET", path, undefined, c.token)).status, 403);
    assert.equal((await f.call("POST", path + "/description", { type: "offer", sdp }, b.token)).status, 403);
    assert.equal((await f.call("POST", path + "/description", { type: "answer", sdp }, b.token)).status, 409);
    assert.equal((await f.call("POST", path + "/description", { type: "offer", sdp: sdp + "m=audio 9 RTP/AVP 0\r\n" }, a.token)).status, 400);
    assert.equal((await f.call("POST", path + "/candidate", { ...candidate, candidate: candidate.candidate.replace("typ host", "typ relay") }, b.token)).status, 400);
    assert.equal((await f.call("POST", path + "/complete", { elapsedMs: 1 }, b.token)).status, 403);
    const failed = await f.call("POST", path + "/fail", { error: "UNREACHABLE" }, b.token);
    assert.equal(failed.body.result.success, false); assert.equal(failed.body.result.elapsedMs, null); assert.equal(failed.body.result.error, "UNREACHABLE");
    assert.equal((await f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId: "next", scope: "lan" }, a.token)).status, 200, "failure releases the slot immediately");
    assert.equal((await f.call("DELETE", "/rtc-probes/next", undefined, b.token)).status, 200);
    assert.equal((await f.call("GET", "/devices/me/rtc-probes", undefined, a.token)).body.results.length, 1, "explicit cancel does not fabricate another result");
  } finally { await f.close(); }
});

test("probe timeout, recent-result TTL and foreground lease perform actual transient cleanup", async () => {
  const f = await fixture();
  try {
    const [a, b] = await f.pair();
    const create = (attemptId: string) => f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId, scope: "public" }, a.token);
    await create("timeout"); f.advance(12000);
    let snapshot = (await f.call("GET", "/devices/me/rtc-probes", undefined, a.token)).body;
    assert.deepEqual(snapshot.probes, []); assert.equal(snapshot.results[0].error, "PROBE_TIMEOUT");
    assert.equal(Date.parse(snapshot.results[0].expiresAt) - Date.parse(snapshot.results[0].checkedAt), 120000);
    for (let i = 0; i < 6; i++) { f.advance(20000); await f.foreground(a); await f.foreground(b); }
    snapshot = (await f.call("GET", "/devices/me/rtc-probes", undefined, b.token)).body; assert.deepEqual(snapshot.results, []);
    await create("lease"); await f.call("POST", "/rtc-probes/lease/fail", { error: "UNREACHABLE" }, a.token);
    await create("active"); f.advance(40000);
    snapshot = (await f.call("GET", "/devices/me/rtc-probes", undefined, a.token)).body;
    assert.deepEqual(snapshot.presence, { foreground: false, expiresAt: null }); assert.deepEqual(snapshot.peers, []); assert.deepEqual(snapshot.probes, []); assert.deepEqual(snapshot.results, []);
    await f.foreground(a); await f.foreground(b); assert.equal((await create("fresh")).status, 200);
    await f.foreground(b, false);
    assert.equal((await f.call("GET", "/rtc-probes/fresh", undefined, a.token)).status, 410);
    assert.deepEqual((await f.call("GET", "/devices/me/rtc-probes", undefined, a.token)).body.results, []);
  } finally { await f.close(); }
});

test("last WebSocket removes probe addresses and results while additional sockets keep the active device", async () => {
  const f = await fixture();
  try {
    const [a, b] = await f.pair(), second = await f.connect(a.token);
    const create = (attemptId: string) => f.call("POST", `/devices/${b.id}/rtc-probes`, { attemptId, scope: "lan" }, a.token);
    await create("result"); await f.call("POST", "/rtc-probes/result/fail", { error: "UNREACHABLE" }, b.token);
    await create("active"); await f.call("POST", "/rtc-probes/active/candidate", candidate, a.token);
    await a.ws.close(); assert.equal((await f.call("GET", "/rtc-probes/active", undefined, b.token)).status, 200);
    await second.close();
    await eventually(() => b.ws.messages.some(v => v.type === "presence" && v.deviceId === a.id && !v.online));
    const snapshot = (await f.call("GET", "/devices/me/rtc-probes", undefined, b.token)).body;
    assert.deepEqual(snapshot.probes, []); assert.deepEqual(snapshot.results, []); assert.deepEqual(snapshot.peers, []);
    await f.connect(a.token); await f.foreground(a);
    assert.deepEqual((await f.call("GET", "/devices/me/rtc-probes", undefined, a.token)).body.probes, []);
    assert.equal((await create("after-reconnect")).status, 409, "reconnect requires fresh RTC capability announcement");
    await f.call("POST", "/devices/me/rtc", { scopes: ["lan"] }, a.token);
    assert.equal((await create("after-reconnect")).status, 200);
  } finally { await f.close(); }
});
