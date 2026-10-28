import type { RtcScope, RtcCandidate, RtcSession, RtcView } from "../../packages/protocol/src/index.ts";
import { PEER_TTL_SECONDS } from "../../packages/protocol/src/index.ts";
export type { RtcScope, RtcCandidate } from "../../packages/protocol/src/index.ts";
export interface RtcAttempt {
  transferId: string;
  fileId: string;
  attemptId: string;
  sourceDeviceId: string;
  targetDeviceId: string;
  scope: RtcScope;
  offset: number;
  expires: number;
  transferExpires: number;
  state: "negotiating" | "streaming" | "failed";
  offer: string | null;
  answer: string | null;
  candidates: { source: RtcCandidate[]; target: RtcCandidate[] };
  error?: string;
}

function fail(code: string, message: string, statusCode = 409): never {
  throw Object.assign(new Error(message), { code, statusCode });
}
export function validateDataDescription(sdp: string) {
  if (!/^v=0\r?\n/.test(sdp) || !/^m=application /m.test(sdp) || /^m=(?!application )/m.test(sdp))
    fail("INVALID_SDP", "Only data-channel SDP is accepted", 400);
}
export function validateIceCandidate(candidate: RtcCandidate) {
  if (/[\r\n]/.test(candidate.candidate)) fail("INVALID_CANDIDATE", "Expected one ICE candidate", 400);
}

/** Transient signaling only; no file bytes, credentials or persistent events. */
export class RtcRegistry {
  private readonly capabilities = new Map<string, { scopes: RtcScope[]; expires: number; parallelProbes?: boolean }>();
  private readonly attempts = new Map<string, RtcAttempt>();
  private readonly candidateExpires = new WeakMap<RtcCandidate, number>();
  private readonly descriptionExpires = new WeakMap<RtcAttempt, { offer: number; answer: number }>();
  private readonly now: () => number;
  constructor(now: () => number = Date.now) { this.now = now; }
  capability(deviceId: string) {
    const value = this.capabilities.get(deviceId);
    return value && value.expires > this.now()
      ? { scopes: [...value.scopes], expiresAt: new Date(value.expires).toISOString(), ...(value.parallelProbes ? {parallelProbes:true} : {}) }
      : null;
  }
  register(deviceId: string, scopes: RtcScope[], parallelProbes = false) {
    const previous = this.capability(deviceId);
    if (scopes.length) this.capabilities.set(deviceId, { scopes: [...scopes].sort(), expires: this.now() + PEER_TTL_SECONDS * 1000, parallelProbes });
    else this.capabilities.delete(deviceId);
    return JSON.stringify(previous?.scopes ?? []) !== JSON.stringify([...scopes].sort()) || Boolean(previous?.parallelProbes) !== parallelProbes;
  }
  forgetDevice(deviceId: string) {
    this.capabilities.delete(deviceId);
    const removed: RtcAttempt[] = [];
    for (const [id, attempt] of this.attempts) {
      if (attempt.sourceDeviceId === deviceId || attempt.targetDeviceId === deviceId) {
        this.attempts.delete(id); removed.push(attempt);
      }
    }
    return removed;
  }
  clear(transferId: string, fileId: string) { this.attempts.delete(`${transferId}/${fileId}`); }
  current(transferId: string, fileId: string) {
    const attempt = this.attempts.get(`${transferId}/${fileId}`);
    if (attempt) this.expireAddresses(attempt);
    return attempt && attempt.expires > this.now() ? attempt : null;
  }
  private expireAddresses(attempt: RtcAttempt) {
    for (const role of ["source", "target"] as const)
      attempt.candidates[role] = attempt.candidates[role].filter(value => (this.candidateExpires.get(value) ?? 0) > this.now());
    const expiry = this.descriptionExpires.get(attempt);
    if (expiry && expiry.offer <= this.now()) attempt.offer = null;
    if (expiry && expiry.answer <= this.now()) attempt.answer = null;
  }
  create(input: Pick<RtcAttempt, "transferId"|"fileId"|"attemptId"|"sourceDeviceId"|"targetDeviceId"|"scope"|"offset"|"transferExpires">) {
    for (const deviceId of [input.sourceDeviceId, input.targetDeviceId]) {
      if (!this.capability(deviceId)?.scopes.includes(input.scope)) {
        fail("RTC_UNAVAILABLE", "Both devices must support this WebRTC scope");
      }
    }
    const previous = this.current(input.transferId, input.fileId);
    if (previous?.attemptId === input.attemptId) {
      if (previous.scope !== input.scope || previous.offset !== input.offset) {
        fail("ATTEMPT_CONFLICT", "WebRTC attempt parameters changed");
      }
      return previous;
    }
    const attempt: RtcAttempt = { ...input, expires: Math.min(input.transferExpires, this.now() + 60000),
      state: "negotiating", offer: null, answer: null, candidates: { source: [], target: [] } };
    this.descriptionExpires.set(attempt, { offer: 0, answer: 0 });
    this.attempts.set(`${input.transferId}/${input.fileId}`, attempt);
    return attempt;
  }
  require(transferId: string, fileId: string, attemptId: string, actor: string) {
    const attempt = this.current(transferId, fileId);
    if (!attempt || attempt.attemptId !== attemptId) fail("RTC_ENDED", "WebRTC attempt has ended", 410);
    if (![attempt.sourceDeviceId, attempt.targetDeviceId].includes(actor)) fail("FORBIDDEN", "Not a WebRTC participant", 403);
    return attempt;
  }
  describe(attempt: RtcAttempt, actor: string, type: "offer"|"answer", sdp: string) {
    const expected = type === "offer" ? attempt.targetDeviceId : attempt.sourceDeviceId;
    if (actor !== expected) fail("FORBIDDEN", "Wrong WebRTC signaling role", 403);
    validateDataDescription(sdp);
    if (attempt[type] === sdp) {
      this.descriptionExpires.get(attempt)![type] = this.now() + PEER_TTL_SECONDS * 1000;
      return;
    }
    if (attempt.state !== "negotiating" || type === "answer" && !attempt.offer) {
      fail("INVALID_STATE", "WebRTC description is not expected");
    }
    if (attempt[type] && attempt[type] !== sdp) fail("ATTEMPT_CONFLICT", "WebRTC description already set");
    attempt[type] = sdp;
    this.descriptionExpires.get(attempt)![type] = this.now() + PEER_TTL_SECONDS * 1000;
  }
  candidate(attempt: RtcAttempt, actor: string, candidate: RtcCandidate) {
    this.expireAddresses(attempt);
    if (attempt.state === "failed") fail("RTC_ENDED", "WebRTC attempt failed", 410);
    validateIceCandidate(candidate);
    const values = actor === attempt.sourceDeviceId ? attempt.candidates.source : attempt.candidates.target;
    const existing = values.find(value => value.candidate === candidate.candidate && value.sdpMid === candidate.sdpMid && value.sdpMLineIndex === candidate.sdpMLineIndex);
    if (existing) { this.candidateExpires.set(existing, this.now() + PEER_TTL_SECONDS * 1000); return; }
    if (values.length >= 64) fail("CANDIDATE_LIMIT", "Too many ICE candidates", 429);
    values.push(candidate);
    this.candidateExpires.set(candidate, this.now() + PEER_TTL_SECONDS * 1000);
  }
  started(attempt: RtcAttempt, actor: string) {
    if (actor !== attempt.targetDeviceId) fail("FORBIDDEN", "Only receiver may confirm connection", 403);
    if (!attempt.offer || !attempt.answer || attempt.state === "failed") fail("INVALID_STATE", "WebRTC negotiation is incomplete");
    attempt.state = "streaming";
    attempt.expires = attempt.transferExpires;
  }
  fail(attempt: RtcAttempt, error: string) { attempt.state = "failed"; attempt.error = error; }
  summary(attempt: RtcAttempt): RtcSession {
    return { attemptId: attempt.attemptId, scope: attempt.scope, offset: attempt.offset,
      state: attempt.state, expiresAt: new Date(attempt.expires).toISOString(), ...(attempt.error ? { error: attempt.error } : {}) };
  }
  view(attempt: RtcAttempt): RtcView {
    this.expireAddresses(attempt);
    return { ...this.summary(attempt), transferId: attempt.transferId, fileId: attempt.fileId,
      sourceDeviceId: attempt.sourceDeviceId, targetDeviceId: attempt.targetDeviceId,
      offer: attempt.offer ? { type: "offer", sdp: attempt.offer } : null,
      answer: attempt.answer ? { type: "answer", sdp: attempt.answer } : null,
      candidates: attempt.candidates };
  }
  cleanup() {
    const devices: string[] = [], attempts: RtcAttempt[] = [];
    for (const [id, value] of this.capabilities) if (value.expires <= this.now()) {
      devices.push(id); attempts.push(...this.forgetDevice(id));
    }
    for (const [id, value] of this.attempts) {
      this.expireAddresses(value);
      if (value.expires <= this.now()) { this.attempts.delete(id); attempts.push(value); }
    }
    return { devices, attempts };
  }
}
