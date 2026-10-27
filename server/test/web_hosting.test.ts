import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { once } from "node:events";
import WebSocket from "ws";
import { buildApp } from "../src/server.js";

const root = fileURLToPath(new URL("../../artifacts/tmp/", import.meta.url));

// Real sockets exercise the single production listener, including its path prefix.
test("one center optionally serves Web without changing WS, text or file relay", async (t) => {
  const previous = process.env.WEB_ENABLED;
  const dir = await (async () => {
    await mkdir(root, { recursive: true });
    return mkdtemp(join(root, "web-hosting-"));
  })();
  const staticDir = join(dir, "web");
  await mkdir(join(staticDir, "assets"), { recursive: true });
  await writeFile(join(staticDir, "index.html"), '<!doctype html><script src="./assets/app.js"></script>');
  await writeFile(join(staticDir, "assets", "app.js"), 'document.title="GlobalSend";');
  t.diagnostic(`HTTP fixtures retained in ${dir}`);
  try {
    for (const mode of ["default", "true", "false"] as const) {
      if (mode === "default") delete process.env.WEB_ENABLED;
      else process.env.WEB_ENABLED = mode;
      await t.test(`WEB_ENABLED=${mode}`, async () => {
        const prefix = mode === "default" ? "" : "/globalsend";
        const app = await buildApp({
          dataDir: join(dir, mode), relayDir: join(dir, mode, "relay"),
          staticDir, diskReserve: 0, publicBaseUrl: `http://127.0.0.1${prefix}`,
        });
        const sockets: WebSocket[] = [];
        try {
          const origin = await app.listen({ host: "127.0.0.1", port: 0 });
          const base = `${origin}${prefix}`;
          const page = await fetch(`${base}/app/`);
          assert.equal(page.status, mode === "false" ? 404 : 200);
          const landing = await fetch(`${base}/`, { redirect: "manual" });
          assert.equal(landing.status, mode === "false" ? 404 : 302);
          if (mode !== "false") {
            assert.equal(landing.headers.get("location"), `${prefix}/app/`);
            const html = await page.text();
            const asset = new URL(/src="([^"]+)"/.exec(html)![1], `${base}/app/`);
            const script = await fetch(asset);
            assert.equal(script.status, 200);
            assert.equal(await script.text(), 'document.title="GlobalSend";');
          } else {
            assert.equal((await fetch(`${base}/app/assets/app.js`)).status, 404);
          }
          for (const path of ["/releases", "/releases/client.apk"]) {
            assert.equal((await fetch(`${base}${path}`, { headers: { Range: "bytes=0-8" } })).status, 410);
          }
          assert.equal((await fetch(`${base}/health/ready`)).status, 200);
          async function call(method: string, path: string, body?: unknown, token?: string) {
            const binary = Buffer.isBuffer(body);
            const response = await fetch(`${base}/api/v1${path}`, {
              method, headers: {
                ...(token ? { authorization: `Bearer ${token}` } : {}),
                ...(body !== undefined ? { "content-type": binary ? "application/octet-stream" : "application/json" } : {}),
              }, body: body === undefined ? undefined : binary ? Uint8Array.from(body) : JSON.stringify(body),
            });
            const result = await response.json();
            assert.ok(response.ok, `${method} ${path}: ${response.status} ${JSON.stringify(result)}`);
            return result;
          }
          const devices = [];
          for (const name of ["source", "receiver"]) {
            const enrolled = await call("POST", "/devices/enroll", { name, platform: "web", groupKey: "web-hosting-group" });
            const token = enrolled.deviceToken;
            const ticket = await call("POST", "/session/ws-ticket", {}, token);
            const socket = new WebSocket(`${base.replace(/^http/, "ws")}/api/v1/ws?ticket=${ticket.ticket}`);
            sockets.push(socket);
            const [hello] = await once(socket, "message");
            assert.equal(JSON.parse(hello.toString()).type, "hello");
            devices.push({ token, id: enrolled.device.deviceId });
          }
          const [source, receiver] = devices;
          const text = await call("POST", "/texts", { eventId: "hosting-text", targetDeviceId: receiver.id, text: "同一中心的文本" }, source.token);
          assert.equal(text.event.payload.text, "同一中心的文本");
          const events = await call("GET", "/events", undefined, receiver.token);
          assert.ok(events.events.some((event: any) => event.payload.text === "同一中心的文本"));
          const bytes = Buffer.from("同一中心的中继文件\n");
          await call("POST", "/transfers", {
            transferId: "hosting-file", targetDeviceId: receiver.id, routePreference: "relay",
            files: [{ fileId: "file", name: "示例.txt", mimeType: "text/plain", size: bytes.length,
              sha256: createHash("sha256").update(bytes).digest("hex") }],
          }, source.token);
          await call("POST", "/transfers/hosting-file/accept", { fileIds: ["file"] }, receiver.token);
          const path = "/transfers/hosting-file/files/file";
          await call("PUT", `${path}/chunks?offset=0`, bytes, source.token);
          await call("POST", `${path}/complete`, {}, source.token);
          const ticket = await call("POST", `${path}/download-ticket`, {}, receiver.token);
          const downloaded = await fetch(`${base}${ticket.downloadPath}`);
          assert.equal(downloaded.status, 200);
          assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), bytes);
          const receipt = await call("POST", `${path}/received`, { transport: "relay" }, receiver.token);
          assert.equal(receipt.file.status, "received");
        } finally {
          sockets.forEach(socket => socket.terminate());
          await app.close();
        }
      });
    }
    process.env.WEB_ENABLED = "false";
    const missingAssets = await buildApp({ dataDir: join(dir, "no-assets"), staticDir: join(dir, "absent"), diskReserve: 0 });
    try {
      const address = await missingAssets.listen({ host: "127.0.0.1", port: 0 });
      assert.equal((await fetch(`${address}/app/`)).status, 404);
      assert.equal((await fetch(`${address}/health/ready`)).status, 200);
    } finally { await missingAssets.close(); }
  } finally {
    if (previous === undefined) delete process.env.WEB_ENABLED;
    else process.env.WEB_ENABLED = previous;
  }
});
