import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";
import { buildApp, type Options } from "../src/server.js";

type Identity = { id: string; token: string };
const group = "url-intents-fixture-group";
const caller = "com.donglan.chrona";
async function fixture(options: Options = {}) {
  const root = fileURLToPath(new URL("../../artifacts/tmp/", import.meta.url));
  await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, "globalsend-url-intents-"));
  let app = await buildApp({ dataDir: dir, diskReserve: 0, ...options });
  async function call(method: any, path: string, body?: unknown, identity?: Identity) {
    const response = await app.inject({ method, url: "/api/v1" + path,
      headers: identity ? { authorization: "Bearer " + identity.token } : {}, payload: body as any });
    return { status: response.statusCode, body: response.json() as any };
  }
  async function enroll(name: string, groupKey = group, platform = "windows"): Promise<Identity> {
    const enrolled = await call("POST", "/devices/enroll", { name, groupKey, platform });
    assert.equal(enrolled.status, 201);
    return { id: enrolled.body.device.deviceId, token: enrolled.body.deviceToken };
  }
  async function capability(identity: Identity, openUrlIntentV1 = true) {
    return call("POST", "/devices/me/capabilities", { folderTransfer: true, openUrlIntentV1 }, identity);
  }
  async function online(identity: Identity) {
    const ticket = await call("POST", "/session/ws-ticket", {}, identity);
    const messages: any[] = [];
    let hello!: Promise<void>;
    await app.injectWS("/api/v1/ws?ticket=" + ticket.body.ticket, { headers: { origin: "http://127.0.0.1" } }, {
      onInit(socket) {
        hello = new Promise(resolve => socket.once("message", () => resolve()));
        socket.on("message", value => messages.push(JSON.parse(String(value))));
      },
    });
    await hello;
    return messages;
  }
  return { dir, call, enroll, capability, online,
    async restart(beforeOpen?: () => void) { await app.close(); beforeOpen?.(); app = await buildApp({ dataDir: dir, diskReserve: 0, ...options }); },
    async close() {
      await app.close();
      assert.equal(resolve(dirname(dir)), resolve(root));
      await rm(dir, { recursive: true, force: true });
    },
  };
}
function request(target: Identity, change = {}) {
  return { requestId: randomUUID(), targetDeviceId: target.id, callerAppId: caller,
    url: "http://10.194.43.84:8765/", expiresInMs: 120000, ...change };
}
async function changed(messages: any[]) {
  for (let i = 0; i < 100; i++) {
    if (messages.some(message => message.type === "url_intents.changed")) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  assert.fail("URL intent notification was not delivered");
}

test("native capability is additive and a legacy folder update does not clear it", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("sender"), b = await f.enroll("phone", group, "android");
    await f.online(a); await f.online(b);
    assert.equal((await f.call("GET", "/info")).body.features.openUrlIntents, true);
    assert.equal((await f.capability(b)).body.device.openUrlIntentV1, true);
    const legacy = await f.call("POST", "/devices/me/capabilities", { folderTransfer: false }, b);
    assert.equal(legacy.body.device.openUrlIntentV1, true);
    assert.equal(legacy.body.device.folderTransfer, false);
    const peers = (await f.call("GET", "/devices", undefined, a)).body.devices;
    assert.equal(peers.find((d: any) => d.deviceId === b.id).openUrlIntentV1, true);
    assert.equal((await f.capability(b, false)).body.device.openUrlIntentV1, false);
    const web = await f.enroll("browser", group, "web");
    assert.equal((await f.capability(web)).body.error.code, "unsupported_target");
    const body = request(b);
    assert.equal((await f.call("POST", "/url-intents", body, a)).body.error.code, "unsupported_target");
  } finally { await f.close(); }
});

test("an existing folder-only capability table migrates without losing its row", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("source"), b = await f.enroll("legacy target");
    await f.call("POST", "/devices/me/capabilities", { folderTransfer: true }, b);
    await f.restart(() => {
      const db = new DatabaseSync(join(f.dir, "globalsend.sqlite"));
      db.exec("ALTER TABLE device_capabilities DROP COLUMN open_url_intent");
      db.close();
    });
    const legacy = await f.call("POST", "/devices/me/capabilities", { folderTransfer: true }, b);
    assert.equal(legacy.status, 200);
    assert.equal(legacy.body.device.folderTransfer, true);
    assert.equal(legacy.body.device.openUrlIntentV1, false);
    assert.equal((await f.capability(b)).body.device.openUrlIntentV1, true);
    assert.equal((await f.call("POST", "/url-intents", request(b), a)).body.state, "queued");
  } finally { await f.close(); }
});

test("URL commands are same-group targeted, source-scoped and separate from normal text", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("source", group, "android"), b = await f.enroll("target"), c = await f.enroll("third"), outsider = await f.enroll("outside", "other-url-intent-group");
    await f.capability(b); await f.capability(outsider);
    const [sourceMessages, targetMessages, outsideMessages] = await Promise.all([f.online(a), f.online(b), f.online(outsider)]);
    assert.equal((await f.call("POST", "/url-intents", request(b))).status, 401);
    assert.equal((await f.call("POST", "/url-intents", request(a), a)).body.error.code, "target_unavailable");
    assert.equal((await f.call("POST", "/url-intents", request(outsider), a)).body.error.code, "target_unavailable");
    const body = request(b), created = await f.call("POST", "/url-intents", body, a);
    assert.equal(created.status, 200); assert.equal(created.body.state, "queued");
    assert.equal(created.body.callerAppId, caller); assert.equal(created.body.sourceDeviceId, a.id); assert.equal(created.body.url, undefined);
    await Promise.all([changed(sourceMessages), changed(targetMessages)]);
    assert.equal(outsideMessages.filter(message => message.type === "url_intents.changed").length, 0);
    assert.equal(sourceMessages.some(message => message.type === "event" && message.event.type.startsWith("text.")), false);
    assert.equal((await f.call("GET", "/url-intents/" + body.requestId, undefined, b)).status, 404);
    assert.equal((await f.call("GET", "/url-intents/" + body.requestId, undefined, outsider)).status, 404);
    assert.equal((await f.call("GET", "/url-intents/pending", undefined, c)).body.intents.length, 0);
    const pending = (await f.call("GET", "/url-intents/pending", undefined, b)).body.intents;
    assert.equal(pending.length, 1); assert.equal(pending[0].url, body.url); assert.equal(pending[0].sourceDeviceId, a.id);
    assert.equal((await f.call("POST", `/url-intents/${body.requestId}/result`, { sourceDeviceId: a.id, state: "launch_accepted" }, c)).status, 404);
    assert.equal((await f.call("POST", `/url-intents/${body.requestId}/result`, { sourceDeviceId: a.id, state: "launch_accepted" }, outsider)).status, 404);
    const text = await f.call("POST", "/texts", { eventId: randomUUID(), targetDeviceId: b.id, text: "http://10.194.43.84:8765/" }, a);
    assert.equal(text.status, 201);
    assert.equal((await f.call("GET", "/url-intents/pending", undefined, b)).body.intents.length, 1);
    const db = new DatabaseSync(join(f.dir, "globalsend.sqlite"), { readOnly: true });
    assert.equal((db.prepare("SELECT count(*) AS n FROM transfers").get() as any).n, 0);
    assert.equal((db.prepare("SELECT count(*) AS n FROM url_intents").get() as any).n, 1); db.close();
  } finally { await f.close(); }
});

test("lost responses retry once, payload conflicts, restart and expiry preserve dedup tombstones", async () => {
  let now = Date.now(); const f = await fixture({ urlIntentNow: () => now });
  try {
    const a = await f.enroll("source"), b = await f.enroll("target"); await f.capability(b);
    const body = request(b, { expiresInMs: 60000 }), first = (await f.call("POST", "/url-intents", body, a)).body;
    now += 1000;
    assert.deepEqual((await f.call("POST", "/url-intents", body, a)).body, first);
    for (const expiresInMs of [1000, 120000])
      assert.deepEqual((await f.call("POST", "/url-intents", { ...body, expiresInMs }, a)).body, first);
    for (const change of [{ url: "http://10.194.43.85:8765/" }, { callerAppId: "com.another.caller" }, { targetDeviceId: a.id }])
      assert.equal((await f.call("POST", "/url-intents", { ...body, ...change }, a)).body.error.code, "conflict");
    await f.restart();
    assert.equal((await f.call("GET", "/url-intents/pending", undefined, b)).body.intents[0].url, body.url);
    assert.equal((await f.call("GET", "/url-intents/" + body.requestId, undefined, a)).body.expiresAt, first.expiresAt);
    now = Date.parse(first.expiresAt);
    const expired = (await f.call("GET", "/url-intents/" + body.requestId, undefined, a)).body;
    assert.equal(expired.state, "expired"); assert.equal((await f.call("GET", "/url-intents/pending", undefined, b)).body.intents.length, 0);
    const db = new DatabaseSync(join(f.dir, "globalsend.sqlite"), { readOnly: true });
    assert.equal((db.prepare("SELECT url FROM url_intents WHERE request_id=?").get(body.requestId) as any).url, null); db.close();
    await f.restart();
    assert.equal((await f.call("POST", "/url-intents", body, a)).body.state, "expired");
    assert.equal((await f.call("POST", "/url-intents", { ...body, url: "http://10.194.43.85:8765/" }, a)).body.error.code, "conflict");
    assert.equal((await f.call("POST", `/url-intents/${body.requestId}/result`, { sourceDeviceId: a.id, state: "launch_accepted" }, b)).body.state, "expired");
  } finally { await f.close(); }
});

test("tap-to-open progresses once and stale acknowledgements cannot requeue or downgrade it", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("source"), b = await f.enroll("target", group, "android"); await f.capability(b);
    const body = request(b); await f.call("POST", "/url-intents", body, a);
    const result = (state: string, error?: any) => f.call("POST", `/url-intents/${body.requestId}/result`, { sourceDeviceId: a.id, state, ...(error ? {error} : {}) }, b);
    assert.equal((await result("delivered")).body.state, "delivered");
    assert.equal((await f.call("GET", "/url-intents/pending", undefined, b)).body.intents.length, 1);
    const waiting = (await result("needs_tap")).body;
    assert.equal(waiting.state, "needs_tap");
    assert.equal((await f.call("GET", "/url-intents/pending", undefined, b)).body.intents.length, 0);
    assert.deepEqual((await result("delivered")).body, waiting);
    assert.deepEqual((await result("needs_tap")).body, waiting);
    const accepted = (await result("launch_accepted")).body;
    assert.equal(accepted.state, "launch_accepted");
    assert.deepEqual((await result("delivered")).body, accepted);
    assert.deepEqual((await result("failed", { code: "late_failure", message: "迟到的旧回执" })).body, accepted);
    assert.equal((await f.call("GET", "/url-intents/" + body.requestId, undefined, a)).body.state, "launch_accepted");
    const db = new DatabaseSync(join(f.dir, "globalsend.sqlite"), { readOnly: true });
    assert.equal((db.prepare("SELECT count(*) AS n FROM events").get() as any).n, 0); db.close();
  } finally { await f.close(); }
});

test("revocation retires queued intent and URL validation never dispatches unsafe schemes", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("source"), b = await f.enroll("target"); await f.capability(b);
    for (const url of ["file:///tmp/page", "javascript:alert(1)", "https://user:password@example.org/", " http://10.194.43.84:8765/"])
      assert.equal((await f.call("POST", "/url-intents", request(b, {url}), a)).body.error.code, "invalid_url");
    assert.equal((await f.call("POST", "/url-intents", request(b, {expiresInMs:120001}), a)).status, 400);
    assert.equal((await f.call("POST", "/url-intents", request(b, {requestId:"pending"}), a)).status, 400);
    const body = request(b); await f.call("POST", "/url-intents", body, a);
    assert.equal((await f.call("DELETE", "/devices/" + b.id, undefined, a)).status, 200);
    const status = (await f.call("GET", "/url-intents/" + body.requestId, undefined, a)).body;
    assert.equal(status.state, "failed"); assert.equal(status.error.code, "target_unavailable");
    assert.equal((await f.call("POST", "/url-intents", body, a)).body.state, "failed");
  } finally { await f.close(); }
});
