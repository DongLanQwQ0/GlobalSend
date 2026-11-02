import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { once } from "node:events";
import WebSocket from "ws";
import { buildApp } from "../src/server.js";

async function fixture() {
  const root = fileURLToPath(new URL("../../artifacts/tmp/", import.meta.url));
  await mkdir(root, { recursive: true });
  const dir = await mkdtemp(join(root, "copied-files-"));
  let app = await buildApp({ dataDir: dir, diskReserve: 0 });
  await app.listen({ host: "127.0.0.1", port: 0 });
  const origin = () => `http://127.0.0.1:${(app.server.address() as any).port}`;
  async function call(method: string, path: string, body?: unknown, token?: string) {
    const response = await fetch(origin() + "/api/v1" + path, { method,
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body === undefined ? {} : { "content-type": "application/json" }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() as any };
  }
  async function enroll(name: string, groupKey = "copied-files-group") {
    const response = await call("POST", "/devices/enroll", { name, platform: "windows", groupKey });
    assert.equal(response.status, 201);
    return { id: response.body.device.deviceId as string, token: response.body.deviceToken as string };
  }
  async function connect(token: string) {
    const ticket = (await call("POST", "/session/ws-ticket", {}, token)).body.ticket;
    const socket = new WebSocket(origin().replace("http:", "ws:") + "/api/v1/ws?ticket=" + ticket, { origin: origin() });
    const messages: any[] = [];
    socket.on("message", data => messages.push(JSON.parse(String(data))));
    await once(socket, "open");
    return { messages, async close() { const closed = once(socket, "close"); socket.close(); await closed; } };
  }
  async function eventually(check: () => boolean | Promise<boolean>) {
    for (let i = 0; i < 100; i++) { if (await check()) return; await new Promise(resolve => setTimeout(resolve, 10)); }
    assert.fail("Expected socket/state transition did not arrive");
  }
  return { call, enroll, connect, eventually,
    async restart() { await app.close(); app = await buildApp({ dataDir: dir, diskReserve: 0 }); await app.listen({ host: "127.0.0.1", port: 0 }); },
    async close() { await app.close(); await rm(dir, { recursive: true, force: true }); } };
}
const clipboard = { offerId: "copied-batch", items: [
  { id: "file", name: "picture.jpg", kind: "file", size: 1024 },
  { id: "folder", name: "Course", kind: "directory" },
] };

test("copied files announce metadata only and pull once by unique device and item IDs", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("same name"), b = await f.enroll("same name"), unselected = await f.enroll("unselected"), outside = await f.enroll("outside", "other-copied-group");
    const source = await f.connect(a.token), target = await f.connect(b.token), other = await f.connect(unselected.token);
    assert.equal((await f.call("GET", "/info")).body.features.copiedFiles, true);
    assert.equal((await f.call("PUT", "/clipboard/files", clipboard, a.token)).status, 400);
    const published = await f.call("PUT", "/clipboard/files", { ...clipboard, targetDeviceIds: [b.id] }, a.token);
    assert.equal(published.status, 200);
    await f.eventually(() => target.messages.some(message => message.type === "clipboard.files.changed"));
    const listed = (await f.call("GET", "/clipboard/files", undefined, b.token)).body.offers;
    assert.equal(listed.length, 1); assert.equal(listed[0].sourceDeviceId, a.id);
    assert.equal(listed[0].sourceName, "same name"); assert.deepEqual(listed[0].items, clipboard.items);
    assert.equal(listed[0].items.filter((item: any) => item.kind === "directory").length, 1);
    assert.deepEqual((await f.call("GET", "/clipboard/files", undefined, a.token)).body.offers, []);
    assert.deepEqual((await f.call("GET", "/clipboard/files", undefined, outside.token)).body.offers, []);
    assert.deepEqual((await f.call("GET", "/clipboard/files", undefined, unselected.token)).body.offers, []);
    assert.equal(other.messages.filter(message => message.type === "clipboard.files.changed").length, 0);
    assert.equal(listed[0].targetDeviceIds, undefined);
    assert.deepEqual((await f.call("GET", "/transfers", undefined, b.token)).body.transfers, []);
    assert.deepEqual((await f.call("GET", "/events", undefined, b.token)).body.events, []);
    assert.equal((await f.call("GET", "/clipboard/files")).status, 401);
    const request = { offerId: clipboard.offerId, requestId: "one-pull", itemIds: ["folder"] };
    assert.equal((await f.call("POST", `/clipboard/files/${a.id}/pull`, request, outside.token)).status, 403);
    assert.equal((await f.call("POST", `/clipboard/files/${a.id}/pull`, request, unselected.token)).status, 403);
    const pull = await f.call("POST", `/clipboard/files/${a.id}/pull`, request, b.token);
    assert.equal(pull.status, 200); assert.equal(pull.body.targetDeviceId, b.id); assert.equal(pull.body.state, "pending");
    await f.eventually(() => source.messages.some(message => message.type === "clipboard.files.pull"));
    assert.deepEqual(source.messages.find(message => message.type === "clipboard.files.pull"), { type: "clipboard.files.pull", ...pull.body });
    assert.deepEqual((await f.call("POST", `/clipboard/files/${a.id}/pull`, request, b.token)).body, pull.body);
    assert.equal(source.messages.filter(message => message.type === "clipboard.files.pull").length, 1);
    assert.equal((await f.call("POST", `/clipboard/files/${a.id}/pull`, { ...request, itemIds: ["file"] }, b.token)).status, 409);
    assert.equal((await f.call("GET", "/clipboard/files/pulls", undefined, a.token)).body.pulls.length, 1);
    const resultPath = `/clipboard/files/pulls/${b.id}/one-pull`;
    assert.equal((await f.call("PUT", resultPath, { state: "sent" }, outside.token)).status, 403);
    await f.call("PUT", resultPath, { state: "sending" }, a.token);
    await f.call("PUT", resultPath, { state: "sent" }, a.token);
    assert.equal((await f.call("PUT", resultPath, { state: "sending" }, a.token)).body.state, "sent");
    await f.eventually(() => target.messages.some(message => message.type === "clipboard.files.pull.updated" && message.state === "sent"));
    assert.equal((await f.call("GET", "/clipboard/files/pulls/one-pull", undefined, b.token)).body.state, "sent");
    assert.deepEqual((await f.call("GET", "/clipboard/files/pulls", undefined, a.token)).body.pulls, []);
  } finally { await f.close(); }
});

test("offers deduplicate multiple groups, change with clipboard, and withdraw only on last source disconnect", async () => {
  const f = await fixture();
  try {
    const a = await f.enroll("source"), b = await f.enroll("target");
    await f.call("POST", "/groups/join", { groupKey: "second-shared-group" }, a.token);
    await f.call("POST", "/groups/join", { groupKey: "second-shared-group" }, b.token);
    const first = await f.connect(a.token), second = await f.connect(a.token);
    await f.call("PUT", "/clipboard/files", { ...clipboard, targetDeviceIds: [b.id, b.id] }, a.token);
    assert.equal((await f.call("GET", "/clipboard/files", undefined, b.token)).body.offers.length, 1);
    await first.close();
    assert.equal((await f.call("GET", "/clipboard/files", undefined, b.token)).body.offers.length, 1);
    const next = { offerId: "next-copy", items: [clipboard.items[0]], targetDeviceIds: [b.id] };
    await f.call("PUT", "/clipboard/files", next, a.token);
    assert.equal((await f.call("POST", `/clipboard/files/${a.id}/pull`,
      { offerId: clipboard.offerId, requestId: "stale", itemIds: ["file"] }, b.token)).status, 404);
    assert.equal((await f.call("GET", "/clipboard/files", undefined, b.token)).body.offers[0].offerId, "next-copy");
    await second.close();
    await f.eventually(async () => !(await f.call("GET", "/clipboard/files", undefined, b.token)).body.offers.length);
    assert.equal((await f.call("PUT", "/clipboard/files", next, a.token)).status, 409);
    await f.connect(a.token); await f.call("PUT", "/clipboard/files", next, a.token);
    await f.call("DELETE", "/clipboard/files", undefined, a.token);
    assert.deepEqual((await f.call("GET", "/clipboard/files", undefined, b.token)).body.offers, []);
    await f.call("PUT", "/clipboard/files", next, a.token);
    await f.restart();
    assert.deepEqual((await f.call("GET", "/clipboard/files", undefined, b.token)).body.offers, []);
  } finally { await f.close(); }
});

test("changing the designated target withdraws the previous target instead of publishing to its whole group", async () => {
  const f = await fixture();
  try {
    const source = await f.enroll("source"), first = await f.enroll("first"), second = await f.enroll("second");
    await f.connect(source.token); const firstSocket = await f.connect(first.token), secondSocket = await f.connect(second.token);
    await f.call("PUT", "/clipboard/files", { ...clipboard, targetDeviceIds: [first.id] }, source.token);
    await f.eventually(() => firstSocket.messages.some(message => message.type === "clipboard.files.changed"));
    assert.equal(secondSocket.messages.filter(message => message.type === "clipboard.files.changed").length, 0);
    const replacement = { ...clipboard, offerId: "other-target", targetDeviceIds: [second.id] };
    await f.call("PUT", "/clipboard/files", replacement, source.token);
    await f.eventually(() => secondSocket.messages.some(message => message.type === "clipboard.files.changed"));
    assert.deepEqual((await f.call("GET", "/clipboard/files", undefined, first.token)).body.offers, []);
    assert.equal((await f.call("GET", "/clipboard/files", undefined, second.token)).body.offers.length, 1);
    assert.equal((await f.call("POST", `/clipboard/files/${source.id}/pull`,
      { offerId: replacement.offerId, requestId: "not-designated", itemIds: ["file"] }, first.token)).status, 403);
    assert.equal((await f.call("PUT", "/clipboard/files", { ...replacement, targetDeviceIds: [] }, source.token)).status, 400);
  } finally { await f.close(); }
});


test('exact copied context survives center restart and metadata requests never create content transfers',async()=>{
 const f=await fixture();try{
  const source=await f.enroll('source'),target=await f.enroll('target');await f.connect(source.token);await f.connect(target.token);
  await f.call('PUT','/clipboard/files',{...clipboard,targetDeviceIds:[target.id]},source.token);
  const metadata={offerId:clipboard.offerId,requestId:'manifest',itemIds:['folder'],metadataOnly:true};
  assert.equal((await f.call('POST',`/clipboard/files/${source.id}/pull`,metadata,target.token)).status,200);
  const entries=[{relativePath:'Course',kind:'directory',size:0},{relativePath:'Course/empty',kind:'directory',size:0},{relativePath:'Course/note.txt',kind:'file',size:7}];
  assert.equal((await f.call('PUT',`/clipboard/files/pulls/${target.id}/manifest`,{state:'sent',entries},source.token)).status,200);
  assert.deepEqual((await f.call('GET','/clipboard/files/pulls/manifest',undefined,target.token)).body.entries,entries);
  assert.deepEqual((await f.call('GET','/transfers',undefined,target.token)).body.transfers,[]);
  const offer={transferId:'context-transfer',targetDeviceId:target.id,files:[{fileId:'context-file',name:'picture.jpg',size:1024,mimeType:'image/jpeg',sha256:'0'.repeat(64)}],copiedFile:{requestId:'manifest',offerId:clipboard.offerId,itemId:'folder'}};
  assert.equal((await f.call('POST','/transfers',offer,source.token)).status,403);
  await f.call('POST',`/clipboard/files/${source.id}/pull`,{offerId:clipboard.offerId,requestId:'real-pull',itemIds:['file']},target.token);
  offer.copiedFile={requestId:'real-pull',offerId:clipboard.offerId,itemId:'file'};
  const offered=await f.call('POST','/transfers',offer,source.token);assert.equal(offered.status,201);assert.deepEqual(offered.body.transfer.copiedFile,offer.copiedFile);
  await f.restart();const restored=(await f.call('GET','/transfers',undefined,target.token)).body.transfers;assert.deepEqual(restored[0].copiedFile,offer.copiedFile);
  assert.equal((await f.call('POST','/transfers',offer,source.token)).status,200);
 }finally{await f.close();}
});
