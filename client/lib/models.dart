import 'dart:convert';

import 'package:crypto/crypto.dart';

String normalizeServer(String input, {bool allowHttp = false}) {
  final u = Uri.tryParse(input.trim());
  if (u == null ||
      !u.hasAuthority ||
      u.host.isEmpty ||
      u.userInfo.isNotEmpty ||
      u.hasQuery ||
      u.hasFragment ||
      (u.scheme != 'https' && !(allowHttp && u.scheme == 'http'))) {
    throw const FormatException('请输入 HTTPS 中心地址，不含账号、查询参数或片段');
  }
  return u.replace(path: u.path.replaceAll(RegExp(r'/+$'), '')).toString();
}

String profileKey(String url, String instance) =>
    sha256.convert(utf8.encode('$url\n$instance')).toString();
String safeName(String name) {
  var value = name
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (value.isEmpty ||
      RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
        caseSensitive: false,
      ).hasMatch(value)) {
    value = 'file_$value';
  }
  return value.length > 160 ? value.substring(value.length - 160) : value;
}

class ServerProfile {
  ServerProfile({
    required this.baseUrl,
    required this.instanceId,
    this.deviceId = '',
    this.name = '',
    this.cursor = 0,
    this.groupId = '',
    List<Map<String, dynamic>>? groups,
    this.autoReceive = true,
    this.sendRoutePreference = 'auto',
    this.receiveRoutePreference = 'auto',
    this.cellularAllowed = true,
    this.relayConfirmMiB = 32,
    this.transferConcurrency = 4,
    this.storageId = '',
    this.legacyPeerIdentity = true,
  }) : groups = groups ?? [];
  final String baseUrl, instanceId;
  final String storageId;
  bool legacyPeerIdentity;
  String deviceId, name, groupId;
  List<Map<String, dynamic>> groups;
  int cursor;
  bool autoReceive;
  bool cellularAllowed;
  int relayConfirmMiB;
  int transferConcurrency;
  String sendRoutePreference, receiveRoutePreference;
  String get key => profileKey(baseUrl, instanceId);
  String get storageKey {
    if (storageId.isEmpty) return key;
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(storageId)) {
      throw const FormatException('本地身份存储标识无效');
    }
    return '$key.$storageId';
  }

  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'instanceId': instanceId,
    'deviceId': deviceId,
    'name': name,
    'cursor': cursor,
    'groupId': groupId,
    'groups': groups,
    'autoReceive': autoReceive,
    'sendRoutePreference': sendRoutePreference,
    'receiveRoutePreference': receiveRoutePreference,
    'cellularAllowed': cellularAllowed,
    'relayConfirmMiB': relayConfirmMiB,
    'transferConcurrency': transferConcurrency,
    'storageId': storageId,
    'legacyPeerIdentity': legacyPeerIdentity,
  };
  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
    baseUrl: j['baseUrl'],
    instanceId: j['instanceId'],
    deviceId: j['deviceId'] ?? '',
    name: j['name'] ?? '',
    cursor: j['cursor'] ?? 0,
    groupId: j['groupId'] ?? '',
    groups: (j['groups'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList(),
    autoReceive: j['autoReceive'] ?? true,
    sendRoutePreference: j['sendRoutePreference'] ?? 'auto',
    receiveRoutePreference: j['receiveRoutePreference'] ?? 'auto',
    cellularAllowed: j['cellularAllowed'] ?? true,
    relayConfirmMiB: j['relayConfirmMiB'] ?? 32,
    transferConcurrency: j['transferConcurrency'] ?? 4,
    storageId: j['storageId'] ?? '',
    legacyPeerIdentity: j['legacyPeerIdentity'] ?? true,
  );
}

class DockEntry {
  DockEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.source,
    this.text = '',
    this.editedAt = '',
    this.editCursor = 0,
    this.contentId = '',
    this.contentRevision = 0,
    this.contentDigest = '',
    this.status = 'ready',
    this.transferId = '',
    this.fileId = '',
    this.size = 0,
    this.localPath = '',
    this.error = '',
    this.progress = 0,
    this.outgoing = false,
    this.route = 'relay',
    this.autoClipboard = false,
    this.expiresAtMillis = 0,
    this.originDeviceId = '',
    this.sourceEventId = '',
    this.receivedBytes = 0,
    this.partialPath = '',
    this.offerRoutePreference = 'auto',
    this.routeDetail = '',
    this.attemptId = '',
    this.receiveRoutePreference = '',
    this.targetDeviceId = '',
    this.relayConfirmed = false,
    this.relayConfirmationPending = false,
    this.relayPendingBeforeAccept = false,
    this.locallyCanceled = false,
    this.locallyPaused = false,
    this.receiveFailure = false,
    this.receiveFailureReported = false,
    int? createdAtMillis,
    this.receivedAtMillis = 0,
    this.sourceReference = '',
    this.sourceLabel = '',
    this.relativePath = '',
    this.entryKind = 'file',
    this.transferBytesPerSecond = 0,
  }) : createdAtMillis =
           createdAtMillis ?? DateTime.now().millisecondsSinceEpoch;
  final String id, kind, title, source, transferId, fileId;
  String text, editedAt;
  int editCursor;
  String contentId, contentDigest;
  int contentRevision;
  final int size;
  final int createdAtMillis;
  int receivedAtMillis;
  String sourceReference;
  String sourceLabel;
  String relativePath, entryKind;
  bool get isDirectory => entryKind == 'directory';
  List<String> get dragPaths => kind == 'file' && localPath.isNotEmpty
      ? [sourceReference.isNotEmpty ? sourceReference : localPath]
      : const [];
  double transferBytesPerSecond;
  int? _transferSampleMicros;
  int _transferSampleBytes = 0;
  void recordTransferBytes(int completedBytes, {int? nowMicros}) {
    final now = nowMicros ?? DateTime.now().microsecondsSinceEpoch;
    final previous = _transferSampleMicros;
    if (previous == null || completedBytes < _transferSampleBytes) {
      _transferSampleMicros = now;
      _transferSampleBytes = completedBytes;
      transferBytesPerSecond = 0;
      return;
    }
    final elapsed = now - previous;
    if (elapsed < 200000) return;
    transferBytesPerSecond =
        (completedBytes - _transferSampleBytes) * 1000000 / elapsed;
    _transferSampleMicros = now;
    _transferSampleBytes = completedBytes;
  }

  final bool outgoing;
  final bool autoClipboard;
  final int expiresAtMillis;
  final String originDeviceId, sourceEventId;
  int receivedBytes;
  String partialPath;
  String status, localPath, error, route;
  String offerRoutePreference, routeDetail, attemptId, receiveRoutePreference;
  String targetDeviceId;
  bool relayConfirmed, relayConfirmationPending, relayPendingBeforeAccept;
  bool locallyCanceled;
  bool locallyPaused;
  bool receiveFailure;
  bool receiveFailureReported;
  double progress;
  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAtMillis': createdAtMillis,
    'receivedAtMillis': receivedAtMillis,
    'sourceReference': sourceReference,
    'sourceLabel': sourceLabel,
    'relativePath': relativePath,
    'entryKind': entryKind,
    'kind': kind,
    'title': title,
    'source': source,
    'text': text,
    'editedAt': editedAt,
    'editCursor': editCursor,
    'contentId': contentId,
    'contentRevision': contentRevision,
    'contentDigest': contentDigest,
    'status': status,
    'error': error,
    'transferId': transferId,
    'fileId': fileId,
    'size': size,
    'localPath': localPath,
    'outgoing': outgoing,
    'route': route,
    'receivedBytes': receivedBytes,
    'partialPath': partialPath,
    'offerRoutePreference': offerRoutePreference,
    'routeDetail': routeDetail,
    'attemptId': attemptId,
    'receiveRoutePreference': receiveRoutePreference,
    'targetDeviceId': targetDeviceId,
    'relayConfirmed': relayConfirmed,
    'relayConfirmationPending': relayConfirmationPending,
    'relayPendingBeforeAccept': relayPendingBeforeAccept,
    'locallyCanceled': locallyCanceled,
    'locallyPaused': locallyPaused,
    'receiveFailure': receiveFailure,
    'receiveFailureReported': receiveFailureReported,
  };
  factory DockEntry.fromJson(Map<String, dynamic> j) => DockEntry(
    id: j['id'],
    createdAtMillis: j['createdAtMillis'] ?? 0,
    receivedAtMillis: j['receivedAtMillis'] ?? 0,
    sourceReference: j['sourceReference'] ?? '',
    sourceLabel: j['sourceLabel'] ?? '',
    relativePath: j['relativePath'] ?? '',
    entryKind: j['entryKind'] ?? 'file',
    transferBytesPerSecond:
        (j['transferBytesPerSecond'] as num?)?.toDouble() ?? 0,
    kind: j['kind'],
    title: j['title'],
    source: j['source'],
    text: j['text'] ?? '',
    editedAt: j['editedAt'] ?? '',
    editCursor: j['editCursor'] ?? 0,
    contentId: j['contentId'] ?? '',
    contentRevision: j['contentRevision'] ?? 0,
    contentDigest: j['contentDigest'] ?? '',
    status: j['status'],
    error: j['error'] ?? '',
    transferId: j['transferId'] ?? '',
    fileId: j['fileId'] ?? '',
    size: j['size'] ?? 0,
    localPath: j['localPath'] ?? '',
    outgoing: j['outgoing'] ?? false,
    route: j['route'] ?? 'relay',
    receivedBytes: j['receivedBytes'] ?? 0,
    partialPath: j['partialPath'] ?? '',
    offerRoutePreference: j['offerRoutePreference'] ?? 'auto',
    routeDetail: j['routeDetail'] ?? '',
    attemptId: j['attemptId'] ?? '',
    receiveRoutePreference: j['receiveRoutePreference'] ?? '',
    targetDeviceId: j['targetDeviceId'] ?? '',
    relayConfirmed: j['relayConfirmed'] ?? false,
    relayConfirmationPending: j['relayConfirmationPending'] ?? false,
    relayPendingBeforeAccept: j['relayPendingBeforeAccept'] ?? false,
    locallyCanceled: j['locallyCanceled'] ?? j['status'] == 'canceled',
    locallyPaused: j['locallyPaused'] ?? j['status'] == 'paused',
    receiveFailure: j['receiveFailure'] ?? false,
    receiveFailureReported: j['receiveFailureReported'] ?? false,
  );
}

String bytesLabel(int bytes) => bytes < 1024
    ? '$bytes B'
    : bytes < 1048576
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '${(bytes / 1048576).toStringAsFixed(1)} MiB';
