import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { once } from "node:events";
import { createHash, X509Certificate } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import WebSocket from "ws";
import { buildApp } from "../src/server.js";

const hash = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
async function eventually(check: () => boolean) {
  for (let i = 0; i < 150; i++) {
    if (check()) return;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.fail("HTTPS probe message was not delivered");
}
async function fixture() {
  const root = fileURLToPath(new URL("../../artifacts/tmp/", import.meta.url));
  await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, "https-preflight-"));
  const app = await buildApp({ dataDir: dir, diskReserve: 0 });
  await app.listen({ host: "127.0.0.1", port: 0 });
  const origin = `http://127.0.0.1:${(app.server.address() as any).port}`;
  const sockets: WebSocket[] = [];
  const certificatePem = await readFile(new URL("./fixtures/peer-certificate.pem", import.meta.url), "utf8");
  const peer = { candidates: ["https://192.168.50.3:53317"], certificatePem,
    certificateSha256: hash(new X509Certificate(certificatePem).raw), push: true, httpsProbe: true };
  async function call(method: string, path: string, body?: unknown, token?: string, signal?: AbortSignal) {
    const response = await fetch(origin + "/api/v1" + path, { method, signal, headers: { connection: "close",
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body === undefined ? {} : { "content-type": "application/json" }),
    }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() as any };
  }
  async function enroll(name: string, groupKey = "https-probe-test-password", capable = true) {
    const value = await call("POST", "/devices/enroll", { name, platform: "android", groupKey });
    assert.equal(value.status, 201);
    const token = value.body.deviceToken, id = value.body.device.deviceId;
    const ticket = (await call("POST", "/session/ws-ticket", {}, token)).body.ticket;
    const ws = new WebSocket(origin.replace("http:", "ws:") + "/api/v1/ws?ticket=" + ticket, { origin });
    const messages: any[] = []; ws.on("message", data => messages.push(JSON.parse(String(data))));
    sockets.push(ws); await once(ws, "open"); await eventually(() => messages.some(m => m.type === "hello"));
    assert.equal((await call("POST", "/devices/me/peer", { ...peer, httpsProbe: capable }, token)).status, 200);
    return { id, token, ws, messages };
  }
  function counts() {
    const db = new DatabaseSync(join(dir, "globalsend.sqlite"), { readOnly: true });
    try { return Object.fromEntries(["events", "transfers", "files"].map(table =>
      [table, db.prepare(`SELECT * FROM ${table}`).all()])); }
    finally { db.close(); }
  }
  return { app, call, enroll, counts, peer, async close() {
    await Promise.all(sockets.map(async ws => { if (ws.readyState === WebSocket.CLOSED) return; const done = once(ws, "close"); if (ws.readyState === WebSocket.OPEN) ws.close(); await done; }));
    await app.close(); await rm(dir, { force: true, recursive: true });
  } };
}

test("reverse HTTPS preflight returns a real peer response without consuming an existing file grant", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("receiver"), b = await f.enroll("sender"), observer = await f.enroll("observer");
    const info = (await f.call("GET", "/info")).body; assert.equal(info.features.httpsPeerProbes, true);
    assert.equal((await f.call("POST", "/transfers", { transferId: "active", targetDeviceId: a.id,
      routePreference: "auto", files: [{ fileId: "file", name: "note.txt", size: 4, sha256: hash("data") }] }, b.token)).status, 201);
    await f.call("POST", "/transfers/active/accept", { fileIds: ["file"] }, a.token);
    const grant = (await f.call("POST", "/transfers/active/files/file/direct-ticket", {}, a.token)).body;
    const before = f.counts();
    const pending = f.call("POST", `/devices/${b.id}/https-probes`, { scope: "lan", timeoutMs: 1000 }, a.token);
    await eventually(() => b.messages.some(m => m.type === "https.probe"));
    const message = b.messages.find(m => m.type === "https.probe");
    assert.equal(message.requesterDeviceId, a.id); assert.equal(message.scope, "lan");
    assert.deepEqual(message.peer, { candidates: f.peer.candidates, certificateSha256: f.peer.certificateSha256 });
    const result = { reachable: true, tested: true, elapsedMs: 12, address: f.peer.candidates[0],
      sourceEndpoint: "192.168.50.4:50001", targetEndpoint: "192.168.50.3:53317", sourceName: "Wi-Fi", cellular: false };
    assert.equal((await f.call("POST", `/https-probes/${message.probeId}/result`, result, b.token)).status, 200);
    assert.deepEqual((await pending).body.result, result);
    assert.deepEqual(f.counts(), before, "probe never mutates a file, event, transfer, or direct ticket");
    assert.ok(!observer.messages.some(m => m.type === "https.probe"));
    const verify = { ticket: grant.ticket, transferId: "active", fileId: "file" };
    assert.equal((await f.call("POST", "/direct-tickets/verify", verify, b.token)).status, 200);
    assert.equal((await f.call("POST", `/https-probes/${message.probeId}/result`, result, b.token)).status, 410);
  } finally { await f.close(); }
});

test("LAN and public reverse checks run together and complete independently", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("receiver"), b = await f.enroll("sender");
    const lan = f.call("POST", `/devices/${b.id}/https-probes`, { scope: "lan" }, a.token);
    const pub = f.call("POST", `/devices/${b.id}/https-probes`, { scope: "public" }, a.token);
    await eventually(() => b.messages.filter(m => m.type === "https.probe").length === 2);
    const messages = b.messages.filter(m => m.type === "https.probe");
    const result = { reachable: true, tested: true, elapsedMs: 8, address: f.peer.candidates[0], cellular: true };
    await f.call("POST", `/https-probes/${messages.find(m => m.scope === "public").probeId}/result`, result, b.token);
    assert.deepEqual((await pub).body.result, result);
    const noPath = { reachable: false, tested: true, elapsedMs: 18, error: "没有可达的内网地址对" };
    await f.call("POST", `/https-probes/${messages.find(m => m.scope === "lan").probeId}/result`, noPath, b.token);
    assert.deepEqual((await lan).body.result, noPath);
  } finally { await f.close(); }
});

test("deadline and caller cancellation stop the remote probe, and late results cannot resurrect it", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("receiver"), b = await f.enroll("sender");
    const pending = f.call("POST", `/devices/${b.id}/https-probes`, { scope: "public", timeoutMs: 45 }, a.token);
    await eventually(() => b.messages.some(m => m.type === "https.probe"));
    const message = b.messages.find(m => m.type === "https.probe");
    const timeout = (await pending).body.result; assert.equal(timeout.tested, false); assert.equal(timeout.reachable, false);
    await eventually(() => b.messages.some(m => m.type === "https.probe.cancel" && m.probeId === message.probeId));
    assert.equal((await f.call("POST", `/https-probes/${message.probeId}/result`, { tested: true, reachable: false, elapsedMs: 60 }, b.token)).status, 410);
    const controller = new AbortController();
    const canceled = f.call("POST", `/devices/${b.id}/https-probes`, { scope: "lan" }, a.token, controller.signal);
    const rejected = assert.rejects(canceled, /abort/i);
    await eventually(() => b.messages.filter(m => m.type === "https.probe").length === 2);
    const second = b.messages.filter(m => m.type === "https.probe")[1]; controller.abort(); await rejected;
    await eventually(() => b.messages.some(m => m.type === "https.probe.cancel" && m.probeId === second.probeId));
  } finally { await f.close(); }
});

test("offline, revoked, or republished receiving endpoints cannot produce a stale success", async () => {
  const f = await fixture();
  try {
    for (const reason of ["offline", "revoke", "changed"]) {
      const a = await f.enroll("receiver-" + reason), b = await f.enroll("sender-" + reason);
      const pending = f.call("POST", `/devices/${b.id}/https-probes`, { scope: "lan" }, a.token);
      await eventually(() => b.messages.some(m => m.type === "https.probe"));
      const message = b.messages.find(m => m.type === "https.probe");
      if (reason === "offline") { const done = once(b.ws, "close"); b.ws.close(); await done; }
      if (reason === "revoke") await f.call("DELETE", `/devices/${b.id}`, undefined, a.token);
      if (reason === "changed") {
        await f.call("POST", "/devices/me/peer", { ...f.peer, candidates: ["https://192.168.50.8:53317"] }, a.token);
        assert.equal((await f.call("POST", `/https-probes/${message.probeId}/result`, { tested: true, reachable: true,
          elapsedMs: 8, address: f.peer.candidates[0] }, b.token)).status, 410);
      }
      const result = (await pending).body.result;
      assert.equal(result.tested, false, reason); assert.equal(result.reachable, false, reason);
    }
  } finally { await f.close(); }
});

test("preflight keeps group/identity boundaries and old peers retain their existing publication contract", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("receiver"), b = await f.enroll("sender"), same = await f.enroll("same-group"),
      outsider = await f.enroll("outsider", "another-probe-group"), old = await f.enroll("old sender", undefined, false);
    assert.equal((await f.call("POST", `/devices/${a.id}/https-probes`, { scope: "lan" }, a.token)).status, 409);
    assert.equal((await f.call("POST", `/devices/${outsider.id}/https-probes`, { scope: "lan" }, a.token)).status, 403);
    assert.equal((await f.call("POST", `/devices/${old.id}/https-probes`, { scope: "lan" }, a.token)).status, 409);
    const { httpsProbe, ...oldPublication } = f.peer;
    assert.equal((await f.call("POST", "/devices/me/peer", oldPublication, old.token)).status, 200);
    const pending = f.call("POST", `/devices/${b.id}/https-probes`, { scope: "lan" }, a.token);
    await eventually(() => b.messages.some(m => m.type === "https.probe"));
    const message = b.messages.find(m => m.type === "https.probe"), path = `/https-probes/${message.probeId}/result`;
    const result = { tested: true, reachable: true, elapsedMs: 4, address: f.peer.candidates[0] };
    assert.equal((await f.call("POST", path, result, same.token)).status, 403);
    assert.equal((await f.call("POST", path, { ...result, address: "https://192.168.50.99:5555" }, b.token)).status, 409);
    assert.equal((await f.call("POST", path, result, b.token)).status, 200);
    assert.equal((await pending).body.result.reachable, true);
  } finally { await f.close(); }
});
