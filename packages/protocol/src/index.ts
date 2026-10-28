export const PROTOCOL_VERSION = 1 as const;
export const DEFAULT_CHUNK_SIZE = 1024 * 1024;
export const MIN_GROUP_PASSWORD_LENGTH = 10;
export const PEER_TTL_SECONDS = 30 * 60;
export type Platform = "windows" | "android" | "web" | "other";
export const ROUTE_PREFERENCES = ["auto", "lan", "public", "relay"] as const;
export type RoutePreference = (typeof ROUTE_PREFERENCES)[number];
export type FileStatus =
  | "offered"
  | "accepted"
  | "uploading"
  | "ready"
  | "received"
  | "rejected"
  | "canceled"
  | "failed"
  | "expired";
export interface Peer {
  candidates: string[];
  certificatePem: string;
  certificateSha256: string;
  expiresAt: string;
  push?: boolean;
  cellularPush?: boolean;
}
export interface DirectPush {
  attemptId: string;
  scope: "lan" | "public";
  cellular: boolean;
  offset: number;
  expiresAt: string;
  state: "waiting" | "streaming" | "failed";
  error?: string;
}
export type RtcScope = "lan" | "public";
export interface RtcCapability { scopes: RtcScope[]; expiresAt: string }
export interface RtcSession {
  attemptId: string;
  scope: RtcScope;
  offset: number;
  state: "negotiating" | "streaming" | "failed";
  expiresAt: string;
  error?: string;
}
export interface RtcCandidate {
  candidate: string;
  sdpMid: string | null;
  sdpMLineIndex: number | null;
}
export interface RtcView extends RtcSession {
  transferId: string;
  fileId: string;
  sourceDeviceId: string;
  targetDeviceId: string;
  offer: { type: "offer"; sdp: string } | null;
  answer: { type: "answer"; sdp: string } | null;
  candidates: { source: RtcCandidate[]; target: RtcCandidate[] };
}
export interface RtcProbePresence { foreground: boolean; expiresAt: string | null }
export interface RtcProbePeer { deviceId: string; scopes: RtcScope[]; foregroundExpiresAt: string }
export interface RtcProbeView {
  attemptId: string;
  initiatorDeviceId: string;
  responderDeviceId: string;
  scope: RtcScope;
  expiresAt: string;
  offer: { type: "offer"; sdp: string } | null;
  answer: { type: "answer"; sdp: string } | null;
  candidates: { initiator: RtcCandidate[]; responder: RtcCandidate[] };
}
export interface RtcProbeResult {
  attemptId: string;
  initiatorDeviceId: string;
  responderDeviceId: string;
  scope: RtcScope;
  success: boolean;
  elapsedMs: number | null;
  initiatorAddress?: string;
  responderAddress?: string;
  checkedAt: string;
  expiresAt: string;
  error?: string;
}
export interface RtcProbeSnapshot {
  presence: RtcProbePresence;
  peers: RtcProbePeer[];
  probes: RtcProbeView[];
  results: RtcProbeResult[];
}
export interface Device {
  deviceId: string;
  groupId?: string;
  name: string;
  platform: Platform;
  online: boolean;
  revoked: boolean;
  createdAt: string;
  peer?: Peer | null;
  rtc?: RtcCapability | null;
  folderTransfer?: boolean;
}
export interface TransferFile {
  fileId: string;
  name: string;
  size: number;
  mimeType: string;
  sha256: string;
  relativePath?: string;
  entryKind?: "file" | "directory";
  status: FileStatus;
  offset: number;
  attemptId: string;
  errorCode: string | null;
  receiveFailure?: boolean;
  /** Receiver reused verified local bytes; no file payload was transferred. */
  reused?: boolean;
  receivedAt?: string;
  transport?: "relay" | "direct" | null;
  directPush?: DirectPush;
  rtc?: RtcSession;
}
export interface Transfer {
  transferId: string;
  sourceDeviceId: string;
  targetDeviceId: string;
  createdAt: string;
  expiresAt: string;
  routePreference?: RoutePreference;
  files: TransferFile[];
}
/** Receiver verified a complete retained root before accepting its payload. */
export interface FolderReuseRequest {
  files: { fileId: string; sha256: string; size: number }[];
}
export interface FolderReuseReceipt {
  files: TransferFile[];
}
export interface Event {
  cursor: number;
  protocolVersion: 1;
  eventId: string;
  type: string;
  sourceDeviceId: string;
  targetDeviceId: string;
  createdAt: string;
  expiresAt: string;
  payload: Record<string, unknown>;
}
export interface ServerInfo {
  protocolVersion: 1;
  instanceId: string;
  name: string;
  limits: {
    chunkSize: number;
    maxFileSize: number;
    totalQuota: number;
    ttlSeconds: number;
    maxTextLength: number;
  };
  features: { relay: true; direct: boolean; routePreference?: boolean; directPush?: boolean; rtcDataChannels?: boolean; rtcProbes?: boolean; rtcProbeAddresses?: boolean; groupSharedText?: boolean; folderTransfer?: boolean; receiveErrorReporting?: boolean; fileReuse?: boolean; folderReuse?: boolean };
  rtc?: { iceServers: { urls: string | string[] }[] };
  enrollment?: {
    mode?: "group-password";
    groupKey: true;
    legacyBootstrap: boolean;
    pairingCode?: false;
    allowGroupCreation: boolean;
    minGroupKeyLength: 10;
  };
  discovery?: { onlineOnly: true; peerTtlSeconds: number };
}
export interface EnrollmentResponse {
  deviceToken: string;
  device: Device;
  groupId: string;
  createdGroup: boolean;
}
export interface GroupKeyRotation {
  groupId: string;
  groupKey: string;
  rotatedAt: string;
}
export interface ClipboardContext { originDeviceId: string; sourceEventId: string; parentEventId?: string }
export interface TextPayload { text: string; clipboard?: ClipboardContext }
export interface GroupSharedText {
  text: string;
  revision: number;
  updatedAt: string;
  updatedBy: string;
  mutationId: string;
}
export type ServerMessage =
  | { type: "hello"; deviceId: string; protocolVersion: 1 }
  | { type: "presence"; deviceId: string; online: boolean }
  | { type: "devices.changed" }
  | { type: "rtc.changed"; transferId: string; fileId: string; attemptId: string }
  | { type: "rtc.probes.changed" }
  | ({ type: "sharedText.updated" } & GroupSharedText)
  | { type: "event"; event: Event }
  | { type: "pong" };
export const idPattern = "^[a-zA-Z0-9_-]{1,100}$";
export const fileOfferSchema = {
  type: "object",
  additionalProperties: false,
  required: ["fileId", "name", "size", "sha256"],
  properties: {
    fileId: { type: "string", pattern: idPattern },
    name: { type: "string", minLength: 1, maxLength: 255 },
    size: { type: "integer", minimum: 0, maximum: Number.MAX_SAFE_INTEGER },
    mimeType: { type: "string", maxLength: 150 },
    sha256: { type: "string", pattern: "^[a-f0-9]{64}$" },
    relativePath: { type: "string", minLength: 1, maxLength: 1024 },
    entryKind: { enum: ["file", "directory"] },
  },
} as const;
export function normalizeBaseUrl(value: string, allowHttp = false): string {
  const url = new URL(value.trim());
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !["https:", ...(allowHttp ? ["http:"] : [])].includes(url.protocol)
  )
    throw new Error("请输入不含用户名、查询或片段的 HTTPS 中心地址");
  return url.href.replace(/\/+$/, "");
}
