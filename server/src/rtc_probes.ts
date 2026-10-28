import type { RtcCandidate, RtcProbePresence, RtcProbeResult, RtcProbeView, RtcScope } from "../../packages/protocol/src/index.ts";
import { validateDataDescription, validateIceCandidate } from "./rtc.ts";

export const PROBE_PRESENCE_MS = 40000;
export const PROBE_SESSION_MS = 12000;
export const PROBE_RESULT_MS = 120000;
type Pair = Pick<RtcProbeView, "initiatorDeviceId" | "responderDeviceId">;
const participants = (pair: Pair) => [pair.initiatorDeviceId, pair.responderDeviceId];
function fail(code: string, message: string, statusCode = 409): never {
  throw Object.assign(new Error(message), { code, statusCode });
}

/** Separate, short-lived data-only reachability signaling. Never creates a transfer. */
export class RtcProbeRegistry {
  private readonly foreground = new Map<string, number>();
  private readonly probes = new Map<string, RtcProbeView>();
  private readonly results = new Map<string, RtcProbeResult>();
  private readonly now: () => number;
  constructor(now: () => number = Date.now) { this.now = now; }
  presence(deviceId: string): RtcProbePresence {
    const expires = this.foreground.get(deviceId) ?? 0;
    return expires > this.now() ? { foreground: true, expiresAt: new Date(expires).toISOString() } : { foreground: false, expiresAt: null };
  }
  setPresence(deviceId: string, foreground: boolean) {
    if (foreground) { this.foreground.set(deviceId, this.now() + PROBE_PRESENCE_MS); return [deviceId]; }
    return this.forgetDevice(deviceId);
  }
  forgetDevice(deviceId: string) {
    const changed = new Set([deviceId]); this.foreground.delete(deviceId);
    for (const entries of [this.probes, this.results]) for (const [id, value] of entries) {
      if (participants(value).includes(deviceId)) { entries.delete(id); for (const peer of participants(value)) changed.add(peer); }
    }
    return [...changed];
  }
  create(initiatorDeviceId: string, responderDeviceId: string, attemptId: string, scope: RtcScope) {
    const previous = this.probes.get(attemptId);
    if (previous) {
      if (previous.initiatorDeviceId !== initiatorDeviceId || previous.responderDeviceId !== responderDeviceId || previous.scope !== scope)
        fail("ATTEMPT_CONFLICT", "Probe attempt parameters changed");
      return previous;
    }
    if (this.results.has(attemptId)) fail("PROBE_ENDED", "Probe attempt has ended", 410);
    for (const deviceId of [initiatorDeviceId, responderDeviceId]) {
      if (!this.presence(deviceId).foreground) fail("PROBE_BACKGROUND", "Both devices must be in the foreground");
      if ([...this.probes.values()].some(value => participants(value).includes(deviceId))) fail("PROBE_BUSY", "A device already has an active probe");
    }
    const probe: RtcProbeView = { attemptId, initiatorDeviceId, responderDeviceId, scope,
      expiresAt: new Date(this.now() + PROBE_SESSION_MS).toISOString(), offer: null, answer: null, candidates: { initiator: [], responder: [] } };
    this.probes.set(attemptId, probe); return probe;
  }
  require(attemptId: string, actor: string) {
    const probe = this.probes.get(attemptId);
    if (!probe || Date.parse(probe.expiresAt) <= this.now()) fail("PROBE_ENDED", "Probe attempt has ended", 410);
    if (!participants(probe).includes(actor)) fail("FORBIDDEN", "Not a probe participant", 403);
    return probe;
  }
  describe(probe: RtcProbeView, actor: string, type: "offer" | "answer", sdp: string) {
    if (actor !== (type === "offer" ? probe.initiatorDeviceId : probe.responderDeviceId)) fail("FORBIDDEN", "Wrong probe signaling role", 403);
    validateDataDescription(sdp);
    if (/^a=candidate:.*\btyp relay\b/m.test(sdp)) fail("INVALID_SDP", "Probe does not use TURN relay", 400);
    if (type === "answer" && !probe.offer) fail("INVALID_STATE", "Probe offer is missing");
    if (probe[type] && probe[type]!.sdp !== sdp) fail("ATTEMPT_CONFLICT", "Probe description already set");
    if (type === "offer") probe.offer = { type, sdp }; else probe.answer = { type, sdp };
  }
  candidate(probe: RtcProbeView, actor: string, candidate: RtcCandidate) {
    validateIceCandidate(candidate);
    if (/\btyp relay\b/.test(candidate.candidate)) fail("INVALID_CANDIDATE", "Probe does not use TURN relay", 400);
    const values = actor === probe.initiatorDeviceId ? probe.candidates.initiator : probe.candidates.responder;
    if (values.some(value => value.candidate === candidate.candidate && value.sdpMid === candidate.sdpMid && value.sdpMLineIndex === candidate.sdpMLineIndex)) return;
    if (values.length >= 64) fail("CANDIDATE_LIMIT", "Too many probe ICE candidates", 429);
    values.push(candidate);
  }
  finish(probe: RtcProbeView, elapsedMs: number | null, error?: string): RtcProbeResult {
    this.probes.delete(probe.attemptId);
    for (const [id, value] of this.results) if (value.initiatorDeviceId === probe.initiatorDeviceId && value.responderDeviceId === probe.responderDeviceId && value.scope === probe.scope) this.results.delete(id);
    const result: RtcProbeResult = { attemptId: probe.attemptId, initiatorDeviceId: probe.initiatorDeviceId, responderDeviceId: probe.responderDeviceId,
      scope: probe.scope, success: !error, elapsedMs, checkedAt: new Date(this.now()).toISOString(), expiresAt: new Date(this.now() + PROBE_RESULT_MS).toISOString(), ...(error ? { error } : {}) };
    this.results.set(probe.attemptId, result); return result;
  }
  complete(probe: RtcProbeView, actor: string, elapsedMs: number,
    addresses: Pick<RtcProbeResult, "initiatorAddress" | "responderAddress"> = {}) {
    if (actor !== probe.initiatorDeviceId) fail("FORBIDDEN", "Only probe initiator records round-trip time", 403);
    if (!probe.offer || !probe.answer) fail("INVALID_STATE", "Probe negotiation is incomplete");
    const result = this.finish(probe, elapsedMs);
    if (addresses.initiatorAddress) result.initiatorAddress = addresses.initiatorAddress;
    if (addresses.responderAddress) result.responderAddress = addresses.responderAddress;
    return result;
  }
  stop(probe: RtcProbeView) { this.probes.delete(probe.attemptId); }
  snapshot(deviceId: string) {
    return { presence: this.presence(deviceId), probes: [...this.probes.values()].filter(value => participants(value).includes(deviceId)),
      results: [...this.results.values()].filter(value => participants(value).includes(deviceId)) };
  }
  cleanup(eligible: (deviceId: string, scope: RtcScope) => boolean) {
    const changed = new Set<string>(), presenceChanged: string[] = [];
    for (const [id, expires] of this.foreground) if (expires <= this.now()) {
      presenceChanged.push(id); for (const peer of this.forgetDevice(id)) changed.add(peer);
    }
    for (const [id, probe] of this.probes) {
      if (participants(probe).some(peer => !eligible(peer, probe.scope))) { this.probes.delete(id); for (const peer of participants(probe)) changed.add(peer); }
      else if (Date.parse(probe.expiresAt) <= this.now()) { this.finish(probe, null, "PROBE_TIMEOUT"); for (const peer of participants(probe)) changed.add(peer); }
    }
    for (const [id, result] of this.results) if (Date.parse(result.expiresAt) <= this.now()) {
      this.results.delete(id); for (const peer of participants(result)) changed.add(peer);
    }
    return { changed: [...changed], presenceChanged };
  }
}
