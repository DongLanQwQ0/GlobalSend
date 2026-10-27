import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, X509Certificate } from "node:crypto";
import { once } from "node:events";
import WebSocket from "ws";
import { buildApp } from "../src/server.js";
import { RtcRegistry } from "../src/rtc.js";

const hash = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
const sdp = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n";
const candidate = { candidate: "candidate:1 1 udp 1 192.168.1.2 3456 typ host", sdpMid: "0", sdpMLineIndex: 0 };

async function fixture(stunUrls: string[] = []) {
  const root = fileURLToPath(new URL("../../artifacts/tmp/", import.meta.url));
  await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, "globalsend-rtc-"));
  const app = await buildApp({ dataDir: dir, diskReserve: 0, stunUrls });
  await app.listen({ host: "127.0.0.1", port: 0 });
  const origin = `http://127.0.0.1:${(app.server.address() as any).port}`;
  const sockets: WebSocket[] = [];
  async function call(method: string, path: string, body?: unknown, token?: string) {
    const response = await fetch(`${origin}/api/v1${path}`, { method, headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    }, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, body: await response.json() as any };
  }
  async function enroll(name: string, groupKey = "test-rtc-shared-group-key") {
    const response = await call("POST", "/devices/enroll", { name, groupKey, platform: "web" });
    assert.equal(response.status, 201, JSON.stringify(response.body));
    await ws(response.body.deviceToken);
    return { token: response.body.deviceToken as string, id: response.body.device.deviceId as string };
  }
  async function ws(token: string) {
    const ticket = (await call("POST", "/session/ws-ticket", {}, token)).body.ticket;
    const socket = new WebSocket(`${origin.replace("http:", "ws:")}/api/v1/ws?ticket=${ticket}`, { origin });
    const messages: any[] = [];
    socket.on("message", value => messages.push(JSON.parse(String(value))));
    sockets.push(socket);
    await once(socket, "open");
    return messages;
  }
  return { app, dir, call, enroll, ws, async close() {
    for (const socket of sockets) {
      if (socket.readyState === WebSocket.CLOSED) continue;
      const closed = once(socket, "close"); socket.close(); await closed;
    }
    await app.close();
    // dir is the exact mkdtemp result inside this project's owned test root.
    await rm(dir, { recursive: true, force: true });
  } };
}

test("WebRTC endpoints bind consent, roles and route; signaling stays transient and participant-only", async () => {
  const f = await fixture(["stun:stun.example.test:3478"]);
  try {
    const a = await f.enroll("Windows"), b = await f.enroll("iPad"), c = await f.enroll("unrelated"), d = await f.enroll("other group", "another-rtc-group-key");
    const [am, bm, cm] = await Promise.all([f.ws(a.token), f.ws(b.token), f.ws(c.token)]);
    const info = (await f.call("GET", "/info")).body;
    assert.equal(info.features.rtcDataChannels, true);
    assert.deepEqual(info.rtc, { iceServers: [{ urls: ["stun:stun.example.test:3478"] }] });
    for (const device of [a, b]) assert.equal((await f.call("POST", "/devices/me/rtc", { scopes: ["lan", "public"] }, device.token)).status, 200);
    const devices = (await f.call("GET", "/devices", undefined, a.token)).body.devices;
    assert.deepEqual(devices.find((value: any) => value.deviceId === b.id).rtc.scopes, ["lan", "public"]);
    await f.call("POST", "/transfers", { transferId: "rtc-file", targetDeviceId: b.id, routePreference: "lan", files: [{ fileId: "f", name: "hello.txt", size: 6, sha256: hash("123456") }] }, a.token);
    const path = "/transfers/rtc-file/files/f", attempt = { attemptId: "first", scope: "lan", offset: 2 };
    assert.equal((await f.call("POST", `${path}/rtc`, attempt, b.token)).status, 409);
    await f.call("POST", "/transfers/rtc-file/accept", { fileIds: ["f"] }, b.token);
    assert.equal((await f.call("POST", `${path}/rtc`, attempt, a.token)).status, 403);
    assert.equal((await f.call("POST", `${path}/rtc`, { ...attempt, scope: "public" }, b.token)).body.error.code, "ROUTE_NOT_ALLOWED");
    assert.equal((await f.call("POST", `${path}/rtc`, { ...attempt, offset: 7 }, b.token)).body.error.code, "INVALID_OFFSET");
    const created = await f.call("POST", `${path}/rtc`, attempt, b.token);
    assert.equal(created.status, 200);
    assert.equal(created.body.rtc.offset, 2);
    assert.equal(created.body.rtc.sourceDeviceId, a.id);
    const current = `${path}/rtc/first`;
    assert.equal((await f.call("POST", `${path}/rtc`, attempt, b.token)).body.rtc.expiresAt, created.body.rtc.expiresAt);
    assert.equal((await f.call("POST", `${path}/rtc`, { ...attempt, offset: 1 }, b.token)).status, 409);
    assert.equal((await f.call("GET", current, undefined, c.token)).status, 404);
    assert.equal((await f.call("GET", current, undefined, d.token)).status, 404);
    assert.equal((await f.call("POST", `${current}/description`, { type: "offer", sdp }, a.token)).status, 403);
    assert.equal((await f.call("POST", `${current}/description`, { type: "answer", sdp }, a.token)).status, 409);
    assert.equal((await f.call("POST", `${current}/description`, { type: "offer", sdp: sdp + "m=audio 9 RTP/AVP 0\r\n" }, b.token)).status, 400);
    const historyBefore = (await f.call("GET", "/events", undefined, b.token)).body;
    assert.equal((await f.call("POST", `${current}/description`, { type: "offer", sdp }, b.token)).status, 200);
    assert.equal((await f.call("POST", `${current}/description`, { type: "answer", sdp }, a.token)).status, 200);
    await f.call("POST", `${current}/candidate`, candidate, a.token);
    await f.call("POST", `${current}/candidate`, candidate, a.token);
    await f.call("POST", `${current}/candidate`, { ...candidate, candidate: candidate.candidate.replace("1.2", "1.3") }, b.token);
    assert.equal((await f.call("POST", `${current}/started`, {}, a.token)).status, 403);
    const started = await f.call("POST", `${current}/started`, {}, b.token);
    assert.equal(started.body.rtc.state, "streaming");
    assert.equal(started.body.rtc.candidates.source.length, 1);
    assert.equal(started.body.rtc.candidates.target.length, 1);
    assert.equal((await f.call("POST", `${current}/description`, { type: "answer", sdp }, a.token)).status, 200, "lost answer response may be replayed after started");
    assert.deepEqual((await f.call("GET", "/events", undefined, b.token)).body, historyBefore, "SDP and ICE must not create durable events");
    const snapshot = (await f.call("GET", "/transfers/rtc-file", undefined, a.token)).body.transfer.files[0];
    assert.equal(snapshot.rtc.state, "streaming");
    assert.equal(snapshot.transport, "direct");
    assert.equal(snapshot.offset, 0);
    assert.equal(JSON.stringify(snapshot).includes("m=application"), false);
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.ok(am.some(value => value.type === "rtc.changed" && value.attemptId === "first"));
    assert.ok(bm.some(value => value.type === "rtc.changed" && value.attemptId === "first"));
    assert.equal(cm.some(value => value.type === "rtc.changed"), false);
    assert.equal((await f.call("POST", `${current}/stop`, {}, a.token)).status, 403);
    assert.equal((await f.call("POST", `${path}/received`, { transport: "direct" }, b.token)).status, 200);
    assert.equal((await f.call("GET", current, undefined, a.token)).status, 410);
    const received = (await f.call("GET", "/transfers/rtc-file", undefined, a.token)).body.transfer.files[0];
    assert.equal(received.status, "received");
    assert.equal(received.offset, 0);
    assert.equal(received.rtc, undefined);
  } finally { await f.close(); }
});

test("WebRTC shares one direct grant, preserves old peer endpoints, and clears on stop, relay, cancel or revoke", async () => {
  const f = await fixture();
  try {
    assert.deepEqual((await f.call("GET", "/info")).body.rtc.iceServers, []);
    const a = await f.enroll("source"), b = await f.enroll("receiver");
    const certificatePem = await readFile(new URL("./fixtures/peer-certificate.pem", import.meta.url), "utf8");
    const peer = { candidates: ["https://127.0.0.1:9999"], certificatePem, certificateSha256: hash(new X509Certificate(certificatePem).raw), push: true };
    for (const device of [a, b]) {
      await f.call("POST", "/devices/me/peer", peer, device.token);
      await f.call("POST", "/devices/me/rtc", { scopes: ["lan", "public"] }, device.token);
    }
    const setup = async (transferId: string, routePreference = "auto") => {
      await f.call("POST", "/transfers", { transferId, targetDeviceId: b.id, routePreference, files: [{ fileId: "f", name: "file", size: 6, sha256: hash("123456") }] }, a.token);
      await f.call("POST", `/transfers/${transferId}/accept`, { fileIds: ["f"] }, b.token);
      return `/transfers/${transferId}/files/f`;
    };
    const path = await setup("exclusive"), attempt = { attemptId: "one", scope: "lan", offset: 1 };
    const oldPull = (await f.call("POST", `${path}/direct-ticket`, {}, b.token)).body.ticket;
    assert.equal((await f.call("POST", `${path}/rtc`, attempt, b.token)).status, 200);
    assert.equal((await f.call("POST", "/direct-tickets/verify", { ticket: oldPull, transferId: "exclusive", fileId: "f" }, a.token)).status, 401);
    const rtcPath = `${path}/rtc/one`;
    assert.equal((await f.call("POST", `${path}/relay`, {}, a.token)).status, 409, "sender cannot force relay");
    const pull = (await f.call("POST", `${path}/direct-ticket`, {}, b.token)).body.ticket;
    assert.equal((await f.call("GET", rtcPath, undefined, a.token)).status, 410);
    assert.equal((await f.call("POST", "/direct-tickets/verify", { ticket: pull, transferId: "exclusive", fileId: "f" }, a.token)).status, 200, "old pull contract remains usable");
    await f.call("POST", `${path}/direct-push`, { attemptId: "push", scope: "lan", offset: 1, cellular: false }, b.token);
    const push = (await f.call("POST", `${path}/push-ticket`, { attemptId: "push" }, a.token)).body.ticket;
    await f.call("POST", `${path}/rtc`, attempt, b.token);
    assert.equal((await f.call("POST", "/push-tickets/verify", { ticket: push, transferId: "exclusive", fileId: "f", attemptId: "push" }, b.token)).status, 401);
    assert.equal((await f.call("GET", "/transfers/exclusive", undefined, a.token)).body.transfer.files[0].directPush, undefined);
    await f.call("POST", `${path}/rtc`, { ...attempt, attemptId: "two" }, b.token);
    await f.call("POST", `${rtcPath}/stop`, {}, b.token);
    assert.equal((await f.call("GET", `${path}/rtc/two`, undefined, a.token)).status, 200, "old stop must preserve a replacement");
    await f.call("POST", `${path}/rtc/two/fail`, { error: "connection unavailable" }, a.token);
    assert.equal((await f.call("GET", `${path}/rtc/two`, undefined, b.token)).body.rtc.state, "failed");
    await f.call("POST", `${path}/rtc/two/stop`, {}, b.token);
    assert.equal((await f.call("GET", `${path}/rtc/two`, undefined, a.token)).status, 410);
    await f.call("POST", `${path}/rtc`, { ...attempt, attemptId: "three" }, b.token);
    assert.equal((await f.call("POST", `${path}/relay`, {}, b.token)).status, 200);
    assert.equal((await f.call("GET", `${path}/rtc/three`, undefined, a.token)).status, 410);
    assert.equal((await f.call("POST", `${path}/rtc`, { ...attempt, attemptId: "four" }, b.token)).status, 409);
    const canceled = await setup("canceled");
    await f.call("POST", `${canceled}/rtc`, attempt, b.token);
    await f.call("POST", `${canceled}/cancel`, {}, a.token);
    assert.equal((await f.call("GET", `${canceled}/rtc/one`, undefined, b.token)).status, 410);
    const manual = await setup("manual", "public");
    assert.equal((await f.call("POST", `${manual}/rtc`, attempt, b.token)).body.error.code, "ROUTE_NOT_ALLOWED");
    assert.equal((await f.call("POST", `${manual}/rtc`, { ...attempt, scope: "public" }, b.token)).status, 200);
    assert.equal((await f.call("POST", `${manual}/relay`, {}, b.token)).body.error.code, "ROUTE_NOT_ALLOWED");
    const unavailable = await setup("unavailable");
    await f.call("POST", "/devices/me/rtc", { scopes: [] }, a.token);
    assert.equal((await f.call("POST", `${unavailable}/rtc`, attempt, b.token)).body.error.code, "RTC_UNAVAILABLE");
    await f.call("DELETE", `/devices/${b.id}`, undefined, a.token);
    assert.equal((await f.call("GET", `${manual}/rtc/one`, undefined, a.token)).status, 403);
    assert.equal((await f.call("GET", "/devices", undefined, a.token)).body.devices.find((value: any) => value.deviceId === b.id), undefined);
  } finally { await f.close(); }
});

test("WebRTC negotiation expires after one minute; capability expiry ends its address-bearing session", () => {
  let now = 1000;
  const rtc = new RtcRegistry(() => now);
  for (const device of ["a", "b"]) rtc.register(device, ["lan"]);
  const create = (attemptId: string) => rtc.create({ transferId: "t", fileId: "f", attemptId, sourceDeviceId: "a", targetDeviceId: "b", scope: "lan", offset: 0, transferExpires: 3600000 });
  create("first"); now += 60001; rtc.cleanup();
  assert.equal(rtc.current("t", "f"), null);
  assert.throws(() => rtc.require("t", "f", "first", "a"), /ended/);
  const second = create("second");
  rtc.describe(second, "b", "offer", sdp); rtc.describe(second, "a", "answer", sdp); rtc.started(second, "b");
  now = 400000; rtc.cleanup();
  assert.ok(rtc.capability("a"));
  assert.equal(rtc.current("t", "f")?.state, "streaming");
  now = 1801001; rtc.cleanup();
  assert.equal(rtc.capability("a"), null);
  assert.equal(rtc.current("t", "f"), null);
});
