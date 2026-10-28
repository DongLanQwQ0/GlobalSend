import test from "node:test";
import assert from "node:assert/strict";
import fsPromises, { mkdtemp, mkdir, rm, readFile, appendFile, readdir } from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, X509Certificate } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { once } from "node:events";
import WebSocket from "ws";
import { buildApp } from "../src/server.js";

const bootstrapSecret = "test-bootstrap-32-characters-secret";
const hash = (b: string | Buffer) =>
  createHash("sha256").update(b).digest("hex");
const testTempRoot = fileURLToPath(
  new URL("../../artifacts/tmp/", import.meta.url),
);
const ownedTestDirectories = new Set<string>();
async function makeTestDirectory(kind: "test" | "config") {
  await mkdir(testTempRoot, { recursive: true });
  const dir = await mkdtemp(join(testTempRoot, `globalsend-${kind}-`));
  ownedTestDirectories.add(dir);
  return dir;
}
async function removeTestDirectory(dir: string) {
  if (
    !ownedTestDirectories.has(dir) ||
    resolve(dirname(dir)) !== resolve(testTempRoot) ||
    !basename(dir).startsWith("globalsend-")
  )
    throw new Error("Refusing to remove an unowned test directory");
  await rm(dir, { recursive: true, force: true });
  ownedTestDirectories.delete(dir);
}
async function fixture(options = {}) {
  const dir = await makeTestDirectory("test");
  const identities = new Map<string, string>();
  let app: Awaited<ReturnType<typeof buildApp>>;
  try {
    app = await buildApp({
      dataDir: dir,
      bootstrapSecret,
      diskReserve: 0,
      ...options,
    });
  } catch (error) {
    await removeTestDirectory(dir);
    throw error;
  }
  async function call(
    method: any,
    path: string,
    body?: unknown,
    token?: string,
  ) {
    const response = await app.inject({
      method,
      url: `/api/v1${path}`,
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(Buffer.isBuffer(body)
          ? { "content-type": "application/octet-stream" }
          : {}),
      },
      payload: body as any,
    });
    return {
      status: response.statusCode,
      body: response.headers["content-type"]?.includes("json")
        ? response.json()
        : response.rawPayload,
      headers: response.headers,
    };
  }
  async function online(token: string) {
    const ticket = await call("POST", "/session/ws-ticket", {}, token);
    if (ticket.status === 401) return;
    assert.equal(ticket.status, 200);
    let hello: Promise<void>;
    await app.injectWS(`/api/v1/ws?ticket=${ticket.body.ticket}`, { headers: { origin: "http://127.0.0.1" } }, {
      onInit(socket) { hello = new Promise(resolve => socket.once("message", () => resolve())); },
    });
    await hello!;
  }
  async function track(token: string, groupKey: string) {
    identities.set(token, groupKey); await online(token);
  }
  async function enroll(name = "A", groupKey = "fixture-group-password") {
    const r = await call("POST", "/devices/enroll", {
      name,
      platform: "web",
      groupKey,
    });
    assert.equal(r.status, 201, JSON.stringify(r.body));
    await track(r.body.deviceToken, groupKey);
    return {
      token: r.body.deviceToken as string,
      id: r.body.device.deviceId as string,
    };
  }
  async function pair(token: string, name = "B") {
    // Existing relay/direct regression callers now join by the same password.
    return enroll(name, identities.get(token)!);
  }
  async function restart(beforeBuild?: () => void) {
    await app.close();
    beforeBuild?.();
    app = await buildApp({
      dataDir: dir,
      bootstrapSecret,
      diskReserve: 0,
      ...options,
    });
    for (const token of identities.keys()) await online(token);
  }
  return {
    dir,
    get app() {
      return app;
    },
    call,
    track,
    enroll,
    pair,
    restart,
    async close() {
      try {
        await app.close();
      } finally {
        await removeTestDirectory(dir);
      }
    },
  };
}

test("verified local reuse completes offers without payload, route negotiation or relay bytes", async () => {
  const f = await fixture({ totalQuota: 6 });
  try {
    const a = await f.enroll(), b = await f.pair(a.token);
    for (const routePreference of ["auto", "lan", "public", "relay"]) {
      const transferId = "reuse-" + routePreference, path = `/transfers/${transferId}/files/f/`;
      const offer = { transferId, targetDeviceId: b.id, routePreference,
        files: [{ fileId: "f", name: "renamed.txt", size: 6, sha256: hash("abcdef") }] };
      assert.equal((await f.call("POST", "/transfers", offer, a.token)).status, 201);
      const reused = await f.call("POST", path + "reuse", { sha256: hash("abcdef"), size: 6 }, b.token);
      assert.equal(reused.status, 200, JSON.stringify(reused.body));
      assert.equal(reused.body.file.status, "received"); assert.equal(reused.body.file.reused, true);
      assert.equal(reused.body.file.offset, 0); assert.equal(reused.body.file.transport, "direct");
      assert.ok(Date.parse(reused.body.file.receivedAt));
      const replay = await f.call("POST", path + "reuse", { sha256: hash("abcdef"), size: 6 }, b.token);
      assert.deepEqual(replay.body, reused.body, "lost acknowledgement is idempotent");
      const accepted = await f.call("POST", `/transfers/${transferId}/accept`, { fileIds: ["f"] }, b.token);
      assert.equal(accepted.body.transfer.files[0].status, "received", "late accept never restarts a reused file");
      assert.equal((await f.call("PUT", path + "chunks?offset=0", Buffer.from("abcdef"), a.token)).status, 409);
      assert.deepEqual(await readdir(join(f.dir, "relay")), []);
    }
    // All four receipts release the 6-byte relay reservation. Old history is
    // not an input: the target inventory is the authority for local bytes.
    await f.restart();
    const receipt = (await f.call("GET", "/transfers/reuse-relay", undefined, a.token)).body.transfer.files[0];
    assert.equal(receipt.reused, true); assert.equal(receipt.status, "received");
    assert.equal((await f.call("GET", "/info")).body.features.fileReuse, true);
  } finally { await f.close(); }
});

test("reuse only confirms matching receiver-local files before payload starts", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(), b = await f.pair(a.token);
    const offer = { transferId: "reuse-state", targetDeviceId: b.id,
      files: [{ fileId: "f", name: "note.txt", size: 6, sha256: hash("abcdef") }] };
    const path = "/transfers/reuse-state/files/f/", content = { sha256: hash("abcdef"), size: 6 };
    await f.call("POST", "/transfers", offer, a.token);
    assert.equal((await f.call("POST", path + "reuse", content, a.token)).status, 403);
    assert.equal((await f.call("POST", path + "reuse", { ...content, sha256: hash("ABCDEF") }, b.token)).body.error.code, "CONTENT_MISMATCH");
    assert.equal((await f.call("POST", path + "reuse", { ...content, size: 5 }, b.token)).body.error.code, "CONTENT_MISMATCH");
    await f.call("POST", "/transfers/reuse-state/accept", { fileIds: ["f"] }, b.token);
    await f.call("PUT", path + "chunks?offset=0", Buffer.from("abc"), a.token);
    assert.equal((await f.call("POST", path + "reuse", content, b.token)).body.error.code, "TRANSFER_STARTED");
    await f.call("PUT", path + "chunks?offset=3", Buffer.from("def"), a.token);
    assert.equal((await f.call("POST", path + "complete", {}, a.token)).status, 200);
    assert.equal((await f.call("POST", path + "received", {}, b.token)).status, 200);
    const ordinary = (await f.call("GET", "/transfers/reuse-state", undefined, b.token)).body.transfer.files[0];
    assert.equal(ordinary.reused, undefined, "normal receive stays on its existing contract");
  } finally { await f.close(); }
});

test("receiver storage failures notify the sender and resume committed relay bytes after restart", async () => {
  const f = await fixture({ totalQuota: 6 });
  try {
    const a = await f.enroll(), b = await f.pair(a.token);
    const offer = { transferId: "save-failure", targetDeviceId: b.id,
      files: [{ fileId: "item", name: "note.txt", size: 6, sha256: hash("abcdef") }] };
    const path = "/transfers/save-failure/files/item/";
    assert.equal((await f.call("POST", "/transfers", offer, a.token)).status, 201);
    await f.call("POST", "/transfers/save-failure/accept", { fileIds: ["item"] }, b.token);
    await f.call("PUT", path + "chunks?offset=0", Buffer.from("abc"), a.token);
    assert.equal((await f.call("POST", path + "receive-error", { message: "Choose a local folder" }, a.token)).status, 403);
    const failed = await f.call("POST", path + "receive-error", { message: "请选择设备的本地文件夹" }, b.token);
    assert.equal(failed.body.file.status, "failed");
    assert.equal(failed.body.file.offset, 3);
    assert.equal(failed.body.file.receiveFailure, true);
    const source = (await f.call("GET", "/transfers/save-failure", undefined, a.token)).body.transfer.files[0];
    assert.equal(source.errorCode, "请选择设备的本地文件夹");
    assert.equal((await f.call("GET", "/events", undefined, a.token)).body.events.at(-1).type, "transfer.updated");
    assert.equal((await f.call("POST", "/transfers", { ...offer, transferId: "over-quota" }, a.token)).status, 507);
    await f.restart();
    const retry = (await f.call("POST", path + "receive-retry", {}, b.token)).body.file;
    assert.equal(retry.status, "uploading"); assert.equal(retry.offset, 3); assert.equal(retry.receiveFailure, false);
    assert.equal(retry.attemptId, failed.body.file.attemptId);
    // Replaying the prefix proves it is still present, not merely an offset.
    assert.equal((await f.call("PUT", path + "chunks?offset=0", Buffer.from("abc"), a.token)).status, 200);
    await f.call("PUT", path + "chunks?offset=3", Buffer.from("def"), a.token);
    await f.call("POST", path + "complete", {}, a.token);
    await f.call("POST", path + "receive-error", { message: "Directory unavailable" }, b.token);
    assert.equal((await f.call("POST", path + "receive-retry", {}, a.token)).body.file.status, "ready");
    assert.equal((await f.call("POST", path + "received", {}, b.token)).status, 200);
    assert.equal((await f.call("POST", path + "receive-error", { message: "Late failure" }, b.token)).body.file.status, "received");
    assert.equal((await f.call("GET", "/info")).body.features.receiveErrorReporting, true);
  } finally { await f.close(); }
});

test("device rename updates its identity label, not its token, and notifies peers", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("电脑"), b = await f.pair(a.token, "手机");
    await f.app.listen({ host: "127.0.0.1", port: 0 });
    const port = (f.app.server.address() as any).port;
    const ticket = (await f.call("POST", "/session/ws-ticket", {}, b.token)).body.ticket;
    const socket = new WebSocket(`ws://127.0.0.1:${port}/api/v1/ws?ticket=${ticket}`, { origin: "http://127.0.0.1" });
    await once(socket, "open");
    const change = new Promise<void>((resolve) => {
      socket.on("message", data => { if (JSON.parse(String(data)).type === "devices.changed") resolve(); });
    });
    const renamed = await f.call("PATCH", "/devices/me", { name: "  我的电脑  " }, a.token);
    assert.equal(renamed.status, 200);
    assert.equal(renamed.body.device.name, "我的电脑");
    assert.equal(renamed.body.device.deviceId, a.id);
    await change;
    const devices = (await f.call("GET", "/devices", undefined, b.token)).body.devices;
    assert.equal(devices.find((d: any) => d.deviceId === a.id).name, "我的电脑");
    assert.equal(devices.find((d: any) => d.deviceId === b.id).name, "手机");
    assert.equal((await f.call("PATCH", "/devices/me", { name: "   " }, a.token)).status, 400);
    const closed = once(socket, "close"); socket.close(); await closed;
    await f.restart();
    assert.equal((await f.call("GET", "/devices", undefined, a.token)).body.devices.find((d: any) => d.deviceId === a.id).name, "我的电脑");
  } finally { await f.close(); }
});

test("sent text edits replay to the receiver and survive restart", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(), b = await f.pair(a.token);
    const sent = await f.call("POST", "/texts", { eventId: "editable-text", targetDeviceId: b.id, text: "第一版" }, a.token);
    assert.equal(sent.status, 201);
    const cursor = sent.body.event.cursor;
    assert.equal((await f.call("PATCH", "/texts/editable-text", { text: "不能修改收到的消息" }, b.token)).status, 404);
    const edit = await f.call("PATCH", "/texts/editable-text", { text: "第二版\n保留换行" }, a.token);
    assert.equal(edit.status, 200);
    assert.equal(edit.body.event.type, "text.updated");
    assert.equal(edit.body.event.payload.sourceEventId, "editable-text");
    const replay = (await f.call("GET", `/events?after=${cursor}`, undefined, b.token)).body.events;
    assert.equal(replay.length, 1);
    assert.equal(replay[0].payload.text, "第二版\n保留换行");
    assert.equal((await f.call("PATCH", "/texts/editable-text", { text: "   " }, a.token)).status, 400);
    const same = await f.call("PATCH", "/texts/editable-text", { text: "第二版\n保留换行" }, a.token);
    assert.equal(same.body.event.type, "text.created");
    await f.restart();
    const restored = (await f.call("GET", "/events", undefined, b.token)).body.events;
    assert.equal(restored.find((e: any) => e.eventId === "editable-text").payload.text, "第二版\n保留换行");
    assert.equal(restored.filter((e: any) => e.type === "text.updated").length, 1);
  } finally { await f.close(); }
});

test("bootstrap and invitations are retired; authenticated device revocation remains enforced", async () => {
  const f = await fixture();
  try {
    assert.equal((await f.call("GET", "/devices")).status, 401);
    assert.equal(
      (
        await f.call("POST", "/devices/enroll", {
          name: "bad",
          platform: "web",
          bootstrapSecret: "wrong",
        })
      ).status,
      410,
    );
    const a = await f.enroll();
    assert.equal(
      (
        await f.call("POST", "/devices/enroll", {
          name: "bad",
          platform: "web",
          bootstrapSecret,
        })
      ).status,
      410,
    );
    assert.equal((await f.call("POST", "/pairing-codes", {}, a.token)).status, 410);
    const b = await f.pair(a.token);
    assert.equal(
      (
        await f.call("POST", "/devices/enroll", {
          name: "C",
          platform: "web",
          pairingCode: "retired-invitation",
        })
      ).status,
      410,
    );
    assert.equal(
      (await f.call("GET", "/devices", undefined, b.token)).body.devices.length,
      2,
    );
    assert.equal(
      (await f.call("DELETE", `/devices/${b.id}`, undefined, a.token)).status,
      200,
    );
    assert.equal(
      (await f.call("GET", "/devices", undefined, b.token)).status,
      401,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/texts",
          { eventId: "forbidden", targetDeviceId: b.id, text: "x" },
          a.token,
        )
      ).status,
      403,
    );
  } finally {
    await f.close();
  }
});

test("persistent text cursors, sender identity, idempotency conflicts, receiver-only ACK", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(),
      b = await f.pair(a.token),
      c = await f.pair(a.token, "C");
    const body = {
      eventId: "message-1",
      targetDeviceId: b.id,
      text: "中文独立文本\nhello",
    };
    const sent = await f.call("POST", "/texts", body, a.token);
    assert.equal(sent.status, 201);
    assert.equal(sent.body.event.sourceDeviceId, a.id);
    assert.equal(
      (await f.call("POST", "/texts", body, a.token)).body.replayed,
      true,
    );
    assert.equal(
      (await f.call("POST", "/texts", { ...body, text: "conflict" }, a.token))
        .status,
      409,
    );
    assert.equal(
      (await f.call("GET", "/events", undefined, c.token)).body.events.length,
      0,
    );
    assert.equal(
      (await f.call("POST", "/events/message-1/ack", {}, a.token)).status,
      404,
    );
    await f.call("POST", "/events/message-1/ack", {}, b.token);
    await f.call("POST", "/events/message-1/ack", {}, b.token);
    const info = (await f.call("GET", "/info")).body;
    await f.restart();
    assert.equal(
      (await f.call("GET", "/info")).body.instanceId,
      info.instanceId,
    );
    const history = (await f.call("GET", "/events", undefined, b.token)).body;
    assert.deepEqual(
      history.events.map((e: any) => e.type),
      ["text.created", "text.received"],
    );
    assert.equal(
      (
        await f.call(
          "GET",
          `/events?after=${history.cursor}`,
          undefined,
          b.token,
        )
      ).body.events.length,
      0,
    );
    assert.equal(
      (await f.call("POST", "/texts", body, a.token)).body.replayed,
      true,
    );
  } finally {
    await f.close();
  }
});

test("multi-file consent, permission, chunk replay, restart offsets, integrity failure isolation and retry", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(),
      b = await f.pair(a.token),
      c = await f.pair(a.token, "C");
    const good = Buffer.from("good bytes"),
      bad = Buffer.from("bad bytes");
    const offered = {
      transferId: "batch-1",
      targetDeviceId: b.id,
      files: [
        {
          fileId: "good",
          name: "中文 名.txt",
          size: good.length,
          sha256: hash(good),
        },
        {
          fileId: "bad",
          name: "bad.txt",
          size: bad.length,
          sha256: hash("expected!"),
        },
        { fileId: "empty", name: "empty.txt", size: 0, sha256: hash("") },
      ],
    };
    assert.equal(
      (await f.call("POST", "/transfers", offered, a.token)).status,
      201,
    );
    assert.equal(
      (await f.call("POST", "/transfers", offered, a.token)).body.replayed,
      true,
    );
    assert.equal(
      (await f.call("GET", "/transfers/batch-1", undefined, c.token)).status,
      404,
    );
    const file = (id: string, action: string) =>
      `/transfers/batch-1/files/${id}/${action}`;
    assert.equal(
      (await f.call("PUT", file("good", "chunks?offset=0"), good, a.token))
        .status,
      409,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/transfers/batch-1/accept",
          { fileIds: ["good", "bad", "empty"] },
          a.token,
        )
      ).status,
      403,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/transfers/batch-1/accept",
          { fileIds: ["good", "bad", "empty"] },
          b.token,
        )
      ).status,
      200,
    );
    assert.equal(
      (
        await f.call(
          "PUT",
          file("good", "chunks?offset=0"),
          good.subarray(0, 4),
          b.token,
        )
      ).status,
      403,
    );
    assert.equal(
      (
        await f.call(
          "PUT",
          file("good", "chunks?offset=0"),
          good.subarray(0, 4),
          a.token,
        )
      ).body.file.offset,
      4,
    );
    assert.equal(
      (
        await f.call(
          "PUT",
          file("good", "chunks?offset=0"),
          good.subarray(0, 4),
          a.token,
        )
      ).body.file.offset,
      4,
    );
    assert.equal(
      (
        await f.call(
          "PUT",
          file("good", "chunks?offset=0"),
          Buffer.from("xxxx"),
          a.token,
        )
      ).status,
      409,
    );
    await f.restart();
    assert.equal(
      (await f.call("GET", "/transfers/batch-1", undefined, a.token)).body
        .transfer.files[0].offset,
      4,
    );
    assert.equal(
      (
        await f.call(
          "PUT",
          file("good", "chunks?offset=4"),
          good.subarray(4),
          a.token,
        )
      ).status,
      200,
    );
    assert.equal(
      (await f.call("POST", file("good", "complete"), {}, a.token)).body.file
        .status,
      "ready",
    );
    assert.equal(
      (await f.call("POST", file("empty", "complete"), {}, a.token)).body.file
        .status,
      "ready",
    );
    await f.call("PUT", file("bad", "chunks?offset=0"), bad, a.token);
    assert.equal(
      (await f.call("POST", file("bad", "complete"), {}, a.token)).status,
      422,
    );
    let state = (await f.call("GET", "/transfers/batch-1", undefined, b.token))
      .body.transfer.files;
    assert.deepEqual(
      state.map((x: any) => x.status),
      ["ready", "failed", "ready"],
    );
    assert.equal(
      (
        await f.call(
          "POST",
          file("bad", "retry"),
          { attemptId: "attempt-2" },
          a.token,
        )
      ).body.file.offset,
      0,
    );
    await f.call(
      "PUT",
      file("bad", "chunks?offset=0"),
      Buffer.from("expected!"),
      a.token,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          file("bad", "retry"),
          { attemptId: "attempt-2" },
          a.token,
        )
      ).body.file.offset,
      9,
    );
    assert.equal(
      (await f.call("POST", file("bad", "complete"), {}, a.token)).body.file
        .status,
      "ready",
    );
    assert.equal(
      (await f.call("POST", file("good", "download-ticket"), {}, a.token))
        .status,
      403,
    );
    const download = (
      await f.call("POST", file("good", "download-ticket"), {}, b.token)
    ).body;
    const result = await f.call(
      "GET",
      download.downloadPath.replace("/api/v1", ""),
    );
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, good);
    assert.equal(
      (await f.call("GET", download.downloadPath.replace("/api/v1", "")))
        .status,
      401,
    );
    assert.equal(
      (await f.call("POST", file("good", "received"), {}, b.token)).body.file
        .status,
      "received",
    );
    await f.call("POST", file("empty", "cancel"), {}, b.token);
    assert.equal(
      (await f.call("POST", file("empty", "download-ticket"), {}, b.token))
        .status,
      409,
    );
  } finally {
    await f.close();
  }
});

test("quota reservations, path rejection, overflow and receiver rejection", async () => {
  const f = await fixture({ totalQuota: 10, maxFileSize: 9 });
  try {
    const a = await f.enroll(),
      b = await f.pair(a.token);
    const offer = (transferId: string, size = 6, name = "file.txt") => ({
      transferId,
      targetDeviceId: b.id,
      files: [{ fileId: "f", name, size, sha256: hash("123456") }],
    });
    assert.equal(
      (
        await f.call(
          "POST",
          "/transfers",
          offer("bad-name", 6, "../secret"),
          a.token,
        )
      ).status,
      400,
    );
    assert.equal(
      (await f.call("POST", "/transfers", offer("too-big", 10), a.token))
        .status,
      413,
    );
    await f.call("POST", "/transfers", offer("one"), a.token);
    assert.equal(
      (await f.call("POST", "/transfers", offer("two"), a.token)).status,
      507,
    );
    await f.call("POST", "/transfers/one/accept", { fileIds: [] }, b.token);
    assert.equal(
      (await f.call("POST", "/transfers", offer("two"), a.token)).status,
      201,
    );
    await f.call("POST", "/transfers/two/accept", { fileIds: ["f"] }, b.token);
    assert.equal(
      (
        await f.call(
          "PUT",
          "/transfers/two/files/f/chunks?offset=0",
          Buffer.from("1234567"),
          a.token,
        )
      ).status,
      409,
    );
  } finally {
    await f.close();
  }
});

test("restart truncates bytes beyond committed offset and expiry blocks recovery", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(),
      b = await f.pair(a.token);
    await f.call(
      "POST",
      "/transfers",
      {
        transferId: "restart",
        targetDeviceId: b.id,
        files: [{ fileId: "f", name: "file", size: 6, sha256: hash("123456") }],
      },
      a.token,
    );
    await f.call(
      "POST",
      "/transfers/restart/accept",
      { fileIds: ["f"] },
      b.token,
    );
    await f.call(
      "PUT",
      "/transfers/restart/files/f/chunks?offset=0",
      Buffer.from("123"),
      a.token,
    );
    const db = new DatabaseSync(join(f.dir, "globalsend.sqlite"));
    const row = db.prepare("SELECT path FROM files").get() as any;
    await appendFile(row.path, "garbage");
    db.close();
    await f.restart();
    assert.equal(
      (
        await f.call(
          "PUT",
          "/transfers/restart/files/f/chunks?offset=3",
          Buffer.from("456"),
          a.token,
        )
      ).status,
      200,
    );
    assert.equal(
      (await f.call("POST", "/transfers/restart/files/f/complete", {}, a.token))
        .status,
      200,
    );
    const db2 = new DatabaseSync(join(f.dir, "globalsend.sqlite"));
    db2.prepare("UPDATE transfers SET expires=0").run();
    db2.close();
    await f.restart();
    assert.equal(
      (await f.call("GET", "/transfers/restart", undefined, a.token)).status,
      410,
    );
  } finally {
    await f.close();
  }
});

test("WebSocket ticket single use, origin check and revocation closes actual connection", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(),
      b = await f.pair(a.token);
    await f.app.listen({ host: "127.0.0.1", port: 0 });
    const port = (f.app.server.address() as any).port;
    const ticket = (await f.call("POST", "/session/ws-ticket", {}, b.token))
      .body.ticket;
    const socket = new WebSocket(
      `ws://127.0.0.1:${port}/api/v1/ws?ticket=${ticket}`,
      { origin: "http://127.0.0.1" },
    );
    const hello = once(socket, "message");
    await once(socket, "open");
    assert.equal(JSON.parse(String((await hello)[0])).type, "hello");
    assert.equal(
      (await f.call("GET", "/devices", undefined, a.token)).body.devices.find(
        (d: any) => d.deviceId === b.id,
      ).online,
      true,
    );
    const replay = await f.app.inject({
      method: "GET",
      url: `/api/v1/ws?ticket=${ticket}`,
      headers: {
        upgrade: "websocket",
        connection: "Upgrade",
        "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==",
        "sec-websocket-version": "13",
      },
    });
    assert.equal(replay.statusCode, 401);
    const close = once(socket, "close");
    await f.call("DELETE", `/devices/${b.id}`, undefined, a.token);
    await close;
    const otherTicket = (
      await f.call("POST", "/session/ws-ticket", {}, a.token)
    ).body.ticket;
    const denied = await f.app.inject({
      method: "GET",
      url: `/api/v1/ws?ticket=${otherTicket}`,
      headers: { origin: "https://evil.example" },
    });
    assert.equal(denied.statusCode, 403);
  } finally {
    await f.close();
  }
});

test("production requires HTTPS base, retires bootstrap, and honors the configured prefix", async () => {
  const dir = await makeTestDirectory("config");
  try {
    await assert.rejects(
      buildApp({ dataDir: dir, production: true }),
      /PUBLIC_BASE_URL/,
    );
    const withoutLegacy = await buildApp({ dataDir: dir, production: true, publicBaseUrl: "https://example.org" });
    try { assert.equal((await withoutLegacy.inject("/api/v1/info")).json().enrollment.legacyBootstrap, false); }
    finally { await withoutLegacy.close(); }
    const app = await buildApp({
      dataDir: dir,
      production: true,
      publicBaseUrl: "https://example.org/send",
      bootstrapSecret,
    });
    try {
      assert.equal((await app.inject("/send/api/v1/info")).statusCode, 200);
      assert.equal((await app.inject("/api/v1/info")).statusCode, 404);
    } finally {
      await app.close();
    }
  } finally {
    await removeTestDirectory(dir);
  }
});

test("test temporary directories stay in project and cleanup refuses unowned paths", async () => {
  const dir = await makeTestDirectory("test");
  try {
    assert.equal(resolve(dirname(dir)), resolve(testTempRoot));
    await assert.rejects(
      removeTestDirectory(resolve(testTempRoot, "..")),
      /unowned/,
    );
  } finally {
    await removeTestDirectory(dir);
  }
  assert.equal(ownedTestDirectories.size, 0);
});

test("reverse push authorization binds direction, phase, receiver consent and one live attempt", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(), b = await f.pair(a.token);
    const certificatePem = await readFile(new URL("./fixtures/peer-certificate.pem", import.meta.url), "utf8");
    const peer = { candidates: ["https://127.0.0.1:9999"], certificatePem,
      certificateSha256: hash(new X509Certificate(certificatePem).raw), push: true, cellularPush: false };
    await f.call("POST", "/devices/me/peer", peer, a.token);
    await f.call("POST", "/devices/me/peer", peer, b.token);
    await f.call("POST", "/transfers", { transferId: "reverse", targetDeviceId: b.id,
      routePreference: "lan", files: [{ fileId: "f", name: "file", size: 6, sha256: hash("123456") }] }, a.token);
    const path = "/transfers/reverse/files/f";
    const attempt = { attemptId: "one", scope: "lan", cellular: false, offset: 0 };
    assert.equal((await f.call("POST", `${path}/direct-push`, attempt, b.token)).status, 409);
    await f.call("POST", "/transfers/reverse/accept", { fileIds: ["f"] }, b.token);
    assert.equal((await f.call("POST", `${path}/direct-push`, attempt, a.token)).status, 403);
    assert.equal((await f.call("POST", `${path}/direct-push`, { ...attempt, scope: "public" }, b.token)).status, 409);
    assert.equal((await f.call("POST", `${path}/direct-push`, { ...attempt, cellular: true }, b.token)).status, 409);
    assert.equal((await f.call("POST", `${path}/direct-push`, attempt, b.token)).status, 200);
    const grant = await f.call("POST", `${path}/push-ticket`, { attemptId: "one" }, a.token);
    assert.equal(grant.status, 200);
    const verify = { ticket: grant.body.ticket, transferId: "reverse", fileId: "f", attemptId: "one" };
    assert.equal((await f.call("POST", "/push-tickets/verify", verify, a.token)).status, 403);
    assert.equal((await f.call("POST", "/direct-tickets/verify", { ticket: grant.body.ticket, transferId: "reverse", fileId: "f" }, a.token)).status, 401);
    assert.equal((await f.call("POST", "/push-tickets/verify", { ...verify, attemptId: "other" }, b.token)).status, 401);
    assert.equal((await f.call("POST", "/push-tickets/verify", verify, b.token)).status, 200);
    assert.equal((await f.call("POST", "/push-tickets/verify", verify, b.token)).status, 401);
    await f.call("POST", `${path}/direct-push/stop`, { attemptId: "one" }, b.token);
    assert.equal((await f.call("POST", `${path}/direct-push`, { ...attempt, attemptId: "two", offset: 2 }, b.token)).status, 200);
    const second = (await f.call("POST", `${path}/push-ticket`, { attemptId: "two" }, a.token)).body;
    const secondVerify = { ...verify, attemptId: "two", ticket: second.ticket };
    await f.call("POST", `${path}/direct-push/stop`, { attemptId: "two" }, b.token);
    assert.equal((await f.call("POST", "/push-tickets/verify", secondVerify, b.token)).status, 401);
    assert.equal((await f.call("POST", `${path}/push-ticket`, { attemptId: "two" }, a.token)).status, 409);
  } finally { await f.close(); }
});

test("direct authorization is receiver-consented, sender-bound, single-use, path-exclusive and quota-releasing", async () => {
  const f = await fixture({ totalQuota: 6 });
  try {
    const a = await f.enroll(),
      b = await f.pair(a.token),
      c = await f.pair(a.token, "C");
    const certificatePem = await readFile(
      new URL("./fixtures/peer-certificate.pem", import.meta.url),
      "utf8",
    );
    const certificateSha256 = hash(new X509Certificate(certificatePem).raw);
    const peer = {
      candidates: ["https://127.0.0.1:9999"],
      certificatePem,
      certificateSha256,
    };
    assert.equal(
      (
        await f.call(
          "POST",
          "/devices/me/peer",
          { ...peer, candidates: ["http://127.0.0.1:9999"] },
          a.token,
        )
      ).status,
      400,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/devices/me/peer",
          { ...peer, certificateSha256: hash("wrong") },
          a.token,
        )
      ).status,
      400,
    );
    assert.equal(
      (await f.call("POST", "/devices/me/peer", peer, a.token)).status,
      200,
    );
    assert.equal(
      (await f.call("GET", "/devices", undefined, b.token)).body.devices.find(
        (d: any) => d.deviceId === a.id,
      ).peer.certificateSha256,
      certificateSha256,
    );
    const offer = (transferId: string) => ({
      transferId,
      targetDeviceId: b.id,
      files: [{ fileId: "f", name: "file", size: 6, sha256: hash("123456") }],
    });
    await f.call("POST", "/transfers", offer("direct"), a.token);
    const path = "/transfers/direct/files/f";
    assert.equal(
      (await f.call("POST", `${path}/direct-ticket`, {}, b.token)).status,
      409,
    );
    await f.call(
      "POST",
      "/transfers/direct/accept",
      { fileIds: ["f"] },
      b.token,
    );
    assert.equal(
      (await f.call("POST", `${path}/direct-ticket`, {}, a.token)).status,
      403,
    );
    const ticket = (await f.call("POST", `${path}/direct-ticket`, {}, b.token))
      .body.ticket;
    assert.equal(
      (await f.call("POST", "/transfers", offer("over-quota"), a.token)).status,
      507,
    );
    assert.equal(
      (await f.call("POST", `${path}/relay`, {}, a.token)).status,
      409,
    );
    assert.equal(
      (
        await f.call(
          "PUT",
          `${path}/chunks?offset=0`,
          Buffer.from("123456"),
          a.token,
        )
      ).status,
      409,
    );
    const verification = { ticket, transferId: "direct", fileId: "f" };
    assert.equal(
      (await f.call("POST", "/direct-tickets/verify", verification, c.token))
        .status,
      404,
    );
    assert.equal(
      (await f.call("POST", "/direct-tickets/verify", verification, a.token))
        .body.size,
      6,
    );
    assert.equal(
      (await f.call("POST", "/direct-tickets/verify", verification, a.token))
        .status,
      401,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          `${path}/received`,
          { transport: "direct" },
          b.token,
        )
      ).body.file.transport,
      "direct",
    );
    assert.equal(
      (await f.call("POST", "/transfers", offer("released"), a.token)).status,
      201,
    );
    assert.equal(
      (await f.call("POST", `${path}/download-ticket`, {}, b.token)).status,
      409,
    );
    await f.restart();
    await f.call("POST", "/devices/me/peer", peer, a.token);
    assert.equal(
      (await f.call("GET", "/transfers/direct", undefined, b.token)).body
        .transfer.files[0].status,
      "received",
    );
    await f.call(
      "POST",
      "/transfers/released/accept",
      { fileIds: ["f"] },
      b.token,
    );
    const another = (
      await f.call(
        "POST",
        "/transfers/released/files/f/direct-ticket",
        {},
        b.token,
      )
    ).body;
    assert.equal(
      (await f.call("POST", "/transfers/released/files/f/relay", {}, b.token))
        .body.file.transport,
      "relay",
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/direct-tickets/verify",
          { ticket: another.ticket, transferId: "released", fileId: "f" },
          a.token,
        )
      ).status,
      401,
    );
  } finally {
    await f.close();
  }
});

test("concurrent offer retries commit once and socket shutdown is clean", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(),
      b = await f.pair(a.token);
    const body = {
      transferId: "simultaneous",
      targetDeviceId: b.id,
      files: [{ fileId: "f", name: "file", size: 3, sha256: hash("123") }],
    };
    const responses = await Promise.all(
      Array.from({ length: 5 }, () =>
        f.call("POST", "/transfers", body, a.token),
      ),
    );
    assert.deepEqual(
      responses.map((r) => r.status).sort(),
      [200, 200, 200, 200, 201],
    );
    assert.equal(
      (await f.call("GET", "/events", undefined, b.token)).body.events.filter(
        (e: any) => e.type === "transfer.offered",
      ).length,
      1,
    );
    await f.app.listen({ host: "127.0.0.1", port: 0 });
    const ticket = (await f.call("POST", "/session/ws-ticket", {}, b.token))
      .body.ticket;
    const socket = new WebSocket(
      `ws://127.0.0.1:${(f.app.server.address() as any).port}/api/v1/ws?ticket=${ticket}`,
    );
    await once(socket, "open");
    await f.restart();
    assert.notEqual(socket.readyState, WebSocket.OPEN);
  } finally {
    await f.close();
  }
});

const groupAKey = "group-A-256-bit-style-test-secret";
const groupBKey = "group-B-256-bit-style-test-secret";
async function joinGroup(
  f: Awaited<ReturnType<typeof fixture>>,
  name: string,
  groupKey: string,
) {
  const r = await f.call("POST", "/devices/enroll", {
    name,
    platform: "web",
    groupKey,
  });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  await f.track(r.body.deviceToken, groupKey);
  return {
    token: r.body.deviceToken as string,
    id: r.body.device.deviceId as string,
    groupId: r.body.groupId as string,
    createdGroup: r.body.createdGroup as boolean,
  };
}

test("group keys create stable groups; all routes and actual WS stay isolated across groups", async () => {
  const f = await fixture();
  try {
    const a = await joinGroup(f, "A", groupAKey),
      b = await joinGroup(f, "B", groupAKey),
      c = await joinGroup(f, "C", groupBKey);
    assert.equal(a.createdGroup, true);
    assert.equal(b.createdGroup, false);
    assert.equal(c.createdGroup, true);
    assert.equal(a.groupId, b.groupId);
    assert.notEqual(a.groupId, c.groupId);
    assert.deepEqual(
      (await f.call("GET", "/devices", undefined, a.token)).body.devices
        .map((d: any) => d.deviceId)
        .sort(),
      [a.id, b.id].sort(),
    );
    assert.equal(
      (await f.call("DELETE", `/devices/${a.id}`, undefined, c.token)).status,
      403,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/texts",
          { eventId: "cross-text", targetDeviceId: c.id, text: "hidden" },
          a.token,
        )
      ).status,
      403,
    );
    const offer = {
      transferId: "group-file",
      targetDeviceId: b.id,
      files: [{ fileId: "f", name: "file", size: 3, sha256: hash("123") }],
    };
    assert.equal(
      (
        await f.call(
          "POST",
          "/transfers",
          { ...offer, targetDeviceId: c.id },
          a.token,
        )
      ).status,
      403,
    );
    await f.call("POST", "/transfers", offer, a.token);
    assert.equal(
      (await f.call("GET", "/transfers/group-file", undefined, c.token)).status,
      404,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/transfers/group-file/accept",
          { fileIds: ["f"] },
          c.token,
        )
      ).status,
      404,
    );
    assert.equal(
      (
        await f.call(
          "PUT",
          "/transfers/group-file/files/f/chunks?offset=0",
          Buffer.from("123"),
          c.token,
        )
      ).status,
      404,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/transfers/group-file/files/f/download-ticket",
          {},
          c.token,
        )
      ).status,
      404,
    );
    const cert = await readFile(
      new URL("./fixtures/peer-certificate.pem", import.meta.url),
      "utf8",
    );
    await f.call(
      "POST",
      "/devices/me/peer",
      {
        candidates: ["https://127.0.0.1:9999"],
        certificatePem: cert,
        certificateSha256: hash(new X509Certificate(cert).raw),
      },
      a.token,
    );
    await f.call(
      "POST",
      "/transfers/group-file/accept",
      { fileIds: ["f"] },
      b.token,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/transfers/group-file/files/f/direct-ticket",
          {},
          c.token,
        )
      ).status,
      404,
    );
    const direct = (
      await f.call(
        "POST",
        "/transfers/group-file/files/f/direct-ticket",
        {},
        b.token,
      )
    ).body;
    assert.equal(
      (
        await f.call(
          "POST",
          "/direct-tickets/verify",
          { ticket: direct.ticket, transferId: "group-file", fileId: "f" },
          c.token,
        )
      ).status,
      404,
    );
    assert.equal(
      (
        await f.call(
          "POST",
          "/direct-tickets/verify",
          { ticket: direct.ticket, transferId: "group-file", fileId: "f" },
          a.token,
        )
      ).status,
      200,
    );
    const sameGroupFile = "/transfers/group-file/files/f";
    assert.equal((await f.call("POST", `${sameGroupFile}/relay`, {}, b.token)).status, 200);
    assert.equal((await f.call("PUT", `${sameGroupFile}/chunks?offset=0`, Buffer.from("123"), a.token)).status, 200);
    assert.equal((await f.call("POST", `${sameGroupFile}/complete`, {}, a.token)).status, 200);
    const download = (await f.call("POST", `${sameGroupFile}/download-ticket`, {}, b.token)).body;
    assert.deepEqual((await f.call("GET", download.downloadPath.replace("/api/v1", ""))).body, Buffer.from("123"));
    assert.equal((await f.call("POST", `${sameGroupFile}/received`, {}, b.token)).body.file.status, "received");
    assert.equal(
      (await f.call("GET", "/transfers", undefined, c.token)).body.transfers
        .length,
      0,
    );
    assert.equal(
      (await f.call("GET", "/events", undefined, c.token)).body.events.length,
      0,
    );
    await f.app.listen({ host: "127.0.0.1", port: 0 });
    const port = (f.app.server.address() as any).port;
    const messagesA: any[] = [],
      messagesC: any[] = [];
    const connect = async (token: string, messages: any[]) => {
      const ticket = (await f.call("POST", "/session/ws-ticket", {}, token))
        .body.ticket;
      const socket = new WebSocket(
        `ws://127.0.0.1:${port}/api/v1/ws?ticket=${ticket}`,
      );
      socket.on("message", (data) => messages.push(JSON.parse(String(data))));
      await once(socket, "open");
      return socket;
    };
    const socketA = await connect(a.token, messagesA);
    await connect(c.token, messagesC);
    await connect(b.token, []);
    const delivered = new Promise<void>((resolve) => {
      const listener = (data: WebSocket.RawData) => {
        if (JSON.parse(String(data)).event?.eventId === "same-group-text") {
          socketA.off("message", listener);
          resolve();
        }
      };
      socketA.on("message", listener);
    });
    await f.call(
      "POST",
      "/texts",
      { eventId: "same-group-text", targetDeviceId: b.id, text: "同组可见" },
      a.token,
    );
    await delivered;
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(
      messagesC.some(
        (m) =>
          m.type === "event" ||
          (m.type === "presence" && [a.id, b.id].includes(m.deviceId)),
      ),
      false,
    );
    assert.equal(
      messagesA.some((m) => m.type === "presence" && m.deviceId === c.id),
      false,
    );
    await f.restart();
    const after = await joinGroup(f, "D", groupAKey);
    assert.equal(after.groupId, a.groupId);
    assert.equal(after.createdGroup, false);
    const db = new DatabaseSync(join(f.dir, "globalsend.sqlite"));
    try {
      const rows = db.prepare("SELECT key_hash FROM group_keys").all() as any[];
      assert.equal(rows.length, 2);
      assert.ok(rows.every((r) => /^[a-f0-9]{64}$/.test(r.key_hash)));
      assert.ok(
        !JSON.stringify(db.prepare("SELECT * FROM group_keys").all()).includes(
          groupAKey,
        ),
      );
    } finally {
      db.close();
    }
  } finally {
    await f.close();
  }
});

test("explicit password rotation retains group and tokens and retires the old password across restart", async () => {
  const f = await fixture();
  try {
    const a = await joinGroup(f, "A", groupAKey),
      b = await joinGroup(f, "B", groupAKey),
      c = await joinGroup(f, "C", groupBKey);
    assert.equal(
      (await f.call("POST", "/groups/key", { newGroupKey: groupAKey }, c.token))
        .status,
      409,
    );
    const replacement = "new-rotated-group-A-secret-256bit";
    const rotated = await f.call(
      "POST",
      "/groups/key",
      { newGroupKey: replacement },
      a.token,
    );
    assert.equal(rotated.status, 200);
    assert.equal(rotated.body.groupId, a.groupId);
    assert.equal(rotated.body.groupKey, replacement);
    assert.equal(
      (await f.call("GET", "/devices", undefined, b.token)).status,
      200,
    );
    assert.equal(
      (
        await f.call("POST", "/devices/enroll", {
          name: "old",
          platform: "web",
          groupKey: groupAKey,
        })
      ).body.error.code,
      "GROUP_KEY_RETIRED",
    );
    assert.equal(
      (
        await f.call("POST", "/devices/enroll", {
          name: "invite",
          platform: "web",
          pairingCode: "retired-invitation",
        })
      ).status,
      410,
    );
    await f.restart();
    assert.equal(
      (
        await f.call("POST", "/devices/enroll", {
          name: "old",
          platform: "web",
          groupKey: groupAKey,
        })
      ).body.error.code,
      "GROUP_KEY_RETIRED",
    );
    assert.equal((await joinGroup(f, "D", replacement)).groupId, a.groupId);
    await f.call("DELETE", `/devices/${b.id}`, undefined, a.token);
    assert.equal(
      (await f.call("GET", "/devices", undefined, b.token)).status,
      401,
    );
    // Revocation is deliberately not implicit shared-key rotation.
    assert.equal((await joinGroup(f, "B2", replacement)).groupId, a.groupId);
    const generated = (await f.call("POST", "/groups/key", {}, a.token)).body;
    assert.match(generated.groupKey, /^[A-Za-z0-9_-]{43}$/);
    assert.equal(generated.groupId, a.groupId);
    assert.equal(
      (
        await f.call("POST", "/devices/enroll", {
          name: "old",
          platform: "web",
          groupKey: replacement,
        })
      ).body.error.code,
      "GROUP_KEY_RETIRED",
    );
  } finally {
    await f.close();
  }
});

test("v2 enrolled tokens migrate and reconnect without invitations or bootstrap", async () => {
  const legacy = await fixture({ allowGroupCreation: false, maxGroups: 0, maxDevicesPerGroup: 0 });
  try {
    const a = await legacy.enroll();
    const b = await legacy.pair(a.token);
    const before = (await legacy.call("GET", "/devices", undefined, a.token))
      .body.devices;
    await legacy.restart(() => {
      const oldDatabase = new DatabaseSync(join(legacy.dir, "globalsend.sqlite"));
      try { oldDatabase.exec("DROP TABLE group_keys; DROP TABLE groups; DELETE FROM meta WHERE key='groupIndexSecret'; PRAGMA user_version=2"); }
      finally { oldDatabase.close(); }
    });
    assert.equal((await legacy.call("GET", "/devices", undefined, a.token)).body.devices[0].groupId, before[0].groupId);
    const rotation = (
      await legacy.call(
        "POST",
        "/groups/key",
        { newGroupKey: groupAKey },
        a.token,
      )
    ).body;
    assert.equal(
      (await joinGroup(legacy, "C", groupAKey)).groupId,
      rotation.groupId,
    );
    await legacy.restart();
    assert.deepEqual(
      (await legacy.call("GET", "/devices", undefined, b.token)).body.devices
        .slice(0, 2)
        .map((d: any) => d.deviceId),
      before.map((d: any) => d.deviceId),
    );
  } finally {
    await legacy.close();
  }
});

test("route preference defaults preserve old retries and manual paths remain enforced after restart", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(), b = await f.pair(a.token);
    const certificatePem = await readFile(new URL("./fixtures/peer-certificate.pem", import.meta.url), "utf8");
    await f.call("POST", "/devices/me/peer", {
      candidates: ["https://127.0.0.1:9999"], certificatePem,
      certificateSha256: hash(new X509Certificate(certificatePem).raw),
    }, a.token);
    assert.equal((await f.call("GET", "/info")).body.features.routePreference, true);
    const offer = (transferId: string, routePreference?: string) => ({
      transferId, targetDeviceId: b.id,
      files: [{ fileId: "f", name: "file.txt", size: 6, sha256: hash("123456") }],
      ...(routePreference === undefined ? {} : { routePreference }),
    });
    assert.equal((await f.call("POST", "/transfers", offer("old"), a.token)).body.transfer.routePreference, "auto");
    assert.equal((await f.call("POST", "/transfers", offer("old", "auto"), a.token)).body.replayed, true);
    assert.equal((await f.call("POST", "/transfers", offer("bad", "anything"), a.token)).status, 400);
    for (const route of ["lan", "public", "relay"]) {
      const result = await f.call("POST", "/transfers", offer(route, route), a.token);
      assert.equal(result.status, 201);
      assert.equal(result.body.transfer.routePreference, route);
      assert.equal((await f.call("POST", "/transfers", offer(route, "auto"), a.token)).status, 409);
      const accepted = await f.call("POST", `/transfers/${route}/accept`, { fileIds: ["f"] }, b.token);
      assert.equal(accepted.body.transfer.files[0].transport, route === "relay" ? "relay" : null);
    }
    await f.restart();
    await f.call("POST", "/devices/me/peer", {
      candidates: ["https://127.0.0.1:9999"], certificatePem,
      certificateSha256: hash(new X509Certificate(certificatePem).raw),
    }, a.token);
    for (const route of ["lan", "public", "relay"]) {
      assert.equal((await f.call("GET", `/transfers/${route}`, undefined, b.token)).body.transfer.routePreference, route);
    }
    assert.equal((await f.call("POST", "/transfers/old/accept", { fileIds: ["f"] }, b.token)).body.transfer.routePreference, "auto");
    const relay = "/transfers/relay/files/f";
    assert.equal((await f.call("POST", `${relay}/direct-ticket`, {}, b.token)).body.error.code, "ROUTE_NOT_ALLOWED");
    assert.equal((await f.call("PUT", `${relay}/chunks?offset=0`, Buffer.from("123456"), a.token)).status, 200);
    assert.equal((await f.call("POST", `${relay}/complete`, {}, a.token)).status, 200);
    assert.equal((await f.call("POST", `${relay}/download-ticket`, {}, b.token)).status, 200);
    for (const route of ["lan", "public"]) {
      const path = `/transfers/${route}/files/f`;
      for (const [method, suffix, body, token] of [
        ["POST", "relay", {}, b.token],
        ["PUT", "chunks?offset=0", Buffer.from("123456"), a.token],
        ["POST", "complete", {}, a.token],
        ["POST", "retry", { attemptId: "next" }, a.token],
        ["POST", "download-ticket", {}, b.token],
        ["POST", "received", { transport: "relay" }, b.token],
      ] as const) {
        const result = await f.call(method, `${path}/${suffix}`, body, token);
        assert.equal(result.status, 409, `${route}/${suffix}`);
        assert.equal(result.body.error.code, "ROUTE_NOT_ALLOWED");
      }
      assert.equal((await f.call("POST", `${path}/direct-ticket`, {}, b.token)).status, 200);
    }
  } finally { await f.close(); }
});

test("fresh download tickets resume exact ranges, while stale If-Range restarts the whole file", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll(), b = await f.pair(a.token), data = Buffer.from("0123456789");
    const path = "/transfers/range/files/f", etag = `"sha256-${hash(data)}"`;
    await f.call("POST", "/transfers", { transferId: "range", targetDeviceId: b.id, files: [
      { fileId: "f", name: "断点.txt", size: data.length, sha256: hash(data) },
    ] }, a.token);
    await f.call("POST", "/transfers/range/accept", { fileIds: ["f"] }, b.token);
    await f.call("PUT", `${path}/chunks?offset=0`, data, a.token);
    await f.call("POST", `${path}/complete`, {}, a.token);
    async function download(headers: Record<string, string>) {
      const ticket = await f.call("POST", `${path}/download-ticket`, {}, b.token);
      const response = await f.app.inject({ method: "GET", url: ticket.body.downloadPath, headers });
      assert.equal((await f.app.inject({ method: "GET", url: ticket.body.downloadPath })).statusCode, 401);
      return response;
    }
    const resumed = await download({ range: "bytes=4-", "if-range": etag });
    assert.equal(resumed.statusCode, 206);
    assert.equal(resumed.headers.etag, etag);
    assert.equal(resumed.headers["content-range"], "bytes 4-9/10");
    assert.deepEqual(resumed.rawPayload, data.subarray(4));
    assert.deepEqual((await download({ range: "bytes=2-5" })).rawPayload, data.subarray(2, 6));
    assert.deepEqual((await download({ range: "bytes=-3" })).rawPayload, data.subarray(7));
    const restarted = await download({ range: "bytes=4-", "if-range": '"different-file"' });
    assert.equal(restarted.statusCode, 200);
    assert.deepEqual(restarted.rawPayload, data);
    const invalid = await download({ range: "bytes=10-" });
    assert.equal(invalid.statusCode, 416);
    assert.equal(invalid.headers["content-range"], "bytes */10");
    assert.equal((await f.call("GET", "/transfers/range", undefined, b.token)).body.transfer.files[0].status, "ready");
  } finally { await f.close(); }
});

test("cancel during the chunk disk check cannot recreate an orphan relay file", async () => {
  const f = await fixture();
  const originalStatfs = fsPromises.statfs;
  let entered!: () => void, release!: () => void;
  const reachedDiskCheck = new Promise<void>((resolve) => { entered = resolve; });
  const diskCheckReleased = new Promise<void>((resolve) => { release = resolve; });
  let upload: ReturnType<typeof f.call> | undefined;
  try {
    const a = await f.enroll(), b = await f.pair(a.token);
    await f.call("POST", "/transfers", { transferId: "race", targetDeviceId: b.id, files: [
      { fileId: "f", name: "race.txt", size: 6, sha256: hash("123456") },
    ] }, a.token);
    await f.call("POST", "/transfers/race/accept", { fileIds: ["f"] }, b.token);
    fsPromises.statfs = (async (path: Parameters<typeof originalStatfs>[0], options?: any) => {
      entered(); await diskCheckReleased; return originalStatfs(path, options);
    }) as typeof originalStatfs;
    syncBuiltinESMExports();
    upload = f.call("PUT", "/transfers/race/files/f/chunks?offset=0", Buffer.from("123456"), a.token);
    await reachedDiskCheck;
    assert.equal((await f.call("POST", "/transfers/race/files/f/cancel", {}, b.token)).body.file.status, "canceled");
    release();
    assert.equal((await upload).status, 409);
    assert.deepEqual(await readdir(join(f.dir, "relay")), []);
    assert.equal((await f.call("GET", "/transfers/race", undefined, b.token)).body.transfer.files[0].offset, 0);
  } finally {
    release(); fsPromises.statfs = originalStatfs; syncBuiltinESMExports();
    if (upload) await upload;
    await f.close();
  }
});
