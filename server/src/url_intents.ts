import { createHash } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import type { OpenUrlIntent, OpenUrlIntentRequest, OpenUrlIntentState, OpenUrlIntentResult } from "../../packages/protocol/src/index.ts";

type Row = Record<string, any>;
const terminal = new Set<OpenUrlIntentState>(["launch_accepted", "failed", "expired"]);
function reject(code: string, message: string, statusCode = 400): never {
  throw Object.assign(new Error(message), { code, statusCode });
}

/** A separate, durable command queue. Ordinary text/events never enter it. */
export class UrlIntents {
  constructor(private db: DatabaseSync, private now: () => number,
      private changed: (source: string, target: string) => void) {
    db.exec(`CREATE TABLE IF NOT EXISTS url_intents(
      source_device_id TEXT NOT NULL,request_id TEXT NOT NULL,target_device_id TEXT NOT NULL,
      group_id TEXT NOT NULL,caller_app_id TEXT NOT NULL,url TEXT,payload_digest TEXT NOT NULL,
      state TEXT NOT NULL,created INTEGER NOT NULL,expires INTEGER NOT NULL,updated INTEGER NOT NULL,
      error_code TEXT,error_message TEXT,PRIMARY KEY(source_device_id,request_id));
      CREATE INDEX IF NOT EXISTS url_intents_pending ON url_intents(target_device_id,state,expires);
      CREATE INDEX IF NOT EXISTS url_intents_expiry ON url_intents(expires) WHERE url IS NOT NULL;`);
  }
  private get(sql: string, ...args: any[]) { return this.db.prepare(sql).get(...args) as Row | undefined; }
  private all(sql: string, ...args: any[]) { return this.db.prepare(sql).all(...args) as Row[]; }
  private run(sql: string, ...args: any[]) { return this.db.prepare(sql).run(...args); }
  private find(source: string, request: string) { return this.get("SELECT * FROM url_intents WHERE source_device_id=? AND request_id=?", source, request); }
  private view(row: Row, includeUrl = false): OpenUrlIntent {
    return {
      requestId: row.request_id, sourceDeviceId: row.source_device_id, targetDeviceId: row.target_device_id,
      callerAppId: row.caller_app_id, state: row.state,
      createdAt: new Date(row.created).toISOString(), expiresAt: new Date(row.expires).toISOString(),
      updatedAt: new Date(row.updated).toISOString(),
      ...(includeUrl && row.url !== null ? { url: row.url } : {}),
      ...(row.error_code ? { error: { code: row.error_code, message: row.error_message } } : {}),
    };
  }
  private normalizedUrl(value: string) {
    if (value !== value.trim() || /[\x00-\x1f\x7f]/.test(value)) reject("invalid_url", "网页地址格式无效");
    let url: URL;
    try { url = new URL(value); } catch { reject("invalid_url", "网页地址格式无效"); }
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password)
      reject("invalid_url", "只支持不含账号信息的 HTTP(S) 网页");
    return url.href;
  }
  create(source: Row, body: OpenUrlIntentRequest) {
    this.cleanup();
    const url = this.normalizedUrl(body.url), lifetime = body.expiresInMs ?? 120000;
    // This fingerprint is the actual idempotency contract, retained after URL
    // erasure so an expired ID cannot be repurposed to launch another page.
    // TTL constrains first acceptance, not operation identity: a retry may have
    // waited in a cold-start queue, but must never extend the first deadline.
    const fingerprint = createHash("sha256").update(JSON.stringify([body.targetDeviceId, body.callerAppId, url])).digest("hex");
    const previous = this.find(source.id, body.requestId);
    if (previous) {
      if (previous.payload_digest !== fingerprint) reject("conflict", "此请求编号已用于不同的网页发送", 409);
      return this.view(previous);
    }
    const target = this.get("SELECT * FROM devices WHERE id=? AND group_id=? AND revoked=0", body.targetDeviceId, source.group_id);
    if (!target || target.id === source.id) reject("target_unavailable", "目标设备不在当前分组中", 404);
    if (!["windows", "android"].includes(target.platform) || !this.get("SELECT open_url_intent FROM device_capabilities WHERE device_id=?", target.id)?.open_url_intent)
      reject("unsupported_target", "目标设备尚不支持打开网页，请先更新 GlobalSend", 409);
    const now = this.now();
    this.run(`INSERT INTO url_intents(source_device_id,request_id,target_device_id,group_id,caller_app_id,url,payload_digest,state,created,expires,updated)
      VALUES(?,?,?,?,?,?,?,'queued',?,?,?)`, source.id, body.requestId, target.id, source.group_id, body.callerAppId, url, fingerprint, now, now + lifetime, now);
    this.changed(source.id, target.id);
    return this.view(this.find(source.id, body.requestId)!);
  }
  status(source: Row, requestId: string) {
    this.cleanup();
    const row = this.find(source.id, requestId);
    if (!row) reject("request_not_found", "未找到此网页发送请求", 404);
    return this.view(row);
  }
  pending(target: Row) {
    this.cleanup();
    return { intents: this.all("SELECT * FROM url_intents WHERE target_device_id=? AND state IN ('queued','delivered') AND expires>? ORDER BY created,source_device_id,request_id", target.id, this.now())
      .map(row => this.view(row, true)) };
  }
  result(target: Row, requestId: string, body: OpenUrlIntentResult) {
    this.cleanup();
    const row = this.find(body.sourceDeviceId, requestId);
    if (!row || row.target_device_id !== target.id) reject("request_not_found", "未找到发给本设备的网页请求", 404);
    // Retries and out-of-order acknowledgements never downgrade a completed
    // launch or turn a waiting-for-tap notice back into an auto-launch job.
    if (terminal.has(row.state) || row.state === body.state || row.state === "needs_tap" && body.state === "delivered") return this.view(row);
    const error = body.error ?? (body.state === "failed" ? { code: "launch_failed", message: "接收设备未能打开网页" } :
      body.state === "expired" ? { code: "expired", message: "打开请求已过期" } : undefined);
    this.run("UPDATE url_intents SET state=?,updated=?,error_code=?,error_message=? WHERE source_device_id=? AND request_id=?",
      body.state, this.now(), error?.code ?? null, error?.message ?? null, row.source_device_id, requestId);
    this.changed(row.source_device_id, row.target_device_id);
    return this.view(this.find(row.source_device_id, requestId)!);
  }
  cleanup() {
    const now = this.now();
    for (const row of this.all("SELECT * FROM url_intents WHERE state IN ('queued','delivered','needs_tap')")) {
      const source = this.get("SELECT group_id,revoked FROM devices WHERE id=?", row.source_device_id);
      const target = this.get("SELECT group_id,revoked FROM devices WHERE id=?", row.target_device_id);
      const unavailable = !source || !target || source.revoked || target.revoked || source.group_id !== row.group_id || target.group_id !== row.group_id;
      if (row.expires > now && !unavailable) continue;
      const state = row.expires <= now ? "expired" : "failed";
      this.run("UPDATE url_intents SET state=?,url=NULL,updated=?,error_code=?,error_message=? WHERE source_device_id=? AND request_id=?",
        state, now, unavailable && state !== "expired" ? "target_unavailable" : "expired",
        state === "expired" ? "打开请求已过期" : "设备已离开原分组或被撤销", row.source_device_id, row.request_id);
      this.changed(row.source_device_id, row.target_device_id);
    }
    // Keep only dedup/status tombstones after the deadline, including success.
    this.run("UPDATE url_intents SET url=NULL WHERE expires<=? AND url IS NOT NULL", now);
  }
}
