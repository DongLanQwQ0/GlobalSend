import Fastify, { LogController, type FastifyRequest } from "fastify";
import websocket from "@fastify/websocket";
import staticFiles from "@fastify/static";
import { DatabaseSync } from "node:sqlite";
import {
  createHash,
  createHmac,
  randomBytes,
  randomUUID,
  X509Certificate,
} from "node:crypto";
import {
  mkdirSync,
  writeFileSync,
  existsSync,
  statSync,
  truncateSync,
  unlinkSync,
  openSync,
  closeSync,
  fsyncSync,
  writeSync,
  accessSync,
  constants,
} from "node:fs";
import { createReadStream } from "node:fs";
import { statfs, open } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type WebSocket } from "ws";
import { RtcRegistry, type RtcAttempt, type RtcScope } from "./rtc.ts";
import { RtcProbeRegistry } from "./rtc_probes.ts";
import { TextContents } from "./text_content.ts";
import {
  PROTOCOL_VERSION,
  DEFAULT_CHUNK_SIZE,
  MIN_GROUP_PASSWORD_LENGTH,
  PEER_TTL_SECONDS,
  ROUTE_PREFERENCES,
  fileOfferSchema,
  idPattern,
  type Event,
  type Transfer,
  type TransferFile,
  type RoutePreference,
  type Peer,
  type GroupSharedText,
} from "../../packages/protocol/src/index.ts";

type Row = Record<string, any>;
export interface Options {
  dataDir?: string;
  relayDir?: string;
  /** Retired compatibility input; never read or used for new enrollment. */
  bootstrapSecret?: string;
  publicBaseUrl?: string;
  production?: boolean;
  ttlSeconds?: number;
  totalQuota?: number;
  maxFileSize?: number;
  diskReserve?: number;
  log?: boolean;
  staticDir?: string;
  webEnabled?: boolean;
  /** Retired compatibility inputs; same-password enrollment is unconditional. */
  allowGroupCreation?: boolean;
  maxGroups?: number;
  maxDevicesPerGroup?: number;
  stunUrls?: string[];
  discoveryNow?: () => number;
}
const digest = (x: string | Buffer) =>
  createHash("sha256").update(x).digest("hex");
const secret = () => randomBytes(32).toString("base64url");
const iso = (n = Date.now()) => new Date(n).toISOString();
const id = { type: "string", pattern: idPattern };
function fail(code: string, message: string, statusCode = 400): never {
  throw Object.assign(new Error(message), { code, statusCode });
}
function numberEnv(name: string, fallback: number) {
  const n = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(n) || n < 0) throw new Error(`Invalid ${name}`);
  return n;
}
function filename(value: string) {
  if (
    !value.trim() ||
    /[\x00-\x1f\\/]/.test(value) ||
    value === "." ||
    value === ".."
  )
    fail(
      "INVALID_FILENAME",
      "File name must not contain paths or control characters",
    );
  return value;
}
function relativeFilename(value: string) {
  if (value.startsWith("/") || value.includes("\\") || value.split("/").some(part => !part || part === "." || part === ".." || /[\x00-\x1f:]/.test(part)))
    fail("INVALID_RELATIVE_PATH", "Folder entries require a relative path inside the selected root");
  return value;
}
function validateGroupKey(value: string) {
  if (
    value.length < MIN_GROUP_PASSWORD_LENGTH ||
    value.length > 256 ||
    value !== value.trim() ||
    /[\x00-\x1f\x7f]/.test(value)
  )
    fail(
      "INVALID_GROUP_KEY",
      "Group password must be 10–256 characters without edge whitespace or controls",
    );
  return value;
}
function parseSingleByteRange(header: string, size: number): { start: number; end: number } | null {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!match || (!match[1] && !match[2]) || size === 0) return null;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    return { start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = Number(match[1]), requestedEnd = match[2] ? Number(match[2]) : size - 1;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(requestedEnd) || start >= size || requestedEnd < start) return null;
  return { start, end: Math.min(requestedEnd, size - 1) };
}

export async function buildApp(options: Options = {}) {
  const discoveryNow = options.discoveryNow ?? Date.now;
  const stunUrls = options.stunUrls ?? (process.env.STUN_URLS ?? "").split(/[\s,]+/).filter(Boolean);
  if (stunUrls.some(value => !/^stuns?:[^\s/?#@]+(?:\?transport=(?:udp|tcp))?$/i.test(value)))
    throw new Error("STUN_URLS must contain only stun: or stuns: URLs");
  const iceServers = stunUrls.length ? [{ urls: stunUrls }] : [];
  const production =
    options.production ?? process.env.NODE_ENV === "production";
  const dataDir = resolve(options.dataDir ?? process.env.DATA_DIR ?? "./data");
  const relayDir = resolve(
    options.relayDir ?? process.env.RELAY_DIR ?? join(dataDir, "relay"),
  );
  mkdirSync(dataDir, { recursive: true });
  mkdirSync(relayDir, { recursive: true });
  const publicBase = options.publicBaseUrl ?? process.env.PUBLIC_BASE_URL ?? "";
  let prefix = "";
  if (publicBase) {
    const url = new URL(publicBase);
    if (
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      (production && url.protocol !== "https:")
    )
      throw new Error("Invalid PUBLIC_BASE_URL");
    prefix = url.pathname.replace(/\/+$/, "");
  }
  if (production && !publicBase)
    throw new Error("PUBLIC_BASE_URL is required in production");
  const limits = {
    chunkSize: DEFAULT_CHUNK_SIZE,
    maxFileSize:
      options.maxFileSize ?? numberEnv("MAX_FILE_SIZE", 2 * 1024 ** 3),
    totalQuota: options.totalQuota ?? numberEnv("TOTAL_QUOTA", 10 * 1024 ** 3),
    ttlSeconds: options.ttlSeconds ?? numberEnv("TTL_SECONDS", 86400),
    maxTextLength: 100000,
  };
  const enrollment = {
    mode: "group-password" as const,
    groupKey: true as const,
    legacyBootstrap: false,
    pairingCode: false,
    allowGroupCreation: true,
    minGroupKeyLength: MIN_GROUP_PASSWORD_LENGTH,
  };
  const diskReserve =
    options.diskReserve ?? numberEnv("DISK_RESERVE", 64 * 1024 ** 2);
  const app = Fastify({
    ajv: { customOptions: { removeAdditional: false } },
    logger:
      (options.log ?? production)
        ? {
            level: process.env.LOG_LEVEL || "info",
            redact: ["req.headers.authorization"],
          }
        : false,
    logController: new LogController({ disableRequestLogging: true }),
    bodyLimit: limits.chunkSize,
  });
  app.setErrorHandler((error: any, _req, reply) => {
    const status = error.statusCode ?? 500;
    if (status >= 500)
      app.log.error({ code: error.code ?? "INTERNAL" }, "request failed");
    reply.code(status).send({
      error: {
        code: error.validation
          ? "VALIDATION_ERROR"
          : (error.code ?? "INTERNAL"),
        message: status >= 500 ? "Internal server error" : error.message,
      },
    });
  });
  app.addHook("onResponse", (req, reply, done) => {
    app.log.info(
      { method: req.method, statusCode: reply.statusCode },
      "request completed",
    );
    done();
  });
  app.addHook("onSend", async (req, reply, payload) => {
    if (req.url.startsWith(`${prefix}/api/`))
      reply.header("Cache-Control", "no-store");
    return payload;
  });
  const db = new DatabaseSync(join(dataDir, "globalsend.sqlite"));
  if (
    ((db.prepare("PRAGMA user_version").get() as Row)?.user_version ?? 0) > 3
  ) {
    db.close();
    throw new Error(
      "Database schema is newer than this server; restore the matching release or backup",
    );
  }
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
    CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,group_id TEXT NOT NULL,name TEXT NOT NULL,platform TEXT NOT NULL,token TEXT NOT NULL UNIQUE,revoked INTEGER NOT NULL DEFAULT 0,created TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS invites(code TEXT PRIMARY KEY,group_id TEXT NOT NULL,issuer TEXT NOT NULL,expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS events(cursor INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,type TEXT NOT NULL,source TEXT NOT NULL,target TEXT NOT NULL,created TEXT NOT NULL,expires INTEGER NOT NULL,payload TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS events_target ON events(target,cursor);
    CREATE TABLE IF NOT EXISTS text_acks(id TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS peers(device_id TEXT PRIMARY KEY,data TEXT NOT NULL,expires INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS pending_deletes(path TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY,created TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS group_shared_text(group_id TEXT PRIMARY KEY,text TEXT NOT NULL,revision INTEGER NOT NULL,updated_at TEXT NOT NULL,updated_by TEXT NOT NULL,mutation_id TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS group_keys(key_hash TEXT PRIMARY KEY,group_id TEXT NOT NULL,state TEXT NOT NULL,created TEXT NOT NULL,retired TEXT);
    CREATE UNIQUE INDEX IF NOT EXISTS active_group_key ON group_keys(group_id) WHERE state='active';
    CREATE TABLE IF NOT EXISTS transfers(id TEXT PRIMARY KEY,source TEXT NOT NULL,target TEXT NOT NULL,created TEXT NOT NULL,expires INTEGER NOT NULL,offer TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS device_capabilities(device_id TEXT PRIMARY KEY,folder_transfer INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS files(transfer_id TEXT NOT NULL,id TEXT NOT NULL,name TEXT NOT NULL,size INTEGER NOT NULL,mime TEXT NOT NULL,sha TEXT NOT NULL,status TEXT NOT NULL,offset INTEGER NOT NULL DEFAULT 0,attempt TEXT NOT NULL,error TEXT,path TEXT NOT NULL,PRIMARY KEY(transfer_id,id),FOREIGN KEY(transfer_id) REFERENCES transfers(id));
    `);
  if (
    !(db.prepare("PRAGMA table_info(files)").all() as Row[]).some(
      (c) => c.name === "transport",
    )
  )
    db.exec("ALTER TABLE files ADD COLUMN transport TEXT");
  const fileColumns = (db.prepare("PRAGMA table_info(files)").all() as Row[]).map(column => column.name);
  if (!fileColumns.includes("relative_path")) db.exec("ALTER TABLE files ADD COLUMN relative_path TEXT");
  if (!fileColumns.includes("entry_kind")) db.exec("ALTER TABLE files ADD COLUMN entry_kind TEXT");
  if (!fileColumns.includes("receive_failure")) db.exec("ALTER TABLE files ADD COLUMN receive_failure TEXT");
  if (!fileColumns.includes("reused_at")) db.exec("ALTER TABLE files ADD COLUMN reused_at TEXT");
  db.exec("PRAGMA user_version=3");
  const get = (sql: string, ...args: any[]) =>
    db.prepare(sql).get(...args) as Row | undefined;
  const all = (sql: string, ...args: any[]) =>
    db.prepare(sql).all(...args) as Row[];
  const run = (sql: string, ...args: any[]) => db.prepare(sql).run(...args);
  const tx = <T>(fn: () => T) => {
    db.exec("BEGIN IMMEDIATE");
    try {
      const result = fn();
      db.exec("COMMIT");
      return result;
    } catch (e) {
      db.exec("ROLLBACK");
      throw e;
    }
  };
  const textContents = new TextContents(db);
  run(
    "INSERT OR IGNORE INTO groups(id,created) SELECT group_id,MIN(created) FROM devices GROUP BY group_id",
  );
  if (!get("SELECT value FROM meta WHERE key=?", "groupIndexSecret"))
    run("INSERT INTO meta VALUES(?,?)", "groupIndexSecret", secret());
  const groupIndexSecret = get(
    "SELECT value FROM meta WHERE key=?",
    "groupIndexSecret",
  )!.value;
  const groupKeyHash = (value: string) =>
    createHmac("sha256", groupIndexSecret).update(value, "utf8").digest("hex");
  if (!get("SELECT value FROM meta WHERE key=?", "instanceId"))
    run("INSERT INTO meta VALUES(?,?)", "instanceId", randomUUID());
  const instanceId = get(
    "SELECT value FROM meta WHERE key=?",
    "instanceId",
  )!.value;
  const sessions = new Map<string, Set<WebSocket>>();
  const tickets = new Map<string, { deviceId: string; expires: number }>();
  const downloads = new Map<
    string,
    { deviceId: string; transferId: string; fileId: string; expires: number }
  >();
  const directTickets = new Map<
    string,
    { deviceId: string; transferId: string; fileId: string; expires: number; direction?: "push"; attemptId?: string }
  >();
  type PushAttempt = {
    attemptId: string; scope: "lan" | "public"; cellular: boolean; offset: number;
    expires: number; state: "waiting" | "streaming" | "failed"; error?: string;
  };
  const directPushes = new Map<string, PushAttempt>();
  const peerAnnouncements = new Map<string, { data: Omit<Peer, "expiresAt">; expires: number }>();
  const rtc = new RtcRegistry(discoveryNow);
  const rtcProbes = new RtcProbeRegistry(discoveryNow);
  function rtcChanged(attempt: RtcAttempt) {
    const value = { type: "rtc.changed", transferId: attempt.transferId, fileId: attempt.fileId, attemptId: attempt.attemptId };
    send(attempt.sourceDeviceId, value);
    if (attempt.targetDeviceId !== attempt.sourceDeviceId) send(attempt.targetDeviceId, value);
  }
  function clearDirect(transferId: string, fileId: string, preserveRtc = false) {
    if (!preserveRtc) {
      const attempt = rtc.current(transferId, fileId);
      rtc.clear(transferId, fileId);
      if (attempt) rtcChanged(attempt);
    }
    directPushes.delete(`${transferId}/${fileId}`);
    for (const [key, ticket] of directTickets)
      if (ticket.transferId === transferId && ticket.fileId === fileId) directTickets.delete(key);
  }
  const online = (deviceId: string) => (sessions.get(deviceId)?.size ?? 0) > 0;
  function requireOnline(deviceId: string) {
    if (!online(deviceId)) fail("DEVICE_OFFLINE", "Device is offline; reconnect before exchanging addresses", 409);
  }
  function requireOnlinePeers(t: Row) { requireOnline(t.source); requireOnline(t.target); }
  const peerView = (deviceId: string) => {
    if (!online(deviceId)) return null;
    const peer = peerAnnouncements.get(deviceId);
    return peer && peer.expires > discoveryNow()
      ? { ...peer.data, expiresAt: iso(peer.expires) }
      : null;
  };
  const deviceView = (d: Row) => ({
    deviceId: d.id,
    groupId: d.group_id,
    name: d.name,
    platform: d.platform,
    online: online(d.id),
    revoked: Boolean(d.revoked),
    createdAt: d.created,
    peer: d.revoked ? null : peerView(d.id),
    rtc: d.revoked || !online(d.id) ? null : rtc.capability(d.id),
    folderTransfer: Boolean(get("SELECT folder_transfer FROM device_capabilities WHERE device_id=?", d.id)?.folder_transfer),
  });
  function device(req: FastifyRequest) {
    const value = req.headers.authorization;
    if (!value?.startsWith("Bearer "))
      fail("UNAUTHORIZED", "Device authentication required", 401);
    const d = get(
      "SELECT * FROM devices WHERE token=? AND revoked=0",
      digest(value.slice(7)),
    );
    if (!d) fail("UNAUTHORIZED", "Invalid or revoked device token", 401);
    return d;
  }
  function target(source: Row, targetId: string) {
    const d = get(
      "SELECT * FROM devices WHERE id=? AND group_id=? AND revoked=0",
      targetId,
      source.group_id,
    );
    if (!d) fail("FORBIDDEN", "Target device unavailable", 403);
    return d;
  }
  function send(deviceId: string, value: unknown) {
    for (const socket of sessions.get(deviceId) ?? [])
      if (socket.readyState === 1) socket.send(JSON.stringify(value));
  }
  let closing = false;
  function presence(d: Row, active: boolean) {
    if (closing) return;
    for (const peer of all(
      "SELECT id FROM devices WHERE group_id=? AND revoked=0",
      d.group_id,
    ))
      send(peer.id, { type: "presence", deviceId: d.id, online: active });
  }
  function devicesChanged(groupId: string) {
    for (const peer of all("SELECT id FROM devices WHERE group_id=? AND revoked=0", groupId))
      send(peer.id, { type: "devices.changed" });
  }
  function clearPeerAddresses(deviceId: string) {
    peerAnnouncements.delete(deviceId);
    for (const t of all("SELECT * FROM transfers WHERE source=? OR target=?", deviceId, deviceId))
      for (const f of all("SELECT id FROM files WHERE transfer_id=? AND status='accepted'", t.id))
        clearDirect(t.id, f.id, true);
  }
  function clearDeviceDiscovery(deviceId: string) {
    clearPeerAddresses(deviceId);
    for (const attempt of rtc.forgetDevice(deviceId)) rtcChanged(attempt);
    probesChanged(rtcProbes.forgetDevice(deviceId), true);
  }
  function probesChanged(deviceIds: string[], groupWide = false) {
    if (!groupWide) { for (const deviceId of new Set(deviceIds)) send(deviceId, { type: "rtc.probes.changed" }); return; }
    const groups = new Set<string>();
    for (const deviceId of deviceIds) {
      const d = get("SELECT group_id FROM devices WHERE id=?", deviceId);
      if (d) groups.add(d.group_id);
    }
    for (const groupId of groups) for (const peer of all("SELECT id FROM devices WHERE group_id=? AND revoked=0", groupId))
      send(peer.id, { type: "rtc.probes.changed" });
  }
  function cleanupProbes() {
    const changed = rtcProbes.cleanup((deviceId, scope) => online(deviceId) && Boolean(rtc.capability(deviceId)?.scopes.includes(scope)));
    probesChanged(changed.changed); probesChanged(changed.presenceChanged, true);
  }
  function cleanupDiscovery() {
    const changedGroups = new Set<string>();
    for (const [deviceId, peer] of peerAnnouncements) if (peer.expires <= discoveryNow()) {
      clearPeerAddresses(deviceId);
      const d = get("SELECT group_id FROM devices WHERE id=?", deviceId);
      if (d) changedGroups.add(d.group_id);
    }
    const expired = rtc.cleanup();
    for (const deviceId of expired.devices) {
      const d = get("SELECT group_id FROM devices WHERE id=?", deviceId);
      if (d) changedGroups.add(d.group_id);
    }
    for (const attempt of expired.attempts) rtcChanged(attempt);
    for (const groupId of changedGroups) devicesChanged(groupId);
  }
  // Legacy versions persisted peer IPs. New announcements live only in memory;
  // a restart requires online clients to publish again, not to enroll again.
  run("DELETE FROM peers");
  const eventView = (r: Row): Event => ({
    cursor: r.cursor,
    protocolVersion: PROTOCOL_VERSION,
    eventId: r.id,
    type: r.type,
    sourceDeviceId: r.source,
    targetDeviceId: r.target,
    createdAt: r.created,
    expiresAt: iso(r.expires),
    payload: JSON.parse(r.payload),
  });
  function emit(
    type: string,
    source: string,
    dest: string,
    payload: unknown,
    eventId = randomUUID(),
    ttlSeconds = limits.ttlSeconds,
  ): Event {
    run(
      "INSERT INTO events(id,type,source,target,created,expires,payload) VALUES(?,?,?,?,?,?,?)",
      eventId,
      type,
      source,
      dest,
      iso(),
      Date.now() + Math.min(ttlSeconds, limits.ttlSeconds) * 1000,
      JSON.stringify(payload),
    );
    const e = eventView(get("SELECT * FROM events WHERE id=?", eventId)!);
    send(source, { type: "event", event: e });
    if (dest !== source) send(dest, { type: "event", event: e });
    return e;
  }
  const fileView = (f: Row): TransferFile => ({
    fileId: f.id,
    name: f.name,
    size: f.size,
    mimeType: f.mime,
    sha256: f.sha,
    ...(f.relative_path ? { relativePath: f.relative_path, entryKind: f.entry_kind ?? "file" } : {}),
    status: f.status,
    offset: f.offset,
    attemptId: f.attempt,
    errorCode: f.error ?? null,
    receiveFailure: Boolean(f.receive_failure),
    ...(f.reused_at ? { reused: true, receivedAt: f.reused_at } : {}),
    transport: f.transport ?? null,
    ...(() => {
      const push = directPushes.get(`${f.transfer_id}/${f.id}`);
      if (!push || push.expires <= Date.now() || f.status !== "accepted" || f.transport !== "direct") return {};
      const { expires, ...value } = push;
      return { directPush: { ...value, expiresAt: iso(expires) } };
    })(),
    ...(() => {
      const attempt = rtc.current(f.transfer_id, f.id);
      return attempt && f.status === "accepted" && f.transport === "direct" ? { rtc: rtc.summary(attempt) } : {};
    })(),
  });
  // The canonical offer is already durable. Default auto keeps the original
  // JSON shape, so old offers and their idempotent retries need no migration.
  const transferRoute = (t: Row): RoutePreference => JSON.parse(t.offer).routePreference ?? "auto";
  function allowTransport(t: Row, transport: "relay" | "direct") {
    const preference = transferRoute(t);
    const directOnly = preference === "lan" || preference === "public";
    if ((transport === "direct" && preference === "relay") || (transport === "relay" && directOnly))
      fail("ROUTE_NOT_ALLOWED", `Sender selected ${preference}; this transfer cannot use ${transport}`, 409);
  }
  const transferView = (t: Row): Transfer => ({
    transferId: t.id,
    sourceDeviceId: t.source,
    targetDeviceId: t.target,
    createdAt: t.created,
    expiresAt: iso(t.expires),
    routePreference: transferRoute(t),
    files: all(
      "SELECT * FROM files WHERE transfer_id=? ORDER BY rowid",
      t.id,
    ).map(fileView),
  });
  function transfer(d: Row, transferId: string) {
    if (!get("SELECT id FROM devices WHERE id=? AND revoked=0", d.id))
      fail("UNAUTHORIZED", "Device revoked", 401);
    const t = get(
      "SELECT * FROM transfers WHERE id=? AND (source=? OR target=?)",
      transferId,
      d.id,
      d.id,
    );
    if (!t) fail("NOT_FOUND", "Transfer not found", 404);
    if (t.expires <= Date.now()) fail("EXPIRED", "Transfer expired", 410);
    const peer = t.source === d.id ? t.target : t.source;
    target(d, peer);
    return t;
  }
  function file(t: Row, fileId: string) {
    const f = get(
      "SELECT * FROM files WHERE transfer_id=? AND id=?",
      t.id,
      fileId,
    );
    if (!f) fail("NOT_FOUND", "File not found", 404);
    return f;
  }
  function role(d: Row, t: Row, which: "source" | "target") {
    if (d.id !== t[which])
      fail("FORBIDDEN", "This operation belongs to the other participant", 403);
  }
  const changed = (t: Row) =>
    emit("transfer.updated", t.source, t.target, { transferId: t.id, routePreference: transferRoute(t) });
  const streams = new Map<string, Set<ReturnType<typeof createReadStream>>>();
  const pendingDeletes = new Set<string>(
    all("SELECT path FROM pending_deletes").map((r) => r.path),
  );
  function removeBytes(f: Row) {
    for (const stream of streams.get(f.path) ?? []) stream.destroy();
    try {
      unlinkSync(f.path);
      pendingDeletes.delete(f.path);
      run("DELETE FROM pending_deletes WHERE path=?", f.path);
    } catch (e: any) {
      if (["EBUSY", "EPERM"].includes(e.code)) {
        pendingDeletes.add(f.path);
        run("INSERT OR IGNORE INTO pending_deletes VALUES(?)", f.path);
      } else if (e.code !== "ENOENT") throw e;
    }
  }
  function cancelFile(f: Row, state = "canceled", error: string | null = null) {
    clearDirect(f.transfer_id, f.id);
    removeBytes(f);
    run(
      "UPDATE files SET status=?,offset=0,error=?,receive_failure=NULL WHERE transfer_id=? AND id=?",
      state,
      error,
      f.transfer_id,
      f.id,
    );
    for (const [key, ticket] of downloads)
      if (ticket.transferId === f.transfer_id && ticket.fileId === f.id)
        downloads.delete(key);
    for (const [key, ticket] of directTickets)
      if (ticket.transferId === f.transfer_id && ticket.fileId === f.id)
        directTickets.delete(key);
  }
  const reserved = () =>
    get(
      "SELECT COALESCE(SUM(size),0) AS n FROM files WHERE (status IN ('offered','accepted','uploading','ready','received') OR (status='failed' AND receive_failure IS NOT NULL)) AND NOT (status='received' AND COALESCE(transport,'relay')='direct')",
    )!.n as number;
  async function space(bytes: number) {
    if (reserved() + bytes > limits.totalQuota)
      fail("QUOTA_EXCEEDED", "Relay storage quota exceeded", 507);
    const s = await statfs(relayDir);
    if (s.bavail * s.bsize < bytes + diskReserve)
      fail("DISK_FULL", "Insufficient relay disk space", 507);
  }
  function cleanup() {
    const now = Date.now();
    cleanupDiscovery();
    for (const f of all(
      "SELECT files.* FROM files JOIN transfers ON transfers.id=files.transfer_id WHERE transfers.expires<=? AND files.status NOT IN ('expired','canceled','rejected')",
      now,
    ))
      cancelFile(f, "expired");
    run("DELETE FROM invites WHERE expires<=?", now);
    run("DELETE FROM events WHERE expires<=?", now);
    run("DELETE FROM text_acks WHERE id NOT IN (SELECT id FROM events)");
    for (const path of pendingDeletes) {
      try {
        unlinkSync(path);
        pendingDeletes.delete(path);
        run("DELETE FROM pending_deletes WHERE path=?", path);
      } catch (e: any) {
        if (e.code === "ENOENT") {
          pendingDeletes.delete(path);
          run("DELETE FROM pending_deletes WHERE path=?", path);
        }
      }
    }
    for (const [key, t] of tickets) if (t.expires <= now) tickets.delete(key);
    for (const [key, t] of downloads)
      if (t.expires <= now) downloads.delete(key);
    for (const [key, t] of directTickets)
      if (t.expires <= now) directTickets.delete(key);
    for (const [key, t] of directPushes)
      if (t.expires <= now) directPushes.delete(key);
  }
  cleanup();
  for (const f of all(
    "SELECT * FROM files WHERE (status IN ('accepted','uploading','ready','received') OR (status='failed' AND receive_failure IS NOT NULL)) AND COALESCE(transport,'relay') != 'direct'",
  )) {
    const length = existsSync(f.path) ? statSync(f.path).size : 0;
    if (length < f.offset) cancelFile(f, "failed", "STORAGE_LOST");
    else if (length > f.offset) truncateSync(f.path, f.offset);
  }
  const timer = setInterval(() => {
    try {
      cleanup();
    } catch (e: any) {
      app.log.error(
        { code: e.code ?? "CLEANUP_FAILED" },
        "Relay cleanup failed",
      );
    }
  }, 30000);
  timer.unref();
  await app.register(websocket, { options: { maxPayload: 4096 } });
  app.addContentTypeParser(
    "application/octet-stream",
    { parseAs: "buffer" },
    (_req, body, done) => done(null, body),
  );
  const api = `${prefix}/api/v1`;
  const health = () => {
    get("SELECT 1");
    accessSync(dataDir, constants.W_OK);
    accessSync(relayDir, constants.W_OK);
    return { ok: true };
  };
  app.get(`${prefix}/health/live`, async () => ({ ok: true }));
  app.get(`${prefix}/health/ready`, async () => health());
  app.get(`${api}/info`, async () => ({
    protocolVersion: 1,
    instanceId,
    name: process.env.SERVER_NAME || "GlobalSend",
    limits,
    enrollment,
    features: { relay: true, direct: true, routePreference: true, directPush: true, rtcDataChannels: true, rtcProbes: true, rtcProbeAddresses: true, groupSharedText: true, discoveryRefresh: true, folderTransfer: true, textContentSync: true, receiveErrorReporting: true, fileReuse: true },
    rtc: { iceServers },
    discovery: { onlineOnly: true, peerTtlSeconds: PEER_TTL_SECONDS },
  }));
  app.post(
    `${api}/devices/enroll`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["name", "platform"],
          properties: {
            name: { type: "string", minLength: 1, maxLength: 80 },
            platform: { enum: ["windows", "android", "web", "other"] },
            bootstrapSecret: { type: "string", maxLength: 200 },
            pairingCode: { type: "string", maxLength: 20 },
            groupKey: { type: "string", minLength: MIN_GROUP_PASSWORD_LENGTH, maxLength: 256 },
          },
        },
      },
    },
    async (req, reply) => {
      const b = req.body as any;
      if (typeof b.groupKey !== "string")
        fail("GROUP_PASSWORD_REQUIRED", "Use a group password of at least 10 characters; invitation and bootstrap enrollment are retired", 410);
      validateGroupKey(b.groupKey);
      const token = secret(),
        deviceId = randomUUID();
      let groupId: string,
        createdGroup = false;
      tx(() => {
        const index = groupKeyHash(b.groupKey),
          group = get("SELECT * FROM group_keys WHERE key_hash=?", index);
        if (group?.state === "retired")
          fail("GROUP_KEY_RETIRED", "This group password was changed; obtain the current password", 403);
        if (group) groupId = group.group_id;
        else {
          groupId = randomUUID();
          createdGroup = true;
          run("INSERT INTO groups VALUES(?,?)", groupId, iso());
          run("INSERT INTO group_keys VALUES(?,?,?, ?,NULL)", index, groupId, "active", iso());
        }
        run(
          "INSERT INTO devices(id,group_id,name,platform,token,created) VALUES(?,?,?,?,?,?)",
          deviceId,
          groupId,
          b.name.trim() || "Device",
          b.platform,
          digest(token),
          iso(),
        );
      });
      reply.code(201);
      return {
        deviceToken: token,
        groupId: groupId!,
        createdGroup,
        device: deviceView(get("SELECT * FROM devices WHERE id=?", deviceId)!),
      };
    },
  );
  const rotations = new Map<string, { count: number; reset: number }>();
  app.post(
    `${api}/groups/key`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          properties: {
            newGroupKey: { type: "string", minLength: MIN_GROUP_PASSWORD_LENGTH, maxLength: 256 },
          },
        },
      },
    },
    async (req) => {
      const d = device(req),
        groupKey = validateGroupKey((req.body as any)?.newGroupKey ?? secret()),
        index = groupKeyHash(groupKey);
      let rotatedAt = iso();
      let budget = rotations.get(d.group_id);
      if (!budget || budget.reset <= Date.now()) {
        budget = { count: 0, reset: Date.now() + 3600000 };
        rotations.set(d.group_id, budget);
      }
      if (++budget.count > 10)
        fail("RATE_LIMITED", "Too many group key rotations; wait an hour", 429);
      tx(() => {
        const old = get("SELECT * FROM group_keys WHERE key_hash=?", index);
        if (old && old.group_id === d.group_id && old.state === "active") {
          rotatedAt = old.created;
          return;
        }
        if (old)
          fail(
            "GROUP_KEY_UNAVAILABLE",
            "Group key is already assigned or retired",
            409,
          );
        run(
          "UPDATE group_keys SET state='retired',retired=? WHERE group_id=? AND state='active'",
          rotatedAt,
          d.group_id,
        );
        run(
          "INSERT INTO group_keys VALUES(?,?,?, ?,NULL)",
          index,
          d.group_id,
          "active",
          rotatedAt,
        );
        run("DELETE FROM invites WHERE group_id=?", d.group_id);
      });
      return { groupId: d.group_id, groupKey, rotatedAt };
    },
  );
  app.post(`${api}/pairing-codes`, async (req) => {
    device(req);
    fail("GROUP_PASSWORD_REQUIRED", "Invitations are retired; use the same group password", 410);
  });
  function sharedText(groupId: string): GroupSharedText {
    const row = get("SELECT * FROM group_shared_text WHERE group_id=?", groupId);
    return row ? {
      text: row.text, revision: row.revision, updatedAt: row.updated_at,
      updatedBy: row.updated_by, mutationId: row.mutation_id,
    } : { text: "", revision: 0, updatedAt: "", updatedBy: "", mutationId: "" };
  }
  app.get(`${api}/group/shared-text`, async req => sharedText(device(req).group_id));
  app.put(`${api}/group/shared-text`, {
    schema: { body: {
      type: "object", additionalProperties: false,
      required: ["text", "baseRevision", "mutationId"],
      properties: {
        text: { type: "string", maxLength: limits.maxTextLength },
        baseRevision: { type: "integer", minimum: 0 },
        mutationId: id,
      },
    } },
  }, async (req, reply) => {
    const d = device(req), body = req.body as { text: string; baseRevision: number; mutationId: string };
    const result = tx(() => {
      const current = sharedText(d.group_id);
      // A lost HTTP response can be retried without making another revision.
      if (current.mutationId === body.mutationId && current.updatedBy === d.id && current.text === body.text)
        return { current, changed: false, conflict: false };
      if (current.revision !== body.baseRevision)
        return { current, changed: false, conflict: true };
      if (current.text === body.text) return { current, changed: false, conflict: false };
      const next: GroupSharedText = { text: body.text, revision: current.revision + 1,
        updatedAt: iso(), updatedBy: d.id, mutationId: body.mutationId };
      run(`INSERT INTO group_shared_text(group_id,text,revision,updated_at,updated_by,mutation_id)
        VALUES(?,?,?,?,?,?) ON CONFLICT(group_id) DO UPDATE SET
        text=excluded.text,revision=excluded.revision,updated_at=excluded.updated_at,
        updated_by=excluded.updated_by,mutation_id=excluded.mutation_id`,
        d.group_id, next.text, next.revision, next.updatedAt, next.updatedBy, next.mutationId);
      return { current: next, changed: true, conflict: false };
    });
    if (result.conflict) return reply.code(409).send({
      error: { code: "SHARED_TEXT_CONFLICT", message: "共享内容已更新" }, current: result.current,
    });
    if (result.changed) for (const peer of all("SELECT id FROM devices WHERE group_id=? AND revoked=0", d.group_id))
      send(peer.id, { type: "sharedText.updated", ...result.current });
    return result.current;
  });
  app.get(`${api}/devices`, async (req) => {
    const d = device(req);
    cleanupDiscovery();
    return {
      devices: all(
        "SELECT * FROM devices WHERE group_id=? AND revoked=0 ORDER BY created",
        d.group_id,
      ).filter(row => row.id === d.id || online(row.id)).map(deviceView),
    };
  });
  app.post(`${api}/devices/me/capabilities`, {
    schema: { body: { type: "object", additionalProperties: false, required: ["folderTransfer"], properties: { folderTransfer: { type: "boolean" } } } },
  }, async req => {
    const d = device(req), enabled = (req.body as {folderTransfer:boolean}).folderTransfer;
    const previous = get("SELECT folder_transfer FROM device_capabilities WHERE device_id=?", d.id)?.folder_transfer ?? 0;
    run("INSERT INTO device_capabilities(device_id,folder_transfer) VALUES(?,?) ON CONFLICT(device_id) DO UPDATE SET folder_transfer=excluded.folder_transfer", d.id, enabled ? 1 : 0);
    if (Boolean(previous) !== enabled) for (const peer of all("SELECT id FROM devices WHERE group_id=? AND revoked=0", d.group_id)) send(peer.id, {type:"devices.changed"});
    return {device:deviceView(d)};
  });
  app.patch(`${api}/devices/me`, {
    schema: {
      body: {
        type: "object", additionalProperties: false, required: ["name"],
        properties: { name: { type: "string", minLength: 1, maxLength: 80 } },
      },
    },
  }, async (req) => {
    const d = device(req), name = (req.body as { name: string }).name.trim();
    if (!name) fail("INVALID_DEVICE_NAME", "Device name must not be blank");
    run("UPDATE devices SET name=? WHERE id=?", name, d.id);
    for (const peer of all("SELECT id FROM devices WHERE group_id=? AND revoked=0", d.group_id)) {
      send(peer.id, { type: "devices.changed" });
    }
    return { device: deviceView(get("SELECT * FROM devices WHERE id=?", d.id)!) };
  });
  app.post(`${api}/devices/me/rtc`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["scopes"],
    properties: { scopes: { type: "array", maxItems: 2, uniqueItems: true, items: { enum: ["lan", "public"] } }, refresh: { type: "boolean" } },
  } } }, async (req) => {
    const d = device(req), body = req.body as { scopes: RtcScope[]; refresh?: boolean }, scopes = body.scopes;
    requireOnline(d.id);
    if (rtc.register(d.id, scopes) || body.refresh === true) {
      for (const peer of all("SELECT id FROM devices WHERE group_id=? AND revoked=0", d.group_id))
        send(peer.id, { type: "devices.changed" });
    }
    cleanupProbes();
    return { rtc: rtc.capability(d.id) };
  });
  app.post(`${api}/devices/me/rtc-probes/presence`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["foreground"], properties: { foreground: { type: "boolean" } },
  } } }, async (req) => {
    const d = device(req); requireOnline(d.id); cleanupProbes();
    probesChanged(rtcProbes.setPresence(d.id, (req.body as { foreground: boolean }).foreground), true);
    return { presence: rtcProbes.presence(d.id) };
  });
  app.get(`${api}/devices/me/rtc-probes`, async (req) => {
    const d = device(req); cleanupProbes();
    const ownScopes = rtc.capability(d.id)?.scopes ?? [];
    const peers = !online(d.id) || !rtcProbes.presence(d.id).foreground ? [] : all("SELECT id,platform FROM devices WHERE group_id=? AND revoked=0 AND id<>?", d.group_id, d.id)
      .filter(peer => online(peer.id) && rtcProbes.presence(peer.id).foreground)
      .map(peer => ({ deviceId: peer.id, scopes: (rtc.capability(peer.id)?.scopes ?? []).filter(scope => ownScopes.includes(scope)), foregroundExpiresAt: rtcProbes.presence(peer.id).expiresAt! }))
      .filter(peer => peer.scopes.length > 0);
    return { ...rtcProbes.snapshot(d.id), peers };
  });
  app.post(`${api}/devices/:peerId/rtc-probes`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["attemptId", "scope"], properties: { attemptId: id, scope: { enum: ["lan", "public"] } },
  } } }, async (req) => {
    const d = device(req), peer = target(d, (req.params as any).peerId), b = req.body as { attemptId: string; scope: RtcScope };
    cleanupProbes(); requireOnline(d.id); requireOnline(peer.id);
    for (const participant of [d, peer]) if (!rtc.capability(participant.id)?.scopes.includes(b.scope)) fail("RTC_UNAVAILABLE", "Both devices must support this WebRTC scope", 409);
    const probe = rtcProbes.create(d.id, peer.id, b.attemptId, b.scope); probesChanged([d.id, peer.id]); return { probe };
  });
  const probePath = `${api}/rtc-probes/:probeAttemptId`;
  function probeRequest(req: FastifyRequest) {
    const d = device(req); cleanupProbes();
    const probe = rtcProbes.require((req.params as any).probeAttemptId, d.id);
    return { d, probe };
  }
  app.get(probePath, async req => ({ probe: probeRequest(req).probe }));
  app.post(`${probePath}/description`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["type", "sdp"],
    properties: { type: { enum: ["offer", "answer"] }, sdp: { type: "string", minLength: 1, maxLength: 65536 } },
  } } }, async req => {
    const { d, probe } = probeRequest(req), b = req.body as { type: "offer" | "answer"; sdp: string };
    rtcProbes.describe(probe, d.id, b.type, b.sdp); probesChanged([probe.initiatorDeviceId, probe.responderDeviceId]); return { probe };
  });
  app.post(`${probePath}/candidate`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["candidate", "sdpMid", "sdpMLineIndex"],
    properties: { candidate: { type: "string", minLength: 1, maxLength: 4096 },
      sdpMid: { anyOf: [{ type: "string", maxLength: 256 }, { type: "null" }] },
      sdpMLineIndex: { anyOf: [{ type: "integer", minimum: 0, maximum: 65535 }, { type: "null" }] } },
  } } }, async req => {
    const { d, probe } = probeRequest(req); rtcProbes.candidate(probe, d.id, req.body as any);
    probesChanged([probe.initiatorDeviceId, probe.responderDeviceId]); return { probe };
  });
  app.post(`${probePath}/complete`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["elapsedMs"], properties: {
      elapsedMs: { type: "number", minimum: 0, maximum: 12000 },
      initiatorAddress: { type: "string", minLength: 1, maxLength: 512 },
      responderAddress: { type: "string", minLength: 1, maxLength: 512 },
    },
  } } }, async req => {
    const { d, probe } = probeRequest(req), body = req.body as { elapsedMs: number; initiatorAddress?: string; responderAddress?: string },
      result = rtcProbes.complete(probe, d.id, body.elapsedMs, body);
    probesChanged([probe.initiatorDeviceId, probe.responderDeviceId]); return { result };
  });
  app.post(`${probePath}/fail`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["error"], properties: { error: { type: "string", minLength: 1, maxLength: 128 } },
  } } }, async req => {
    const { probe } = probeRequest(req), result = rtcProbes.finish(probe, null, (req.body as { error: string }).error);
    probesChanged([probe.initiatorDeviceId, probe.responderDeviceId]); return { result };
  });
  app.delete(probePath, async req => {
    const { probe } = probeRequest(req); rtcProbes.stop(probe); probesChanged([probe.initiatorDeviceId, probe.responderDeviceId]); return { ok: true };
  });
  const probeTimer = setInterval(cleanupProbes, 1000); probeTimer.unref();
  app.post(
    `${api}/devices/me/peer`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["candidates", "certificatePem", "certificateSha256"],
          properties: {
            candidates: {
              type: "array",
              minItems: 0,
              maxItems: 8,
              items: { type: "string", maxLength: 512 },
            },
            certificatePem: { type: "string", maxLength: 16384 },
            certificateSha256: { type: "string", pattern: "^[a-f0-9]{64}$" },
            push: { type: "boolean" },
            cellularPush: { type: "boolean" },
          },
        },
      },
    },
    async (req) => {
      const d = device(req),
        b = req.body as any;
      requireOnline(d.id);
      for (const value of b.candidates) {
        let u: URL;
        try {
          u = new URL(value);
        } catch {
          fail("INVALID_CANDIDATE", "Invalid peer HTTPS candidate");
        }
        if (
          u.protocol !== "https:" ||
          u.username ||
          u.password ||
          u.search ||
          u.hash ||
          u.pathname !== "/"
        )
          fail("INVALID_CANDIDATE", "Peer candidate must be an HTTPS origin");
      }
      let certificate: X509Certificate;
      try {
        certificate = new X509Certificate(b.certificatePem);
      } catch {
        fail("INVALID_CERTIFICATE", "Invalid peer certificate");
      }
      if (digest(certificate.raw) !== b.certificateSha256)
        fail("INVALID_CERTIFICATE", "Peer certificate fingerprint mismatch");
      if (
        Date.parse(certificate.validTo) <= Date.now() ||
        Date.parse(certificate.validFrom) > Date.now()
      )
        fail("INVALID_CERTIFICATE", "Peer certificate is not currently valid");
        if (b.candidates.length === 0) {
          peerAnnouncements.delete(d.id);
          devicesChanged(d.group_id);
          return { peer: null };
        }
      const expires = discoveryNow() + PEER_TTL_SECONDS * 1000;
      peerAnnouncements.set(d.id, { data: b, expires });
      devicesChanged(d.group_id);
      return { peer: peerView(d.id) };
    },
  );
  app.delete(`${api}/devices/:deviceId`, async (req) => {
    const d = device(req),
      p = req.params as any;
    const victim = target(d, p.deviceId);
    run("UPDATE devices SET revoked=1 WHERE id=?", victim.id);
    clearDeviceDiscovery(victim.id);
    run("DELETE FROM invites WHERE issuer=?", victim.id);
    for (const socket of sessions.get(victim.id) ?? [])
      socket.close(4001, "Device revoked");
    for (const t of all(
      "SELECT * FROM transfers WHERE source=? OR target=?",
      victim.id,
      victim.id,
    )) {
      for (const f of all(
        "SELECT * FROM files WHERE transfer_id=? AND status NOT IN ('canceled','expired','rejected')",
        t.id,
      ))
        cancelFile(f);
      changed(t);
    }
    for (const peer of all(
      "SELECT id FROM devices WHERE group_id=? AND revoked=0",
      d.group_id,
    ))
      emit("device.revoked", d.id, peer.id, { deviceId: victim.id });
    return { ok: true };
  });
  app.post(
    `${api}/texts`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["eventId", "targetDeviceId", "text"],
          properties: {
            eventId: id,
            targetDeviceId: id,
            text: {
              type: "string",
              minLength: 1,
              maxLength: limits.maxTextLength,
            },
            clipboard: { type: "object", additionalProperties: false, properties: { sourceEventId: id } },
          },
        },
      },
    },
    async (req, reply) => {
      const d = device(req),
        b = req.body as any;
      target(d, b.targetDeviceId);
      const old = get("SELECT * FROM events WHERE id=?", b.eventId);
      const delivered = textContents.delivery(b.eventId);
      if (!old && delivered) {
        if (delivered.source !== d.id || delivered.target !== b.targetDeviceId || delivered.request_text !== b.text || b.clipboard !== undefined)
          fail("ID_CONFLICT", "Event ID already used with different content", 409);
        return { event: { cursor: delivered.cursor, protocolVersion: PROTOCOL_VERSION, eventId: b.eventId, type: 'text.created', sourceDeviceId: delivered.source, targetDeviceId: delivered.target, createdAt: delivered.created, expiresAt: iso(delivered.expires), payload: textContents.document(delivered.content_id) }, replayed: true };
      }
      if (old) {
        const priorPayload = JSON.parse(old.payload);
        const matchingClipboard = b.clipboard !== undefined
          ? priorPayload.clipboard && priorPayload.clipboard.parentEventId === b.clipboard.sourceEventId
          : priorPayload.clipboard === undefined;
        if (
          old.type !== "text.created" ||
          old.source !== d.id ||
          old.target !== b.targetDeviceId ||
          (delivered?.request_text ?? priorPayload.text) !== b.text || !matchingClipboard
        )
          fail(
            "ID_CONFLICT",
            "Event ID already used with different content",
            409,
          );
        return { event: eventView(old), replayed: true };
      }
      const payload: { text: string; clipboard?: { originDeviceId: string; sourceEventId: string; parentEventId?: string } } = { text: b.text };
      if (b.clipboard !== undefined) {
        if (Buffer.byteLength(b.text, "utf8") > 8192) fail("CLIPBOARD_TOO_LARGE", "Automatic clipboard text is limited to 8 KiB", 413);
        payload.clipboard = { originDeviceId: d.id, sourceEventId: b.eventId };
        if (b.clipboard.sourceEventId) {
          const parent = get("SELECT * FROM events WHERE id=? AND type='text.created' AND (source=? OR target=?) AND expires>?", b.clipboard.sourceEventId, d.id, d.id, Date.now());
          if (!parent) fail("SOURCE_EVENT_UNAVAILABLE", "Clipboard source must be a visible unexpired text event", 403);
          const previous = JSON.parse(parent.payload);
          if (previous.text !== b.text) fail("SOURCE_EVENT_CONFLICT", "Forwarded clipboard text differs from its source", 409);
          payload.clipboard = { originDeviceId: previous.clipboard?.originDeviceId ?? parent.source, sourceEventId: previous.clipboard?.sourceEventId ?? parent.id, parentEventId: parent.id };
        }
      }
      reply.code(201);
      return tx(() => {
        const event = emit(
          "text.created",
          d.id,
          b.targetDeviceId,
          payload,
          b.eventId,
          b.clipboard !== undefined ? 300 : limits.ttlSeconds,
        );
        if (b.clipboard === undefined) {
          const document = textContents.attach(get('SELECT * FROM events WHERE id=?', b.eventId)!, b.text, d.group_id);
          event.payload = {...event.payload as object,...document};
          run('UPDATE events SET payload=? WHERE id=?', JSON.stringify(event.payload), b.eventId);
        }
        return {event,replayed:false};
      });
    },
  );
  app.patch(`${api}/texts/:eventId`, {
    schema: { body: {
      type: "object", additionalProperties: false, required: ["text"],
      properties: { text: { type: "string", minLength: 1, maxLength: limits.maxTextLength } },
    } },
  }, async (req) => {
    const d = device(req), { eventId } = req.params as { eventId: string };
    const original = get("SELECT * FROM events WHERE id=? AND type='text.created' AND source=?", eventId, d.id);
    if (!original) fail("NOT_FOUND", "Sent text not found", 404);
    if (original.expires <= Date.now()) fail("EXPIRED", "This message has expired", 410);
    target(d, original.target);
    const { text } = req.body as { text: string }, payload = JSON.parse(original.payload);
    if (!text.trim()) fail("EMPTY_TEXT", "Text must not be blank");
    if (payload.clipboard && Buffer.byteLength(text, "utf8") > 8192) fail("CLIPBOARD_TOO_LARGE", "Automatic clipboard text is limited to 8 KiB", 413);
    if (text === payload.text) return { event: eventView(original) };
    const editedAt = iso();
    const event = tx(() => {
      if (!payload.clipboard) {
        textContents.attach(original, payload.text, d.group_id);
        const result = textContents.edit(original.id, text);
        let response: Event | undefined;
        for (const delivery of result.deliveries) {
          // Preserve each original delivery and its own acknowledgement/expiry.
          const update = emit('text.updated', delivery.source, delivery.target, {
            ...textContents.document(result.document.contentId, delivery.target),
            sourceEventId: delivery.event_id,
            sourceEventIds: [delivery.event_id],
          });
          if (delivery.event_id === eventId) response = update;
        }
        return response!;
      }
      run("UPDATE events SET payload=? WHERE id=?", JSON.stringify({ ...payload, text, editedAt }), original.id);
      return emit("text.updated", d.id, original.target, {
        sourceEventId: original.id, text, editedAt,
      }, randomUUID(), (original.expires - Date.now()) / 1000);
    });
    return { event };
  });
  app.get(`${api}/texts/latest`, async (req) => ({ documents: textContents.latest(device(req).id) }));
  app.get(`${api}/events`, async (req) => {
    const d = device(req),
      q = req.query as any;
    const after = Number(q.after ?? 0),
      limit = Number(q.limit ?? 100);
    if (
      !Number.isSafeInteger(after) ||
      after < 0 ||
      !Number.isSafeInteger(limit) ||
      limit < 1 ||
      limit > 200
    )
      fail("INVALID_CURSOR", "Invalid cursor or limit");
    const rows = all(
      "SELECT * FROM events WHERE cursor>? AND (source=? OR target=?) AND expires>? ORDER BY cursor LIMIT ?",
      after,
      d.id,
      d.id,
      Date.now(),
      limit + 1,
    );
    const events = rows.slice(0, limit).map(eventView);
    return {
      events,
      cursor: events.at(-1)?.cursor ?? after,
      hasMore: rows.length > limit,
    };
  });
  app.post(`${api}/events/:eventId/ack`, async (req) => {
    const d = device(req),
      p = req.params as any;
    const e = get(
      "SELECT * FROM events WHERE id=? AND target=? AND type=? AND expires>?",
      p.eventId,
      d.id,
      "text.created",
      Date.now(),
    );
    if (!e) fail("NOT_FOUND", "Text event not found", 404);
    if (!get("SELECT id FROM text_acks WHERE id=?", e.id))
      tx(() => {
        run("INSERT INTO text_acks VALUES(?)", e.id);
        emit("text.received", d.id, e.source, { sourceEventId: e.id });
      });
    return { ok: true };
  });
  app.post(`${api}/session/ws-ticket`, async (req) => {
    const d = device(req),
      ticket = secret(),
      expires = Date.now() + 30000;
    tickets.set(digest(ticket), { deviceId: d.id, expires });
    return { ticket, expiresAt: iso(expires) };
  });
  app.get(
    `${api}/ws`,
    {
      websocket: true,
      preValidation: async (req) => {
        const origin = req.headers.origin;
        if (origin) {
          let valid = false;
          try {
            valid = publicBase
              ? new URL(origin).origin === new URL(publicBase).origin
              : !production &&
                ["localhost", "127.0.0.1", "[::1]"].includes(
                  new URL(origin).hostname,
                );
          } catch {}
          if (!valid)
            fail("ORIGIN_DENIED", "WebSocket origin is not permitted", 403);
        }
        const key = digest(String((req.query as any).ticket ?? "")),
          ticket = tickets.get(key);
        tickets.delete(key);
        if (
          !ticket ||
          ticket.expires <= Date.now() ||
          !get(
            "SELECT id FROM devices WHERE id=? AND revoked=0",
            ticket.deviceId,
          )
        )
          fail("UNAUTHORIZED", "Invalid WebSocket ticket", 401);
        (req as any).wsDevice = ticket.deviceId;
      },
    },
    (socket, req) => {
      const d = get("SELECT * FROM devices WHERE id=?", (req as any).wsDevice)!;
      let group = sessions.get(d.id);
      const wasOnline = online(d.id);
      if (!group) {
        group = new Set();
        sessions.set(d.id, group);
      }
      group.add(socket);
      socket.send(
        JSON.stringify({ type: "hello", deviceId: d.id, protocolVersion: 1 }),
      );
      if (!wasOnline) { presence(d, true); devicesChanged(d.group_id); }
      let alive = true;
      const heartbeat = setInterval(() => {
        if (!alive) return socket.terminate();
        alive = false;
        socket.ping();
      }, 25000);
      heartbeat.unref();
      socket.on("pong", () => {
        alive = true;
      });
      socket.on("message", (data) => {
        try {
          const msg = JSON.parse(data.toString());
          if (msg.type === "ping")
            socket.send(JSON.stringify({ type: "pong" }));
        } catch {
          socket.close(1008, "Invalid JSON");
        }
      });
      socket.on("close", () => {
        clearInterval(heartbeat);
        group!.delete(socket);
        if (!group!.size) {
          sessions.delete(d.id);
          if (!closing) {
            clearDeviceDiscovery(d.id);
            presence(d, false);
            devicesChanged(d.group_id);
          }
        }
      });
    },
  );
  app.post(
    `${api}/transfers`,
    {
      bodyLimit: 8 * 1024 * 1024,
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["transferId", "targetDeviceId", "files"],
          properties: {
            transferId: id,
            targetDeviceId: id,
            routePreference: { enum: ROUTE_PREFERENCES },
            files: {
              type: "array",
              minItems: 1,
              maxItems: 10000,
              items: fileOfferSchema,
            },
          },
        },
      },
    },
    async (req, reply) => {
      const d = device(req),
        b = req.body as any;
      target(d, b.targetDeviceId);
      const folder = b.files.some((f:any) => f.relativePath || f.entryKind === "directory");
      if (!folder && b.files.length > 32) fail("TOO_MANY_FILES", "Select at most 32 ordinary files");
      if (folder && !get("SELECT folder_transfer FROM device_capabilities WHERE device_id=?", b.targetDeviceId)?.folder_transfer)
        fail("RECEIVER_UPGRADE_REQUIRED", "接收设备需要升级后才能接收文件夹", 409);
      const offer = JSON.stringify({
        transferId: b.transferId,
        targetDeviceId: b.targetDeviceId,
        files: b.files.map((f: any) => ({
          fileId: f.fileId,
          name: f.name,
          size: f.size,
          mimeType: f.mimeType || "application/octet-stream",
          sha256: f.sha256,
          ...(f.relativePath ? { relativePath: relativeFilename(f.relativePath), entryKind: f.entryKind ?? "file" } : {}),
        })),
        ...(b.routePreference && b.routePreference !== "auto" ? { routePreference: b.routePreference } : {}),
      });
      const old = get("SELECT * FROM transfers WHERE id=?", b.transferId);
      if (old) {
        if (old.source !== d.id || old.offer !== offer)
          fail("ID_CONFLICT", "Transfer ID already used", 409);
        return { transfer: transferView(old), replayed: true };
      }
      let total = 0;
      const ids = new Set<string>();
      const paths = new Set<string>();
      for (const f of b.files) {
        filename(f.name);
        if (f.entryKind === "directory" && (!f.relativePath || f.size !== 0 || f.sha256 !== digest(Buffer.alloc(0))))
          fail("INVALID_DIRECTORY", "Directories require a relative path and an empty payload");
        if (f.relativePath) {
          relativeFilename(f.relativePath);
          if (paths.has(f.relativePath)) fail("DUPLICATE_PATH", "Folder paths must be unique");
          paths.add(f.relativePath);
          if (f.name !== f.relativePath.split("/").at(-1)) fail("INVALID_RELATIVE_PATH", "File name must match the relative path");
        }
        if (ids.has(f.fileId))
          fail("DUPLICATE_FILE", "File IDs must be unique");
        ids.add(f.fileId);
        if (f.size > limits.maxFileSize)
          fail("FILE_TOO_LARGE", "File exceeds maximum size", 413);
        total += f.size;
      }
      if (!Number.isSafeInteger(total))
        fail("FILE_TOO_LARGE", "Offer too large", 413);
      if (!folder &&
        get(
          "SELECT COUNT(*) AS n FROM files JOIN transfers ON transfers.id=files.transfer_id WHERE transfers.source=? AND files.relative_path IS NULL AND files.status IN ('offered','accepted','uploading')",
          d.id,
        )!.n +
          b.files.length >
        64
      )
        fail("CONCURRENCY_LIMIT", "Too many active files", 429);
      await space(total);
      device(req);
      target(d, b.targetDeviceId);
      const concurrent = get(
        "SELECT * FROM transfers WHERE id=?",
        b.transferId,
      );
      if (concurrent) {
        if (concurrent.source !== d.id || concurrent.offer !== offer)
          fail("ID_CONFLICT", "Transfer ID already used", 409);
        return { transfer: transferView(concurrent), replayed: true };
      }
      tx(() => {
        if (!folder &&
          get(
            "SELECT COUNT(*) AS n FROM files JOIN transfers ON transfers.id=files.transfer_id WHERE transfers.source=? AND files.relative_path IS NULL AND files.status IN ('offered','accepted','uploading')",
            d.id,
          )!.n +
            b.files.length >
          64
        )
          fail("CONCURRENCY_LIMIT", "Too many active files", 429);
        if (reserved() + total > limits.totalQuota)
          fail("QUOTA_EXCEEDED", "Relay storage quota exceeded", 507);
        run(
          "INSERT INTO transfers VALUES(?,?,?,?,?,?)",
          b.transferId,
          d.id,
          b.targetDeviceId,
          iso(),
          Date.now() + limits.ttlSeconds * 1000,
          offer,
        );
        for (const f of b.files)
          run(
            "INSERT INTO files(transfer_id,id,name,size,mime,sha,status,attempt,path,relative_path,entry_kind) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            b.transferId,
            f.fileId,
            f.name,
            f.size,
            f.mimeType || "application/octet-stream",
            f.sha256,
            "offered",
            randomUUID(),
            join(relayDir, randomUUID()),
            f.relativePath ?? null,
            f.relativePath ? f.entryKind ?? "file" : null,
          );
      });
      const t = get("SELECT * FROM transfers WHERE id=?", b.transferId)!;
      emit("transfer.offered", d.id, b.targetDeviceId, { transferId: t.id, routePreference: transferRoute(t) });
      reply.code(201);
      return { transfer: transferView(t), replayed: false };
    },
  );
  app.get(`${api}/transfers`, async (req) => {
    const d = device(req);
    return {
      transfers: all(
        "SELECT * FROM transfers WHERE (source=? OR target=?) AND expires>? ORDER BY created DESC LIMIT 500",
        d.id,
        d.id,
        Date.now(),
      ).map(transferView),
    };
  });
  app.get(`${api}/transfers/:transferId`, async (req) => {
    const d = device(req);
    return {
      transfer: transferView(transfer(d, (req.params as any).transferId)),
    };
  });
  app.post(
    `${api}/transfers/:transferId/accept`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["fileIds"],
          properties: {
            fileIds: {
              type: "array",
              uniqueItems: true,
              maxItems: 10000,
              items: id,
            },
          },
        },
      },
    },
    async (req) => {
      const d = device(req),
        t = transfer(d, (req.params as any).transferId);
      role(d, t, "target");
      const selected = new Set<string>((req.body as any).fileIds);
      for (const fileId of selected) file(t, fileId);
      tx(() => {
        for (const f of all(
          "SELECT * FROM files WHERE transfer_id=? AND status='offered'",
          t.id,
        ))
          run(
            "UPDATE files SET status=?,transport=? WHERE transfer_id=? AND id=?",
            selected.has(f.id) ? "accepted" : "rejected",
            selected.has(f.id) && transferRoute(t) === "relay" ? "relay" : null,
            t.id,
            f.id,
          );
      });
      changed(t);
      return { transfer: transferView(t) };
    },
  );
  const locks = new Set<string>();
  async function locked<T>(key: string, fn: () => Promise<T>) {
    if (locks.has(key))
      fail("FILE_BUSY", "File operation in progress; retry", 409);
    locks.add(key);
    try {
      return await fn();
    } finally {
      locks.delete(key);
    }
  }
  const filePath = `${api}/transfers/:transferId/files/:fileId`;
  app.post(`${filePath}/rtc`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["attemptId", "scope", "offset"],
    properties: { attemptId: id, scope: { enum: ["lan", "public"] },
      offset: { type: "integer", minimum: 0, maximum: Number.MAX_SAFE_INTEGER } },
  } } }, async (req) => {
    const d = device(req), p = req.params as any, b = req.body as any, t = transfer(d, p.transferId);
    role(d, t, "target"); allowTransport(t, "direct");
    cleanupDiscovery(); requireOnlinePeers(t);
    const f = file(t, p.fileId), preference = transferRoute(t);
    if (f.status !== "accepted" || f.transport === "relay" || locks.has(`${t.id}/${f.id}`))
      fail("NOT_ACCEPTED", "File is not available for WebRTC", 409);
    if ((preference === "lan" || preference === "public") && preference !== b.scope)
      fail("ROUTE_NOT_ALLOWED", "WebRTC scope does not match the sender route", 409);
    if (b.offset > f.size) fail("INVALID_OFFSET", "WebRTC offset exceeds file size", 409);
    const previous = rtc.current(t.id, f.id);
    const attempt = rtc.create({ transferId: t.id, fileId: f.id, attemptId: b.attemptId,
      sourceDeviceId: t.source, targetDeviceId: t.target, scope: b.scope, offset: b.offset, transferExpires: t.expires });
    if (attempt !== previous) {
      clearDirect(t.id, f.id, true);
      run("UPDATE files SET transport='direct' WHERE transfer_id=? AND id=?", t.id, f.id);
      if (previous) rtcChanged(previous);
      changed(t);
      rtcChanged(attempt);
    }
    return { rtc: rtc.view(attempt) };
  });
  const rtcPath = `${filePath}/rtc/:rtcAttemptId`;
  function rtcRequest(req: FastifyRequest) {
    const d = device(req), p = req.params as any, t = transfer(d, p.transferId), f = file(t, p.fileId);
    allowTransport(t, "direct");
    if (f.status !== "accepted" || f.transport !== "direct") fail("RTC_ENDED", "WebRTC file is no longer active", 410);
    cleanupDiscovery();
    const attempt = rtc.require(t.id, f.id, p.rtcAttemptId, d.id);
    requireOnlinePeers(t);
    return { d, t, f, attempt };
  }
  app.get(rtcPath, async (req) => ({ rtc: rtc.view(rtcRequest(req).attempt) }));
  app.post(`${rtcPath}/description`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["type", "sdp"],
    properties: { type: { enum: ["offer", "answer"] }, sdp: { type: "string", minLength: 1, maxLength: 65536 } },
  } } }, async (req) => {
    const { d, attempt } = rtcRequest(req), b = req.body as { type: "offer"|"answer"; sdp: string };
    rtc.describe(attempt, d.id, b.type, b.sdp); rtcChanged(attempt);
    return { rtc: rtc.view(attempt) };
  });
  app.post(`${rtcPath}/candidate`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["candidate", "sdpMid", "sdpMLineIndex"],
    properties: { candidate: { type: "string", minLength: 1, maxLength: 4096 },
      sdpMid: { anyOf: [{ type: "string", maxLength: 256 }, { type: "null" }] },
      sdpMLineIndex: { anyOf: [{ type: "integer", minimum: 0, maximum: 65535 }, { type: "null" }] } },
  } } }, async (req) => {
    const { d, attempt } = rtcRequest(req);
    rtc.candidate(attempt, d.id, req.body as any); rtcChanged(attempt);
    return { rtc: rtc.view(attempt) };
  });
  const emptyRtcBody = { type: "object", additionalProperties: false, properties: {} };
  app.post(`${rtcPath}/started`, { schema: { body: emptyRtcBody } }, async (req) => {
    const { d, attempt } = rtcRequest(req);
    rtc.started(attempt, d.id); rtcChanged(attempt);
    return { rtc: rtc.view(attempt) };
  });
  app.post(`${rtcPath}/fail`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["error"],
    properties: { error: { type: "string", maxLength: 512 } },
  } } }, async (req) => {
    const { attempt } = rtcRequest(req);
    rtc.fail(attempt, (req.body as { error: string }).error); rtcChanged(attempt);
    return { rtc: rtc.view(attempt) };
  });
  app.post(`${rtcPath}/stop`, { schema: { body: emptyRtcBody } }, async (req) => {
    const d = device(req), p = req.params as any, t = transfer(d, p.transferId); role(d, t, "target");
    const f = file(t, p.fileId), attempt = rtc.current(t.id, f.id);
    // Stopping an old connection must not tear down a newer receive attempt.
    if (attempt?.attemptId === p.rtcAttemptId) { clearDirect(t.id, f.id); changed(t); }
    return { ok: true };
  });
  app.post(`${filePath}/direct-ticket`, async (req) => {
    const d = device(req),
      p = req.params as any,
      t = transfer(d, p.transferId);
    role(d, t, "target");
    allowTransport(t, "direct");
    cleanupDiscovery(); requireOnlinePeers(t);
    const f = file(t, p.fileId);
    if (locks.has(`${t.id}/${f.id}`))
      fail("FILE_BUSY", "File operation in progress", 409);
    if (f.status !== "accepted")
      fail(
        "NOT_ACCEPTED",
        "File has not been accepted for direct transfer",
        409,
      );
    if (f.transport === "relay")
      fail("PATH_SELECTED", "Relay path already selected", 409);
    const peer = peerView(t.source);
    if (!peer)
      fail("PEER_UNAVAILABLE", "Sender has no current peer endpoint", 409);
    clearDirect(t.id, f.id);
    const ticket = secret(),
      expires = Date.now() + 60000;
    directTickets.set(digest(ticket), {
      deviceId: d.id,
      transferId: t.id,
      fileId: f.id,
      expires,
    });
    run(
      "UPDATE files SET transport='direct' WHERE transfer_id=? AND id=?",
      t.id,
      f.id,
    );
    changed(t);
    return {
      ticket,
      expiresAt: iso(expires),
      candidates: peer.candidates,
      certificateSha256: peer.certificateSha256,
    };
  });
  app.post(
    `${api}/direct-tickets/verify`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["ticket", "transferId", "fileId"],
          properties: {
            ticket: { type: "string", maxLength: 100 },
            transferId: id,
            fileId: id,
          },
        },
      },
    },
    async (req) => {
      const d = device(req),
        b = req.body as any,
        key = digest(b.ticket),
        ticket = directTickets.get(key);
      if (
        !ticket ||
        ticket.direction === "push" ||
        ticket.expires <= Date.now() ||
        ticket.transferId !== b.transferId ||
        ticket.fileId !== b.fileId
      )
        fail("UNAUTHORIZED", "Invalid direct ticket", 401);
      const t = transfer(d, ticket.transferId);
      role(d, t, "source");
      allowTransport(t, "direct");
      cleanupDiscovery(); requireOnlinePeers(t);
      const f = file(t, ticket.fileId);
      if (
        t.target !== ticket.deviceId ||
        f.status !== "accepted" ||
        f.transport !== "direct"
      )
        fail("NOT_ACCEPTED", "Direct authorization no longer valid", 409);
      directTickets.delete(key);
      return {
        transferId: t.id,
        fileId: f.id,
        name: f.name,
        size: f.size,
        sha256: f.sha,
        targetDeviceId: t.target,
        expiresAt: iso(ticket.expires),
      };
    },
  );
  // The receiver owns direction/phase selection; a sender cannot race a relay
  // upload against a pending push or turn its own offer into receive consent.
  app.post(`${filePath}/direct-push`, {
    schema: { body: { type: "object", additionalProperties: false,
      required: ["attemptId", "scope", "cellular", "offset"],
      properties: { attemptId: id, scope: { enum: ["lan", "public"] }, cellular: { type: "boolean" }, offset: { type: "integer", minimum: 0 } } } },
  }, async (req) => {
    const d = device(req), p = req.params as any, b = req.body as any, t = transfer(d, p.transferId);
    role(d, t, "target"); allowTransport(t, "direct");
    cleanupDiscovery(); requireOnlinePeers(t);
    const f = file(t, p.fileId), preference = transferRoute(t);
    if (f.status !== "accepted" || f.transport === "relay" || locks.has(`${t.id}/${f.id}`))
      fail("NOT_ACCEPTED", "File is not available for direct push", 409);
    if ((preference === "lan" || preference === "public") && preference !== b.scope)
      fail("ROUTE_NOT_ALLOWED", "Push scope does not match the sender route", 409);
    if (b.offset > f.size) fail("INVALID_OFFSET", "Push offset exceeds file size", 409);
    const sender = peerView(t.source), receiver = peerView(t.target);
    if (!sender?.push || !receiver?.push) fail("PUSH_UNAVAILABLE", "Both devices must support direct push", 409);
    if (b.cellular && (b.scope !== "public" || !sender.cellularPush))
      fail("PUSH_UNAVAILABLE", "Sender has not enabled cellular push", 409);
    const previous = directPushes.get(`${t.id}/${f.id}`);
    if (previous && previous.attemptId === b.attemptId) {
      if (previous.scope !== b.scope || previous.cellular !== b.cellular || previous.offset !== b.offset)
        fail("ATTEMPT_CONFLICT", "Push attempt parameters changed", 409);
      return { file: fileView(f) };
    }
    clearDirect(t.id, f.id);
    directPushes.set(`${t.id}/${f.id}`, { attemptId: b.attemptId, scope: b.scope,
      cellular: b.cellular, offset: b.offset, state: "waiting", expires: Date.now() + 60000 });
    run("UPDATE files SET transport='direct' WHERE transfer_id=? AND id=?", t.id, f.id);
    changed(t);
    return { file: fileView(file(t, f.id)) };
  });
  const pushAttemptBody = { type: "object", additionalProperties: false,
    required: ["attemptId"], properties: { attemptId: id } };
  app.post(`${filePath}/push-ticket`, { schema: { body: pushAttemptBody } }, async (req) => {
    const d = device(req), p = req.params as any, b = req.body as any, t = transfer(d, p.transferId);
    role(d, t, "source"); allowTransport(t, "direct");
    cleanupDiscovery(); requireOnlinePeers(t);
    const f = file(t, p.fileId), push = directPushes.get(`${t.id}/${f.id}`), peer = peerView(t.target);
    if (!push || push.attemptId !== b.attemptId || push.expires <= Date.now() || push.state !== "waiting" || f.status !== "accepted" || f.transport !== "direct")
      fail("PUSH_EXPIRED", "Push attempt is no longer active", 409);
    if (!peer?.push) fail("PEER_UNAVAILABLE", "Receiver has no current push endpoint", 409);
    for (const [key, ticket] of directTickets)
      if (ticket.transferId === t.id && ticket.fileId === f.id) directTickets.delete(key);
    const ticket = secret(), expires = Math.min(push.expires, Date.now() + 60000);
    directTickets.set(digest(ticket), { deviceId: d.id, transferId: t.id, fileId: f.id,
      expires, direction: "push", attemptId: push.attemptId });
    return { ticket, expiresAt: iso(expires), candidates: peer.candidates, certificateSha256: peer.certificateSha256,
      attemptId: push.attemptId, scope: push.scope, cellular: push.cellular, offset: push.offset, size: f.size, sha256: f.sha };
  });
  app.post(`${api}/push-tickets/verify`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["ticket", "transferId", "fileId", "attemptId"],
    properties: { ticket: { type: "string", maxLength: 100 }, transferId: id, fileId: id, attemptId: id },
  } } }, async (req) => {
    const d = device(req), b = req.body as any, key = digest(b.ticket), ticket = directTickets.get(key);
    if (!ticket || ticket.direction !== "push" || ticket.expires <= Date.now() || ticket.transferId !== b.transferId || ticket.fileId !== b.fileId || ticket.attemptId !== b.attemptId)
      fail("UNAUTHORIZED", "Invalid push ticket", 401);
    const t = transfer(d, ticket.transferId); role(d, t, "target"); allowTransport(t, "direct");
    cleanupDiscovery(); requireOnlinePeers(t);
    const f = file(t, ticket.fileId), push = directPushes.get(`${t.id}/${f.id}`);
    if (!push || push.attemptId !== ticket.attemptId || push.state !== "waiting" || push.expires <= Date.now() || t.source !== ticket.deviceId || f.status !== "accepted" || f.transport !== "direct")
      fail("NOT_ACCEPTED", "Push authorization no longer valid", 409);
    directTickets.delete(key);
    push.state = "streaming"; push.expires = t.expires;
    changed(t);
    return { transferId: t.id, fileId: f.id, attemptId: push.attemptId, size: f.size, sha256: f.sha,
      offset: push.offset, scope: push.scope, cellular: push.cellular, sourceDeviceId: t.source };
  });
  app.post(`${filePath}/direct-push/stop`, { schema: { body: pushAttemptBody } }, async (req) => {
    const d = device(req), p = req.params as any, t = transfer(d, p.transferId); role(d, t, "target");
    const f = file(t, p.fileId), push = directPushes.get(`${t.id}/${f.id}`);
    if (push?.attemptId === (req.body as any).attemptId) { clearDirect(t.id, f.id); changed(t); }
    return {};
  });
  app.post(`${filePath}/direct-push/fail`, { schema: { body: {
    type: "object", additionalProperties: false, required: ["attemptId", "error"],
    properties: { attemptId: id, error: { type: "string", maxLength: 512 } },
  } } }, async (req) => {
    const d = device(req), p = req.params as any, b = req.body as any, t = transfer(d, p.transferId); role(d, t, "source");
    const f = file(t, p.fileId), push = directPushes.get(`${t.id}/${f.id}`);
    if (push && push.attemptId === b.attemptId && f.status === "accepted" && f.transport === "direct") {
      push.state = "failed"; push.error = b.error; changed(t);
    }
    return {};
  });
  app.post(`${filePath}/relay`, async (req) => {
    const d = device(req),
      p = req.params as any,
      t = transfer(d, p.transferId),
      f = file(t, p.fileId);
    allowTransport(t, "relay");
    if (!["accepted", "uploading"].includes(f.status))
      fail("NOT_ACCEPTED", "File is not active", 409);
    if (d.id === t.source && f.transport === "direct")
      fail("PATH_SELECTED", "Receiver selected direct transfer", 409);
    clearDirect(t.id, f.id);
    run(
      "UPDATE files SET transport='relay' WHERE transfer_id=? AND id=?",
      t.id,
      f.id,
    );
    changed(t);
    return { file: fileView(file(t, f.id)) };
  });
  app.put(`${filePath}/chunks`, async (req) => {
    const d = device(req),
      p = req.params as any,
      t = transfer(d, p.transferId);
    role(d, t, "source");
    allowTransport(t, "relay");
    return locked(`${t.id}/${p.fileId}`, async () => {
      const f = file(t, p.fileId),
        offset = Number((req.query as any).offset),
        body = req.body;
      if (
        !Buffer.isBuffer(body) ||
        !Number.isSafeInteger(offset) ||
        offset < 0 ||
        body.length < 1
      )
        fail(
          "INVALID_CHUNK",
          "Expected octet-stream body and nonnegative offset",
        );
      if (!["accepted", "uploading"].includes(f.status))
        fail(
          "NOT_ACCEPTED",
          "Receiver has not accepted this file, or file is terminal",
          409,
        );
      if (f.transport === "direct")
        fail("PATH_SELECTED", "Receiver selected direct transfer", 409);
      if (body.length > limits.chunkSize || offset + body.length > f.size)
        fail("CHUNK_OVERFLOW", "Chunk exceeds declared size", 409);
      // Every asynchronous boundary must re-establish the lease and this exact
      // file attempt before accessing its path. Cancellation does not take the
      // upload lock, so the initial row is not authority after an await.
      const currentWritable = () => {
        const activeTransfer = transfer(d, t.id);
        role(d, activeTransfer, "source");
        const current = file(activeTransfer, f.id);
        if (!["accepted", "uploading"].includes(current.status))
          fail("NOT_ACCEPTED", "File is no longer active", 409);
        if (current.transport === "direct")
          fail("PATH_SELECTED", "Receiver selected direct transfer", 409);
        if (current.path !== f.path || current.attempt !== f.attempt || current.offset !== f.offset)
          fail("OFFSET_CONFLICT", "File attempt or committed offset changed; reconcile before resuming", 409);
        return current;
      };
      if (offset < f.offset) {
        if (offset + body.length > f.offset)
          fail("OFFSET_CONFLICT", "Chunk overlaps uncommitted bytes", 409);
        const handle = await open(f.path, "r");
        try {
          const previous = Buffer.alloc(body.length);
          await handle.read(previous, 0, body.length, offset);
          if (!previous.equals(body))
            fail(
              "CHUNK_CONFLICT",
              "Repeated chunk contains different bytes",
              409,
            );
          return { file: fileView(currentWritable()) };
        } finally {
          await handle.close();
        }
      }
      if (offset !== f.offset)
        fail("OFFSET_CONFLICT", "Resume from committed offset", 409);
      const disk = await statfs(relayDir);
      // Check before even openSync(..., "w"): an expired/revoked/canceled
      // attempt must never recreate a path that cleanup already removed.
      const writable = currentWritable();
      if (disk.bavail * disk.bsize < body.length + diskReserve)
        fail("DISK_FULL", "Insufficient relay disk space", 507);
      const descriptor = openSync(writable.path, existsSync(writable.path) ? "r+" : "w");
      try {
        let written = 0;
        while (written < body.length)
          written += writeSync(
            descriptor,
            body,
            written,
            body.length - written,
            offset + written,
          );
        fsyncSync(descriptor);
      } finally {
        closeSync(descriptor);
      }
      try {
        // Wall-clock TTL can expire during the synchronous write/fsync even
        // though no other request callback runs in that interval.
        currentWritable();
      } catch (error) {
        // Remove this attempt's path, not a potentially newer attempt. Busy
        // files are recorded by removeBytes in persistent pending_deletes.
        removeBytes(writable);
        const latest = get("SELECT * FROM files WHERE transfer_id=? AND id=?", t.id, f.id);
        if (latest && latest.path === writable.path && ["accepted", "uploading"].includes(latest.status)) {
          const terminal = (error as { code?: string }).code === "EXPIRED" ? "expired" : "canceled";
          run("UPDATE files SET status=?,offset=0,error=NULL WHERE transfer_id=? AND id=?", terminal, t.id, f.id);
        }
        throw error;
      }
      run(
        "UPDATE files SET status='uploading',transport='relay',offset=? WHERE transfer_id=? AND id=?",
        offset + body.length,
        t.id,
        f.id,
      );
      return { file: fileView(file(t, f.id)) };
    });
  });
  app.post(`${filePath}/complete`, async (req) => {
    const d = device(req),
      p = req.params as any,
      t = transfer(d, p.transferId);
    role(d, t, "source");
    allowTransport(t, "relay");
    return locked(`${t.id}/${p.fileId}`, async () => {
      const f = file(t, p.fileId);
      if (["ready", "received"].includes(f.status))
        return { file: fileView(f) };
      if (f.transport === "direct")
        fail("PATH_SELECTED", "Receiver selected direct transfer", 409);
      if (!["accepted", "uploading"].includes(f.status))
        fail("NOT_ACCEPTED", "File cannot be completed", 409);
      if (f.offset !== f.size)
        fail("INCOMPLETE", "File still has missing bytes", 409);
      if (!existsSync(f.path) && f.size === 0)
        writeFileSync(f.path, Buffer.alloc(0));
      const hash = createHash("sha256");
      for await (const data of createReadStream(f.path)) hash.update(data);
      transfer(d, t.id);
      if (!["accepted", "uploading"].includes(file(t, f.id).status))
        fail("CANCELED", "File canceled during verification", 409);
      if (hash.digest("hex") !== f.sha) {
        cancelFile(f, "failed", "HASH_MISMATCH");
        changed(t);
        fail("HASH_MISMATCH", "File SHA-256 did not match", 422);
      }
      run(
        "UPDATE files SET status='ready',transport='relay',error=NULL WHERE transfer_id=? AND id=?",
        t.id,
        f.id,
      );
      changed(t);
      return { file: fileView(file(t, f.id)) };
    });
  });
  app.post(
    `${filePath}/retry`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          required: ["attemptId"],
          properties: { attemptId: id },
        },
      },
    },
    async (req) => {
      const d = device(req),
        p = req.params as any,
        t = transfer(d, p.transferId);
      role(d, t, "source");
      allowTransport(t, "relay");
      return locked(`${t.id}/${p.fileId}`, async () => {
        const f = file(t, p.fileId),
          attemptId = (req.body as any).attemptId;
        if (f.attempt === attemptId) return { file: fileView(f) };
        if (f.transport === "direct")
          fail("PATH_SELECTED", "Receiver selected direct transfer", 409);
        if (!["accepted", "uploading", "failed"].includes(f.status))
          fail("INVALID_STATE", "File cannot be retried", 409);
        await space(f.status === "failed" && !f.receive_failure ? f.size : 0);
        transfer(d, t.id);
        if (!["accepted", "uploading", "failed"].includes(file(t, f.id).status))
          fail("INVALID_STATE", "File changed while retrying", 409);
        if (
          reserved() + (f.status === "failed" && !f.receive_failure ? f.size : 0) >
          limits.totalQuota
        )
          fail("QUOTA_EXCEEDED", "Relay storage quota exceeded", 507);
        removeBytes(f);
        clearDirect(t.id, f.id);
        run(
          "UPDATE files SET status='accepted',transport='relay',offset=0,attempt=?,path=?,error=NULL,receive_failure=NULL WHERE transfer_id=? AND id=?",
          attemptId,
          join(relayDir, randomUUID()),
          t.id,
          f.id,
        );
        changed(t);
        return { file: fileView(file(t, f.id)) };
      });
    },
  );
  // A receiver that cannot prepare its destination must stop both participants,
  // without throwing away an already uploaded prefix. Retrying after choosing a
  // local folder resumes this same offer rather than manufacturing a new send.
  app.post(`${filePath}/receive-error`, {
    schema: { body: { type: "object", additionalProperties: false, required: ["message"],
      properties: { message: { type: "string", minLength: 1, maxLength: 500 } } } },
  }, async (req) => {
    const d = device(req), p = req.params as any, t = transfer(d, p.transferId);
    role(d, t, "target");
    const f = file(t, p.fileId);
    if (!["offered", "accepted", "uploading", "ready"].includes(f.status))
      return { file: fileView(f) };
    clearDirect(t.id, f.id);
    for (const stream of streams.get(f.path) ?? []) stream.destroy();
    run("UPDATE files SET receive_failure=status,status='failed',error=? WHERE transfer_id=? AND id=?",
      (req.body as { message: string }).message.trim() || "Receiver could not save this file", t.id, f.id);
    changed(t);
    return { file: fileView(file(t, f.id)) };
  });
  app.post(`${filePath}/receive-retry`, async (req) => {
    const d = device(req), p = req.params as any, t = transfer(d, p.transferId);
    return locked(`${t.id}/${p.fileId}`, async () => {
      const f = file(t, p.fileId);
      if (!f.receive_failure) return { file: fileView(f) };
      if (f.status !== "failed") fail("INVALID_STATE", "Receiver failure is no longer active", 409);
      clearDirect(t.id, f.id);
      // Direct connections need fresh tickets; relay keeps its committed bytes,
      // attempt and phase, including a complete file awaiting local storage.
      const phase = f.transport === "direct" ? "accepted" : f.receive_failure;
      run("UPDATE files SET status=?,transport=?,error=NULL,receive_failure=NULL WHERE transfer_id=? AND id=?",
        phase, f.transport === "direct" ? null : f.transport, t.id, f.id);
      changed(t);
      return { file: fileView(file(t, f.id)) };
    });
  });
  app.post(`${filePath}/cancel`, async (req) => {
    const d = device(req),
      p = req.params as any,
      t = transfer(d, p.transferId),
      f = file(t, p.fileId);
    cancelFile(f);
    changed(t);
    return { file: fileView(file(t, f.id)) };
  });
  // Check the receiver's local inventory before accepting an offer, so the
  // sender never starts uploading a duplicate. The client verifies the bytes;
  // the center only records the receipt, even after old offers have expired.
  app.post(`${filePath}/reuse`, {
    schema: { body: {
      type: "object", additionalProperties: false, required: ["sha256", "size"],
      properties: {
        sha256: fileOfferSchema.properties.sha256,
        size: fileOfferSchema.properties.size,
      },
    } },
  }, async (req) => {
    const d = device(req), p = req.params as any, t = transfer(d, p.transferId);
    role(d, t, "target");
    const f = file(t, p.fileId), b = req.body as { sha256: string; size: number };
    if (f.entry_kind === "directory") fail("NOT_A_FILE", "Directories use their normal receipt", 409);
    if (b.sha256 !== f.sha || b.size !== f.size)
      fail("CONTENT_MISMATCH", "Local file does not match the offered content", 409);
    if (f.status === "received" && f.reused_at) return { file: fileView(f) };
    if (!["offered", "accepted"].includes(f.status) || f.offset !== 0 || locks.has(`${t.id}/${f.id}`))
      fail("TRANSFER_STARTED", "Local reuse must be confirmed before payload transfer", 409);
    clearDirect(t.id, f.id);
    removeBytes(f);
    run("UPDATE files SET status='received',transport='direct',offset=0,error=NULL,receive_failure=NULL,reused_at=? WHERE transfer_id=? AND id=?",
      iso(), t.id, f.id);
    changed(t);
    return { file: fileView(file(t, f.id)) };
  });
  app.post(
    `${filePath}/received`,
    {
      schema: {
        body: {
          type: "object",
          additionalProperties: false,
          properties: { transport: { enum: ["relay", "direct"] } },
        },
      },
    },
    async (req) => {
      const d = device(req),
        p = req.params as any,
        t = transfer(d, p.transferId);
      role(d, t, "target");
      const f = file(t, p.fileId),
        transport = (req.body as any)?.transport ?? "relay";
      if (f.entry_kind === "directory") {
        if (!["accepted", "received"].includes(f.status)) fail("NOT_ACCEPTED", "Directory must be accepted before creation", 409);
        run("UPDATE files SET status='received',transport=NULL,offset=0 WHERE transfer_id=? AND id=?", t.id, f.id);
        changed(t);
        return { file: fileView(file(t, f.id)) };
      }
      allowTransport(t, transport);
      if (f.status === "received") {
        if (f.transport !== transport)
          fail(
            "INVALID_STATE",
            "File was already received using a different transport",
            409,
          );
        return { file: fileView(f) };
      }
      if (transport === "direct") {
        if (f.status !== "accepted" || f.transport !== "direct")
          fail(
            "NOT_ACCEPTED",
            "Direct file must have been selected and accepted",
            409,
          );
        removeBytes(f);
        clearDirect(t.id, f.id);
        run(
          "UPDATE files SET status='received',transport='direct',offset=0 WHERE transfer_id=? AND id=?",
          t.id,
          f.id,
        );
      } else {
        if (f.status !== "ready") fail("NOT_READY", "File is not ready", 409);
        run(
          "UPDATE files SET status='received',transport='relay' WHERE transfer_id=? AND id=?",
          t.id,
          f.id,
        );
      }
      changed(t);
      return { file: fileView(file(t, f.id)) };
    },
  );
  app.post(`${filePath}/download-ticket`, async (req) => {
    const d = device(req),
      p = req.params as any,
      t = transfer(d, p.transferId);
    role(d, t, "target");
    allowTransport(t, "relay");
    const f = file(t, p.fileId);
    if (!["ready", "received"].includes(f.status) || f.transport === "direct")
      fail("NOT_READY", "Relay file is not ready", 409);
    const ticket = secret(),
      expires = Date.now() + 60000;
    downloads.set(digest(ticket), {
      deviceId: d.id,
      transferId: t.id,
      fileId: f.id,
      expires,
    });
    return {
      ticket,
      expiresAt: iso(expires),
      downloadPath: `/api/v1/downloads/${ticket}`,
    };
  });
  app.head(`${api}/downloads/:ticket`, async (_req, reply) => reply.code(405).header("Allow", "GET").send());
  app.get(`${api}/downloads/:ticket`, async (req, reply) => {
    const key = digest((req.params as any).ticket),
      ticket = downloads.get(key);
    downloads.delete(key);
    if (!ticket || ticket.expires <= Date.now())
      fail("UNAUTHORIZED", "Invalid download ticket", 401);
    const d = get(
      "SELECT * FROM devices WHERE id=? AND revoked=0",
      ticket.deviceId,
    );
    if (!d) fail("UNAUTHORIZED", "Device revoked", 401);
    const t = transfer(d, ticket.transferId),
      f = file(t, ticket.fileId);
    role(d, t, "target");
    allowTransport(t, "relay");
    if (!["ready", "received"].includes(f.status) || f.transport === "direct")
      fail("NOT_READY", "File is not ready", 409);
    const etag = `"sha256-${f.sha}"`;
    reply.header("Accept-Ranges", "bytes").header("ETag", etag);
    let range: { start: number; end: number } | null = null;
    if (req.headers.range && (!req.headers["if-range"] || req.headers["if-range"] === etag)) {
      range = parseSingleByteRange(req.headers.range, f.size);
      if (!range) {
        reply.header("Content-Range", `bytes */${f.size}`);
        fail("RANGE_NOT_SATISFIABLE", "Request one satisfiable byte range with a fresh download ticket", 416);
      }
      reply.code(206).header("Content-Range", `bytes ${range.start}-${range.end}/${f.size}`);
    }
    reply
      .header(
        "Content-Disposition",
        `attachment; filename="download"; filename*=UTF-8''${encodeURIComponent(f.name).replace(/'/g, "%27")}`,
      )
      .header("Content-Length", range ? range.end - range.start + 1 : f.size)
      .header("Cache-Control", "no-store")
      .header("X-Content-Type-Options", "nosniff")
      .type("application/octet-stream");
    const stream = createReadStream(f.path, range ?? undefined);
    let active = streams.get(f.path);
    if (!active) {
      active = new Set();
      streams.set(f.path, active);
    }
    active.add(stream);
    stream.on("close", () => {
      active!.delete(stream);
      if (!active!.size) streams.delete(f.path);
    });
    return reply.send(stream);
  });
  const webEnabled = options.webEnabled ?? process.env.WEB_ENABLED !== "false";
  const webDir = resolve(
    options.staticDir ?? process.env.STATIC_DIR ??
      fileURLToPath(new URL("../../web/dist", import.meta.url)),
  );
  // Package distribution is local-only, independent of optional Web hosting.
  for (const path of [`${prefix}/releases`, `${prefix}/releases/*`]) {
    app.all(path, async (_req, reply) =>
      reply.code(410).type("text/plain").send("Package hosting is disabled."),
    );
  }
  if (webEnabled && existsSync(join(webDir, "index.html"))) {
    await app.register(staticFiles, {
      root: webDir,
      prefix: `${prefix}/app/`,
      index: ["index.html"],
    });
    app.get(`${prefix}/`, async (_req, reply) =>
      reply.redirect(`${prefix}/app/`),
    );
  }
  app.addHook("onClose", async () => {
    closing = true;
    clearInterval(timer);
    clearInterval(probeTimer);
    for (const group of streams.values())
      for (const stream of group) stream.destroy();
    for (const group of sessions.values())
      for (const socket of group) socket.terminate();
    db.close();
  });
  return app;
}
