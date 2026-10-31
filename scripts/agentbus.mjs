#!/usr/bin/env node
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readSync, readFileSync, statSync, unlinkSync, writeFileSync, writeSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Agent bus: one append-only transcript under docs/Communication with two transports.
// HTTP relay when bus/run/server.json is alive, direct file writes when it is not.

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const busRoot = resolve(process.env.AGENTBUS_DIR || join(repoRoot, 'docs', 'Communication'));
const busDir = join(busRoot, 'bus');
const transcriptPath = join(busDir, 'transcript.jsonl');
const ackDir = join(busDir, 'ack');
const runDir = join(busDir, 'run');
const serverFile = join(runDir, 'server.json');
const serverLog = join(runDir, 'server.log');
const lockPath = join(busDir, 'lock');
const leaseFile = join(busDir, 'leases.json');
const digestPath = join(busRoot, 'THREADS.md');

const VERSION = 1;
const KINDS = ['note', 'question', 'answer', 'proposal', 'decision', 'patch', 'review', 'blocker', 'ack'];
const DEFAULT_TIMEOUT_MS = 90000;
const LOCK_STALE_MS = 10000;
const REPEATABLE = new Set(['ref', 'attach']);

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

class UsageError extends Error {}

function ensureLayout() {
  mkdirSync(busDir, { recursive: true });
  mkdirSync(ackDir, { recursive: true });
  mkdirSync(runDir, { recursive: true });
}

function agentName(raw) {
  const name = String(raw || '').trim().toLowerCase();
  if (!/^[a-z0-9][a-z0-9._-]{0,63}$/.test(name)) throw new UsageError('agent name must match [a-z0-9][a-z0-9._-]{0,63}, got ' + JSON.stringify(raw));
  return name;
}

// ---------------------------------------------------------------- transcript

function readAll() {
  if (!existsSync(transcriptPath)) return [];
  const text = readFileSync(transcriptPath, 'utf8');
  const out = [];
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const parsed = JSON.parse(trimmed);
      if (parsed && typeof parsed.seq === 'number') out.push(parsed);
    } catch {
      // A torn trailing line is a crash artifact, not a message.
    }
  }
  return out;
}

function lastSeq() {
  if (!existsSync(transcriptPath)) return 0;
  const size = statSync(transcriptPath).size;
  if (!size) return 0;
  const start = Math.max(0, size - 65536);
  const length = size - start;
  const buffer = Buffer.alloc(length);
  const fd = openSync(transcriptPath, 'r');
  try {
    readSync(fd, buffer, 0, length, start);
  } finally {
    closeSync(fd);
  }
  const lines = buffer.toString('utf8').split('\n').filter((line) => line.trim());
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    try {
      const parsed = JSON.parse(lines[index]);
      if (parsed && typeof parsed.seq === 'number') return parsed.seq;
    } catch {
      // Keep walking back over a partial line.
    }
  }
  return 0;
}

// ---------------------------------------------------------------- lock

function acquireLock(timeoutMs = 6000) {
  ensureLayout();
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    try {
      const fd = openSync(lockPath, 'wx');
      writeSync(fd, process.pid + ' ' + new Date().toISOString());
      closeSync(fd);
      return;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      let stale = false;
      try {
        stale = Date.now() - statSync(lockPath).mtimeMs > LOCK_STALE_MS;
      } catch {
        stale = true;
      }
      if (stale) {
        try {
          unlinkSync(lockPath);
        } catch {
          // Another writer cleared it first.
        }
        continue;
      }
      if (Date.now() > deadline) throw new UsageError('agentbus lock is busy: ' + lockPath);
      sleepSync(15);
    }
  }
}

function releaseLock() {
  try {
    unlinkSync(lockPath);
  } catch {
    // Already gone.
  }
}

function withLock(fn) {
  acquireLock();
  try {
    return fn();
  } finally {
    releaseLock();
  }
}

// ---------------------------------------------------------------- messages

function normaliseKind(raw) {
  const kind = String(raw || 'note').trim().toLowerCase();
  if (!KINDS.includes(kind)) throw new UsageError('unknown kind ' + kind + ', use one of ' + KINDS.join('|'));
  return kind;
}

function recipientsOf(message) {
  return String(message.to || '')
    .split(',')
    .map((part) => part.trim().toLowerCase())
    .filter(Boolean);
}

function isFor(message, agent) {
  if (message.from === agent) return false;
  const recipients = recipientsOf(message);
  return recipients.includes('*') || recipients.includes(agent);
}

function composeMessage(input) {
  const from = agentName(input.from);
  const recipients = String(input.to || '*')
    .split(',')
    .map((part) => part.trim().toLowerCase())
    .filter(Boolean)
    .map((part) => (part === '*' ? '*' : agentName(part)));
  if (!recipients.length) throw new UsageError('--to is required');
  const subject = String(input.subject || '').replace(/\s+/g, ' ').trim();
  if (!subject) throw new UsageError('--subject is required');
  if (subject.length > 200) throw new UsageError('--subject is longer than 200 characters');
  const refs = Array.isArray(input.ref) ? input.ref : input.ref ? [input.ref] : [];
  const attachments = Array.isArray(input.attach) ? input.attach : input.attach ? [input.attach] : [];
  return {
    from,
    to: recipients.join(','),
    kind: normaliseKind(input.kind),
    subject,
    body: String(input.body === undefined ? '' : input.body),
    refs,
    attachments,
    meta: input.meta && typeof input.meta === 'object' ? input.meta : {},
  };
}

function appendMessage(input) {
  ensureLayout();
  const message = withLock(() => {
    const seq = lastSeq() + 1;
    const id = 'm' + String(seq).padStart(6, '0');
    const record = {
      seq,
      id,
      at: new Date().toISOString(),
      from: input.from,
      to: input.to,
      kind: input.kind,
      thread: input.thread || id,
      subject: input.subject,
      body: input.body,
      refs: input.refs,
      attachments: input.attachments,
      meta: input.meta,
    };
    appendFileSync(transcriptPath, JSON.stringify(record) + '\n', 'utf8');
    return record;
  });
  refreshDigest();
  return message;
}

function createMessage(input) {
  const draft = composeMessage(input);
  if (draft.refs.length) {
    const byId = new Map(readAll().map((message) => [message.id, message]));
    for (const ref of draft.refs) {
      const parent = byId.get(ref);
      if (parent) {
        draft.thread = parent.thread || parent.id;
        break;
      }
    }
  }
  return appendMessage(draft);
}

function selectMessages(options) {
  const agent = options.as ? agentName(options.as) : null;
  const after = Number(options.after || 0);
  const limit = Number(options.limit || 200);
  return readAll()
    .filter((message) => message.seq > after)
    .filter((message) => (agent ? isFor(message, agent) : true))
    .slice(-limit);
}

function cursorFor(agent) {
  const file = join(ackDir, agent + '.json');
  if (!existsSync(file)) return 0;
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8'));
    return Number.isFinite(parsed.lastSeq) ? parsed.lastSeq : 0;
  } catch {
    return 0;
  }
}

function setCursor(agent, seq) {
  ensureLayout();
  const value = Number.isFinite(Number(seq)) ? Number(seq) : lastSeq();
  writeFileSync(join(ackDir, agent + '.json'), JSON.stringify({ agent, lastSeq: value, at: new Date().toISOString() }, null, 2), 'utf8');
  return value;
}

// ---------------------------------------------------------------- leases

function readLeases() {
  if (!existsSync(leaseFile)) return {};
  try {
    return JSON.parse(readFileSync(leaseFile, 'utf8')) || {};
  } catch {
    return {};
  }
}

function writeLeases(leases) {
  writeFileSync(leaseFile, JSON.stringify(leases, null, 2) + '\n', 'utf8');
}

function normalisePath(raw) {
  return String(raw || '').replace(/\\/g, '/').replace(/^\.\//, '').trim();
}

function claimLease(owner, paths) {
  return withLock(() => {
    const leases = readLeases();
    const taken = [];
    for (const path of paths) {
      const current = leases[path];
      if (current && current.owner !== owner) taken.push(path + ' (' + current.owner + ')');
    }
    if (taken.length) {
      const error = new UsageError('lease conflict: ' + taken.join(', '));
      error.exitCode = 5;
      throw error;
    }
    for (const path of paths) leases[path] = { owner, at: new Date().toISOString() };
    writeLeases(leases);
    return paths;
  });
}

function releaseLease(owner, paths) {
  return withLock(() => {
    const leases = readLeases();
    const released = [];
    for (const path of paths) {
      if (leases[path] && leases[path].owner === owner) {
        delete leases[path];
        released.push(path);
      }
    }
    writeLeases(leases);
    return released;
  });
}

// ---------------------------------------------------------------- digest

function pad(value) {
  return String(value).padStart(2, '0');
}

function formatTime(iso) {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return String(iso);
  return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
}

function refreshDigest() {
  try {
    const all = readAll();
    const lines = ['# 通信记录', '', '> 由 scripts/agentbus.mjs 生成，请勿手工改写。权威数据：bus/transcript.jsonl。', ''];
    if (!all.length) {
      lines.push('_暂无消息。_', '');
    } else {
      const threads = new Map();
      for (const message of all) {
        const key = message.thread || message.id;
        if (!threads.has(key)) threads.set(key, []);
        threads.get(key).push(message);
      }
      for (const [key, messages] of threads) {
        lines.push('## ' + messages[0].subject, '', 'thread ' + key + ' · ' + messages.length + ' 条', '');
        for (const message of messages) {
          lines.push('### ' + message.id + ' · ' + formatTime(message.at) + ' · ' + message.from + ' → ' + message.to + ' · ' + message.kind, '');
          if (message.refs.length) lines.push('引用：' + message.refs.join('、'), '');
          if (message.attachments.length) lines.push('附件：' + message.attachments.join('、'), '');
          lines.push(message.body || '_（空正文）_', '');
        }
      }
    }
    writeFileSync(digestPath, lines.join('\n'), 'utf8');
  } catch {
    // A digest failure never blocks delivery.
  }
}

// ---------------------------------------------------------------- transport

function readServerInfo() {
  if (!existsSync(serverFile)) return null;
  try {
    const info = JSON.parse(readFileSync(serverFile, 'utf8'));
    return info && info.port ? info : null;
  } catch {
    return null;
  }
}

async function serverAlive(info, timeoutMs = 600) {
  if (!info) return false;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch('http://' + info.host + ':' + info.port + '/health', { signal: controller.signal });
    if (!response.ok) return false;
    const health = await response.json();
    return health.ok === true && health.pid === info.pid;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function resolveTransport(flags = {}) {
  if (flags.http === 'true') {
    const info = readServerInfo();
    if (!info) throw new UsageError('no bus server registered (bus/run/server.json is missing)');
    return { mode: 'http', info };
  }
  if (flags.file === 'true') return { mode: 'file' };
  const info = readServerInfo();
  if (info && (await serverAlive(info))) return { mode: 'http', info };
  if (info) {
    const age = Date.now() - (info.startedAt ? Date.parse(info.startedAt) : 0);
    if (age > 15000) {
      try {
        unlinkSync(serverFile);
      } catch {
        // Raced with a fresh server.
      }
    }
  }
  return { mode: 'file' };
}

async function busRequest(info, method, path, options = {}) {
  const url = new URL('http://' + info.host + ':' + info.port + path);
  for (const [key, value] of Object.entries(options.query || {})) {
    if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs || 5000);
  try {
    const response = await fetch(url, {
      method,
      headers: { 'x-agentbus-token': info.token, ...(options.body ? { 'content-type': 'application/json' } : {}) },
      body: options.body ? JSON.stringify(options.body) : undefined,
      signal: controller.signal,
    });
    const text = await response.text();
    let payload = null;
    try {
      payload = text ? JSON.parse(text) : null;
    } catch {
      payload = { error: text };
    }
    if (!response.ok) throw new Error('bus server ' + response.status + ': ' + (payload && payload.error ? payload.error : text));
    return payload;
  } finally {
    clearTimeout(timer);
  }
}
// ---------------------------------------------------------------- server

function logLine(text) {
  try {
    appendFileSync(serverLog, formatTime(new Date().toISOString()) + ' ' + text + '\n', 'utf8');
  } catch {
    // Logging is best effort.
  }
}

async function startServer(flags) {
  ensureLayout();
  const existing = readServerInfo();
  if (existing && (await serverAlive(existing))) {
    throw new UsageError('bus server already running on ' + existing.host + ':' + existing.port + ' (pid ' + existing.pid + ')');
  }
  const host = String(flags.host && flags.host !== 'true' ? flags.host : '127.0.0.1');
  const preferred = Number(flags.port && flags.port !== 'true' ? flags.port : process.env.AGENTBUS_PORT || 8722);
  const token = randomUUID().replace(/-/g, '');
  const startedAt = new Date().toISOString();
  const waiters = new Set();

  const notify = (message) => {
    for (const waiter of [...waiters]) {
      if (message.seq > waiter.after && isFor(message, waiter.agent)) {
        waiters.delete(waiter);
        clearTimeout(waiter.timer);
        waiter.done({ messages: [message], seq: lastSeq(), timeout: false });
      }
    }
  };

  const parseBody = (request) =>
    new Promise((done, fail) => {
      let raw = '';
      request.on('data', (chunk) => {
        raw += chunk;
        if (raw.length > 4194304) {
          fail(new Error('request body too large'));
          request.destroy();
        }
      });
      request.on('end', () => {
        if (!raw) return done({});
        try {
          done(JSON.parse(raw));
        } catch {
          fail(new Error('invalid JSON body'));
        }
      });
      request.on('error', fail);
    });

  const sendJson = (response, status, payload) => {
    const text = JSON.stringify(payload);
    response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) });
    response.end(text);
  };

  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://' + host);
    const route = url.pathname;
    try {
      if (route === '/health' && request.method === 'GET') {
        return sendJson(response, 200, { ok: true, pid: process.pid, seq: lastSeq(), startedAt, version: VERSION, waiters: waiters.size });
      }
      if (request.headers['x-agentbus-token'] !== token) {
        return sendJson(response, 401, { error: 'bad or missing x-agentbus-token' });
      }
      if (route === '/send' && request.method === 'POST') {
        const message = createMessage(await parseBody(request));
        notify(message);
        return sendJson(response, 201, { message });
      }
      if (route === '/messages' && request.method === 'GET') {
        return sendJson(response, 200, {
          messages: selectMessages({ as: url.searchParams.get('as') || undefined, after: url.searchParams.get('after'), limit: url.searchParams.get('limit') }),
          seq: lastSeq(),
        });
      }
      if (route === '/wait' && request.method === 'GET') {
        const agent = agentName(url.searchParams.get('as'));
        const after = Number(url.searchParams.get('after') || 0);
        const timeoutMs = Math.max(0, Math.min(600000, Number(url.searchParams.get('timeout') || DEFAULT_TIMEOUT_MS)));
        const ready = selectMessages({ as: agent, after, limit: 200 });
        if (ready.length) return sendJson(response, 200, { messages: ready, seq: lastSeq(), timeout: false });
        if (!timeoutMs) return sendJson(response, 200, { messages: [], seq: lastSeq(), timeout: true });
        return await new Promise((done) => {
          const waiter = {
            agent,
            after,
            done: (payload) => {
              if (waiters.delete(waiter)) clearTimeout(waiter.timer);
              sendJson(response, 200, payload);
              done();
            },
          };
          waiter.timer = setTimeout(() => waiter.done({ messages: [], seq: lastSeq(), timeout: true }), timeoutMs);
          waiters.add(waiter);
          request.on('close', () => {
            if (waiters.delete(waiter)) clearTimeout(waiter.timer);
          });
        });
      }
      if (route === '/ack' && request.method === 'POST') {
        const body = await parseBody(request);
        const agent = agentName(body.as || url.searchParams.get('as'));
        return sendJson(response, 200, { as: agent, lastSeq: setCursor(agent, body.seq === undefined ? lastSeq() : body.seq) });
      }
      if (route === '/acks' && request.method === 'GET') {
        const agent = agentName(url.searchParams.get('as'));
        return sendJson(response, 200, { as: agent, lastSeq: cursorFor(agent) });
      }
      if (route === '/log' && request.method === 'GET') {
        const tail = Math.max(1, Math.min(2000, Number(url.searchParams.get('tail') || 50)));
        return sendJson(response, 200, { messages: readAll().slice(-tail), seq: lastSeq() });
      }
      if (route === '/shutdown' && request.method === 'POST') {
        sendJson(response, 200, { ok: true, stopping: process.pid });
        setTimeout(() => stop('shutdown request'), 30);
        return undefined;
      }
      return sendJson(response, 404, { error: 'no route ' + request.method + ' ' + route });
    } catch (error) {
      return sendJson(response, 400, { error: error.message });
    }
  });

  const stop = (reason) => {
    for (const waiter of [...waiters]) {
      waiters.delete(waiter);
      clearTimeout(waiter.timer);
      waiter.done({ messages: [], seq: lastSeq(), timeout: true, closing: true });
    }
    server.close(() => {
      const info = readServerInfo();
      if (info && info.pid === process.pid) {
        try {
          unlinkSync(serverFile);
        } catch {
          // Already removed.
        }
      }
      process.exit(0);
    });
    setTimeout(() => process.exit(0), 1500);
    if (reason) logLine('stopping: ' + reason);
  };

  let port = preferred;
  for (let attempt = 0; attempt < 25; attempt += 1) {
    try {
      await new Promise((done, fail) => {
        const onError = (error) => {
          server.removeListener('listening', onListening);
          fail(error);
        };
        const onListening = () => {
          server.removeListener('error', onError);
          done();
        };
        server.once('error', onError);
        server.once('listening', onListening);
        server.listen(port, host);
      });
      break;
    } catch (error) {
      if (error.code !== 'EADDRINUSE' || attempt === 24) throw error;
      if (port !== 0) port += 1;
    }
  }

  const address = server.address();
  const info = { pid: process.pid, host, port: address.port, token, startedAt, version: VERSION, root: busRoot };
  writeFileSync(serverFile, JSON.stringify(info, null, 2), 'utf8');

  process.on('SIGINT', () => stop('SIGINT'));
  process.on('SIGTERM', () => stop('SIGTERM'));
  process.on('uncaughtException', (error) => logLine('uncaught: ' + (error && error.stack ? error.stack : error)));

  return info;
}

// ---------------------------------------------------------------- render

function renderMessage(message, options = {}) {
  const lines = [];
  lines.push('[' + message.id + '] ' + formatTime(message.at) + ' ' + message.from + ' -> ' + message.to + ' . ' + message.kind);
  if (!options.compact) lines.push('  ' + message.subject);
  if (message.refs.length) lines.push('  refs: ' + message.refs.join(' '));
  if (message.attachments.length) lines.push('  files: ' + message.attachments.join(' '));
  if (!options.compact) {
    const text = String(message.body || '').trimEnd();
    if (text) for (const line of text.split('\n')) lines.push('  ' + line);
  }
  return lines.join('\n');
}

function renderList(messages) {
  return messages.map((message) => renderMessage(message, { compact: messages.length > 6 })).join('\n\n');
}

// ---------------------------------------------------------------- cli

function parseArgs(argv) {
  const flags = {};
  const positional = [];
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token.startsWith('--')) {
      const equals = token.indexOf('=');
      let key;
      let value;
      if (equals !== -1) {
        key = token.slice(2, equals);
        value = token.slice(equals + 1);
      } else {
        key = token.slice(2);
        const next = argv[index + 1];
        if (next !== undefined && !next.startsWith('--')) {
          value = next;
          index += 1;
        } else {
          value = 'true';
        }
      }
      if (REPEATABLE.has(key)) {
        flags[key] = flags[key] || [];
        flags[key].push(value);
      } else {
        flags[key] = value;
      }
    } else {
      positional.push(token);
    }
  }
  return { flags, positional };
}

function flagOn(value) {
  return value === 'true' || value === true || value === '1';
}

function readBody(flags) {
  const encoded = flags['body-b64'];
  if (encoded && encoded !== 'true') return Buffer.from(encoded, 'base64').toString('utf8');
  const file = flags['body-file'];
  if (file && file !== 'true') {
    if (file === '-') return readFileSync(0, 'utf8');
    return readFileSync(resolve(String(file)), 'utf8');
  }
  const inline = flags.body;
  return inline && inline !== 'true' ? String(inline) : '';
}

async function cmdSend(flags) {
  const payload = {
    from: flags.from,
    to: flags.to === undefined ? '*' : flags.to,
    kind: flags.kind === undefined ? 'note' : flags.kind,
    subject: flags.subject,
    body: readBody(flags),
    ref: flags.ref,
    attach: flags.attach,
  };
  const transport = await resolveTransport(flags);
  const message = transport.mode === 'http'
    ? (await busRequest(transport.info, 'POST', '/send', { body: payload })).message
    : createMessage(payload);
  if (flagOn(flags.json)) return console.log(JSON.stringify(message, null, 2));
  console.log('sent ' + message.id + ' -> ' + message.to + ' (' + message.kind + ') via ' + transport.mode);
}

async function cmdInbox(flags) {
  const agent = agentName(flags.as);
  const after = flagOn(flags.all) ? 0 : cursorFor(agent);
  const limit = Number(flags.limit || 50);
  const transport = await resolveTransport(flags);
  const result = transport.mode === 'http'
    ? await busRequest(transport.info, 'GET', '/messages', { query: { as: agent, after, limit } })
    : { messages: selectMessages({ as: agent, after, limit }), seq: lastSeq() };
  if (flagOn(flags.json)) return console.log(JSON.stringify(result, null, 2));
  if (!result.messages.length) return console.log('inbox ' + agent + ': nothing after seq ' + after + ' (last ' + result.seq + ')');
  console.log('inbox ' + agent + ': ' + result.messages.length + ' message(s) after seq ' + after);
  console.log('');
  console.log(renderList(result.messages));
}

async function waitOnce(agent, after, timeoutMs, transport) {
  if (transport.mode === 'http') {
    return busRequest(transport.info, 'GET', '/wait', { query: { as: agent, after, timeout: timeoutMs }, timeoutMs: timeoutMs + 8000 });
  }
  const started = Date.now();
  for (;;) {
    const messages = selectMessages({ as: agent, after, limit: 200 });
    if (messages.length) return { messages, seq: lastSeq(), timeout: false };
    if (Date.now() - started >= timeoutMs) return { messages: [], seq: lastSeq(), timeout: true };
    await sleep(Math.min(250, Math.max(50, timeoutMs)));
  }
}

function timeoutFlag(value) {
  if (value === undefined) return DEFAULT_TIMEOUT_MS;
  const text = String(value).trim();
  const match = /^([0-9]*\.?[0-9]+)(ms|s|m)?$/.exec(text);
  if (!match) throw new UsageError('--timeout must look like 5000, 5s or 1.5s');
  const amount = Number(match[1]);
  const unit = match[2] || 'ms';
  const factor = unit === 'm' ? 60000 : unit === 's' ? 1000 : 1;
  return Math.round(amount * factor);
}

async function cmdWait(flags) {
  const agent = agentName(flags.as);
  const after = flags.after === undefined ? cursorFor(agent) : Number(flags.after);
  const timeoutMs = timeoutFlag(flags.timeout);
  const transport = await resolveTransport(flags);
  const result = await waitOnce(agent, after, timeoutMs, transport);
  if (flagOn(flags.mark)) {
    const top = result.messages.reduce((max, message) => Math.max(max, message.seq), after);
    if (transport.mode === 'http') await busRequest(transport.info, 'POST', '/ack', { body: { as: agent, seq: top } });
    else setCursor(agent, top);
  }
  if (flagOn(flags.json)) {
    console.log(JSON.stringify(result, null, 2));
  } else if (result.messages.length) {
    console.log(renderList(result.messages));
  } else {
    console.log('timeout: nothing for ' + agent + ' after seq ' + after + ' within ' + timeoutMs + 'ms');
  }
  if (!result.messages.length) process.exitCode = 3;
}

async function cmdWatch(flags) {
  const agent = agentName(flags.as);
  const transport = await resolveTransport(flags);
  let after = flags.after === undefined ? cursorFor(agent) : Number(flags.after);
  const tick = timeoutFlag(flags.timeout);
  console.log('watching ' + agent + ' after seq ' + after + ' via ' + transport.mode);
  for (;;) {
    const result = await waitOnce(agent, after, tick, transport);
    for (const message of result.messages) {
      console.log('');
      console.log(renderMessage(message));
      after = Math.max(after, message.seq);
    }
    if (flagOn(flags.once) && result.messages.length) return;
  }
}

async function cmdAck(flags) {
  const agent = agentName(flags.as);
  const seq = flags.seq === undefined ? lastSeq() : Number(flags.seq);
  const transport = await resolveTransport(flags);
  const result = transport.mode === 'http'
    ? await busRequest(transport.info, 'POST', '/ack', { body: { as: agent, seq } })
    : { as: agent, lastSeq: setCursor(agent, seq) };
  console.log('ack ' + result.as + ' up to seq ' + result.lastSeq);
}

async function cmdLog(flags) {
  const messages = readAll().slice(-Number(flags.tail || 20));
  if (flagOn(flags.json)) return console.log(JSON.stringify(messages, null, 2));
  console.log(messages.map((message) => renderMessage(message, { compact: true })).join('\n'));
}

async function cmdShow(flags, positional) {
  const id = positional[0] || flags.id;
  if (!id || id === 'true') throw new UsageError('show needs a message id');
  const message = readAll().find((item) => item.id === id || String(item.seq) === String(id));
  if (!message) throw new UsageError('no such message ' + id);
  if (flagOn(flags.json)) return console.log(JSON.stringify(message, null, 2));
  console.log(renderMessage(message));
  if (Object.keys(message.meta || {}).length) console.log('\nmeta: ' + JSON.stringify(message.meta));
}

async function cmdStatus(flags) {
  const info = readServerInfo();
  const alive = info ? await serverAlive(info) : false;
  const messages = readAll();
  const agents = [...new Set(messages.flatMap((message) => [message.from, ...recipientsOf(message)]).filter((name) => name && name !== '*'))].sort();
  const report = {
    root: busRoot,
    mode: alive ? 'http' : 'file',
    server: info ? { host: info.host, port: info.port, pid: info.pid, alive, startedAt: info.startedAt } : null,
    messages: messages.length,
    lastSeq: messages.length ? messages[messages.length - 1].seq : 0,
    agents: agents.map((name) => ({ name, cursor: cursorFor(name), pending: messages.filter((message) => message.seq > cursorFor(name) && isFor(message, name)).length })),
    leases: readLeases(),
  };
  if (flagOn(flags.json)) return console.log(JSON.stringify(report, null, 2));
  console.log('root      ' + report.root);
  console.log('transport ' + (alive ? 'http ' + info.host + ':' + info.port + ' (pid ' + info.pid + ')' : 'file (no server)'));
  console.log('messages  ' + report.messages + ' (last seq ' + report.lastSeq + ')');
  for (const agent of report.agents) console.log('agent     ' + agent.name + ' cursor ' + agent.cursor + ' pending ' + agent.pending);
  const leases = Object.entries(report.leases);
  for (const [path, lease] of leases) console.log('lease     ' + path + ' -> ' + lease.owner);
}

async function cmdDoctor(flags) {
  const checks = [];
  const add = (name, ok, detail) => checks.push({ name, ok, detail });
  add('bus directory', existsSync(busDir), busDir);
  const messages = readAll();
  let monotonic = true;
  let previous = 0;
  const seen = new Set();
  let duplicates = 0;
  for (const message of messages) {
    if (message.seq <= previous) monotonic = false;
    previous = message.seq;
    if (seen.has(message.id)) duplicates += 1;
    seen.add(message.id);
  }
  add('seq strictly increasing', monotonic, messages.length + ' message(s)');
  add('message ids unique', duplicates === 0, duplicates + ' duplicate(s)');
  const dangling = messages.flatMap((message) => message.refs.filter((ref) => !seen.has(ref)));
  add('refs resolvable', dangling.length === 0, dangling.slice(0, 5).join(' ') || 'all refs known');
  const orphans = messages.filter((message) => !message.thread || !seen.has(message.thread));
  add('threads resolve', orphans.length === 0, orphans.length + ' unresolved');
  const info = readServerInfo();
  const alive = info ? await serverAlive(info) : false;
  add('server', true, info ? (alive ? 'running at ' + info.host + ':' + info.port : 'registered but silent (file fallback active)') : 'not running (file fallback active)');
  add('digest', existsSync(digestPath), digestPath);
  const conflicts = [];
  const leases = readLeases();
  const byPath = new Map();
  for (const [path, lease] of Object.entries(leases)) {
    if (byPath.has(path)) conflicts.push(path);
    byPath.set(path, lease.owner);
  }
  add('leases unique', conflicts.length === 0, Object.keys(leases).length + ' lease(s)');
  if (flagOn(flags.json)) return console.log(JSON.stringify({ ok: checks.every((check) => check.ok), checks }, null, 2));
  for (const check of checks) console.log((check.ok ? 'PASS ' : 'FAIL ') + check.name + (check.detail ? ' -- ' + check.detail : ''));
  if (!checks.every((check) => check.ok)) process.exitCode = 4;
}

async function cmdStop() {
  const info = readServerInfo();
  if (!info) return console.log('no bus server registered');
  if (!(await serverAlive(info))) {
    unlinkSync(serverFile);
    return console.log('server was silent; registration removed');
  }
  await busRequest(info, 'POST', '/shutdown', { body: {} });
  for (let attempt = 0; attempt < 40; attempt += 1) {
    if (!(await serverAlive(info, 300))) return console.log('bus server stopped (pid ' + info.pid + ')');
    await sleep(100);
  }
  console.log('stop requested for pid ' + info.pid);
}

async function cmdLease(flags, positional) {
  const owner = agentName(flags.owner);
  const paths = positional.map(normalisePath).filter(Boolean);
  if (!paths.length) throw new UsageError('lease needs at least one path');
  const result = flagOn(flags.release) ? releaseLease(owner, paths) : claimLease(owner, paths);
  if (flagOn(flags.json)) return console.log(JSON.stringify({ owner, released: flagOn(flags.release), paths: result }, null, 2));
  console.log((flagOn(flags.release) ? 'released ' : 'claimed ') + result.length + ' path(s) for ' + owner);
  for (const path of result) console.log('  ' + path);
}

function cmdLeases(flags) {
  const leases = readLeases();
  const rows = Object.entries(leases).sort((a, b) => a[0].localeCompare(b[0]));
  if (flagOn(flags.json)) return console.log(JSON.stringify(rows.map(([path, lease]) => ({ path, ...lease })), null, 2));
  if (!rows.length) return console.log('no leases');
  for (const [path, lease] of rows) console.log(path.padEnd(48) + ' ' + lease.owner + '  ' + lease.at);
}

const HELP = [
  'agentbus - local agent channel under docs/Communication',
  '',
  '  init                                        create the layout',
  '  serve [--port 8722] [--host 127.0.0.1]      start the long-poll relay',
  '  stop                                        stop the relay',
  '  status [--json]                             transport, cursors, leases',
  '  send --from A --to B --subject S [--kind K] [--body-file f|-] [--ref ID] [--attach p]',
  '  inbox --as A [--all] [--limit N] [--json]',
  '  wait --as A [--after SEQ] [--timeout 30s] [--mark] [--json]    (exit 3 on timeout)',
  '  watch --as A [--after SEQ] [--once]',
  '  ack --as A [--seq N]',
  '  log [--tail N] [--json] | show <id>',
  '  digest                                      rebuild THREADS.md',
  '  lease --owner A path... [--release] [--json] | leases [--json]',
  '  doctor [--json]                             self-check (exit 4 on failure)',
  '',
  '  Transport: HTTP when bus/run/server.json is alive, else direct file writes.',
  '  Force with --http or --file.',
].join('\n');

async function main(argv) {
  const { flags, positional } = parseArgs(argv);
  const command = positional.shift() || 'help';
  if (flagOn(flags.help) || command === 'help' || command === '--help') {
    console.log(HELP);
    return;
  }
  switch (command) {
    case 'init':
      ensureLayout();
      refreshDigest();
      return console.log('layout ready: ' + busRoot);
    case 'serve': {
      const info = await startServer(flags);
      logLine('listening on ' + info.host + ':' + info.port + ' pid ' + info.pid);
      if (!flagOn(flags.quiet)) {
        console.log('agentbus listening on http://' + info.host + ':' + info.port + ' (pid ' + info.pid + ')');
        console.log('state: ' + busDir);
      }
      return await new Promise(() => {});
    }
    case 'stop':
      return cmdStop();
    case 'status':
      return cmdStatus(flags);
    case 'send':
      return cmdSend(flags);
    case 'inbox':
      return cmdInbox(flags);
    case 'wait':
      return cmdWait(flags);
    case 'watch':
      return cmdWatch(flags);
    case 'ack':
      return cmdAck(flags);
    case 'log':
      return cmdLog(flags);
    case 'show':
      return cmdShow(flags, positional);
    case 'digest':
      refreshDigest();
      return console.log('digest written: ' + digestPath);
    case 'doctor':
      return cmdDoctor(flags);
    case 'lease':
      return cmdLease(flags, positional);
    case 'leases':
      return cmdLeases(flags);
    default:
      throw new UsageError('unknown command ' + command + '\n\n' + HELP);
  }
}

main(process.argv.slice(2)).catch((error) => {
  if (error instanceof UsageError) {
    console.error('agentbus: ' + error.message);
    process.exitCode = error.exitCode || 2;
    return;
  }
  console.error('agentbus: ' + (error && error.stack ? error.stack : error));
  process.exitCode = 1;
});