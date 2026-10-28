import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import 'api.dart';
import 'appearance.dart';
import 'app_updates.dart';
import 'models.dart';
import 'content_groups.dart';
import 'network_bridge.dart';
import 'peer.dart';
import 'vault.dart';
import 'credential_recovery.dart';
import 'directories.dart';
import 'system_bridge.dart';
import 'dock_platform.dart';
import 'saved_files.dart';
import 'receive_destination.dart';
import 'received_file_access.dart';
import 'reachability.dart';
import 'rtc_transport.dart';
import 'rtc_probe.dart';
import 'folder_transfer.dart';
import 'group_shared_text.dart';
import 'receive_notifications.dart';
import 'background_receive.dart';
import 'recent_devices.dart';
import 'local_history.dart';
import 'connection_window.dart';
import 'route_probes.dart';
import 'reverse_https_probe.dart';
import 'local_ip_addresses.dart';
import 'candidate_routes.dart';
import 'transfer_operation.dart';
import 'transfer_route_selection.dart';

String newId() {
  final r = Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String newGroupKey() {
  final random = Random.secure();
  return base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

class TransferGate {
  TransferGate({int limit = 4}) : _limit = limit;
  int _limit;
  int get limit => _limit;
  set limit(int value) {
    if (value < 1 || value > 16) throw RangeError.range(value, 1, 16);
    _limit = value;
    _drain();
  }

  int active = 0;
  final List<Completer<void>> waiting = [];
  Future<void> enter({Future<void>? stopped}) async {
    if (active < _limit && waiting.isEmpty) {
      active++;
      return;
    }
    final pending = Completer<void>();
    waiting.add(pending);
    stopped?.then((_) {
      if (waiting.remove(pending))
        pending.completeError(const TransferStopped());
    });
    await pending.future;
  }

  void leave() {
    active--;
    _drain();
  }

  void _drain() {
    while (active < _limit && waiting.isNotEmpty) {
      active++;
      waiting.removeAt(0).complete();
    }
  }
}

typedef _PreparedRoutes = ({
  Map<String, dynamic>? senderPeer,
  Map<String, dynamic>? sourceRtc,
  List<String> advertised,
  ({List<String> lan, List<String> public}) stages,
  RouteProbes probes,
  Map<String, Future<Map<String, dynamic>?>> reverseChecks,
  Map<String, Future<bool?>> rtcChecks,
});

class SendController extends ChangeNotifier {
  final appearance = AppearanceSettings();
  final AppUpdates updates;
  String get _platformName => Platform.isWindows
      ? 'windows'
      : Platform.isAndroid
      ? 'android'
      : 'other';

  SendController({
    Future<Directory> Function()? documentsDirectory,
    Future<Directory> Function()? stateDirectory,
    PlatformVault? vault,
    ReachabilityMonitor? reachability,
    CandidateStages? addressStages,
    Future<String> Function()? deviceName,
    Future<List<LocalIpAddress>> Function()? ipAddresses,
    ReceivedNotifications? receivedNotifications,
    BackgroundReceive? backgroundReceive,
    AppUpdates? updates,
  }) : documentsDirectory = documentsDirectory ?? receivedDirectory,
       stateDirectory = stateDirectory ?? appDataDirectory,
       _addressStages = addressStages ?? PeerTransport.candidateStages,
       _readDeviceName = deviceName ?? SystemBridge.deviceName,
       _readIpAddresses = ipAddresses ?? readLocalIpAddresses,
       receivedNotifications = receivedNotifications ?? ReceivedNotifications(),
       _providedBackgroundReceive = backgroundReceive,
       updates = updates ?? AppUpdates(),
       vault = vault ?? PlatformVault() {
    this.reachability =
        reachability ??
        ReachabilityMonitor(
          cellularCapable: Platform.isAndroid,
          localAddresses: _readIpAddresses,
          onNetworkChanged: _networkChanged,
        );
  }
  late final ReachabilityMonitor reachability;
  final CandidateStages _addressStages;
  final Future<String> Function() _readDeviceName;
  Future<String> systemDeviceName() => _readDeviceName();
  final Future<List<LocalIpAddress>> Function() _readIpAddresses;
  Future<List<LocalIpAddress>> localIpAddresses() => _readIpAddresses();
  bool _reachabilityStarted = false;
  final Future<Directory> Function() documentsDirectory;
  final Future<Directory> Function() stateDirectory;
  bool cellularUploads = true;
  final Map<String, String> nativeOperations = {};
  final Map<String, String> _sendingPush = {};
  final Map<String, String> _startedPushes = {};
  PeerTransport? peer;
  RtcFileTransport? rtc;
  RtcProbeMonitor? rtcProbes;
  ReverseHttpsProbes? reverseHttpsProbes;
  bool _probeForeground = true;
  bool _appForeground = true;
  Timer? rtcHeartbeat;
  final Map<String, String> _sendingRtc = {}, _startedRtc = {};
  final Map<String, Map<String, dynamic>> _pendingRtc = {};
  final Map<String, String> _rtcNetwork = {};
  Timer? peerHeartbeat;
  final Map<String, Timer> routeTimers = {};
  String peerStatus = '直连尚未启动';
  final PlatformVault vault;
  VaultException? credentialProblem;
  bool recoveringCredentials = false;
  List<CredentialRecoveryRecord> credentialRecoveryRecords = [];
  Completer<void>? _credentialCommitFinished;
  final ReceivedNotifications receivedNotifications;
  final BackgroundReceive? _providedBackgroundReceive;
  late final BackgroundReceive backgroundReceive =
      _providedBackgroundReceive ??
      BackgroundReceive(
        onChanged: changed,
        onStopRequested: () async {
          if (!_appForeground) _pauseBackgroundConnection();
          changed();
        },
      );
  bool _backgroundConnectionPaused = false, _resumingBackground = false;
  bool _hasStoredSession = false;
  bool get backgroundReceiveAvailable => backgroundReceive.supported;
  bool get backgroundReceiveEnabled => backgroundReceive.enabled;
  bool get backgroundReceiveRunning => backgroundReceive.running;
  bool get backgroundBatteryUnrestricted =>
      backgroundReceive.batteryUnrestricted;
  String get backgroundReceiveStatus => backgroundReceive.status;
  Future<void> openBackgroundBatterySettings() =>
      backgroundReceive.openBatterySettings();
  Future<void> setBackgroundEnabled(bool enabled) async {
    await backgroundReceive.setEnabled(enabled);
    if (!enabled && !_appForeground) {
      _pauseBackgroundConnection();
    } else if (enabled && _backgroundConnectionPaused) {
      await _resumeBackgroundConnection();
    }
    changed();
  }

  void _pauseBackgroundConnection() {
    if (_backgroundConnectionPaused || api?.token.isNotEmpty != true) return;
    _backgroundConnectionPaused = true;
    _connectRequest++;
    _restoreTimer?.cancel();
    generation++;
    stopConnections();
    connection = '后台接收已暂停';
  }

  Future<void> _resumeBackgroundConnection() async {
    final p = profile;
    if (_resumingBackground || p == null || p.deviceId.isEmpty) return;
    _resumingBackground = true;
    _backgroundConnectionPaused = false;
    try {
      await _restoreRecent(p);
    } finally {
      _resumingBackground = false;
    }
  }

  bool receiveNotificationsEnabled = false;
  bool get receiveNotificationsAvailable => receivedNotifications.supported;
  bool get receivePopupAvailable => receiveNotificationsAvailable;
  bool receivePopupEnabled = true, receivePopupAllowed = false;
  bool receiveHeadsUpAllowed = false;
  String get receivePopupStatus => !receivePopupEnabled
      ? '已关闭'
      : receivePopupAllowed
      ? '弹出失败时通知'
      : '需要授权';
  int notificationOpenSerial = 0;
  String notificationOpenTarget = '';
  Future<void>? _notificationInitialization;
  String _notificationScope = '';
  Future<void> _notificationWork = Future<void>.value();
  bool allowLegacyPeerIdentity = true;
  bool clipboardEnabled = false;
  String clipboardTarget = '', clipboardStatus = '自动剪贴板已关闭';
  int _clipboardEnabledAt = 0, _clipboardSequence = -1, _lastClipboardSend = 0;
  StreamSubscription<Map<String, dynamic>>? _clipboardSubscription;
  Timer? _clipboardDebounce, _ephemeralCleanup;
  int _nextSavedFilesCleanup = 0;
  bool _cleaningSavedFiles = false;
  final Map<String, int> _clipboardRoots = {};
  final List<String> stagedFiles = [], stagedTexts = [];
  final Map<String, String> stagedTargetStates = {};
  List<String> _stagedBatchFiles = [], _stagedBatchTexts = [];
  final Map<String, int> _stagedTargetProgress = {};
  final Set<String> _stagedInFlightPaths = {};
  int receiptSerial = 0;
  bool receiptWindowFloating = false;
  bool receiptPresentedExternally = false;
  DockEntry? latestReceipt;
  final Map<String, DockEntry> pendingReceipts = {};
  final Set<String> nativeDismissedReceiptIds = {};
  final Map<String, int> _receiptSequence = {};
  final Map<String, String> _receiptVersions = {};
  final Map<String, String> stagedDirectoryNames = {};
  final Map<String, String> _directorySources = {};
  final Set<String> _temporarySources = {}, _hiddenDockIds = {};
  bool _checkingSentReferences = false;
  Future<void>? _folderRelease;
  late final GroupSharedText sharedDocument = GroupSharedText(
    onChanged: changed,
  );
  String get sharedText => sharedDocument.text;
  String get sharedTextRemote => sharedDocument.remoteText;
  String get sharedTextStatus => sharedDocument.status;
  int get sharedTextRevision => sharedDocument.revision;
  bool get sharedTextSupported => info['features']?['groupSharedText'] == true;
  bool get sharedTextDirty => sharedDocument.dirty;
  bool get sharedTextConflict => sharedDocument.conflict;
  void setSharedTextDraft(String value) => sharedDocument.setDraft(value);
  Future<void> retrySharedText() => sharedDocument.keepMine();
  void useRemoteSharedText() => sharedDocument.useRemote();
  bool _sendingStaged = false;
  final Set<String> _nativeDropIds = {};
  final Set<String> _sharedBatchIds = {};
  StreamSubscription<Map<String, dynamic>>? _dockSubscription;
  bool nativeDragActive = false, nativeImporting = false;
  bool nativeQueueDragActive = false;
  bool nativeLocalDragActive = false;
  int nativeSendNavigationSerial = 0;
  List<ServerProfile> profiles = [];
  ServerProfile? profile;
  CenterApi? api;
  Map<String, dynamic> info = {};
  List<Map<String, dynamic>> devices = [];
  final recentDevices = RecentDevices();
  int Function() discoveryNow = () => DateTime.now().millisecondsSinceEpoch;
  Timer? _deviceGraceTimer;
  int _deviceRevision = 0;
  List<Map<String, dynamic>> get sendablePeers => devices
      .where(
        (device) =>
            device['deviceId'] != profile?.deviceId &&
            recentDevices.available(device, discoveryNow()),
      )
      .toList();

  void updateDiscoveredDevices(List<Map<String, dynamic>> snapshot) {
    devices = recentDevices.merge(devices, snapshot, discoveryNow());
    _scheduleDeviceExpiry();
  }

  void _scheduleDeviceExpiry() {
    _deviceGraceTimer?.cancel();
    if (recentDevices.deadlines.isEmpty || disposed) return;
    final deadline = recentDevices.deadlines.values.reduce(min);
    _deviceGraceTimer = Timer(
      Duration(milliseconds: max(0, deadline - discoveryNow())),
      () {
        updateDiscoveredDevices(devices);
        changed();
      },
    );
  }

  List<Map<String, dynamic>> get onlinePeers => connected
      ? devices
            .where(
              (device) =>
                  device['deviceId'] != profile?.deviceId &&
                  device['revoked'] != true &&
                  device['online'] == true,
            )
            .toList()
      : [];
  List<DockEntry> dock = [];
  LocalHistoryStore? _localHistory;
  Future<void>? _historyLoading;
  bool isLocalHistory(DockEntry entry) => !dock.contains(entry);
  bool _isHiddenDockId(String id) =>
      _hiddenDockIds.contains(id) ||
      profile != null && _localHistory?.isHidden(profile!.key, id) == true;

  List<DockEntry> _restoreLocalHistoryEntries(
    ServerProfile owner,
    List<DockEntry> entries,
  ) {
    final restored = entries
        .where((entry) => _localHistory?.isHidden(owner.key, entry.id) != true)
        .toList();
    for (final entry in restored) {
      _relocateSavedEntry(entry);
      _localHistory?.restoreLocalEdit(owner.key, entry);
    }
    return restored;
  }

  List<DockEntry> get historyDock {
    final active = {for (final entry in dock) '${profile?.key}:${entry.id}'};
    return [
      ...dock.where((entry) => !_isHiddenDockId(entry.id)),
      ...?_localHistory?.records.values
          .where((record) => !active.contains(record.key))
          .map((record) => record.entry),
    ]..sort((a, b) => b.createdAtMillis.compareTo(a.createdAtMillis));
  }

  Future<void> _loadLocalHistory() async {
    final directory = root;
    if (directory == null) return;
    await (_historyLoading ??= () async {
      final history = LocalHistoryStore(directory);
      await history.load(profiles);
      _localHistory = history;
      _applyRelocatedSavedPaths();
    }());
  }

  Future<void> stageHistoryEntry(DockEntry entry) => requeueDockEntry(entry);
  Future<void> removeHistoryEntries(Iterable<DockEntry> entries) async {
    final keys = entries
        .map((entry) => '${entry.outgoing}:${contentKey(entry)}')
        .toSet();
    for (final entry
        in historyDock
            .where(
              (entry) =>
                  keys.contains('${entry.outgoing}:${contentKey(entry)}'),
            )
            .toList()) {
      await deleteDockEntry(entry);
    }
  }

  List<DockEntry> get failedOutgoingFiles => dock
      .where(
        (item) =>
            item.outgoing &&
            item.kind == 'file' &&
            item.status == 'failed' &&
            !item.locallyPaused &&
            !item.locallyCanceled,
      )
      .toList(growable: false);

  Future<void> retryFailedOutgoingFiles() async {
    await Future.wait(failedOutgoingFiles.map(retry));
  }

  Future<void> clearFailedOutgoingFiles() async {
    // This is a queue operation, not content-group history deletion. A failed
    // send of the same original must not remove its successful sibling record.
    for (final item in failedOutgoingFiles) {
      if (dock.contains(item) && item.status == 'failed')
        await deleteDockEntry(item);
    }
  }

  Map<String, String> sources = {};
  Map<String, String> pendingTexts = {};
  Future<void> _saveTail = Future<void>.value();
  Future<void> get persistenceIdle => _saveTail;
  final Set<String> busyFiles = {};
  final TransferGate _gate = TransferGate();
  final Map<String, TransferOperation> _fileOperations = {};
  final Map<String, Set<Completer<void>>> _sourceGateWaits = {};
  final Set<String> _receiveErrorReports = {};
  int get transferConcurrency => profile?.transferConcurrency ?? 4;
  String connection = '未连接', message = '';
  String rememberedCenter = '';
  bool busy = false, connected = false;
  WebSocket? socket;
  int _socketAttempt = 0;
  Timer? reconnect, poll;
  int generation = 0, failures = 0;
  bool syncing = false, disposed = false;
  bool _reconcileAgain = false;
  int _connectRequest = 0;
  bool _startTransportsOnConnect = false;
  Timer? _restoreTimer;
  final Set<String> _acceptingTransfers = {};
  Directory? root;
  SavedFilesStore? _savedFilesStore;
  Future<SavedFilesStore?>? _savedFilesLoading;
  int get savedFileRetentionHours =>
      _savedFilesStore?.retentionHours ?? SavedFile.defaultRetentionHours;
  Future<void> setSavedFileRetentionHours(int hours) async {
    final store = await _savedStore();
    if (store == null) return;
    await store.setRetentionHours(hours);
    changed();
  }

  SavedFileCleanupFilter get savedFileCleanupFilter =>
      _savedFilesStore?.cleanupFilter ?? SavedFileCleanupFilter();
  Future<void> setSavedFileCleanupFilter(SavedFileCleanupFilter filter) async {
    final store = await _savedStore();
    if (store == null) return;
    await store.setCleanupFilter(filter);
    changed();
  }

  String get receiveDirectoryLabel =>
      _savedFilesStore?.receiveDestinationLabel ?? '';
  String receiveDirectoryMigrationStatus = '';
  Completer<void>? _receiveDirectoryMigration;
  int get receiveDirectoryCleanupPending =>
      _savedFilesStore?.migrationCleanupPending ?? 0;
  bool get hasCustomReceiveDirectory =>
      _savedFilesStore?.receiveDestinationLocation.isNotEmpty ?? false;
  Future<void> chooseReceiveDirectory() async {
    final selected = await ReceiveDestination.pick();
    if (selected == null) return;
    final store = await _savedStore();
    if (store == null) return;
    await changeReceiveDirectory(selected['location']!, selected['label']!);
  }

  Future<void> clearReceiveDirectory() async {
    await changeReceiveDirectory('', '');
  }

  Future<void> changeReceiveDirectory(String location, String label) async {
    if (_receiveDirectoryMigration != null) return;
    if (_sendingStaged) throw StateError('请在本次发送完成后更改接收目录');
    final barrier = Completer<void>();
    _receiveDirectoryMigration = barrier;
    try {
      if (busyFiles.isNotEmpty) {
        receiveDirectoryMigrationStatus = '等待当前传输完成';
        changed();
        final idle = Completer<void>();
        void check() {
          if (busyFiles.isEmpty && !idle.isCompleted) idle.complete();
        }

        addListener(check);
        try {
          check();
          await idle.future;
        } finally {
          removeListener(check);
        }
      }
      final store = await _savedStore();
      if (store == null) return;
      receiveDirectoryMigrationStatus = '正在迁移文件';
      changed();
      await store.setReceiveDestination(
        location,
        label,
        onProgress: (done, total) {
          receiveDirectoryMigrationStatus = '正在迁移 $done / $total';
          changed();
        },
        onCommitted: () async {
          _applyRelocatedSavedPaths();
          await save();
          changed();
        },
      );
      if (store.migrationSkippedFiles > 0)
        message = '已切换接收目录；${store.migrationSkippedFiles} 项旧文件暂不可读，已保留原位置';
    } finally {
      _applyRelocatedSavedPaths();
      receiveDirectoryMigrationStatus = '';
      _receiveDirectoryMigration = null;
      barrier.complete();
      changed();
    }
  }

  Future<void> finishReceiveDirectoryCleanup() async {
    await (await _savedStore())?.finishMigrationCleanup();
    changed();
    if (receiveDirectoryCleanupPending > 0) {
      throw const FileSystemException('旧文件仍被占用，请关闭占用程序后重试');
    }
  }

  String _relocatedSavedPath(String path) =>
      _savedFilesStore?.relocatedLocations[path] ?? path;

  void _relocateSavedEntry(DockEntry entry) {
    entry.localPath = _relocatedSavedPath(entry.localPath);
    entry.sourceReference = _relocatedSavedPath(entry.sourceReference);
  }

  void _applyRelocatedSavedPaths() {
    for (final entry in dock) {
      _relocateSavedEntry(entry);
    }
    for (final record
        in _localHistory?.records.values ?? <LocalHistoryRecord>[]) {
      _relocateSavedEntry(record.entry);
    }
    sources.updateAll((key, path) => _relocatedSavedPath(path));
    final directorySources = {
      for (final item in _directorySources.entries)
        _relocatedSavedPath(item.key): _relocatedSavedPath(item.value),
    };
    _directorySources
      ..clear()
      ..addAll(directorySources);
    final directoryNames = {
      for (final item in stagedDirectoryNames.entries)
        _relocatedSavedPath(item.key): item.value,
    };
    stagedDirectoryNames
      ..clear()
      ..addAll(directoryNames);
    for (var index = 0; index < stagedFiles.length; index++) {
      stagedFiles[index] = _relocatedSavedPath(stagedFiles[index]);
    }
    _stagedBatchFiles = _stagedBatchFiles.map(_relocatedSavedPath).toList();
  }

  List<SavedFile> get savedFiles => _savedFilesStore?.items ?? [];

  Future<SavedFilesStore?> _savedStore() {
    final directory = root;
    if (directory == null) return Future.value(null);
    return _savedFilesLoading ??= () async {
      final store = SavedFilesStore(
        indexFile: File('${directory.path}/saved-files.json'),
        documentsDirectory: await documentsDirectory(),
      );
      await store.load();
      _savedFilesStore = store;
      return store;
    }();
  }

  String savedFilesIssue = '';
  Future<void> _libraryWork = Future<void>.value();
  Future<void> get localLibraryIdle => _libraryWork;
  Future<void> refreshLocalLibrary({bool migrate = false}) {
    final pending = _refreshLocalLibrary(migrate: migrate);
    _libraryWork = Future.wait<void>([_libraryWork, pending]).then((_) {});
    return pending;
  }

  Future<void> _refreshLocalLibrary({required bool migrate}) async {
    try {
      if (migrate) {
        await _migrateSavedFiles();
      } else {
        await refreshSavedFiles();
      }
      savedFilesIssue = '';
    } catch (error) {
      // Local files are independent of center authentication. Keep their
      // index/identity intact and offer a library retry instead of aborting login.
      savedFilesIssue =
          error is PlatformException || error is FileSystemException
          ? '部分本地文件暂不可读，请重新授权接收文件夹后重试'
          : '文件库暂不可用，请重试';
    }
    if (!disposed) changed();
  }

  Future<void> refreshSavedFiles({bool cleanup = false}) async {
    await pruneSentReferences();
    final store = await _savedStore();
    if (store == null) return;
    final current = profile;
    _applyRelocatedSavedPaths();
    var stalePaths = false;
    if (current != null) {
      for (final entry
          in dock
              .where(
                (entry) =>
                    !entry.outgoing &&
                    entry.kind == 'file' &&
                    entry.localPath.isNotEmpty,
              )
              .toList()) {
        try {
          final registered = await store.register(
            profile: current,
            entry: entry,
          );
          if (registered != null && entry.receivedAtMillis == 0) {
            entry.receivedAtMillis = registered.receivedAtMillis;
          }
          if (registered == null &&
              !await ReceivedFileAccess.exists(entry.localPath)) {
            entry.localPath = '';
            entry.routeDetail = '本机副本已删除';
            _localHistory?.remove('${current.key}:${entry.id}');
            _hiddenDockIds.add(entry.id);
            dock.remove(entry);
            stalePaths = true;
          }
        } on FileSystemException {
          entry.routeDetail = '本机文件暂不可读，请重新授权所在文件夹';
        } on PlatformException {
          entry.routeDetail = '本机文件暂不可读，请重新授权所在文件夹';
        }
      }
    }
    final removed = await store.prune(DateTime.now(), removeExpired: cleanup);
    _forgetSavedCopies(removed);
    if (removed.isNotEmpty || stalePaths) await save();
    changed();
  }

  Future<void> _migrateSavedFiles() async {
    final store = await _savedStore();
    if (store == null) return;
    for (final savedProfile in profiles) {
      final state = File('${root!.path}/${savedProfile.storageKey}.json');
      if (!await state.exists()) continue;
      final values = jsonDecode(await state.readAsString()) as Map;
      for (final value in values['dock'] as List? ?? []) {
        final entry = DockEntry.fromJson(Map<String, dynamic>.from(value));
        try {
          await store.register(profile: savedProfile, entry: entry);
        } on FileSystemException {
          // Keep the original dock reference until its directory is available.
        } on PlatformException {
          // Revoked external access must not prevent the remaining migration.
        }
      }
    }
    await refreshSavedFiles(cleanup: true);
  }

  Future<void> _rememberSavedFile(
    DockEntry entry,
    ServerProfile owner, {
    DateTime? receivedAt,
    bool managedLocation = false,
  }) async {
    if (entry.receivedAtMillis == 0) {
      entry.receivedAtMillis =
          (receivedAt ?? DateTime.now()).millisecondsSinceEpoch;
    }
    final savedOwner = ServerProfile.fromJson(owner.toJson());
    final store = await _savedStore();
    if (store == null) return;
    await store.register(
      profile: savedOwner,
      entry: entry,
      receivedAt: receivedAt,
      managedLocation: managedLocation,
    );
    if (!entry.outgoing &&
        savedOwner.deviceId == profile?.deviceId &&
        savedOwner.groupId == profile?.groupId &&
        savedOwner.key == profile?.key) {
      _postReceivedNotice(entry, 'received', fileName: entry.title);
    }
    changed();
  }

  Future<void> _initializeReceivedNotifications() async {
    if (!receiveNotificationsAvailable) return;
    receivedNotifications.onOpen = openReceivedNotification;
    receivedNotifications.onPermission = (enabled) {
      receiveNotificationsEnabled = enabled;
      changed();
    };
    receivedNotifications.onPopupState = _adoptReceivePopup;
    receivedNotifications.onDismiss = (event) {
      final versions = Map<String, dynamic>.from(
        event['versions'] as Map? ?? {},
      );
      for (final entry in versions.entries) {
        if (_receiptVersions[entry.key] == entry.value) {
          pendingReceipts.remove(entry.key);
          nativeDismissedReceiptIds.add(entry.key);
          if (latestReceipt?.id == entry.key) {
            latestReceipt = pendingReceipts.values.lastOrNull;
          }
        }
      }
      changed();
    };
    await receivedNotifications.initialize();
    await receivedNotifications
        .setForeground(_appForeground)
        .catchError((Object _) {});
  }

  void openReceivedNotification([String target = 'receive']) {
    if (target == 'shared') return;
    final itemId = target.startsWith('receive:') ? target.substring(8) : '';
    final item = itemId.isEmpty
        ? latestReceipt
        : dock.where((entry) => entry.id == itemId).firstOrNull;
    if (item != null && item.id != 'group-shared-text') {
      nativeDismissedReceiptIds.remove(item.id);
      pendingReceipts[item.id] = item;
      latestReceipt = item;
      receiptSerial++;
      _receiptSequence[item.id] = receiptSerial;
    }
    notificationOpenTarget = 'receive';
    notificationOpenSerial++;
    changed();
  }

  Future<void> _configureReceivedNotifications() async {
    if (!receiveNotificationsAvailable || profile == null) return;
    try {
      await (_notificationInitialization ??=
          _initializeReceivedNotifications());
      final p = profile!;
      final scope = '${p.key}:${p.groupId}:${p.deviceId}';
      if (_notificationScope != scope) {
        await receivedNotifications.setScope(scope);
        _notificationScope = scope;
      }
      await refreshReceiveNotifications();
    } catch (_) {
      // Receipt/transfer completion does not depend on notification permission.
    }
  }

  Future<void> refreshReceiveNotifications({
    bool request = false,
    bool explicit = false,
  }) async {
    if (!receiveNotificationsAvailable) return;
    try {
      await (_notificationInitialization ??=
          _initializeReceivedNotifications());
      receiveNotificationsEnabled = request
          ? await receivedNotifications.permission(explicit: explicit)
          : await receivedNotifications.status();
      await refreshReceivePopup();
      changed();
    } catch (_) {
      receiveNotificationsEnabled = false;
    }
  }

  void _adoptReceivePopup(Map<String, dynamic> state) {
    receivePopupEnabled = state['enabled'] == true;
    receivePopupAllowed = state['allowed'] == true;
    receiveHeadsUpAllowed = state['headsUpAllowed'] == true;
    changed();
  }

  Future<void> refreshReceivePopup() async {
    if (!receivePopupAvailable) return;
    try {
      _adoptReceivePopup(await receivedNotifications.popupState());
    } catch (_) {
      receivePopupAllowed = false;
    }
  }

  Future<void> setReceivePopupEnabled(bool enabled) async {
    if (!receivePopupAvailable) return;
    _adoptReceivePopup(await receivedNotifications.setPopupEnabled(enabled));
  }

  Future<void> openReceivePopupSettings() async {
    if (receivePopupAvailable) await receivedNotifications.openPopupSettings();
  }

  Future<void> openReceiveNotificationSettings() async {
    if (receiveNotificationsAvailable) {
      await receivedNotifications.openNotificationSettings();
    }
  }

  String _noticeSource(String id) =>
      devices.where((device) => device['deviceId'] == id).firstOrNull?['name']
          as String? ??
      '其他设备';

  void _postReceivedNotice(
    DockEntry item,
    String version, {
    String? text,
    String? fileName,
    bool updated = false,
  }) {
    if (item.outgoing) return;
    _showReceipt(item, version);
    _enqueueReceivedNotice(
      itemId: item.id,
      version: version,
      conversation: item.source,
      sourceName: _noticeSource(item.source),
      text: text,
      fileName: fileName,
      localPath: item.localPath,
      size: item.size,
      updated: updated,
    );
    // Present received content before persistence, delivery ACKs and the rest
    // of reconciliation. Those operations may wait on disk or the network.
    changed();
  }

  void _showReceipt(DockEntry item, String version) {
    if (item.sourceLabel.isEmpty) item.sourceLabel = _noticeSource(item.source);
    if (_receiptVersions[item.id] == version) return;
    // A Windows receive is presented when offered. Completing that same file
    // updates its existing card, not a second arrival or a dismissed window.
    if (Platform.isWindows &&
        item.kind == 'file' &&
        _receiptSequence.containsKey(item.id)) {
      _receiptVersions[item.id] = version;
      return;
    }
    _receiptVersions[item.id] = version;
    nativeDismissedReceiptIds.remove(item.id);
    latestReceipt = item;
    pendingReceipts[item.id] = item;
    receiptSerial++;
    _receiptSequence[item.id] = receiptSerial;
  }

  void dismissReceipts(Iterable<String> ids, {int? throughSerial}) {
    for (final id in ids) {
      if (throughSerial == null ||
          (_receiptSequence[id] ?? 0) <= throughSerial) {
        pendingReceipts.remove(id);
      }
    }
  }

  void _enqueueReceivedNotice({
    required String itemId,
    required String version,
    required String conversation,
    required String sourceName,
    String? text,
    String? fileName,
    String? localPath,
    int? size,
    bool updated = false,
    String target = 'receive',
  }) {
    if (!receiveNotificationsAvailable || _notificationScope.isEmpty) return;
    final epoch = generation, scope = _notificationScope;
    _notificationWork = _notificationWork
        .catchError((Object _) {})
        .then((_) async {
          if (disposed || epoch != generation || scope != _notificationScope) {
            return;
          }
          await receivedNotifications.show(
            scope: scope,
            conversation: conversation,
            itemId: itemId,
            version: version,
            sourceName: sourceName,
            text: text,
            fileName: fileName,
            localPath: localPath,
            size: size,
            updated: updated,
            target: target,
          );
        })
        .catchError((Object _) {});
  }

  Future<void> get notificationIdle => _notificationWork;

  void _forgetSavedCopies(Iterable<SavedFile> removed) {
    final paths = removed.map((file) => file.path).toSet();
    for (final entry
        in dock
            .where((entry) => !entry.outgoing && entry.localPath.isNotEmpty)
            .toList()) {
      if (paths.contains(ReceivedFileAccess.canonical(entry.localPath))) {
        if (profile != null) {
          _localHistory?.remove('${profile!.key}:${entry.id}');
        }
        _hiddenDockIds.add(entry.id);
        dock.remove(entry);
      }
    }
    for (final record
        in _localHistory?.records.values.toList() ?? <LocalHistoryRecord>[]) {
      if (!record.entry.outgoing &&
          paths.contains(
            ReceivedFileAccess.canonical(record.entry.localPath),
          )) {
        _localHistory!.remove(record.key);
      }
    }
  }

  Future<void> renameSavedFile(String id, String name) async {
    final store = await _savedStore();
    if (store == null || !savedFiles.any((file) => file.id == id)) return;
    await store.rename(id, name);
    changed();
  }

  Future<void> deleteSavedFiles(Iterable<String> ids) async {
    final store = await _savedStore();
    if (store == null) return;
    final selected = ids.toSet().intersection(
      savedFiles.map((file) => file.id).toSet(),
    );
    _forgetSavedCopies(await store.remove(selected));
    await save();
    changed();
  }

  Future<void> forwardSavedFiles(String target, Iterable<String> ids) async {
    if (!sendablePeers.any((device) => device['deviceId'] == target)) {
      throw StateError('请选择设备');
    }
    final selected = ids.toSet();
    await refreshSavedFiles();
    final files = savedFiles
        .where((file) => selected.contains(file.id))
        .toList();
    if (files.length != selected.length || files.isEmpty) {
      throw StateError('文件已过期或被移除');
    }
    for (final file in files.where((file) => file.directory)) {
      _directorySources[file.path] = file.path;
    }
    await offer(
      target,
      files.map((file) => file.path).toList(),
      displayNames: {for (final file in files) file.path: file.name},
    );
  }

  void changed() {
    if (!_sendingStaged &&
        (!listEquals(stagedFiles, _stagedBatchFiles) ||
            !listEquals(stagedTexts, _stagedBatchTexts))) {
      stagedTargetStates.clear();
      _stagedTargetProgress.clear();
    }
    _updateReachability();
    if (!disposed) notifyListeners();
    if (!disposed) {
      backgroundReceive.update(
        authenticated: api?.token.isNotEmpty == true || _hasStoredSession,
        connected: connected,
        transferring:
            busyFiles.isNotEmpty ||
            nativeOperations.isNotEmpty ||
            _sendingPush.isNotEmpty ||
            _sendingRtc.isNotEmpty,
      );
    }
  }

  void _updateReachability() {
    if (disposed || !_reachabilityStarted) return;
    reachability.update(
      onlineDevices: onlinePeers,
      centerUrl: api?.baseUrl ?? '',
      online: connected,
      cellular: cellularUploads,
    );
    rtcProbes?.update(
      online: connected,
      foreground: _probeForeground,
      devices: onlinePeers,
    );
    reverseHttpsProbes?.update(
      onlinePeers,
      online: connected && peer != null,
      localSignature: jsonEncode([peer?.fingerprint, peer?.candidates]),
    );
  }

  void setProbeForeground(bool value) {
    _probeForeground = value;
    _updateReachability();
  }

  void setAppForeground(bool value) {
    _appForeground = value;
    if (value) {
      updateDiscoveredDevices(devices);
      changed();
    }
    if (receivePopupAvailable) {
      unawaited(
        receivedNotifications.setForeground(value).catchError((Object _) {}),
      );
      if (value) unawaited(refreshReceivePopup());
    }
    if (backgroundReceiveAvailable && !backgroundReceiveEnabled) {
      if (!value) {
        _pauseBackgroundConnection();
      } else if (_backgroundConnectionPaused) {
        unawaited(_resumeBackgroundConnection());
      }
    }
  }

  void _startRtcProbes() {
    if (info['features']?['rtcProbes'] != true ||
        rtcProbes != null ||
        rtc == null) {
      return;
    }
    final self = profile!.deviceId;
    rtcProbes = RtcProbeMonitor(
      api!,
      self,
      onResults: (results) => reachability.setRtcResults(self, results),
      supportsAddressReporting: info['features']?['rtcProbeAddresses'] == true,
      parallel: info['features']?['rtcParallelProbes'] == true,
    );
    _updateReachability();
  }

  Future<void> _republishNetworkAddresses() async {
    final epoch = generation;
    if (disposed || !connected) return;
    reverseHttpsProbes?.invalidate();
    await rtcProbes?.invalidate();
    await peer?.publish();
    await rtc?.publish();
    if (disposed || epoch != generation || !connected) return;
    await safeReconcile();
  }

  Future<void>? _networkReconnectWork;
  Future<void> _networkChanged() => _networkReconnectWork ??=
      _reconnectNetwork().whenComplete(() => _networkReconnectWork = null);

  Future<void> _reconnectNetwork() async {
    if (disposed ||
        api == null ||
        api!.token.isEmpty ||
        _backgroundConnectionPaused)
      return;
    final epoch = generation;
    reverseHttpsProbes?.invalidate();
    // Replace an OPEN socket too: its old interface can have disappeared while
    // the OS has not yet delivered its close event. Do not reset transfer state.
    await openSocket(epoch);
    if (disposed || epoch != generation || !connected) return;
    await rtcProbes?.invalidate();
    await reachability.refresh();
  }

  Future<void> init() async {
    _reachabilityStarted = true;
    reachability.start();
    if (Platform.isWindows) {
      _clipboardSubscription = SystemBridge.clipboardEvents.listen(
        _onClipboard,
      );
      _dockSubscription = SystemBridge.dropEvents.listen(handleNativeDockEvent);
    }
    _ephemeralCleanup = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pruneEphemeral(),
    );
    if (Platform.isAndroid) {
      _dockSubscription = DockPlatform.events.listen(handleNativeDockEvent);
      unawaited(refreshNativeDock().catchError((Object _) {}));
    }
    try {
      await backgroundReceive.initialize();
      root = await stateDirectory();
      await appearance.load(File('${root!.path}/appearance.json'));
      unawaited(updates.initialize(File('${root!.path}/updates.json')));
      await _loadStagedOutbox(restoreQueue: true);
      final file = File('${root!.path}/profiles.json');
      if (await file.exists()) {
        profiles = (jsonDecode(await file.readAsString()) as List)
            .map((e) => ServerProfile.fromJson(e))
            .toList();
      }
      await _loadLocalHistory();
      _nextSavedFilesCleanup = DateTime.now()
          .add(const Duration(minutes: 15))
          .millisecondsSinceEpoch;
      final recentFile = File('${root!.path}/recent-center.json');
      final recentKey = await recentFile.exists()
          ? jsonDecode(await recentFile.readAsString())['profileKey'] as String?
          : null;
      final recent = recentKey == null
          ? profiles.where((p) => p.deviceId.isNotEmpty).lastOrNull
          : profiles
                .where((p) => p.key == recentKey && p.deviceId.isNotEmpty)
                .firstOrNull;
      rememberedCenter = recent?.baseUrl ?? '';
      _hasStoredSession = recent?.deviceId.isNotEmpty == true;
      if (recent != null && _connectRequest == 0) {
        // Local library access does not need a network session. Credentials
        // remain unused until connect verifies the center's instance ID.
        profile = recent;
        final state = File('${root!.path}/${recent.storageKey}.json');
        if (await state.exists()) {
          final values = jsonDecode(await state.readAsString());
          if (_connectRequest == 0) {
            dock = (values['dock'] as List)
                .map((value) => DockEntry.fromJson(value))
                .toList();
            sources = Map<String, String>.from(values['sources'] ?? {});
            pendingTexts = Map<String, String>.from(
              values['pendingTexts'] ?? {},
            );
            _hiddenDockIds.addAll(
              List<String>.from(values['hiddenDockIds'] ?? []),
            );
            _temporarySources.addAll(
              List<String>.from(values['temporarySources'] ?? []),
            );
            _sharedBatchIds.addAll(
              List<String>.from(values['sharedBatchIds'] ?? []),
            );
            _directorySources.addAll(
              Map<String, String>.from(values['directorySources'] ?? {}),
            );
            dock = _restoreLocalHistoryEntries(recent, dock);
          }
        }
        await refreshCredentialRecoveries();
      }
      changed();
      unawaited(refreshLocalLibrary(migrate: true));
      if (recent != null && _connectRequest == 0) await _restoreRecent(recent);
    } catch (e) {
      message = '本地配置读取失败：$e';
      changed();
    } finally {
      backgroundReceive.ready();
    }
  }

  Future<void> _restoreRecent(ServerProfile recent) async {
    final attempt = connect(
      recent.baseUrl,
      development: recent.baseUrl.startsWith('http:'),
    );
    final request = _connectRequest;
    try {
      await attempt;
    } on VaultException {
      // connect already exposed a local-credential recovery state. Network
      // retries cannot unlock a DPAPI key and must not create a new identity.
      return;
    } catch (_) {
      if (disposed || request != _connectRequest) return;
      if (api != null && api!.token.isEmpty) return;
      connection = '中心暂不可用 · 自动重连';
      changed();
      _restoreTimer = Timer(
        const Duration(seconds: 10),
        () => unawaited(_restoreRecent(recent)),
      );
    }
  }

  Future<void> save() {
    final commit = _credentialCommitFinished;
    if (commit != null) return commit.future.then((_) => save());
    final directory = root;
    if (directory == null) return Future<void>.value();
    if (profile != null) dock = _restoreLocalHistoryEntries(profile!, dock);
    final profileJson = jsonEncode(profiles.map((p) => p.toJson()).toList());
    final key = profile?.storageKey;
    final logicalKey = profile?.key;
    final historyOwner = profile == null
        ? null
        : ServerProfile.fromJson(profile!.toJson());
    var historyEntries = dock.where((entry) => !entry.autoClipboard).map((
      entry,
    ) {
      final copy = DockEntry.fromJson(entry.toJson());
      if (copy.sourceLabel.isEmpty) {
        copy.sourceLabel = _noticeSource(
          entry.outgoing ? entry.targetDeviceId : entry.source,
        );
      }
      return copy;
    }).toList();
    final historySources = Map<String, String>.from(sources);
    final outboxJson = jsonEncode({
      'files': List<String>.from(stagedFiles),
      'texts': List<String>.from(stagedTexts),
      'temporarySources': _temporarySources.toList(),
      'directorySources': Map<String, String>.from(_directorySources),
      'directoryNames': Map<String, String>.from(stagedDirectoryNames),
      'sharedBatchIds': _sharedBatchIds.toList(),
    });
    final state = <String, dynamic>{
      'sources': Map<String, String>.from(sources),
      'pendingTexts': Map<String, String>.from(pendingTexts),
      'hiddenDockIds': _hiddenDockIds.toList(),
      'temporarySources': _temporarySources.toList(),
      'sharedBatchIds': _sharedBatchIds.toList(),
      'directorySources': Map<String, String>.from(_directorySources),
    };
    _saveTail = _saveTail.catchError((Object _) {}).then((_) async {
      await directory.create(recursive: true);
      await _loadLocalHistory();
      if (historyOwner != null) {
        historyEntries = _restoreLocalHistoryEntries(
          historyOwner,
          historyEntries,
        );
        _localHistory!.capture(historyOwner, historyEntries, historySources);
      }
      state['dock'] = historyEntries.map((entry) => entry.toJson()).toList();
      final stateJson = jsonEncode(state);
      await _localHistory!.save();
      Future<void> write(String name, String data) async {
        final temporary = File('${directory.path}/$name.tmp');
        await temporary.writeAsString(data, flush: true);
        await temporary.rename('${directory.path}/$name');
      }

      if (key != null) await write('$key.json', stateJson);
      await write('outbox.json', outboxJson);
      await write('profiles.json', profileJson);
      if (key != null) {
        await write(
          'recent-center.json',
          jsonEncode({'profileKey': logicalKey}),
        );
      }
    });
    return _saveTail;
  }

  Future<void> connect(String address, {bool development = false}) async {
    if (recoveringCredentials) throw StateError('正在恢复登录，请稍候');
    final request = ++_connectRequest;
    _restoreTimer?.cancel();
    final base = normalizeServer(address, allowHttp: development);
    final probe = CenterApi(base);
    Map<String, dynamic> data;
    try {
      data = await probe.call('GET', '/info', null, false);
    } finally {
      probe.close();
    }
    if (data['protocolVersion'] != 1 || data['instanceId'] is! String) {
      throw const FormatException('中心协议不兼容');
    }
    if (disposed || request != _connectRequest) return;
    await save();
    if (disposed || request != _connectRequest) return;
    generation++;
    stopConnections(
      preserveStaging: profile == null,
      clearNotifications:
          profile?.baseUrl != base || profile?.instanceId != data['instanceId'],
    );
    api = null;
    final p =
        profiles
            .where(
              (p) => p.baseUrl == base && p.instanceId == data['instanceId'],
            )
            .firstOrNull ??
        ServerProfile(baseUrl: base, instanceId: data['instanceId']);
    if (!profiles.contains(p)) profiles.add(p);
    profile = p;
    allowLegacyPeerIdentity = p.deviceId.isNotEmpty && p.legacyPeerIdentity;
    cellularUploads = p.cellularAllowed;
    _gate.limit = p.transferConcurrency;
    info = data;
    dock = [];
    sources = {};
    pendingTexts = {};
    _hiddenDockIds.clear();
    _temporarySources.clear();
    _directorySources.clear();
    devices = [];
    message = '';
    final local = root == null
        ? null
        : File('${root!.path}/${p.storageKey}.json');
    if (local != null && await local.exists()) {
      final j = jsonDecode(await local.readAsString());
      if (disposed || request != _connectRequest) return;
      dock = (j['dock'] as List).map((e) => DockEntry.fromJson(e)).toList();
      sources = Map<String, String>.from(j['sources'] ?? {});
      pendingTexts = Map<String, String>.from(j['pendingTexts'] ?? {});
      _hiddenDockIds.addAll(List<String>.from(j['hiddenDockIds'] ?? []));
      _temporarySources.addAll(List<String>.from(j['temporarySources'] ?? []));
      _sharedBatchIds.addAll(List<String>.from(j['sharedBatchIds'] ?? []));
      _directorySources.addAll(
        Map<String, String>.from(j['directorySources'] ?? {}),
      );
    }
    await _loadStagedOutbox();
    dock = _restoreLocalHistoryEntries(p, dock);
    unawaited(refreshLocalLibrary());
    if (disposed || request != _connectRequest) return;
    await refreshCredentialRecoveries();
    String token;
    try {
      token = await vault.read(key: 'token_${p.storageKey}') ?? '';
    } on VaultException catch (error) {
      if (disposed || request != _connectRequest) return;
      credentialProblem = error;
      _hasStoredSession = p.deviceId.isNotEmpty;
      connection = '登录凭据暂不可用';
      message = error.toString();
      changed();
      rethrow;
    }
    if (disposed || request != _connectRequest) return;
    credentialProblem = null;
    api = CenterApi(base, token: token);
    _hasStoredSession = token.isNotEmpty;
    connection = api!.token.isEmpty ? '等待入组' : '连接中';
    changed();
    await save();
    if (disposed || request != _connectRequest) return;
    if (api!.token.isNotEmpty) await start();
  }

  Future<void> enrollGroup(String name, String groupKey) async {
    if (groupKey.runes.length < 10 ||
        groupKey.runes.length > 256 ||
        groupKey != groupKey.trim() ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(groupKey)) {
      throw const FormatException('组密码需 10–256 字符，不含首尾空白或控制字符');
    }
    final epoch = generation, a = api!, p = profile!;
    if (name.trim().isEmpty) name = await systemDeviceName();
    _requireSession(epoch, a, p);
    final j = await a.call('POST', '/devices/enroll', {
      'name': name,
      'platform': _platformName,
      'groupKey': groupKey,
    }, false);
    _requireSession(epoch, a, p);
    await adoptEnrollment(j, name);
  }

  Future<void> refreshCredentialRecoveries() async {
    final directory = root;
    final selected = profile;
    credentialRecoveryRecords = directory == null || selected == null
        ? []
        : await CredentialRecoveryStore(directory, vault).records(selected.key);
  }

  /// Called only after the UI explains and confirms the replacement identity.
  /// The old protected bytes and local history are archived before enrollment;
  /// no old transfer permission is inherited by the replacement device.
  Future<void> recoverCredentialEnrollment(String name, String groupKey) async {
    if (credentialProblem == null || profile == null) {
      throw StateError('当前无需恢复登录凭据');
    }
    if (recoveringCredentials) throw StateError('正在恢复登录，请稍候');
    if (groupKey.runes.length < 10 ||
        groupKey.runes.length > 256 ||
        groupKey != groupKey.trim() ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(groupKey)) {
      throw const FormatException('组密码需 10–256 字符，不含首尾空白或控制字符');
    }
    final p = profile!;
    final request = ++_connectRequest;
    _restoreTimer?.cancel();
    recoveringCredentials = true;
    changed();
    CenterApi? replacement;
    try {
      if (name.trim().isEmpty) name = await systemDeviceName();
      final directory = root ?? await stateDirectory();
      root = directory;
      await save();
      final record = await CredentialRecoveryStore(directory, vault).snapshot(
        profileKey: p.key,
        storageKey: p.storageKey,
        profile: p.toJson(),
        history: {
          'dock': dock
              .where((item) => !item.autoClipboard)
              .map((item) => item.toJson())
              .toList(),
          'sources': sources,
          'pendingTexts': pendingTexts,
          'hiddenDockIds': _hiddenDockIds.toList(),
          'temporarySources': _temporarySources.toList(),
          'directorySources': _directorySources,
          'stagedFiles': stagedFiles,
          'stagedTexts': stagedTexts,
        },
      );
      credentialRecoveryRecords.insert(0, record);
      replacement = CenterApi(p.baseUrl);
      final j = await replacement.call('POST', '/devices/enroll', {
        'name': name,
        'platform': _platformName,
        'groupKey': groupKey,
      }, false);
      if (disposed || request != _connectRequest || profile != p) {
        throw StateError('连接已改变，请重新确认恢复');
      }
      final device = Map<String, dynamic>.from(j['device']);
      final token = j['deviceToken'];
      if (device['deviceId'] is! String ||
          (device['deviceId'] as String).isEmpty ||
          token is! String ||
          token.isEmpty) {
        throw const FormatException('中心未返回可用的新设备身份');
      }
      // Keep replacement credentials/state in an independent storage identity.
      // The old profile pointer stays active until the final durable commit.
      final recovered = ServerProfile.fromJson({
        ...p.toJson(),
        'storageId': newId(),
        'legacyPeerIdentity': false,
        'deviceId': device['deviceId'],
        'groupId': j['groupId'] ?? device['groupId'] ?? '',
        'name': name,
        'cursor': 0,
      });
      if (recovered.groupId != p.groupId) recovered.autoReceive = true;
      _credentialCommitFinished = Completer<void>();
      await _saveTail.catchError((Object _) {});
      await vault.write(key: 'token_${recovered.storageKey}', value: token);
      if (disposed || request != _connectRequest || profile != p) {
        throw StateError('连接已改变，恢复备份已保留');
      }
      await commitCredentialProfile(
        p,
        recovered,
        {
          'dock': <dynamic>[],
          'sources': <String, String>{},
          'pendingTexts': <String, dynamic>{},
          'hiddenDockIds': <String>[],
          'temporarySources': _temporarySources
              .where(stagedFiles.contains)
              .toList(),
          'directorySources': {
            for (final entry in _directorySources.entries)
              if (stagedFiles.contains(entry.key)) entry.key: entry.value,
          },
        },
        canCommit: () =>
            !disposed && request == _connectRequest && profile == p,
      );
      generation++;
      stopConnections(preserveStaging: true, clearNotifications: true);
      // Archived sources must remain on disk, but must not become mutable
      // network history under the new device. Keep current staged inputs usable.
      _temporarySources.removeWhere((path) => !stagedFiles.contains(path));
      _directorySources.removeWhere((path, _) => !stagedFiles.contains(path));
      dock = [];
      sources = {};
      pendingTexts = {};
      _hiddenDockIds.clear();
      devices = [];
      profiles = [
        for (final item in profiles)
          if (identical(item, p)) recovered else item,
      ];
      profile = recovered;
      allowLegacyPeerIdentity = false;
      replacement.token = token;
      api = replacement;
      replacement = null;
      credentialProblem = null;
      _hasStoredSession = true;
      message = '';
      connection = '连接中';
      _finishCredentialCommit();
      await start();
    } on VaultException catch (error) {
      credentialProblem = error;
      connection = '登录凭据暂不可用';
      message = error.toString();
      rethrow;
    } finally {
      _finishCredentialCommit();
      replacement?.close();
      recoveringCredentials = false;
      if (!disposed) changed();
    }
  }

  Future<void> commitCredentialProfile(
    ServerProfile previous,
    ServerProfile recovered,
    Map<String, dynamic> state, {
    required bool Function() canCommit,
  }) => CredentialRecoveryStore(root!, vault).commitIdentity(
    storageKey: recovered.storageKey,
    state: state,
    profiles: [
      for (final item in profiles)
        (identical(item, previous) ? recovered : item).toJson(),
    ],
    canCommit: canCommit,
  );

  void _finishCredentialCommit() {
    final commit = _credentialCommitFinished;
    _credentialCommitFinished = null;
    if (commit != null && !commit.isCompleted) commit.complete();
  }

  Future<void> adoptEnrollment(Map<String, dynamic> j, String name) async {
    final p = profile!;
    final deviceId = j['device']['deviceId'] as String;
    final groupId = j['groupId'] ?? j['device']['groupId'] ?? '';
    final previousApi = api!;
    final previousEpoch = generation;
    final token = j['deviceToken'] as String;
    await save();
    _requireSession(previousEpoch, previousApi, p);
    // Do not mutate the active identity or clear its local state until the new
    // credential has actually been protected and committed.
    await vault.write(key: 'token_${p.storageKey}', value: token);
    _requireSession(previousEpoch, previousApi, p);
    if (p.deviceId != deviceId || p.groupId != groupId) {
      if (p.groupId != groupId) p.autoReceive = true;
      generation++;
      stopConnections(
        preserveStaging: p.deviceId.isEmpty,
        clearNotifications: true,
      );
      dock = [];
      sources = {};
      pendingTexts = {};
      _hiddenDockIds.clear();
      devices = [];
      p.cursor = 0;
      allowLegacyPeerIdentity = false;
      p.legacyPeerIdentity = false;
      api = CenterApi(p.baseUrl);
    }
    final a = api!;
    final epoch = generation;
    a.token = token;
    _hasStoredSession = a.token.isNotEmpty;
    p.deviceId = j['device']['deviceId'];
    p.groupId = groupId;
    p.name = name;
    _requireSession(epoch, a, p);
    await save();
    _requireSession(epoch, a, p);
    await start();
    _requireSession(epoch, a, p);
  }

  Future<void> start() async {
    final epoch = generation, a = api!, p = profile!;
    failures = 0;
    _startTransportsOnConnect = true;
    await openSocket(epoch);
    _requireSession(epoch, a, p);
  }

  Future<void> startPeer() async {
    final a = api!, p = profile!, epoch = generation;
    if (info['features']?['folderTransfer'] == true) {
      await a.call('POST', '/devices/me/capabilities', {
        'folderTransfer': true,
      });
      _requireSession(epoch, a, p);
    }
    if (info['features']?['direct'] != true) {
      peerStatus = '中心仅支持中继';
      return;
    }
    try {
      final identityKey = 'peer_${p.storageKey}_${p.deviceId}';
      final saved =
          await vault.read(key: identityKey) ??
          (allowLegacyPeerIdentity
              ? await vault.read(key: 'peer_${p.key}')
              : null);
      final identity = saved == null
          ? await compute(createPeerIdentity, p.deviceId)
          : Map<String, String>.from(jsonDecode(saved));
      await vault.write(key: identityKey, value: jsonEncode(identity));
      if (epoch != generation) return;
      final paths = sources;
      final service = PeerTransport(
        a,
        (id) => paths[id],
        addressReader: localIpAddresses,
        pushEnabled: info['features']?['directPush'] == true,
        httpsProbeEnabled: info['features']?['httpsPeerProbes'] == true,
        cellularPushAllowed: () => Platform.isAndroid && cellularUploads,
        acquireSource: (fileId) async {
          // A self-transfer already owns its receiver slot in this process.
          if (dock.any(
            (item) =>
                item.fileId == fileId && item.targetDeviceId == p.deviceId,
          ))
            return false;
          final item = dock
              .where((d) => d.fileId == fileId && d.outgoing)
              .firstOrNull;
          if (item?.locallyPaused == true || item?.locallyCanceled == true)
            throw const TransferStopped();
          final stopped = Completer<void>();
          (_sourceGateWaits[fileId] ??= {}).add(stopped);
          try {
            await _gate.enter(stopped: stopped.future);
          } finally {
            _sourceGateWaits[fileId]?.remove(stopped);
            if (_sourceGateWaits[fileId]?.isEmpty == true)
              _sourceGateWaits.remove(fileId);
          }
          try {
            _requireSession(epoch, a, p);
            if (item?.locallyPaused == true || item?.locallyCanceled == true)
              throw const TransferStopped();
            return true;
          } catch (_) {
            _gate.leave();
            rethrow;
          }
        },
        releaseSource: _gate.leave,
        onProgress: (id, bytes, total, finished) {
          if (epoch != generation) return;
          final item = dock
              .where((d) => d.fileId == id && d.outgoing)
              .firstOrNull;
          if (item == null) return;
          if (item.locallyPaused ||
              item.locallyCanceled ||
              item.receiveFailure) {
            if (finished) {
              busyFiles.remove(id);
              changed();
            }
            return;
          }
          if (finished) {
            busyFiles.remove(id);
            item.status = bytes == total ? 'awaitingReceipt' : 'accepted';
          } else {
            busyFiles.add(id);
            item.status = 'directSending';
          }
          if (!['lan', 'public'].contains(item.route)) item.route = 'direct';
          item.progress = total == 0 ? 1 : bytes / total;
          item.recordTransferBytes(bytes);
          changed();
        },
        onRoute: (id, route) {
          if (epoch != generation) return;
          final item = dock
              .where((d) => d.fileId == id && d.outgoing)
              .firstOrNull;
          if (item != null &&
              !item.locallyCanceled &&
              !item.locallyPaused &&
              !item.receiveFailure) {
            item.route = route;
            item.routeDetail = route == 'lan'
                ? '对方正在通过局域网地址拉取'
                : '对方正在通过公网IP拉取';
          }
        },
      );
      if (info['features']?['httpsPeerProbes'] == true) {
        reverseHttpsProbes ??= ReverseHttpsProbes(
          a,
          localAddresses: localIpAddresses,
          cellularAllowed: () => cellularUploads,
          androidCellular: Platform.isAndroid,
        );
      }
      await service.start(identity);
      if (epoch != generation) {
        await service.close();
        return;
      }
      peer = service;
      peerStatus = '原生 HTTPS 直连已就绪';
      peerHeartbeat = Timer.periodic(const Duration(minutes: 2), (_) async {
        try {
          await service.publish();
        } catch (_) {}
      });
    } catch (e) {
      if (epoch != generation) return;
      peerStatus = '直连监听不可用，使用中继：$e';
    }
    changed();
  }

  Future<void> startRtc() async {
    if (info['features']?['rtcDataChannels'] != true) return;
    final epoch = generation, a = api!, p = profile!;
    final service = RtcFileTransport(
      a,
      parallelProbes: info['features']?['rtcParallelProbes'] == true,
      cellularAllowed: () => cellularUploads,
      onNetwork: (fileId, network, family) {
        if (epoch != generation) return;
        final label = switch (network) {
          'cellular' => '蜂窝',
          'wifi' => 'Wi-Fi',
          'ethernet' => '以太网',
          'vpn' => 'VPN',
          _ => '网络未识别',
        };
        _rtcNetwork[fileId] =
            '$label${family == 'ipv6'
                ? ' IPv6'
                : family == 'ipv4'
                ? ' IPv4'
                : ''}';
        final item = dock.where((entry) => entry.fileId == fileId).firstOrNull;
        if (item != null) item.routeDetail = _rtcLabel(item.fileId, item.route);
        changed();
      },
      iceServers: [
        for (final server in info['rtc']?['iceServers'] ?? const [])
          Map<String, dynamic>.from(server),
      ],
    );
    try {
      await RtcFileTransport.initialize();
      _requireSession(epoch, a, p);
      await service.publish();
      _requireSession(epoch, a, p);
      rtc = service;
      _startRtcProbes();
      rtcHeartbeat = Timer.periodic(const Duration(minutes: 2), (_) async {
        try {
          if (epoch == generation) await service.publish();
        } catch (_) {
          // Refresh reconnects an expired capability without changing routes.
        }
      });
    } catch (_) {
      await service.close();
      // HTTPS and relay remain available if the optional native plugin fails.
    }
  }

  Future<void> openSocket(int epoch) async {
    if (epoch != generation || disposed || api == null || api!.token.isEmpty) {
      return;
    }
    reconnect?.cancel();
    final attempt = ++_socketAttempt;
    try {
      await _configureReceivedNotifications();
      if (epoch != generation || disposed || attempt != _socketAttempt) return;
      final a = api!;
      final ticket = await a.call('POST', '/session/ws-ticket', {});
      final uri = a
          .uri('/ws')
          .replace(
            scheme: a.baseUrl.startsWith('https:') ? 'wss' : 'ws',
            queryParameters: {'ticket': ticket['ticket']},
          );
      final ws = await WebSocket.connect(uri.toString())
          .timeout(const Duration(seconds: 15));
      if (epoch != generation || disposed || attempt != _socketAttempt) {
        await ws.close();
        return;
      }
      final previous = socket;
      socket = ws;
      unawaited(previous?.close());
      ws.pingInterval = const Duration(seconds: 20);
      final hello = Completer<void>();
      ws.listen(
        (message) {
          if (epoch != generation || attempt != _socketAttempt) return;
          final value = Map<String, dynamic>.from(
            jsonDecode(message as String),
          );
          if (value['type'] == 'hello' &&
              value['deviceId'] == profile?.deviceId) {
            if (!hello.isCompleted) hello.complete();
            return;
          }
          unawaited(handleServerMessage(value));
        },
        onDone: () {
          if (!hello.isCompleted) hello.completeError(StateError('连接已关闭'));
          if (attempt == _socketAttempt) lost(epoch);
        },
        onError: (Object error) {
          if (!hello.isCompleted) hello.completeError(error);
          if (attempt == _socketAttempt) lost(epoch);
        },
        cancelOnError: true,
      );
      await hello.future.timeout(const Duration(seconds: 15));
      if (epoch != generation || disposed || attempt != _socketAttempt) return;
      connected = true;
      unawaited(refreshReceiveNotifications(request: true));
      sharedDocument.connect(a, enabled: sharedTextSupported);
      unawaited(sharedDocument.refresh());
      connection = '已连接';
      failures = 0;
      changed();
      if (peer != null) {
        await peer!.publish();
      } else if (_startTransportsOnConnect) {
        await startPeer();
      }
      if (rtc != null) {
        await rtc!.publish();
      } else if (_startTransportsOnConnect) {
        await startRtc();
      }
      if (epoch != generation || disposed || attempt != _socketAttempt) return;
      _startRtcProbes();
      poll?.cancel();
      poll = Timer.periodic(
        const Duration(seconds: 15),
        (_) => unawaited(safeReconcile()),
      );
      await safeReconcile();
    } catch (e) {
      if (epoch == generation && attempt == _socketAttempt) {
        message = '连接中断，可重连补收';
        lost(epoch);
      }
    }
  }

  void lost(int epoch) {
    if (epoch != generation || disposed) return;
    _socketAttempt++;
    final previous = socket;
    socket = null;
    unawaited(previous?.close());
    poll?.cancel();
    connected = false;
    sharedDocument.disconnected();
    _deviceRevision++;
    updateDiscoveredDevices(
      devices.map((device) => {...device, 'online': false}).toList(),
    );
    connection = '离线 · 自动重连';
    changed();
    reconnect?.cancel();
    final delay = min(30, 1 << min(failures++, 5));
    reconnect = Timer(
      Duration(milliseconds: delay * 1000 + Random().nextInt(600)),
      () => unawaited(openSocket(epoch)),
    );
  }

  Future<void> handleServerMessage(Map<String, dynamic> message) async {
    if (message['type'] == 'https.probe' ||
        message['type'] == 'https.probe.cancel') {
      await reverseHttpsProbes?.handle(message);
      return;
    }
    if (message['type'] == 'sharedText.updated' && sharedTextSupported) {
      sharedDocument.applyRemote(message);
      return;
    }
    if (message['type'] == 'rtc.probes.changed') {
      await rtcProbes?.signalChanged();
      return;
    }
    if (message['type'] == 'presence') {
      _deviceRevision++;
      final device = devices
          .where((device) => device['deviceId'] == message['deviceId'])
          .firstOrNull;
      if (device != null) {
        updateDiscoveredDevices(
          devices
              .map(
                (item) => item['deviceId'] == message['deviceId']
                    ? {...item, 'online': message['online'] == true}
                    : item,
              )
              .toList(),
        );
        changed();
        if (message['online'] == true) await safeReconcile();
        return;
      }
    }
    await safeReconcile();
  }

  Future<void>? _deviceRefresh;
  Future<void> refreshGroupDevices() => _deviceRefresh ??=
      _refreshGroupDevices().whenComplete(() => _deviceRefresh = null);

  Future<void> refreshConnectionChecks({String? deviceId}) async {
    if (disposed || !connected) return;
    await Future.wait<void>([
      deviceId == null
          ? reachability.refresh()
          : reachability.refreshDevice(deviceId),
      if (rtcProbes != null) rtcProbes!.refreshNow(peerId: deviceId),
      if (reverseHttpsProbes != null)
        reverseHttpsProbes!.refresh(deviceId: deviceId, force: true),
    ]);
  }

  Future<void> _refreshGroupDevices() async {
    if (disposed || api == null || api!.token.isEmpty) return;
    if (!connected) {
      if (_backgroundConnectionPaused) {
        await _resumeBackgroundConnection();
      } else {
        await openSocket(generation);
      }
      if (!disposed && connected) await refreshConnectionChecks();
      return;
    }
    await _republishNetworkAddresses();
    if (!disposed && connected) await refreshConnectionChecks();
  }

  Future<void> safeReconcile() async {
    final epoch = generation, a = api;
    try {
      await reconcile();
    } catch (e) {
      if (disposed || epoch != generation || !identical(a, api)) return;
      message = '$e';
      if (e is ApiException && (e.status == 401 || e.status == 403)) {
        _hasStoredSession = false;
        generation++;
        stopConnections(clearNotifications: true);
        api?.token = '';
        connection = '授权失效 · 请重新输入组密码';
      }
      changed();
    }
  }

  Future<void> reconcile() async {
    if (syncing) {
      _reconcileAgain = true;
      return;
    }
    if (api == null || profile == null) return;
    syncing = true;
    final epoch = generation, a = api!, p = profile!;
    try {
      final revision = _deviceRevision;
      final ds = await a.call('GET', '/devices');
      if (epoch != generation) return;
      if (revision == _deviceRevision) {
        updateDiscoveredDevices(
          (ds['devices'] as List)
              .map((e) => Map<String, dynamic>.from(e))
              .map(
                (device) => connected ? device : {...device, 'online': false},
              )
              .toList(),
        );
      } else {
        _reconcileAgain = true;
      }
      final self = devices
          .where((device) => device['deviceId'] == p.deviceId)
          .firstOrNull;
      if (self != null) p.name = self['name'] as String;
      changed();
      var more = true;
      while (more) {
        final j = await a.call('GET', '/events?after=${p.cursor}&limit=100');
        if (epoch != generation) return;
        for (final e in j['events']) {
          if (e['type'] == 'text.created' &&
              !_isHiddenDockId(e['eventId']) &&
              !dock.any((d) => d.id == e['eventId'])) {
            final outgoing = e['sourceDeviceId'] == p.deviceId;
            final clipboard = e['payload']['clipboard'];
            final automatic = clipboard is Map;
            final expires =
                DateTime.tryParse(e['expiresAt'] ?? '')
                    ?.millisecondsSinceEpoch ??
                DateTime.now().millisecondsSinceEpoch + 300000;
            dock.insert(
              0,
              DockEntry(
                id: e['eventId'],
                createdAtMillis:
                    DateTime.tryParse(e['createdAt'] ?? '')
                        ?.millisecondsSinceEpoch ??
                    DateTime.now().millisecondsSinceEpoch,
                kind: 'text',
                title: outgoing ? '已发送文本' : '收到文本',
                source: e['sourceDeviceId'],
                targetDeviceId: e['targetDeviceId'] ?? '',
                sourceLabel: _noticeSource(
                  outgoing ? e['targetDeviceId'] ?? '' : e['sourceDeviceId'],
                ),
                text: e['payload']['text'],
                editedAt: e['payload']['editedAt'] ?? '',
                contentId: e['payload']['contentId'] ?? '',
                contentRevision: e['payload']['revision'] ?? 0,
                outgoing: outgoing,
                status: outgoing ? 'sent' : 'ready',
                autoClipboard: automatic,
                expiresAtMillis: automatic ? expires : 0,
                originDeviceId: automatic
                    ? clipboard['originDeviceId'] ?? ''
                    : '',
                sourceEventId: automatic
                    ? clipboard['sourceEventId'] ?? ''
                    : '',
              ),
            );
            _localHistory?.restoreLocalEdit(p.key, dock.first);
            if (automatic && !outgoing) {
              await _applyRemoteClipboard(Map<String, dynamic>.from(e));
            }
            if (!outgoing) {
              _postReceivedNotice(
                dock.firstWhere((item) => item.id == e['eventId']),
                '${e['cursor']}',
                text: e['payload']['text'],
              );
            }
          }
          if (e['type'] == 'text.updated') {
            applyTextUpdate(Map<String, dynamic>.from(e));
          }
          if (e['type'] == 'text.received') {
            for (final d in dock.where(
              (d) => d.id == e['payload']['sourceEventId'],
            )) {
              d.status = 'received';
            }
          }
        }
        // Persist entries before advancing/acknowledging delivery.
        await save();
        _requireSession(epoch, a, p);
        p.cursor = j['cursor'];
        await save();
        _requireSession(epoch, a, p);
        for (final e in j['events']) {
          if (e['type'] == 'text.created' &&
              e['targetDeviceId'] == p.deviceId) {
            await a.call('POST', '/events/${e['eventId']}/ack', {});
            _requireSession(epoch, a, p);
          }
        }
        more = j['hasMore'] == true;
      }
      if (info['features']?['textContentSync'] == true) {
        final latest = await a.call('GET', '/texts/latest');
        _requireSession(epoch, a, p);
        for (final value in latest['documents'] as List) {
          applyTextDocument(Map<String, dynamic>.from(value));
        }
      }
      final transfers = await a.call('GET', '/transfers');
      if (epoch != generation) return;
      for (final t in transfers['transfers']) {
        updateTransfer(Map<String, dynamic>.from(t));
      }
      if (p.autoReceive) {
        for (final transfer in transfers['transfers']) {
          _requireSession(epoch, a, p);
          final t = Map<String, dynamic>.from(transfer);
          if (t['targetDeviceId'] != p.deviceId ||
              t['sourceDeviceId'] == p.deviceId) {
            continue;
          }
          final ids = (t['files'] as List)
              .where((f) => f['status'] == 'offered')
              .map((f) => f['fileId'] as String)
              .toList();
          if (ids.isEmpty) continue;
          final batch = dock
              .where(
                (d) =>
                    d.transferId == t['transferId'] && ids.contains(d.fileId),
              )
              .toList();
          if (batch.any((d) => d.locallyCanceled || d.locallyPaused)) continue;
          if (p.receiveRoutePreference == 'relay') {
            for (final item in batch.where(
              (d) => !d.relayConfirmationPending,
            )) {
              item.relayConfirmed = true;
            }
          }
          // /accept rejects omitted offered items. Keep a mixed relay batch
          // intact until the receiver explicitly accepts it.
          final needsConsent = batch.any(
            (d) =>
                d.relayConfirmationPending ||
                (d.offerRoutePreference == 'relay' ||
                        info['features']?['direct'] != true && rtc == null) &&
                    needsRelayConsent(d),
          );
          if (needsConsent) {
            for (final item in batch) {
              markRelayPending(item, beforeAccept: true);
            }
            continue;
          }
          final entry = dock
              .where(
                (d) =>
                    d.transferId == t['transferId'] && ids.contains(d.fileId),
              )
              .firstOrNull;
          if (entry != null && p.autoReceive) {
            await acceptSelected(entry, ids, reconcileAfter: false);
          }
        }
      }
      await save();
      changed();
    } finally {
      syncing = false;
      if (_reconcileAgain) {
        _reconcileAgain = false;
        if (!disposed && api?.token.isNotEmpty == true) {
          unawaited(safeReconcile());
        }
      }
    }
  }

  void updateTransfer(Map<String, dynamic> t) {
    final outgoing = t['sourceDeviceId'] == profile!.deviceId;
    for (final f in t['files']) {
      final id = f['fileId'] as String;
      if (_isHiddenDockId(id)) continue;
      var item = dock
          .where((d) => d.id == id && d.transferId == t['transferId'])
          .firstOrNull;
      if (item == null) {
        item = DockEntry(
          id: id,
          kind: 'file',
          title: f['name'],
          source: t['sourceDeviceId'],
          transferId: t['transferId'],
          fileId: id,
          size: f['size'],
          relativePath: f['relativePath'] ?? '',
          entryKind: f['entryKind'] ?? 'file',
          createdAtMillis:
              DateTime.tryParse(t['createdAt'] ?? '')?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
          outgoing: outgoing,
        );
        dock.insert(0, item);
        if (!outgoing &&
            Platform.isWindows &&
            ['offered', 'accepted', 'uploading', 'ready'].contains(f['status']))
          _showReceipt(item, 'incoming');
        if (!outgoing &&
            profile?.autoReceive == false &&
            f['status'] == 'offered') {
          _postReceivedNotice(item, 'offered', fileName: '待接收 · ${item.title}');
        }
      }
      item.relativePath = f['relativePath'] ?? item.relativePath;
      item.contentDigest = f['sha256'] ?? item.contentDigest;
      item.entryKind = f['entryKind'] ?? item.entryKind;
      final wasReceiveFailure = item.receiveFailure;
      item.receiveFailure = f['receiveFailure'] == true;
      if (item.receiveFailure) item.receiveFailureReported = true;
      if (!outgoing &&
          wasReceiveFailure &&
          !item.receiveFailureReported &&
          item.status == 'failed')
        item.receiveFailure = true;
      if (wasReceiveFailure && !item.receiveFailure) item.error = '';
      if (outgoing) {
        final path = sources[id];
        item.localPath = path ?? item.localPath;
        item.sourceReference = _directorySources[path] ?? item.sourceReference;
      }
      if (item.attemptId != (f['attemptId'] ?? '')) {
        item.attemptId = f['attemptId'] ?? '';
        item.error = '';
      }
      if (!outgoing &&
          !item.locallyPaused &&
          !item.locallyCanceled &&
          item.status == 'failed' &&
          item.error.isNotEmpty &&
          !item.receiveFailure &&
          ['目录', '文件夹', '直接读写'].any(item.error.contains)) {
        item.receiveFailure = true;
        _reportReceiveFailure(item);
      }
      if (f['status'] == 'failed' && f['errorCode'] is String) {
        item.error = f['errorCode'];
        if (item.receiveFailure &&
            !item.locallyCanceled &&
            !item.locallyPaused) {
          item.status = 'failed';
          _stopFile(item);
        }
      }
      if (!busyFiles.contains(id)) {
        if (item.locallyCanceled) {
          item.status = 'canceled';
        } else if (item.locallyPaused) {
          item.status = 'paused';
        } else if (item.relayConfirmationPending &&
            [
              'offered',
              'accepted',
              'uploading',
              'ready',
            ].contains(f['status'])) {
          item.status = 'relayConsent';
          item.relayPendingBeforeAccept = f['status'] == 'offered';
        } else if (!(item.status == 'awaitingReceipt' &&
                f['transport'] == 'direct' &&
                f['status'] == 'accepted') &&
            !(item.status == 'failed' &&
                item.error.isNotEmpty &&
                ['accepted', 'uploading', 'ready'].contains(f['status']))) {
          item.status = f['status'];
        }
        if (f['transport'] != 'direct' ||
            !['lan', 'public'].contains(item.route)) {
          item.route = f['transport'] ?? 'pending';
        }
        item.progress =
            f['status'] == 'received' || item.status == 'awaitingReceipt'
            ? 1
            : item.size == 0
            ? 0
            : (f['offset'] as int) / item.size;
      }
      item.offerRoutePreference = t['routePreference'] ?? 'auto';
      item.targetDeviceId = t['targetDeviceId'];
      item.sourceLabel = _noticeSource(
        outgoing ? item.targetDeviceId : item.source,
      );
      if (['canceled', 'rejected', 'expired'].contains(f['status'])) {
        item.relayConfirmationPending = false;
        item.relayPendingBeforeAccept = false;
        peer?.cancelFile(id);
        unawaited(rtc?.cancelFile(id));
      }
      if (f['status'] == 'received') {
        item.relayConfirmationPending = false;
        item.relayPendingBeforeAccept = false;
        if (outgoing) {
          item.routeDetail = '已送达';
        } else if (item.routeDetail.isEmpty) {
          item.routeDetail = '已保存';
        }
        if (!outgoing && f['reused'] == true && item.localPath.isNotEmpty) {
          final receivedAt = DateTime.tryParse(f['receivedAt'] ?? '');
          if (receivedAt != null &&
              receivedAt.millisecondsSinceEpoch > item.receivedAtMillis) {
            item.receivedAtMillis = receivedAt.millisecondsSinceEpoch;
            // Also recovers a successful reuse receipt whose response was lost.
            unawaited(
              _rememberSavedFile(
                item,
                profile!,
                receivedAt: receivedAt,
              ).then((_) => save()),
            );
          }
        }
      }
      if (!outgoing &&
          Platform.isWindows &&
          pendingReceipts.containsKey(item.id))
        changed();
      final requestedPush = f['directPush'];
      final requestedRtc = f['rtc'];
      if (outgoing &&
          !item.isDirectory &&
          requestedRtc is Map &&
          ['negotiating', 'streaming'].contains(requestedRtc['state'])) {
        _pendingRtc[id] = Map<String, dynamic>.from(requestedRtc);
      } else {
        _pendingRtc.remove(id);
      }
      if (requestedRtc is! Map || requestedRtc['state'] == 'failed') {
        _startedRtc.remove(id);
      }
      final activeRtc = _sendingRtc[id];
      if (activeRtc != null &&
          (requestedRtc is! Map ||
              requestedRtc['attemptId'] != activeRtc ||
              !['negotiating', 'streaming'].contains(requestedRtc['state']))) {
        unawaited(rtc?.cancelFile(id));
      }
      if (requestedPush is! Map || requestedPush['state'] == 'failed') {
        _startedPushes.remove(id);
      }
      final activePush = _sendingPush[id];
      if (activePush != null &&
          (requestedPush is! Map ||
              requestedPush['attemptId'] != activePush ||
              !['waiting', 'streaming'].contains(requestedPush['state']))) {
        peer?.cancelFile(id);
        final operation = nativeOperations[id];
        if (operation != null) unawaited(NetworkBridge.cancel(operation));
      }
      if (outgoing &&
          !item.isDirectory &&
          !item.locallyCanceled &&
          !item.locallyPaused &&
          item.status != 'failed' &&
          item.error.isEmpty &&
          ['accepted', 'uploading'].contains(f['status']) &&
          sources.containsKey(id) &&
          !busyFiles.contains(id)) {
        if (f['transport'] == 'direct') {
          routeTimers.remove(id)?.cancel();
          if (requestedRtc is Map && requestedRtc['state'] == 'negotiating') {
            unawaited(_sendRtc(item, Map<String, dynamic>.from(requestedRtc)));
          } else if (requestedPush is Map &&
              requestedPush['state'] == 'waiting') {
            unawaited(
              _sendPush(
                item,
                t['targetDeviceId'],
                Map<String, dynamic>.from(requestedPush),
              ),
            );
          }
        } else if (f['transport'] == 'relay' ||
            info['features']?['direct'] != true && rtc == null) {
          routeTimers.remove(id)?.cancel();
          unawaited(upload(item));
        }
      } else if (!['accepted', 'uploading'].contains(f['status'])) {
        routeTimers.remove(id)?.cancel();
      }
      if (!outgoing &&
          !item.locallyCanceled &&
          !item.locallyPaused &&
          item.status != 'failed' &&
          !item.relayConfirmationPending &&
          item.localPath.isEmpty &&
          item.error.isEmpty &&
          !busyFiles.contains(id) &&
          (f['status'] == 'ready' ||
              item.isDirectory && f['status'] == 'accepted' ||
              f['status'] == 'accepted' && f['transport'] != 'relay')) {
        unawaited(receive(item, preferDirect: f['status'] == 'accepted'));
      }
    }
    unawaited(_releaseCompletedFolderSources());
  }

  Future<void> revoke(String id) async {
    await api!.call('DELETE', '/devices/$id');
    await safeReconcile();
    message = '设备已移除';
    changed();
  }

  Future<void> renameDevice(String value) async {
    final name = value.trim();
    if (name.isEmpty || name.runes.length > 80) {
      throw const FormatException('设备名称需为 1–80 个字符');
    }
    final epoch = generation, a = api!, p = profile!;
    final result = await a.call('PATCH', '/devices/me', {'name': name});
    _requireSession(epoch, a, p);
    final device = Map<String, dynamic>.from(result['device']);
    p.name = device['name'] as String;
    final index = devices.indexWhere(
      (entry) => entry['deviceId'] == p.deviceId,
    );
    if (index >= 0) devices[index] = device;
    await save();
    _requireSession(epoch, a, p);
    message = '名称已保存';
    changed();
  }

  Future<String> useSystemDeviceName() async {
    final epoch = generation, a = api!, p = profile!;
    final name = await systemDeviceName();
    _requireSession(epoch, a, p);
    await renameDevice(name);
    return p.name;
  }

  Future<void> setClipboardSync(bool enabled, String targetDeviceId) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('自动剪贴板仅用于 Windows；移动端不后台读剪贴板');
    }
    if (!enabled) {
      _stopClipboard();
      changed();
      return;
    }
    if (api?.token.isNotEmpty != true ||
        !devices.any(
          (d) =>
              d['deviceId'] == targetDeviceId &&
              d['revoked'] != true &&
              d['deviceId'] != profile?.deviceId,
        )) {
      throw const FormatException('请先选择同组目标设备');
    }
    _clipboardSubscription ??= SystemBridge.clipboardEvents.listen(
      _onClipboard,
    );
    await SystemBridge.watchClipboard(true);
    clipboardEnabled = true;
    clipboardTarget = targetDeviceId;
    _clipboardEnabledAt = DateTime.now().millisecondsSinceEpoch;
    clipboardStatus = '已开启';
    changed();
  }

  bool _sensitiveClipboard(String text) => RegExp(
    r'-----BEGIN .*PRIVATE KEY-----|(?:password|passwd|secret|token|api[_-]?key)\s*[:=]|验证码|一次性密码|recovery\s+code',
    caseSensitive: false,
  ).hasMatch(text);
  void _onClipboard(Map<String, dynamic> event) {
    if (!clipboardEnabled ||
        !connected ||
        event['private'] == true ||
        (event['marker'] as String? ?? '').isNotEmpty) {
      return;
    }
    final sequence = event['sequence'] as int? ?? -1;
    if (sequence == _clipboardSequence) return;
    _clipboardSequence = sequence;
    final value = event['text'] as String? ?? '';
    if (value.trim().isEmpty ||
        utf8.encode(value).length > 8192 ||
        _sensitiveClipboard(value)) {
      clipboardStatus = '已跳过此内容';
      changed();
      return;
    }
    _clipboardDebounce?.cancel();
    final elapsed = DateTime.now().millisecondsSinceEpoch - _lastClipboardSend;
    final epoch = generation, destination = clipboardTarget;
    _clipboardDebounce = Timer(
      Duration(milliseconds: max(350, 1000 - elapsed)),
      () async {
        if (!clipboardEnabled ||
            !connected ||
            epoch != generation ||
            destination != clipboardTarget) {
          return;
        }
        _lastClipboardSend = DateTime.now().millisecondsSinceEpoch;
        try {
          await api!.call('POST', '/texts', {
            'eventId': newId(),
            'targetDeviceId': destination,
            'text': value,
            'clipboard': <String, dynamic>{},
          });
          clipboardStatus = '已同步';
        } catch (_) {
          clipboardStatus = '同步失败';
        }
        changed();
      },
    );
  }

  Future<void> _applyRemoteClipboard(Map<String, dynamic> event) async {
    if (!Platform.isWindows ||
        !clipboardEnabled ||
        event['sourceDeviceId'] != clipboardTarget) {
      return;
    }
    final payload = event['payload'] as Map,
        clipboard = payload['clipboard'] as Map;
    final origin = clipboard['originDeviceId'] as String? ?? '',
        root = clipboard['sourceEventId'] as String? ?? '';
    final text = payload['text'] as String? ?? '';
    final created =
        DateTime.tryParse(event['createdAt'] ?? '')?.millisecondsSinceEpoch ??
        0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiry =
        DateTime.tryParse(event['expiresAt'] ?? '')?.millisecondsSinceEpoch ??
        0;
    final identity = '$origin/$root';
    if (origin == profile?.deviceId ||
        root.isEmpty ||
        created < _clipboardEnabledAt ||
        expiry <= now ||
        _clipboardRoots.containsKey(identity) ||
        _sensitiveClipboard(text) ||
        utf8.encode(text).length > 8192) {
      return;
    }
    _clipboardRoots[identity] = expiry;
    try {
      await SystemBridge.copy(
        text,
        originDeviceId: origin,
        sourceEventId: root,
        private: true,
      );
      clipboardStatus = '已同步';
    } catch (_) {
      clipboardStatus = '请从接收列表复制';
    }
  }

  Future<void> copyDockText(DockEntry item) => SystemBridge.copy(
    item.text,
    originDeviceId: item.originDeviceId.isEmpty
        ? item.source
        : item.originDeviceId,
    sourceEventId: item.sourceEventId.isEmpty ? item.id : item.sourceEventId,
    private: true,
  );
  void _pruneEphemeral() {
    final now = DateTime.now().millisecondsSinceEpoch, before = dock.length;
    unawaited(pruneSentReferences());
    if (!_cleaningSavedFiles && now >= _nextSavedFilesCleanup && root != null) {
      _nextSavedFilesCleanup = now + const Duration(minutes: 15).inMilliseconds;
      _cleaningSavedFiles = true;
      unawaited(
        refreshSavedFiles(cleanup: true)
            .catchError((Object error) {
              message = '文件清理失败：$error';
              changed();
            })
            .whenComplete(() => _cleaningSavedFiles = false),
      );
    }
    dock.removeWhere((d) => d.autoClipboard && d.expiresAtMillis <= now);
    _clipboardRoots.removeWhere((_, expiry) => expiry <= now);
    if (dock.length != before) changed();
  }

  void _stopClipboard() {
    clipboardEnabled = false;
    clipboardTarget = '';
    _clipboardDebounce?.cancel();
    _clipboardRoots.clear();
    dock.removeWhere((d) => d.autoClipboard);
    clipboardStatus = '已关闭';
    if (Platform.isWindows) {
      unawaited(SystemBridge.watchClipboard(false).catchError((Object _) {}));
    }
  }

  Future<void> signOutLocal() async {
    final p = profile;
    if (p == null) return;
    await save();
    _hasStoredSession = false;
    _connectRequest++;
    _restoreTimer?.cancel();
    generation++;
    stopConnections(clearNotifications: true);
    api = CenterApi(p.baseUrl);
    final epoch = generation, a = api!;
    p.deviceId = '';
    p.groupId = '';
    p.cursor = 0;
    dock = [];
    sources = {};
    pendingTexts = {};
    _hiddenDockIds.clear();
    devices = [];
    allowLegacyPeerIdentity = false;
    await vault.write(key: 'token_${p.storageKey}', value: '');
    _requireSession(epoch, a, p);
    await save();
    _requireSession(epoch, a, p);
    connection = '等待入组';
    message = '';
    changed();
  }

  Future<void> stageInputs(List<String> paths, List<String> texts) async {
    final epoch = generation;
    final prepared = <String>[];
    for (final path in paths) {
      final contentDirectory =
          ReceivedFileAccess.isContentUri(path) &&
          _directorySources.containsKey(path);
      if (contentDirectory ||
          await FileSystemEntity.type(path) == FileSystemEntityType.directory) {
        final entries = contentDirectory
            ? (await DockPlatform.directoryEntries(path))
                  .map(FolderEntry.fromMap)
                  .toList()
            : await readFolderEntries(path);
        if (entries.isEmpty) throw FileSystemException('文件夹已不存在', path);
        _directorySources[path] = path;
        stagedDirectoryNames[path] = entries.first.name;
        prepared.add(path);
      } else if (await ReceivedFileAccess.exists(path)) {
        prepared.add(path);
      } else {
        throw FileSystemException('文件已不存在', path);
      }
      if (epoch != generation || disposed) throw StateError('会话已切换，请重新添加内容');
    }
    for (final path in prepared) {
      if (!stagedFiles.contains(path)) stagedFiles.add(path);
    }
    for (final value in texts) {
      if (value.isNotEmpty &&
          value.length <= (info['limits']?['maxTextLength'] as int? ?? 100000))
        stagedTexts.add(value);
    }
    changed();
  }

  Future<void> stageDirectory(String path) async {
    if (ReceivedFileAccess.isContentUri(path)) _directorySources[path] = path;
    await stageInputs([path], []);
  }

  Future<void> chooseSendDirectory() async {
    if (Platform.isAndroid) {
      final selection = await DockPlatform.pickDirectory();
      if (selection != null) await stageDirectory(selection['source']!);
    } else {
      final path = await FilePicker.getDirectoryPath(dialogTitle: '选择文件夹');
      if (path != null) await stageDirectory(path);
    }
  }

  Future<void> _loadStagedOutbox({bool restoreQueue = false}) async {
    if (root == null) return;
    final file = File('${root!.path}/outbox.json');
    if (!await file.exists()) return;
    final value = jsonDecode(await file.readAsString()) as Map;
    _sharedBatchIds.addAll(List<String>.from(value['sharedBatchIds'] ?? []));
    _temporarySources.addAll(
      List<String>.from(value['temporarySources'] ?? []),
    );
    _directorySources.addAll(
      Map<String, String>.from(value['directorySources'] ?? {}),
    );
    stagedDirectoryNames.addAll(
      Map<String, String>.from(value['directoryNames'] ?? {}),
    );
    if (restoreQueue) {
      stagedFiles
        ..clear()
        ..addAll(List<String>.from(value['files'] ?? []));
      stagedTexts
        ..clear()
        ..addAll(List<String>.from(value['texts'] ?? []));
    }
  }

  Future<bool> stageSharedInputs(
    String batchId,
    List<String> paths,
    List<String> texts,
    List<String> temporaryPaths,
  ) async {
    final epoch = generation;
    if (!_sharedBatchIds.contains(batchId)) {
      _temporarySources.addAll(temporaryPaths);
      await stageInputs(
        paths.where((path) => !stagedFiles.contains(path)).toList(),
        texts.where((text) => !stagedTexts.contains(text)).toList(),
      );
      if (disposed || epoch != generation) return false;
      _sharedBatchIds.add(batchId);
      nativeSendNavigationSerial++;
    }
    try {
      await save();
    } catch (_) {
      _sharedBatchIds.remove(batchId);
      rethrow;
    }
    changed();
    // Confirmed queued content (not an editor's unconfirmed draft) has its own
    // installation-wide outbox, so sharing also survives before first enrollment.
    return root != null;
  }

  Future<void> stageClipboard() async {
    if (Platform.isAndroid) {
      await DockPlatform.importClipboard();
      return;
    }
    final state = root ?? await stateDirectory();
    final folder = Directory('${state.path}/outgoing-clipboard');
    await folder.create(recursive: true);
    final data = await SystemBridge.readClipboard(
      '${folder.path}/clipboard-${newId()}.bmp',
    );
    final paths = List<String>.from(data['paths'] ?? []);
    final texts = List<String>.from(data['texts'] ?? []);
    if (paths.isEmpty && texts.every((text) => text.isEmpty)) return;
    final generated = List<String>.from(data['temporaryPaths'] ?? []);
    _temporarySources.addAll(generated);
    try {
      await stageInputs(paths, texts);
    } catch (_) {
      for (final path in generated) {
        _temporarySources.remove(path);
        if (await File(path).exists()) await File(path).delete();
      }
      rethrow;
    }
  }

  Future<void> removeStagedFile(String path) async {
    stagedFiles.remove(path);
    stagedDirectoryNames.remove(path);
    await _releaseTemporarySource(path);
    changed();
  }

  Future<void> _releaseTemporarySource(String path) async {
    if (!_temporarySources.contains(path) ||
        _stagedInFlightPaths.contains(path) ||
        stagedFiles.contains(path) ||
        sources.containsValue(path)) {
      return;
    }
    if (historyDock.any(
      (entry) =>
          entry.kind == 'file' &&
          entry.sourceReference.isEmpty &&
          entry.localPath == path,
    ))
      return;
    _temporarySources.remove(path);
    _directorySources.remove(path);
    try {
      final exportedApps = root == null
          ? null
          : Directory('${root!.path}/exported-apps').absolute.path;
      if (exportedApps != null &&
          Directory(path).absolute.path
              .startsWith('$exportedApps${Platform.pathSeparator}') &&
          await Directory(path).exists()) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
    } on PathNotFoundException {
      // A provider or an external cleanup may already have removed the copy.
    }
  }

  /// References to sent originals are not library-owned copies. Remove a
  /// missing original from history without ever deleting the sender's file.
  Future<void> pruneSentReferences() async {
    if (_checkingSentReferences || disposed) return;
    final epoch = generation;
    _checkingSentReferences = true;
    var modified = false;
    try {
      for (final entry
          in dock
              .where(
                (item) =>
                    item.kind == 'file' &&
                    (item.outgoing ||
                        item.status == 'received' && item.localPath.isNotEmpty),
              )
              .toList()) {
        final path = entry.sourceReference.isNotEmpty
            ? entry.sourceReference
            : sources[entry.fileId] ?? entry.localPath;
        bool exists;
        try {
          exists =
              path.isEmpty ||
              (entry.sourceReference.isNotEmpty &&
                      !ReceivedFileAccess.isContentUri(path)
                  ? await Directory(path).exists()
                  : await ReceivedFileAccess.exists(path));
        } on PlatformException {
          // A revoked provider grant affects this reference, not the library.
          // Keep it for reauthorization and continue checking the other files.
          continue;
        } on FileSystemException {
          continue;
        }
        if (epoch != generation || disposed) return;
        if (!exists) {
          _hiddenDockIds.add(entry.id);
          if (profile != null)
            _localHistory?.remove('${profile!.key}:${entry.id}');
          final source = sources.remove(entry.fileId);
          dock.remove(entry);
          peer?.cancelFile(entry.fileId);
          await rtc?.cancelFile(entry.fileId);
          if (source != null) await _releaseTemporarySource(source);
          modified = true;
        } else if (entry.outgoing &&
            path.isNotEmpty &&
            !sources.containsKey(entry.fileId)) {
          entry.localPath = path;
        }
      }
      if (_savedFilesStore != null) {
        final missing = await _savedFilesStore!.prune(
          DateTime.now(),
          removeExpired: false,
        );
        if (missing.isNotEmpty) {
          _forgetSavedCopies(missing);
          modified = true;
        }
      }
      if (modified) {
        await save();
        changed();
      }
      for (final record
          in _localHistory?.records.values.toList() ?? <LocalHistoryRecord>[]) {
        final item = record.entry;
        if (item.kind != 'file') continue;
        final path = item.sourceReference.isNotEmpty
            ? item.sourceReference
            : item.localPath;
        if (path.isEmpty) continue;
        bool exists;
        try {
          exists =
              item.sourceReference.isNotEmpty &&
                  !ReceivedFileAccess.isContentUri(path)
              ? await Directory(path).exists()
              : await ReceivedFileAccess.exists(path);
        } on PlatformException {
          continue;
        } on FileSystemException {
          continue;
        }
        if (epoch != generation || disposed) return;
        if (!exists) {
          _localHistory!.remove(record.key);
          modified = true;
        }
      }
      if (modified) {
        await save();
        changed();
      }
      await _releaseCompletedFolderSources();
    } finally {
      _checkingSentReferences = false;
    }
  }

  Future<void> deleteDockEntry(DockEntry item) async {
    if (isLocalHistory(item)) {
      final record = _localHistory?.recordFor(item);
      if (record == null) return;
      if (!item.outgoing && item.kind == 'file') {
        final store = await _savedStore();
        final ids = savedFiles
            .where(
              (file) =>
                  file.profileKey == record.profileKey &&
                  file.transferId == item.transferId &&
                  file.fileId == item.fileId,
            )
            .map((file) => file.id);
        if (store != null) _forgetSavedCopies(await store.remove(ids.toList()));
      }
      _localHistory!.remove(record.key);
      await save();
      changed();
      return;
    }
    if (!dock.contains(item)) return;
    if (item.kind == 'file' &&
        ![
          'received',
          'sent',
          'canceled',
          'rejected',
          'expired',
        ].contains(item.status) &&
        api?.token.isNotEmpty == true) {
      try {
        await cancel(item);
      } catch (_) {
        // Local removal still closes transports and persists the hidden ID;
        // an unavailable center cannot make a dismissed card reappear.
      }
    }
    if (!item.outgoing && item.kind == 'file' && item.localPath.isNotEmpty) {
      final store = await _savedStore();
      if (store != null) {
        final registered = savedFiles
            .where(
              (file) =>
                  file.fileId == item.fileId &&
                  file.transferId == item.transferId &&
                  file.profileKey == profile?.key,
            )
            .map((file) => file.id)
            .toList();
        _forgetSavedCopies(await store.remove(registered));
      }
    }
    final source = sources.remove(item.fileId);
    _hiddenDockIds.add(item.id);
    if (profile != null) _localHistory?.remove('${profile!.key}:${item.id}');
    pendingTexts.remove(item.id);
    dock.remove(item);
    if (source != null) await _releaseTemporarySource(source);
    await save();
    changed();
  }

  Future<void> requeueDockEntry(DockEntry item) async {
    if (item.kind == 'text') {
      await stageInputs([], [item.text]);
    } else if (item.isDirectory || item.sourceReference.isNotEmpty) {
      await stageDirectory(
        item.sourceReference.isNotEmpty ? item.sourceReference : item.localPath,
      );
    } else {
      await stageInputs([item.localPath], []);
    }
  }

  Future<void> _releaseCompletedFolderSources() => _folderRelease ??=
      _releaseFolderSources().whenComplete(() => _folderRelease = null);

  Future<void> _releaseFolderSources() async {
    final epoch = generation;
    for (final path in _directorySources.keys.toList()) {
      if (stagedFiles.contains(path)) continue;
      final ids = sources.entries
          .where((entry) => entry.value == path)
          .map((entry) => entry.key)
          .toList();
      if (ids.isEmpty ||
          ids.any(
            (id) =>
                busyFiles.contains(id) ||
                !dock.any(
                  (entry) =>
                      entry.fileId == id &&
                      [
                        'received',
                        'canceled',
                        'rejected',
                        'expired',
                      ].contains(entry.status),
                ),
          )) {
        continue;
      }
      final original = _directorySources[path]!;
      for (final id in ids) {
        sources.remove(id);
        for (final entry in dock.where((entry) => entry.fileId == id)) {
          entry.sourceReference = original;
          entry.localPath = original;
        }
      }
      await _releaseTemporarySource(path);
      if (epoch != generation || disposed) return;
      await save();
      changed();
    }
  }

  Future<void> sendStaged(String target) async {
    await sendStagedToMany([target]);
  }

  Future<void> clearStaged() async {
    final files = stagedFiles.toList();
    stagedFiles.clear();
    stagedTexts.clear();
    stagedDirectoryNames.clear();
    stagedTargetStates.clear();
    _stagedTargetProgress.clear();
    _stagedBatchFiles = [];
    _stagedBatchTexts = [];
    for (final path in files) {
      await _releaseTemporarySource(path);
    }
    changed();
  }

  Future<void> sendStagedToMany(List<String> targets) async {
    await _receiveDirectoryMigration?.future;
    if (_sendingStaged) throw StateError('待发区正在发送');
    final epoch = generation, a = api!, p = profile!;
    final files = List<String>.from(stagedFiles);
    final texts = List<String>.from(stagedTexts);
    final recipients = targets.toSet().toList();
    if (recipients.isEmpty || (files.isEmpty && texts.isEmpty)) return;
    if (!listEquals(files, _stagedBatchFiles) ||
        !listEquals(texts, _stagedBatchTexts)) {
      _stagedBatchFiles = files;
      _stagedBatchTexts = texts;
      stagedTargetStates.clear();
      _stagedTargetProgress.clear();
    }
    _sendingStaged = true;
    _stagedInFlightPaths.addAll(files);
    for (final target in recipients) {
      if (stagedTargetStates[target] != 'sent') {
        stagedTargetStates[target] = 'queued';
      }
    }
    changed();
    Object? failure;
    try {
      _requireSession(epoch, a, p);
      for (final target in recipients) {
        if (stagedTargetStates[target] == 'sent') continue;
        stagedTargetStates[target] = 'sending';
        changed();
        try {
          var progress = _stagedTargetProgress[target] ?? 0;
          if (files.isNotEmpty && progress == 0) {
            await offer(target, files);
            _requireSession(epoch, a, p);
            _stagedTargetProgress[target] = progress = 1;
          }
          final fileStep = files.isEmpty ? 0 : 1;
          for (var index = progress - fileStep; index < texts.length; index++) {
            _requireSession(epoch, a, p);
            await sendText(target, texts[index]);
            _requireSession(epoch, a, p);
            _stagedTargetProgress[target] = fileStep + index + 1;
          }
          stagedTargetStates[target] = 'sent';
        } catch (error) {
          _requireSession(epoch, a, p);
          stagedTargetStates[target] = 'failed';
          failure ??= error;
        }
        changed();
      }
      if (failure == null &&
          stagedTargetStates.values.every((state) => state == 'sent')) {
        // Consume only the confirmed batch, not content added during sending.
        stagedFiles.removeWhere(files.contains);
        for (final value in texts) {
          stagedTexts.remove(value);
        }
        for (final path in files) {
          stagedDirectoryNames.remove(path);
        }
        _stagedBatchFiles = [];
        _stagedBatchTexts = [];
      }
    } finally {
      _stagedInFlightPaths.removeAll(files);
      _sendingStaged = false;
      for (final path in files) {
        await _releaseTemporarySource(path);
      }
      unawaited(_releaseCompletedFolderSources());
      changed();
    }
    if (failure != null) throw failure;
  }

  Future<void> handleNativeDockEvent(Map<String, dynamic> event) async {
    if (event['type'] == 'nativeDrag') {
      if (event['local'] == true) {
        nativeQueueDragActive = event['active'] == true;
        if (event['sessionActive'] is bool)
          nativeLocalDragActive = event['sessionActive'] == true;
        if (event['navigate'] == 'send') nativeSendNavigationSerial++;
      } else {
        nativeDragActive = event['active'] == true;
      }
      nativeImporting = event['importing'] == true;
      changed();
    } else if (event['type'] == 'nativeDrop') {
      final id = event['dropId'] as String? ?? '';
      if (id.isEmpty || !_nativeDropIds.add(id)) return;
      if (_nativeDropIds.length > 128) {
        _nativeDropIds.remove(_nativeDropIds.first);
      }
      try {
        _temporarySources.addAll(
          List<String>.from(event['temporaryPaths'] ?? []),
        );
        stagedDirectoryNames.addAll(
          Map<String, String>.from(event['directoryNames'] ?? {}),
        );
        _directorySources.addAll(
          Map<String, String>.from(event['directorySources'] ?? {}),
        );
        await stageInputs(
          List<String>.from(event['paths'] ?? []),
          List<String>.from(event['texts'] ?? []),
        );
        if (event['error'] != null) message = event['error'];
      } catch (e) {
        for (final path in List<String>.from(event['temporaryPaths'] ?? [])) {
          await _releaseTemporarySource(path);
        }
        message = '拖入内容暂未加入待发区：$e';
      }
      changed();
    } else if (event['type'] == 'dockState') {
      _adoptDockState(event);
    }
  }

  void _adoptDockState(Map<String, dynamic> value) {
    nativeDragActive = value['active'] == true;
    nativeImporting = value['importing'] == true;
    nativeQueueDragActive = value['queueActive'] == true;
    nativeLocalDragActive = value['localSessionActive'] == true;
    changed();
  }

  Future<void> refreshNativeDock() async {
    if (!Platform.isAndroid) return;
    await DockPlatform.configure(
      maxFileSize: info['limits']?['maxFileSize'] as int?,
    );
    _adoptDockState(await DockPlatform.status());
    for (final event in await DockPlatform.pending()) {
      await handleNativeDockEvent({'type': 'nativeDrop', ...event});
    }
  }

  Future<void> dragOut(DockEntry item, {String pointerKind = 'auto'}) async {
    if (Platform.isWindows) {
      await SystemBridge.dragOut(
        pointerKind: pointerKind,
        text: item.kind == 'text' ? item.text : null,
        paths: item.kind == 'file' && item.localPath.isNotEmpty
            ? [item.localPath]
            : null,
      );
    } else if (Platform.isAndroid) {
      await DockPlatform.startDrag(
        text: item.kind == 'text' ? item.text : null,
        path: item.kind == 'file' && item.localPath.isNotEmpty
            ? item.localPath
            : null,
        label: item.title,
      );
    }
  }

  void _requireSession(int epoch, CenterApi a, ServerProfile p) {
    TransferOperation.current?.check();
    if (disposed ||
        epoch != generation ||
        !identical(api, a.owner) ||
        !identical(profile, p)) {
      throw StateError('中心或分组已切换，旧操作已停止');
    }
  }

  void applyTextUpdate(Map<String, dynamic> event) {
    final payload = event['payload'] as Map;
    if (payload['contentId'] is String) {
      applyTextDocument(Map<String, dynamic>.from(payload), notify: true);
      return;
    }
    if (_isHiddenDockId(payload['sourceEventId'] as String) ||
        profile != null &&
            _localHistory?.hasLocalTextEdit(
                  profile!.key,
                  payload['sourceEventId'] as String,
                ) ==
                true)
      return;
    final item = dock
        .where(
          (entry) =>
              entry.kind == 'text' &&
              entry.id == payload['sourceEventId'] &&
              entry.source == event['sourceDeviceId'],
        )
        .firstOrNull;
    final cursor = event['cursor'] as int;
    if (item == null || cursor <= item.editCursor) return;
    final changedText =
        item.text != payload['text'] || item.editedAt != payload['editedAt'];
    item.text = payload['text'] as String;
    item.editedAt = payload['editedAt'] as String;
    item.editCursor = cursor;
    if (changedText) {
      _postReceivedNotice(item, '$cursor', text: item.text, updated: true);
    }
  }

  void applyTextDocument(Map<String, dynamic> document, {bool notify = false}) {
    final ids = Set<String>.from(document['sourceEventIds'] ?? []);
    final revision = document['revision'] as int;
    final contentId = document['contentId'] as String;
    final entries = {
      ...dock,
      ...?_localHistory?.records.values.map((record) => record.entry),
    };
    DockEntry? receipt;
    for (final entry in entries) {
      if (entry.kind != 'text' ||
          !(ids.contains(entry.id) || entry.contentId == contentId) ||
          revision < entry.contentRevision)
        continue;
      final edited = entry.text != document['text'];
      entry.contentId = contentId;
      entry.contentRevision = revision;
      entry.text = document['text'] as String;
      entry.editedAt = document['editedAt'] ?? '';
      if (edited && !entry.outgoing && !_isHiddenDockId(entry.id))
        receipt = entry;
    }
    if (notify && receipt != null)
      _postReceivedNotice(
        receipt,
        '$contentId:$revision',
        text: receipt.text,
        updated: true,
      );
  }

  Future<void> editSentText(DockEntry item, String text) async {
    if (!item.outgoing || item.kind != 'text') {
      throw StateError('只能编辑自己发送的文字');
    }
    if (text.trim().isEmpty) throw const FormatException('文字不能为空');
    if (isLocalHistory(item)) {
      item.text = text;
      item.editedAt = DateTime.now().toUtc().toIso8601String();
      _localHistory?.recordFor(item)?.localTextEdit = true;
      await save();
      changed();
      return;
    }
    final epoch = generation, a = api!, p = profile!;
    final result = await a.call('PATCH', '/texts/${item.id}', {'text': text});
    _requireSession(epoch, a, p);
    final event = Map<String, dynamic>.from(result['event']);
    _localHistory?.confirmRemoteTextEdit(p.key, item.id);
    if (event['type'] == 'text.updated') {
      applyTextUpdate(event);
    } else {
      item.text = event['payload']['text'];
      item.editedAt = event['payload']['editedAt'] ?? '';
    }
    await save();
    _requireSession(epoch, a, p);
    message = '修改已保存';
    changed();
  }

  Future<void> sendText(String target, String text) async {
    if (text.trim().isEmpty) return;
    final epoch = generation, a = api!, p = profile!;
    final key = sha256.convert(utf8.encode('$target\n$text')).toString();
    final eventId = pendingTexts.putIfAbsent(key, newId);
    await save();
    _requireSession(epoch, a, p);
    await a.call('POST', '/texts', {
      'eventId': eventId,
      'targetDeviceId': target,
      'text': text,
    });
    _requireSession(epoch, a, p);
    pendingTexts.remove(key);
    await save();
    _requireSession(epoch, a, p);
    await safeReconcile();
  }

  Future<void> offer(
    String target,
    List<String> paths, {
    String? routePreferenceOverride,
    Map<String, String>? displayNames,
  }) async {
    final epoch = generation, a = api!, p = profile!;
    final maxFileSize = info['limits']['maxFileSize'] as int;
    final routePreference = routePreferenceOverride ?? p.sendRoutePreference;
    if (routePreference != 'auto' &&
        info['features']?['routePreference'] != true) {
      throw StateError('此中心尚不支持发送路径约束，请升级中心或选择自动');
    }
    final files = <Map<String, dynamic>>[];
    final pending = <String, String>{};
    final entries = <FolderEntry>[];
    final roots = <String>{};
    for (final path in paths) {
      final directory =
          _directorySources.containsKey(path) ||
          await FileSystemEntity.type(path) == FileSystemEntityType.directory;
      if (directory) {
        if (info['features']?['folderTransfer'] != true)
          throw StateError('中心需要升级后才能直接传输文件夹');
        final values = ReceivedFileAccess.isContentUri(path)
            ? (await DockPlatform.directoryEntries(path))
                  .map(FolderEntry.fromMap)
                  .toList()
            : await readFolderEntries(path);
        final original = values.first.name;
        var rootName = original, suffix = 0;
        while (!roots.add(rootName)) rootName = '$original (${++suffix})';
        for (final value in values) {
          entries.add(
            FolderEntry(
              location: value.location,
              relativePath:
                  rootName + value.relativePath.substring(original.length),
              directory: value.directory,
            ),
          );
        }
      } else {
        entries.add(
          FolderEntry(location: path, relativePath: '', directory: false),
        );
      }
    }
    if (entries.length > 10000)
      throw const FormatException('待发送文件夹合计超过 10000 项，请拆分后发送');
    for (final entry in entries) {
      final path = entry.location, id = newId();
      if (entry.directory) {
        files.add({
          'fileId': id,
          'name': entry.name,
          'relativePath': entry.relativePath,
          'entryKind': 'directory',
          'size': 0,
          'mimeType': 'inode/directory',
          'sha256': sha256.convert(const <int>[]).toString(),
        });
        pending[id] = path;
        continue;
      }
      final source = await ReceivedFileAccess.open(path);
      try {
        final file = source.file;
        final size = await file.length();
        _requireSession(epoch, a, p);
        if (size > maxFileSize) throw const FormatException('文件超过中心限制');
        final hash = await sha256.bind(file.openRead()).first;
        _requireSession(epoch, a, p);
        files.add({
          'fileId': id,
          'name': entry.relativePath.isNotEmpty
              ? entry.name
              : displayNames?[path] ?? safeName(path),
          'size': size,
          'mimeType': 'application/octet-stream',
          'sha256': hash.toString(),
          if (entry.relativePath.isNotEmpty) 'relativePath': entry.relativePath,
          if (entry.relativePath.isNotEmpty) 'entryKind': 'file',
        });
        pending[id] = path;
      } finally {
        await source.close();
      }
    }
    _requireSession(epoch, a, p);
    final j = await a.call('POST', '/transfers', {
      'transferId': newId(),
      'targetDeviceId': target,
      'files': files,
      if (routePreference != 'auto') 'routePreference': routePreference,
    });
    _requireSession(epoch, a, p);
    sources.addAll(pending);
    updateTransfer(j['transfer']);
    await save();
    changed();
  }

  String fileRoute(DockEntry d) =>
      '/transfers/${d.transferId}/files/${d.fileId}';
  Future<void> accept(DockEntry item, bool yes) async {
    final ids = dock
        .where(
          (d) =>
              d.transferId == item.transferId &&
              (d.status == 'offered' || d.relayPendingBeforeAccept),
        )
        .map((d) => d.fileId)
        .toList();
    await acceptSelected(item, yes ? ids : <String>[]);
  }

  Future<void> setAutoReceive(bool value) async {
    profile!.autoReceive = value;
    await save();
    changed();
    if (value) await safeReconcile();
  }

  bool needsRelayConsent(DockEntry item) =>
      !item.relayConfirmed &&
      item.size > (profile?.relayConfirmMiB ?? 32) * 1024 * 1024;

  void markRelayPending(DockEntry item, {bool beforeAccept = false}) {
    if (item.locallyCanceled ||
        ['canceled', 'rejected', 'expired', 'received'].contains(item.status)) {
      return;
    }
    final firstNotice = !item.relayConfirmationPending;
    item.relayConfirmationPending = true;
    item.relayPendingBeforeAccept = beforeAccept;
    item.status = 'relayConsent';
    item.routeDetail = '需中继';
    item.error = '';
    if (firstNotice) {
      _postReceivedNotice(
        item,
        'relay-consent',
        fileName: '等待中继确认 · ${item.title}',
      );
    }
  }

  Future<void> approveReceive(DockEntry item, List<String> ids) async {
    final epoch = generation, a = api!, p = profile!;
    for (final entry in dock.where(
      (d) => d.transferId == item.transferId && ids.contains(d.fileId),
    )) {
      entry.relayConfirmed = true;
      entry.relayConfirmationPending = false;
      entry.relayPendingBeforeAccept = false;
    }
    await save();
    _requireSession(epoch, a, p);
    await acceptSelected(item, ids);
  }

  Future<void> approveRelay(DockEntry item) async {
    if (item.locallyCanceled) return;
    final epoch = generation, a = api!, p = profile!;
    item.relayConfirmed = true;
    item.relayConfirmationPending = false;
    item.relayPendingBeforeAccept = false;
    item.error = '';
    await save();
    _requireSession(epoch, a, p);
    final current = await a.call('GET', '/transfers/${item.transferId}');
    _requireSession(epoch, a, p);
    final remote = (current['transfer']['files'] as List).firstWhere(
      (f) => f['fileId'] == item.fileId,
    );
    if (['canceled', 'rejected', 'expired'].contains(remote['status'])) {
      item.status = remote['status'];
      changed();
      return;
    }
    if (['ready', 'received'].contains(remote['status'])) {
      await receive(item, routeOverride: 'relay');
      return;
    }
    await a.call('POST', '${fileRoute(item)}/relay', {});
    _requireSession(epoch, a, p);
    item.status = 'accepted';
    item.route = 'relay';
    item.routeDetail = '等待上传';
    await save();
    changed();
    await safeReconcile();
  }

  Future<void> setCellularAllowed(bool value) async {
    cellularUploads = value;
    profile!.cellularAllowed = value;
    try {
      if (!value) await rtc?.revokeCellular();
    } finally {
      await save();
      if (peer?.pushEnabled == true) await peer!.publish();
      changed();
    }
  }

  Future<void> setRelayConfirmMiB(int value) async {
    if (value < 1) throw const FormatException('请输入大于 0 的 MiB 数');
    profile!.relayConfirmMiB = value;
    await save();
    changed();
  }

  Future<void> setTransferConcurrency(int value) async {
    if (value < 1 || value > 16) throw const FormatException('并发数需为 1–16');
    profile!.transferConcurrency = value;
    _gate.limit = value;
    await save();
    changed();
  }

  Future<void> setRoutePreference(String mode, {required bool sending}) async {
    if (sending) {
      profile!.sendRoutePreference = mode;
    } else {
      profile!.receiveRoutePreference = mode;
    }
    await save();
    changed();
  }

  Future<void> resendWithRoute(DockEntry item, String mode) async {
    final epoch = generation, a = api!, p = profile!;
    final path = sources[item.fileId];
    if (path == null || item.targetDeviceId.isEmpty) {
      throw const FileSystemException('原文件或目标不可用，请重新选择发送');
    }
    if (mode != 'auto' && info['features']?['routePreference'] != true) {
      throw StateError('此中心尚不支持手动发送路径，请升级中心或选择自动');
    }
    final target = item.targetDeviceId;
    if (!['canceled', 'rejected', 'expired'].contains(item.status)) {
      peer?.cancelFile(item.fileId);
      await rtc?.cancelFile(item.fileId);
      await a.call('POST', '${fileRoute(item)}/cancel', {});
      _requireSession(epoch, a, p);
      item.status = 'canceled';
      await save();
      _requireSession(epoch, a, p);
    }
    // Route restrictions are immutable on an offer. A new single-file offer
    // changes only this item, preserving other files in the original batch.
    await offer(target, [path], routePreferenceOverride: mode);
  }

  Future<void> acceptSelected(
    DockEntry item,
    List<String> ids, {
    bool reconcileAfter = true,
  }) async {
    final epoch = generation, a = api!, p = profile!;
    final lock = '$epoch:${item.transferId}';
    if (!_acceptingTransfers.add(lock)) return;
    try {
      await _receiveDirectoryMigration?.future;
      if (info['features']?['folderReuse'] == true) {
        final selected = ids.toSet();
        final roots = dock
            .where(
              (entry) =>
                  !entry.outgoing &&
                  entry.transferId == item.transferId &&
                  entry.isDirectory &&
                  entry.relativePath.isNotEmpty &&
                  !entry.relativePath.contains('/') &&
                  selected.contains(entry.fileId),
            )
            .toList();
        for (final root in roots) {
          final members = dock
              .where(
                (entry) =>
                    !entry.outgoing &&
                    entry.transferId == item.transferId &&
                    (entry.relativePath == root.relativePath ||
                        entry.relativePath.startsWith('${root.relativePath}/')),
              )
              .toList();
          if (members.every(
            (entry) =>
                selected.contains(entry.fileId) &&
                !entry.locallyPaused &&
                !entry.locallyCanceled &&
                (entry.status == 'offered' || entry.relayPendingBeforeAccept),
          )) {
            await _reuseSavedFolder(root, members);
            _requireSession(epoch, a, p);
          }
        }
      }
      if (info['features']?['fileReuse'] == true) {
        for (final entry
            in dock
                .where(
                  (entry) =>
                      !entry.outgoing &&
                      entry.transferId == item.transferId &&
                      ids.contains(entry.fileId) &&
                      (entry.status == 'offered' ||
                          entry.relayPendingBeforeAccept),
                )
                .toList()) {
          await _reuseSavedFile(entry);
          _requireSession(epoch, a, p);
        }
      }
      if (dock.any(
        (entry) =>
            entry.transferId == item.transferId &&
            ids.contains(entry.fileId) &&
            (entry.locallyPaused || entry.locallyCanceled),
      ))
        return;
      await _acceptSelectedWork(item, ids, reconcileAfter: reconcileAfter);
    } finally {
      _acceptingTransfers.remove(lock);
    }
  }

  Future<bool> _reuseSavedFolder(
    DockEntry root,
    List<DockEntry> members,
  ) async {
    final epoch = generation, a = api!, owner = profile!;
    final store = await _savedStore();
    final matched = await store?.reusableFolder(members);
    _requireSession(epoch, a, owner);
    bool stopped() =>
        members.any((entry) => entry.locallyPaused || entry.locallyCanceled);
    if (matched == null || stopped()) return false;
    final previous = {
      for (final entry in members) entry.fileId: entry.localPath,
    };
    for (final entry in members) entry.localPath = matched[entry.fileId]!.path;
    await save(); // Recover a committed receipt even if the HTTP response is lost.
    _requireSession(epoch, a, owner);
    if (stopped()) return false;
    Map<String, dynamic> response;
    try {
      response = await a.call(
        'POST',
        '/transfers/${root.transferId}/folders/${root.fileId}/reuse',
        {
          'files': [
            for (final entry in members)
              {
                'fileId': entry.fileId,
                'sha256': entry.contentDigest,
                'size': entry.size,
              },
          ],
        },
      );
    } on ApiException catch (error) {
      if (error.response?['error']?['code'] != 'TRANSFER_STARTED') rethrow;
      for (final entry in members) entry.localPath = previous[entry.fileId]!;
      await save();
      return false;
    }
    _requireSession(epoch, a, owner);
    if (stopped()) return false;
    final receipt = {
      for (final value in response['files'] as List)
        value['fileId'] as String: value as Map,
    };
    final receivedAt = DateTime.parse(
      receipt[root.fileId]!['receivedAt'] as String,
    );
    final updated = await store!.refreshReusedFolder(
      matched,
      members,
      receivedAt,
    );
    final paths = <String>{};
    for (final entry in members) {
      final remote = receipt[entry.fileId]!;
      if (remote['status'] != 'received' || remote['reused'] != true)
        throw StateError('中心未确认完整目录复用');
      entry.localPath = updated[entry.fileId]?.path ?? entry.localPath;
      paths.add(ReceivedFileAccess.canonical(entry.localPath));
      entry.receivedAtMillis = receivedAt.millisecondsSinceEpoch;
      entry.status = 'received';
      entry.progress = 1;
      entry.receivedBytes = entry.size;
      entry.error = '';
      entry.route = 'direct';
      entry.routeDetail = '已保存';
      entry.relayConfirmationPending = false;
      entry.relayPendingBeforeAccept = false;
      _postReceivedNotice(entry, 'received', fileName: entry.title);
    }
    for (final entry in dock.where(
      (entry) =>
          !entry.outgoing &&
          entry.localPath.isNotEmpty &&
          paths.contains(ReceivedFileAccess.canonical(entry.localPath)),
    )) {
      entry.receivedAtMillis = receivedAt.millisecondsSinceEpoch;
    }
    await save();
    changed();
    return true;
  }

  Future<bool> _reuseSavedFile(DockEntry item) async {
    if (item.locallyCanceled || item.locallyPaused) return false;
    final epoch = generation, a = api!, owner = profile!;
    final store = await _savedStore();
    final saved = await store?.reusableFile(item);
    _requireSession(epoch, a, owner);
    if (saved == null || item.locallyCanceled || item.locallyPaused)
      return false;
    // Persist the binding before the receipt: if the process stops after the
    // server commits, startup still knows which existing local file it owns.
    final oldPath = item.localPath;
    item.localPath = saved.path;
    await save();
    _requireSession(epoch, a, owner);
    if (item.locallyCanceled || item.locallyPaused) return false;
    Map<String, dynamic> response;
    try {
      response = await a.call('POST', '${fileRoute(item)}/reuse', {
        'sha256': item.contentDigest,
        'size': item.size,
      });
    } on ApiException catch (error) {
      if (error.response?['error']?['code'] != 'TRANSFER_STARTED') rethrow;
      item.localPath = oldPath;
      await save();
      return false;
    }
    _requireSession(epoch, a, owner);
    if (item.locallyCanceled || item.locallyPaused) return false;
    final remote = response['file'] as Map;
    if (remote['status'] != 'received' || remote['reused'] != true) {
      throw StateError('中心未确认本地文件复用');
    }
    final receivedAt =
        DateTime.tryParse(remote['receivedAt'] ?? '') ?? DateTime.now();
    item.receivedAtMillis = receivedAt.millisecondsSinceEpoch;
    item.status = 'received';
    item.progress = 1;
    item.receivedBytes = item.size;
    item.error = '';
    item.route = 'direct';
    item.routeDetail = '已保存';
    item.relayConfirmationPending = false;
    item.relayPendingBeforeAccept = false;
    // Updating this one physical owner's timestamp extends retention without
    // creating aliases that could delete each other's file during cleanup.
    await _rememberSavedFile(
      item,
      owner,
      receivedAt: receivedAt,
      managedLocation: saved.managedLocation,
    );
    for (final entry in dock.where(
      (entry) =>
          !entry.outgoing &&
          entry.localPath.isNotEmpty &&
          ReceivedFileAccess.canonical(entry.localPath) == saved.path,
    )) {
      entry.receivedAtMillis = receivedAt.millisecondsSinceEpoch;
    }
    await save();
    changed();
    return true;
  }

  Future<void> _acceptSelectedWork(
    DockEntry item,
    List<String> ids, {
    required bool reconcileAfter,
  }) async {
    final epoch = generation, a = api!, p = profile!;
    if (p.receiveRoutePreference == 'relay') {
      for (final entry in dock.where(
        (d) =>
            d.transferId == item.transferId &&
            ids.contains(d.fileId) &&
            !d.relayConfirmationPending,
      )) {
        entry.relayConfirmed = true;
      }
    }
    if (dock.any(
      (d) =>
          d.transferId == item.transferId &&
          ids.contains(d.fileId) &&
          d.status != 'received' &&
          (d.offerRoutePreference == 'relay' ||
              info['features']?['direct'] != true && rtc == null) &&
          needsRelayConsent(d),
    )) {
      for (final entry in dock.where(
        (d) =>
            d.transferId == item.transferId &&
            (d.status == 'offered' || d.relayPendingBeforeAccept),
      )) {
        markRelayPending(entry, beforeAccept: true);
      }
      await save();
      changed();
      return;
    }
    if (!dock.any(
      (entry) =>
          entry.transferId == item.transferId && entry.status == 'offered',
    )) {
      if (reconcileAfter) await reconcile();
      return;
    }
    final result = await a.call(
      'POST',
      '/transfers/${item.transferId}/accept',
      {'fileIds': ids},
    );
    _requireSession(epoch, a, p);
    if (result['transfer'] != null) {
      updateTransfer(Map<String, dynamic>.from(result['transfer']));
    }
    if (reconcileAfter) await reconcile();
  }

  bool canControlTransfer(DockEntry item) =>
      item.kind == 'file' &&
      !isLocalHistory(item) &&
      ![
        'received',
        'sent',
        'canceled',
        'rejected',
        'expired',
      ].contains(item.status);

  void _stopFile(DockEntry item) {
    unawaited(_fileOperations[item.fileId]?.cancel());
    for (final waiter in _sourceGateWaits[item.fileId] ?? <Completer<void>>{}) {
      if (!waiter.isCompleted) waiter.complete();
    }
    peer?.cancelFile(item.fileId);
    unawaited(rtc?.cancelFile(item.fileId));
    routeTimers.remove(item.fileId)?.cancel();
    _pendingRtc.remove(item.fileId);
    _startedRtc.remove(item.fileId);
    _startedPushes.remove(item.fileId);
    final native = nativeOperations[item.fileId];
    if (native != null) unawaited(NetworkBridge.cancel(native));
  }

  Future<void> pause(DockEntry item) async {
    if (!canControlTransfer(item) || item.locallyPaused) return;
    item.locallyPaused = true;
    item.status = 'paused';
    _stopFile(item);
    changed();
    await save();
  }

  Future<void> cancel(DockEntry item) async {
    final owner = profile, center = api;
    item.status = 'canceled';
    item.locallyCanceled = true;
    item.locallyPaused = false;
    item.relayConfirmationPending = false;
    item.relayPendingBeforeAccept = false;
    _stopFile(item);
    changed();
    // Neither a slow center nor transport teardown delays the local action.
    if (center != null)
      unawaited(
        ConnectionWindow(const Duration(seconds: 3))
            .run(() => center.call('POST', '${fileRoute(item)}/cancel', {}))
            .catchError((Object _) => <String, dynamic>{}),
      );
    Future<void> finishLocalCancel() async {
      await _fileOperations[item.fileId]?.finished.future;
      try {
        if (owner != null &&
            !item.outgoing &&
            !busyFiles.contains(item.fileId)) {
          await _discardPartial(item, owner);
        }
      } finally {
        await save();
        if (!disposed) changed();
      }
    }

    if (_fileOperations.containsKey(item.fileId) ||
        busyFiles.contains(item.fileId)) {
      unawaited(finishLocalCancel());
    } else {
      await finishLocalCancel();
    }
    await save();
  }

  Future<File?> _defaultPartial(DockEntry item, ServerProfile owner) async {
    final location = item.partialPath;
    if (!location.endsWith('/${safeName(item.title)}.part') &&
        !location.endsWith('\\${safeName(item.title)}.part')) {
      return null;
    }
    final file = File(location);
    if (!await file.exists()) return null;
    final scope = Directory(
      '${(await documentsDirectory()).path}/GlobalSend/${owner.key}/${safeName(owner.deviceId)}/${safeName(item.fileId)}',
    );
    if (!await scope.exists()) return null;
    final root = await scope.resolveSymbolicLinks();
    return (await file.resolveSymbolicLinks()).startsWith(
          '$root${Platform.pathSeparator}',
        )
        ? file
        : null;
  }

  Future<void> _discardPartial(DockEntry item, ServerProfile owner) async {
    if (item.partialPath.isEmpty) return;
    if (await ReceiveDestination.isOwned(item.partialPath)) {
      await ReceiveDestination.delete(item.partialPath);
    } else {
      await (await _defaultPartial(item, owner))?.delete();
    }
    item.partialPath = '';
    item.receivedBytes = 0;
  }

  Future<void> retry(DockEntry item) async {
    if (item.locallyPaused) return resume(item);
    return _runFileOperation(item, () async {
      final epoch = generation,
          a = api!.forOperation(TransferOperation.current!),
          p = profile!;
      if (item.receiveFailure) {
        await a.call('POST', '${fileRoute(item)}/receive-retry', {});
        _requireSession(epoch, a, p);
        if (item.locallyCanceled || item.locallyPaused) return;
        item.receiveFailure = false;
        item.receiveFailureReported = false;
        _receiveErrorReports.removeWhere(
          (key) => key.startsWith('${item.id}:'),
        );
        item.error = '';
        await _restartFileWork(item);
        return;
      }
      if (item.outgoing) {
        final response = await a.call('GET', '/transfers/${item.transferId}');
        _requireSession(epoch, a, p);
        final transfer = Map<String, dynamic>.from(response['transfer']);
        final remote = (transfer['files'] as List).firstWhere(
          (f) => f['fileId'] == item.fileId,
        );
        if (remote['status'] == 'failed') {
          // Storage loss/hash failure already discarded invalid relay bytes.
          // Destination failures instead retain them and use receive-retry.
          await a.call(
            'POST',
            '${fileRoute(item)}/${remote['receiveFailure'] == true ? 'receive-retry' : 'retry'}',
            remote['receiveFailure'] == true
                ? <String, dynamic>{}
                : {'attemptId': newId()},
          );
          _requireSession(epoch, a, p);
          item.receiveFailure = false;
          item.receiveFailureReported = false;
          item.error = '';
          await _restartFileWork(item);
          return;
        }
        item.error = '';
        await _restartFileWork(item, transfer: transfer);
      } else {
        await _receiveFile(item);
      }
    });
  }

  Future<void> resume(DockEntry item) async {
    if (!item.locallyPaused || item.locallyCanceled) return;
    final previous = _fileOperations[item.fileId];
    await previous?.finished.future;
    if (item.locallyCanceled || !item.locallyPaused) return;
    item.locallyPaused = false;
    item.error = '';
    item.status = 'accepted';
    changed();
    await _restartFile(item);
  }

  Future<void> _restartFile(DockEntry item) =>
      _runFileOperation(item, () => _restartFileWork(item));

  Future<void> _restartFileWork(
    DockEntry item, {
    Map<String, dynamic>? transfer,
  }) async {
    final a = api!.forOperation(TransferOperation.current!),
        p = profile!,
        epoch = generation;
    try {
      final response = transfer == null
          ? await a.call('GET', '/transfers/${item.transferId}')
          : {'transfer': transfer};
      _requireSession(epoch, a, p);
      final currentTransfer = Map<String, dynamic>.from(response['transfer']);
      updateTransfer(currentTransfer);
      final remote = (currentTransfer['files'] as List).firstWhere(
        (f) => f['fileId'] == item.fileId,
      );
      if ([
        'received',
        'canceled',
        'expired',
        'rejected',
        'failed',
        'offered',
      ].contains(remote['status']))
        return;
      if (item.outgoing) {
        if (remote['transport'] == 'relay')
          await _uploadFile(item);
        else if (remote['directPush'] is Map &&
            remote['directPush']['state'] == 'waiting') {
          await _sendPushFile(
            item,
            item.targetDeviceId,
            Map<String, dynamic>.from(remote['directPush']),
          );
        } else if (remote['rtc'] is Map &&
            remote['rtc']['state'] == 'negotiating') {
          await _sendRtcFile(item, Map<String, dynamic>.from(remote['rtc']));
        }
      } else {
        await _receiveFile(item, preferDirect: remote['transport'] != 'relay');
      }
    } on TransferStopped {
      rethrow;
    } catch (error) {
      if (!item.locallyCanceled && !item.locallyPaused) {
        item.status = 'failed';
        item.error = '$error';
      }
    }
  }

  Future<void> _runFileOperation(
    DockEntry item,
    Future<void> Function() work,
  ) async {
    if (item.locallyCanceled || item.locallyPaused) return;
    final previous = _fileOperations[item.fileId];
    if (previous != null) return previous.finished.future;
    if (busyFiles.contains(item.fileId)) return;
    final operation = TransferOperation();
    _fileOperations[item.fileId] = operation;
    operation.onCancel(() async {
      peer?.cancelFile(item.fileId);
      final native = nativeOperations[item.fileId];
      await Future.wait<void>([
        if (rtc != null) rtc!.cancelFile(item.fileId),
        if (native != null) NetworkBridge.cancel(native),
      ]);
    });
    try {
      await operation.run(work);
    } on TransferStopped {
      /* Pause/cancel already owns the visible state. */
    } finally {
      await operation.dispose();
      if (identical(_fileOperations[item.fileId], operation)) {
        _fileOperations.remove(item.fileId);
        busyFiles.remove(item.fileId);
        _sendingPush.remove(item.fileId);
        _sendingRtc.remove(item.fileId);
      }
      if (item.locallyCanceled)
        item.status = 'canceled';
      else if (item.locallyPaused)
        item.status = 'paused';
      else if (item.receiveFailure)
        item.status = 'failed';
      if (!operation.finished.isCompleted) operation.finished.complete();
      if (!disposed) {
        await save();
        changed();
      }
    }
  }

  Future<void> upload(DockEntry item) =>
      _runFileOperation(item, () => _uploadFile(item));
  Future<void> _sendPush(
    DockEntry item,
    String target,
    Map<String, dynamic> attempt,
  ) => _runFileOperation(item, () => _sendPushFile(item, target, attempt));
  Future<void> _sendRtc(DockEntry item, Map<String, dynamic> attempt) =>
      _runFileOperation(item, () => _sendRtcFile(item, attempt));
  Future<void> receive(
    DockEntry item, {
    bool preferDirect = false,
    String? routeOverride,
  }) => _runFileOperation(
    item,
    () => _receiveFile(
      item,
      preferDirect: preferDirect,
      routeOverride: routeOverride,
    ),
  );

  Future<void> _uploadFile(DockEntry item) async {
    await _receiveDirectoryMigration?.future;
    if (!busyFiles.add(item.fileId)) return;
    final epoch = generation, a = api!.forOperation(TransferOperation.current!);
    await _gate.enter(stopped: TransferOperation.current?.stopped.future);
    if (TransferOperation.current?.isStopped == true) {
      _gate.leave();
      return;
    }
    try {
      if (epoch != generation ||
          disposed ||
          item.status == 'canceled' ||
          item.locallyPaused)
        return;
      final path = sources[item.fileId];
      if (path == null) throw const FileSystemException('原文件不可用，请重新选择发送');
      final j = await a.call('GET', '/transfers/${item.transferId}');
      TransferOperation.current?.check();
      final remote = (j['transfer']['files'] as List).firstWhere(
        (f) => f['fileId'] == item.fileId,
      );
      if (!['accepted', 'uploading'].contains(remote['status']) ||
          item.status == 'canceled' ||
          item.locallyPaused) {
        return;
      }
      var offset = remote['offset'] as int;
      final chunk = info['limits']['chunkSize'] as int;
      final source = await ReceivedFileAccess.open(path);
      try {
        final file = await source.file.open();
        try {
          await file.setPosition(offset);
          item.status = 'uploading';
          while (offset < item.size &&
              epoch == generation &&
              item.status != 'canceled' &&
              !item.locallyPaused) {
            final length = min(chunk, item.size - offset);
            if (Platform.isAndroid && cellularUploads) {
              TransferOperation.current?.check();
              final nativeId = newId();
              nativeOperations[item.fileId] = nativeId;
              try {
                await TransferOperation.current!.wait(
                  NetworkBridge.putFile(
                    a
                        .uri('${fileRoute(item)}/chunks?offset=$offset')
                        .toString(),
                    source.file.path,
                    cellular: true,
                    authorization: 'Bearer ${a.token}',
                    offset: offset,
                    length: length,
                    operationId: nativeId,
                  ),
                );
              } finally {
                if (nativeOperations[item.fileId] == nativeId)
                  nativeOperations.remove(item.fileId);
              }
            } else {
              final bytes = await file.read(length);
              if (bytes.length != length) {
                throw const FileSystemException('原文件已改变');
              }
              await a.upload('${fileRoute(item)}/chunks?offset=$offset', bytes);
            }
            TransferOperation.current?.check();
            offset += length;
            item.recordTransferBytes(offset);
            item.progress = offset / item.size;
            changed();
          }
          if (epoch == generation &&
              item.status != 'canceled' &&
              !item.locallyPaused) {
            await a.call('POST', '${fileRoute(item)}/complete', {});
            item.status = 'ready';
            item.progress = 1;
          }
        } finally {
          await file.close();
        }
      } finally {
        await source.close();
      }
    } catch (e) {
      if (epoch == generation &&
          item.status != 'canceled' &&
          TransferOperation.current?.isStopped != true &&
          !item.locallyPaused) {
        item.status = 'failed';
        item.error = '$e';
      }
    } finally {
      _gate.leave();
      busyFiles.remove(item.fileId);
      if (epoch == generation) {
        await save();
        changed();
      }
    }
  }

  Future<void> _sendPushFile(
    DockEntry item,
    String target,
    Map<String, dynamic> attempt,
  ) async {
    final attemptId = attempt['attemptId'] as String;
    if (busyFiles.contains(item.fileId) ||
        _startedPushes[item.fileId] == attemptId) {
      return;
    }
    final epoch = generation,
        a = api!.forOperation(TransferOperation.current!),
        p = profile!,
        service = peer;
    if (service == null || !service.pushEnabled) return;
    _startedPushes[item.fileId] = attemptId;
    busyFiles.add(item.fileId);
    _sendingPush[item.fileId] = attemptId;
    await _gate.enter(stopped: TransferOperation.current?.stopped.future);
    if (TransferOperation.current?.isStopped == true) {
      _gate.leave();
      return;
    }
    String? chosenCandidate, chosenSource;
    var chosenCellular = false;
    try {
      _requireSession(epoch, a, p);
      if (item.locallyCanceled) throw StateError('发送已取消');
      final grant = await a.call('POST', '${fileRoute(item)}/push-ticket', {
        'attemptId': attemptId,
      });
      _requireSession(epoch, a, p);
      final cellular = grant['cellular'] == true;
      chosenCellular = cellular;
      if (cellular && (!Platform.isAndroid || !cellularUploads)) {
        throw StateError('发送方未启用蜂窝传输');
      }
      final phase = grant['scope'] as String;
      final stages = await _addressStages(
        List<String>.from(grant['candidates']),
      );
      final addresses = reachability.prioritize(
        target,
        phase == 'lan' ? stages.lan : stages.public,
        phase == 'lan' ? ReachabilityScope.lan : ReachabilityScope.public,
        cellular: cellular,
      );
      if (addresses.isEmpty) throw StateError('接收方没有该网络的直连地址');
      final path = sources[item.fileId];
      if (path == null) throw const FileSystemException('发送源文件不可用');
      item.route = phase;
      item.routeDetail =
          '${phase == 'lan' ? '局域网' : '公网'}反向直传${cellular ? '（蜂窝）' : ''}';
      item.status = 'directSending';
      changed();
      final watch = Stopwatch()..start();
      var last = -150;
      void progress(int bytes) {
        _requireSession(epoch, a, p);
        if (item.locallyCanceled ||
            item.locallyPaused ||
            _sendingPush[item.fileId] != attemptId) {
          throw StateError('发送已取消');
        }
        if (bytes == item.size || watch.elapsedMilliseconds - last >= 150) {
          last = watch.elapsedMilliseconds;
          item.recordTransferBytes(bytes);
          item.progress = item.size == 0 ? 1 : bytes / item.size;
          changed();
        }
      }

      final checks = RouteProbes(
        cellular ? [] : addresses,
        cellular ? addresses : [],
        grant['certificateSha256'],
        const Duration(seconds: 1),
        routes: reachability.plannedRoutes(addresses, cellular: cellular),
        verified: reachability.verifiedRoutes(
          target,
          addresses,
          grant['certificateSha256'],
          cellular: cellular,
        ),
        onResult: reachability.captureReporter(target),
      );
      CandidateRoute? selected;
      try {
        selected = await checks.firstRoute(addresses, cellular: cellular);
      } finally {
        await checks.close();
      }
      if (selected == null) throw const SocketException('接收方候选地址不可达');
      chosenCandidate = selected.address;
      chosenSource = selected.sourceAddress;
      if (cellular) {
        final source = await ReceivedFileAccess.open(path);
        final operation = newId();
        nativeOperations[item.fileId] = operation;
        try {
          await NetworkBridge.uploadPeer(
            candidates: [selected.address],
            fingerprint: grant['certificateSha256'],
            ticket: grant['ticket'],
            transferId: item.transferId,
            fileId: item.fileId,
            attemptId: attemptId,
            path: source.file.path,
            offset: grant['offset'],
            expectedSize: item.size,
            operationId: operation,
            nonce: newId(),
            verifiedCandidate: selected.address,
            onProgress: progress,
          );
        } finally {
          nativeOperations.remove(item.fileId);
          await source.close();
        }
      } else {
        final candidate = selected.address;
        _requireSession(epoch, a, p);
        if (_startedPushes[item.fileId] != attemptId)
          throw StateError('反向连接尝试已替换');
        await service.push(
          candidate,
          grant,
          item.transferId,
          item.fileId,
          path,
          progress,
          sourceAddress: chosenSource,
        );
      }
      _requireSession(epoch, a, p);
      if (!item.locallyCanceled &&
          TransferOperation.current?.isStopped != true &&
          !item.locallyPaused &&
          item.status != 'received') {
        item.status = 'awaitingReceipt';
      }
    } catch (error) {
      if (chosenCandidate != null &&
          !item.locallyCanceled &&
          TransferOperation.current?.isStopped != true &&
          !item.locallyPaused) {
        reachability.markFailed(
          target,
          chosenCandidate,
          cellular: chosenCellular,
          sourceAddress: chosenSource,
        );
      }
      if (!disposed &&
          epoch == generation &&
          !item.locallyCanceled &&
          TransferOperation.current?.isStopped != true &&
          !item.locallyPaused) {
        if (_startedPushes[item.fileId] != attemptId) return;
        item.routeDetail = '反向直传未完成：$error';
        try {
          await a.call('POST', '${fileRoute(item)}/direct-push/fail', {
            'attemptId': attemptId,
            'error': '$error'.substring(0, min(512, '$error'.length)),
          });
        } catch (_) {
          /* Receiver still times out and owns the next path. */
        }
      }
    } finally {
      _gate.leave();
      if (!disposed && epoch == generation) {
        if (_sendingPush[item.fileId] == attemptId) {
          _sendingPush.remove(item.fileId);
        }
        busyFiles.remove(item.fileId);
        await save();
        changed();
        _resumePendingRtc(item, attemptId);
        unawaited(safeReconcile());
      }
    }
  }

  void _resumePendingRtc(DockEntry item, String completedAttempt) {
    if (item.locallyCanceled || item.locallyPaused) return;
    final active = _fileOperations[item.fileId];
    if (active != null) {
      unawaited(
        active.finished.future.then((_) {
          if (!disposed) _resumePendingRtc(item, completedAttempt);
        }),
      );
      return;
    }
    // The receiver may replace a failed route before its source has finished
    // closing. Consume that request now, not at the next 15-second sync.
    final pending = _pendingRtc[item.fileId];
    if (pending != null &&
        pending['attemptId'] != completedAttempt &&
        pending['state'] == 'negotiating' &&
        !item.locallyCanceled) {
      unawaited(_sendRtc(item, pending));
    }
  }

  String _rtcLabel(String fileId, String phase) {
    final scope = phase == 'lan'
        ? '局域网'
        : phase == 'public'
        ? '公网'
        : '直连';
    final network = _rtcNetwork[fileId];
    return '$scope WebRTC 直传${network == null ? '' : '（$network）'}';
  }

  Future<void> _sendRtcFile(
    DockEntry item,
    Map<String, dynamic> attempt,
  ) async {
    final attemptId = attempt['attemptId'] as String;
    final service = rtc;
    if (service == null ||
        busyFiles.contains(item.fileId) ||
        _startedRtc[item.fileId] == attemptId) {
      return;
    }
    final epoch = generation,
        a = api!.forOperation(TransferOperation.current!),
        p = profile!;
    _startedRtc[item.fileId] = attemptId;
    _sendingRtc[item.fileId] = attemptId;
    busyFiles.add(item.fileId);
    await _gate.enter(stopped: TransferOperation.current?.stopped.future);
    if (TransferOperation.current?.isStopped == true) {
      _gate.leave();
      return;
    }
    ReceivedFileAccess? source;
    try {
      _requireSession(epoch, a, p);
      final path = sources[item.fileId];
      if (path == null || item.locallyCanceled) throw StateError('发送源不可用');
      source = await ReceivedFileAccess.open(path);
      _requireSession(epoch, a, p);
      item.route = attempt['scope'];
      _rtcNetwork.remove(item.fileId);
      item.routeDetail = _rtcLabel(item.fileId, item.route);
      item.status = 'directSending';
      final watch = Stopwatch()..start();
      var last = -150;
      changed();
      await service.send(
        fileRoute: fileRoute(item),
        attempt: attempt,
        source: source.file,
        size: item.size,
        onProgress: (bytes) {
          _requireSession(epoch, a, p);
          if (item.locallyCanceled) throw StateError('发送已取消');
          if (bytes == item.size || watch.elapsedMilliseconds - last >= 150) {
            last = watch.elapsedMilliseconds;
            item.progress = item.size == 0 ? 1 : bytes / item.size;
            item.recordTransferBytes(bytes);
            changed();
          }
        },
      );
      _requireSession(epoch, a, p);
      if (!item.locallyCanceled &&
          TransferOperation.current?.isStopped != true &&
          !item.locallyPaused &&
          item.status != 'received') {
        item.status = 'awaitingReceipt';
      }
    } catch (error) {
      if (!disposed &&
          epoch == generation &&
          !item.locallyCanceled &&
          TransferOperation.current?.isStopped != true &&
          !item.locallyPaused) {
        item.routeDetail = 'WebRTC直传未完成：$error';
      }
    } finally {
      await source?.close();
      _gate.leave();
      if (!disposed && epoch == generation) {
        if (_sendingRtc[item.fileId] == attemptId) {
          _sendingRtc.remove(item.fileId);
        }
        busyFiles.remove(item.fileId);
        await save();
        changed();
        _resumePendingRtc(item, attemptId);
      }
    }
  }

  Future<_PreparedRoutes> _prepareRouteProbes(
    DockEntry item,
    String mode,
    bool allowCellular,
    RouteDeadline deadline,
  ) async {
    final device = devices
        .where((value) => value['deviceId'] == item.source)
        .firstOrNull;
    final rawPeer = device?['peer'];
    final peerLive =
        rawPeer is Map &&
        (DateTime.tryParse(rawPeer['expiresAt'] ?? '')
                ?.isAfter(DateTime.now()) ??
            true);
    final senderPeer = peerLive ? Map<String, dynamic>.from(rawPeer) : null;
    final sourceRtc = device?['rtc'] is Map
        ? Map<String, dynamic>.from(device!['rtc'])
        : null;
    final advertised = senderPeer == null
        ? <String>[]
        : List<String>.from(senderPeer['candidates'] ?? []);
    final scopes = [if (mode != 'public') 'lan', if (mode != 'lan') 'public'];
    // All of these are read-only handshakes. Do not open competing receive
    // slots or file grants while measuring forward, reverse and RTC paths.
    final reverseChecks = <String, Future<Map<String, dynamic>?>>{
      if (peer?.pushEnabled == true &&
          senderPeer?['push'] == true &&
          info['features']?['directPush'] == true &&
          reverseHttpsProbes != null)
        for (final scope in scopes)
          scope: reverseHttpsProbes!.check(
            item.source,
            scope,
            limit: deadline.remaining,
          ),
    };
    final rtcChecks = <String, Future<bool?>>{
      if (rtc != null && sourceRtc != null)
        for (final scope in scopes)
          if ((sourceRtc['scopes'] as List).contains(scope))
            scope: _waitRtcReadiness(item.source, scope, deadline.remaining),
    };
    if (rtcChecks.isNotEmpty &&
        rtcProbes?.active == true &&
        rtcProbes?.parallel == true) {
      // Legacy/background discovery eligibility is not a file prerequisite.
      unawaited(rtcProbes!.refreshNow(peerId: item.source));
    }
    final stages = await _addressStages(advertised);
    final probes = RouteProbes(
      deadline.expired
          ? []
          : [
              if (mode != 'public') ...stages.lan,
              if (mode != 'lan') ...stages.public,
            ],
      !deadline.expired && Platform.isAndroid && allowCellular && mode != 'lan'
          ? stages.public
          : [],
      senderPeer?['certificateSha256'] ?? '',
      deadline.remaining,
      routes: reachability.plannedRoutes(advertised, cellular: allowCellular),
      lanAddresses: stages.lan,
      verified: reachability.verifiedRoutes(
        item.source,
        advertised,
        senderPeer?['certificateSha256'] ?? '',
        cellular: allowCellular,
      ),
      onResult: reachability.captureReporter(item.source),
    );
    return (
      senderPeer: senderPeer,
      sourceRtc: sourceRtc,
      advertised: advertised,
      stages: stages,
      probes: probes,
      reverseChecks: reverseChecks,
      rtcChecks: rtcChecks,
    );
  }

  bool _rtcReady(String id, String phase) => reachability
      .forDevice(id)
      .any(
        (check) =>
            check.transport == 'rtc' &&
            check.reachable &&
            check.scope ==
                (phase == 'lan'
                    ? ReachabilityScope.lan
                    : ReachabilityScope.public),
      );

  Future<bool?> _waitRtcReadiness(
    String id,
    String phase,
    Duration limit,
  ) async {
    if (_rtcReady(id, phase)) return true;
    if (rtcProbes?.active != true || limit <= Duration.zero) return null;
    final result = Completer<bool?>();
    void changed() {
      if (!result.isCompleted && _rtcReady(id, phase)) result.complete(true);
    }

    reachability.addListener(changed);
    final timer = Timer(limit, () {
      if (!result.isCompleted) result.complete(null);
    });
    try {
      changed();
      return await result.future;
    } finally {
      timer.cancel();
      reachability.removeListener(changed);
    }
  }

  Future<void> _pullByStages(
    DockEntry item,
    File temporary,
    String hash,
    String mode,
    bool allowCellular,
    int epoch,
    CenterApi a,
    ServerProfile p,
    void Function(int) progress, {
    RouteDeadline? connectionDeadline,
    Future<_PreparedRoutes>? preparedRoutes,
  }) async {
    final failures = <String>[];
    final deadline = connectionDeadline ?? RouteDeadline();
    final phases = [if (mode != 'public') 'lan', if (mode != 'lan') 'public'];
    final plan =
        await (preparedRoutes ??
                _prepareRouteProbes(item, mode, allowCellular, deadline))
            .timeout(
              deadline.remaining > Duration.zero
                  ? deadline.remaining
                  : Duration.zero,
            );
    final senderPeer = plan.senderPeer, sourceRtc = plan.sourceRtc;
    final peerLive = senderPeer != null;
    final advertised = plan.advertised,
        advertisedStages = plan.stages,
        probes = plan.probes;
    Future<bool> attempt(String phase) async {
      if (mode == 'auto' &&
          phase == 'public' &&
          probes.readyRoute(advertisedStages.lan, cellular: false, lan: true) !=
              null)
        phase = 'lan';
      var cellular = false;
      var label = phase == 'lan' ? '局域网直连' : '公网直连';
      String? chosenCandidate, chosenSource;
      CandidateRoute? selected;
      try {
        final window = ConnectionWindow.current;
        _requireSession(epoch, a, p);
        if (item.status == 'canceled') throw StateError('传输已取消');
        item.routeDetail = '正在尝试$label';
        changed();
        // Each phase/Network receives a fresh one-use grant, even after a
        // previous endpoint consumed a ticket before its connection failed.
        final known = reachability.prioritize(
          item.source,
          phase == 'lan' ? advertisedStages.lan : advertisedStages.public,
          phase == 'lan' ? ReachabilityScope.lan : ReachabilityScope.public,
          cellular: cellular,
        );
        // Ask for the grant while unknown paths are still probing. Proven
        // paths return immediately; default/cellular compete in one public
        // stage instead of spending a timeout on each Network in succession.
        final results = await Future.wait<Object?>([
          probes.firstRoute(
            known,
            cellular: phase == 'lan' ? false : null,
            lan: phase == 'lan' ? true : null,
          ),
          a.call('POST', '${fileRoute(item)}/direct-ticket', {}),
        ]);
        selected = results[0] as CandidateRoute?;
        cellular = selected?.cellular ?? false;
        if (cellular) label = '公网直连（蜂窝）';
        final earlyCandidate = selected?.address;
        chosenCandidate = earlyCandidate;
        chosenSource = selected?.sourceAddress;
        window?.check();
        if (advertised.isNotEmpty && earlyCandidate == null)
          throw StateError('候选地址不可达');
        final grant = results[1] as Map<String, dynamic>;
        _requireSession(epoch, a, p);
        final stages = await _addressStages(
          List<String>.from(grant['candidates']),
        );
        window?.check();
        final candidates = reachability.prioritize(
          item.source,
          phase == 'lan' ? stages.lan : stages.public,
          phase == 'lan' ? ReachabilityScope.lan : ReachabilityScope.public,
          cellular: cellular,
        );
        if (candidates.isEmpty) {
          throw StateError('没有已发布的${phase == 'lan' ? '局域网' : '公网'}IP候选');
        }
        void scopedProgress(int bytes) {
          if (window?.canceled == true) return;
          if (window != null &&
              !window.established &&
              window.remaining <= Duration.zero)
            return;
          window?.connected();
          item.route = phase;
          item.routeDetail =
              '$label${failures.isEmpty ? '' : ' · ${failures.join('；')}'}';
          progress(bytes);
        }

        if (cellular) {
          final operation = newId();
          nativeOperations[item.fileId] = operation;
          Future<Map<String, dynamic>>? downloading;
          window?.onCancel(() async {
            await NetworkBridge.cancel(operation);
            try {
              await downloading;
            } catch (_) {
              /* Native file handles have closed. */
            }
          });
          try {
            downloading = NetworkBridge.downloadPeer(
              candidates:
                  earlyCandidate != null && candidates.contains(earlyCandidate)
                  ? [earlyCandidate]
                  : candidates,
              fingerprint: grant['certificateSha256'],
              ticket: grant['ticket'],
              transferId: item.transferId,
              fileId: item.fileId,
              path: temporary.path,
              operationId: operation,
              expectedSize: item.size,
              expectedSha256: hash,
              nonce: newId(),
              verifiedCandidate:
                  earlyCandidate != null &&
                      candidates.contains(earlyCandidate) &&
                      grant['certificateSha256'] ==
                          senderPeer?['certificateSha256']
                  ? earlyCandidate
                  : null,
              onProgress: scopedProgress,
            );
            await downloading;
            window?.check();
          } finally {
            nativeOperations.remove(item.fileId);
          }
        } else {
          final candidate =
              earlyCandidate != null &&
                  candidates.contains(earlyCandidate) &&
                  grant['certificateSha256'] == senderPeer?['certificateSha256']
              ? earlyCandidate
              : await PeerTransport.probeCandidates(
                  candidates,
                  grant['certificateSha256'],
                  newId(),
                  timeout: window?.remaining ?? const Duration(seconds: 1),
                  sourceAddresses: {
                    for (final address in candidates)
                      if (reachability.sourceFor(item.source, address) != null)
                        address: reachability.sourceFor(item.source, address)!,
                  },
                );
          chosenCandidate = candidate;
          chosenSource =
              (selected?.address == candidate
                  ? selected?.sourceAddress
                  : null) ??
              reachability.sourceFor(
                item.source,
                candidate,
                scope: phase == 'lan'
                    ? ReachabilityScope.lan
                    : ReachabilityScope.public,
              );
          window?.check();
          _requireSession(epoch, a, p);
          if (item.status == 'canceled') throw StateError('传输已取消');
          await PeerTransport.pull(
            candidate,
            grant['certificateSha256'],
            grant['ticket'],
            item.transferId,
            item.fileId,
            temporary,
            scopedProgress,
            expectedSha256: hash,
            expectedSize: item.size,
            sourceAddress: chosenSource,
          );
        }
        _requireSession(epoch, a, p);
        item.route = phase;
        item.routeDetail =
            '$label${failures.isEmpty ? '' : ' · ${failures.join('；')}'}';
        return true;
      } catch (error) {
        if (chosenCandidate != null) {
          if (selected != null) probes.discard(selected);
          reachability.markFailed(
            item.source,
            chosenCandidate,
            cellular: cellular,
            sourceAddress: chosenSource,
          );
        }
        if (ConnectionWindow.current?.canceled == true) rethrow;
        _requireSession(epoch, a, p);
        if (item.status == 'canceled') rethrow;
        failures.add('$label不可用：$error');
        if (selected != null && ConnectionWindow.current?.established != true) {
          // A stale cached pair can fail quickly. Other source pairs have
          // already been probing; try the next one within this same budget.
          return attempt(phase);
        }
        return false;
      }
    }

    Future<bool> reverse(String phase, bool cellular) async {
      final window = ConnectionWindow.current;
      final service = peer;
      if (info['features']?['directPush'] != true ||
          service?.pushEnabled != true ||
          senderPeer == null ||
          senderPeer['push'] != true ||
          cellular && senderPeer['cellularPush'] != true) {
        return false;
      }
      final label =
          '${phase == 'lan' ? '局域网' : '公网'}反向直传${cellular ? '（发送方蜂窝）' : ''}';
      final attemptId = newId();
      final offset = await temporary.exists() ? await temporary.length() : 0;
      final slot = await service!.prepareReceive(
        transferId: item.transferId,
        fileId: item.fileId,
        attemptId: attemptId,
        file: temporary,
        size: item.size,
        offset: offset,
        onProgress: (bytes) {
          if (window?.canceled == true) return;
          window?.connected();
          item.route = phase;
          item.routeDetail = label;
          progress(bytes);
        },
      );
      window?.onCancel(() => service.stopReceiving(slot));
      try {
        window?.check();
        _requireSession(epoch, a, p);
        if (item.locallyCanceled) throw StateError('接收已取消');
        item.routeDetail = '正在尝试$label';
        changed();
        await a.call('POST', '${fileRoute(item)}/direct-push', {
          'attemptId': attemptId,
          'scope': phase,
          'cellular': cellular,
          'offset': offset,
        });
        final waiting = Stopwatch()..start();
        while (!slot.finished) {
          _requireSession(epoch, a, p);
          if (item.locallyCanceled) throw StateError('接收已取消');
          if (!slot.started &&
              waiting.elapsed > Duration(seconds: cellular ? 25 : 12)) {
            throw TimeoutException('发送方未建立反向连接');
          }
          if (slot.started) {
            window?.connected();
            await slot.completed;
            break;
          }
          final state = await a.call('GET', '/transfers/${item.transferId}');
          final file = (state['transfer']['files'] as List).firstWhere(
            (f) => f['fileId'] == item.fileId,
          );
          final push = file['directPush'];
          if (slot.finished) break;
          if (push is! Map ||
              push['attemptId'] != attemptId ||
              push['state'] == 'failed') {
            throw StateError(
              push is Map ? push['error'] ?? '反向连接已结束' : '反向连接已结束',
            );
          }
          await Future.any([
            slot.completed,
            Future<void>.delayed(const Duration(milliseconds: 400)),
          ]);
        }
        final error = await slot.completed;
        if (error != null) throw StateError(error);
        _requireSession(epoch, a, p);
        item.route = phase;
        item.routeDetail = label;
        return true;
      } catch (error) {
        if (window?.canceled == true) rethrow;
        _requireSession(epoch, a, p);
        if (item.locallyCanceled) rethrow;
        failures.add('$label不可用：$error');
        return false;
      } finally {
        await service.stopReceiving(slot);
        cleanupConnection(() async {
          await a.call('POST', '${fileRoute(item)}/direct-push/stop', {
            'attemptId': attemptId,
          });
        });
      }
    }

    Future<bool> dataChannel(String phase) async {
      final service = rtc;
      final window = ConnectionWindow.current;
      if (service == null ||
          sourceRtc == null ||
          !(sourceRtc['scopes'] as List).contains(phase)) {
        return false;
      }
      final label = '${phase == 'lan' ? '局域网' : '公网'} WebRTC 直传';
      _rtcNetwork.remove(item.fileId);
      try {
        _requireSession(epoch, a, p);
        if (item.locallyCanceled) throw StateError('接收已取消');
        item.routeDetail = '正在尝试$label';
        changed();
        await service.receive(
          fileRoute: fileRoute(item),
          attemptId: newId(),
          scope: phase,
          destination: temporary,
          size: item.size,
          onProgress: (bytes) {
            if (window?.canceled == true) return;
            item.route = phase;
            item.routeDetail = _rtcLabel(item.fileId, phase);
            progress(bytes);
          },
        );
        window?.check();
        _requireSession(epoch, a, p);
        item.route = phase;
        item.routeDetail = _rtcLabel(item.fileId, phase);
        return true;
      } catch (error) {
        if (ConnectionWindow.current?.canceled == true) rethrow;
        _requireSession(epoch, a, p);
        if (item.locallyCanceled) rethrow;
        failures.add('$label不可用：$error');
        return false;
      }
    }

    final choices = <TransferRouteChoice>[];
    for (final phase in phases) {
      final scopeLabel = phase == 'lan' ? '局域网' : '公网';
      final preferRtc = reachability.preferRtc(
        item.source,
        phase == 'lan' ? ReachabilityScope.lan : ReachabilityScope.public,
      );
      final hasRtc =
          rtc != null &&
          sourceRtc != null &&
          (sourceRtc['scopes'] as List).contains(phase);
      final hasReverse =
          peer?.pushEnabled == true &&
          info['features']?['directPush'] == true &&
          senderPeer != null &&
          senderPeer['push'] == true;
      final addresses = phase == 'lan'
          ? advertisedStages.lan
          : advertisedStages.public;
      final forward = probes.readyRoute(
        addresses,
        cellular: phase == 'lan' ? false : null,
        lan: phase == 'lan' ? true : null,
      );
      Future<bool?> forwardReady() async =>
          (await probes.firstRoute(
            addresses,
            cellular: phase == 'lan' ? false : null,
            lan: phase == 'lan' ? true : null,
          )) !=
          null;
      int? measuredLatency(String transport) {
        final checks = reachability
            .forDevice(item.source)
            .where(
              (check) =>
                  check.transport == transport &&
                  check.reachable &&
                  check.scope ==
                      (phase == 'lan'
                          ? ReachabilityScope.lan
                          : ReachabilityScope.public),
            );
        return checks.isEmpty
            ? null
            : checks.map((check) => check.elapsedMs).reduce(min);
      }

      bool? reverseReady(Map<String, dynamic>? result, bool cellular) =>
          result == null || result['tested'] != true
          ? null
          : result['reachable'] != true
          ? false
          : (result['cellular'] == true) == cellular
          ? true
          : null;
      TransferRouteChoice rtcChoice() => TransferRouteChoice(
        phase: phase,
        label: '$scopeLabel WebRTC直传',
        run: () => dataChannel(phase),
        ready: _rtcReady(item.source, phase) ? true : null,
        readiness: plan.rtcChecks[phase],
        latency: () => measuredLatency('rtc'),
      );
      TransferRouteChoice reverseChoice(bool cellular) {
        var result = reverseHttpsProbes?.cached(item.source, phase);
        return TransferRouteChoice(
          phase: phase,
          label: '$scopeLabel${cellular ? '蜂窝' : ''}反向直传',
          run: () => reverse(phase, cellular),
          ready: reverseReady(result, cellular),
          readiness: plan.reverseChecks[phase]?.then((value) {
            result = value;
            return reverseReady(value, cellular);
          }),
          latency: () => result?['elapsedMs'] as int?,
        );
      }

      if (preferRtc && hasRtc) choices.add(rtcChoice());
      if ((phase == 'lan' ? advertisedStages.lan : advertisedStages.public)
              .isNotEmpty ||
          !peerLive && info['features']?['direct'] == true)
        choices.add(
          TransferRouteChoice(
            phase: phase,
            label: '$scopeLabel直连',
            run: () => attempt(phase),
            ready: forward != null ? true : null,
            // With no advertised peer, only the legacy file grant knows its
            // candidates. Keep that entry point usable without preflight.
            readiness: advertised.isEmpty ? null : forwardReady(),
            latency: () => measuredLatency('https'),
          ),
        );
      if (hasReverse) choices.add(reverseChoice(false));
      if (!preferRtc && hasRtc) choices.add(rtcChoice());
      // Cellular HTTPS is already raced with ordinary public source pairs.
      if (phase == 'public' && hasReverse && senderPeer['cellularPush'] == true)
        choices.add(reverseChoice(true));
    }
    final selection = TransferRouteSelection(choices);
    try {
      for (final phase in phases) {
        if (deadline.expired) break;
        final phaseWatch = Stopwatch()..start();
        final phaseLimit = deadline.scopeBudget(
          last: phase == 'public' || !choices.any((c) => c.phase == 'public'),
          verified: selection.readyIn(phase),
          nextVerified: selection.readyIn('public'),
        );
        while (!deadline.expired) {
          final remaining = phaseLimit - phaseWatch.elapsed;
          if (remaining <= Duration.zero) break;
          final wait = Duration(
            microseconds: (remaining.inMicroseconds * .35).floor(),
          );
          final choice = await selection.next(
            phase,
            wait > const Duration(milliseconds: 200)
                ? const Duration(milliseconds: 200)
                : wait,
          );
          if (choice == null) break;
          final budget = selection.attemptBudget(
            choice,
            phaseLimit - phaseWatch.elapsed,
          );
          choice.attempted = true;
          if (budget <= Duration.zero) break;
          try {
            // Exactly one file writer; cancellation/teardown completes before
            // any other ready transport is allowed to acquire its file grant.
            if (await ConnectionWindow(budget).run(choice.run)) return;
          } catch (error) {
            _requireSession(epoch, a, p);
            if (item.locallyCanceled) rethrow;
            failures.add('${choice.label}不可用：$error');
          }
        }
      }
    } finally {
      selection.close();
      await probes.close();
    }
    throw StateError(failures.join('；'));
  }

  void _reportReceiveFailure(DockEntry item) {
    final center = api;
    if (center == null || info['features']?['receiveErrorReporting'] != true)
      return;
    final message = item.error;
    if (!_receiveErrorReports.add('${item.id}:$message')) return;
    // This report must outlive the failed file operation's owned HTTP client.
    Zone.root.run(() {
      unawaited(
        ConnectionWindow(const Duration(seconds: 3))
            .run(
              () => center.call('POST', '${fileRoute(item)}/receive-error', {
                'message': message.length > 500
                    ? message.substring(0, 500)
                    : message,
              }),
            )
            .then((result) {
              if (item.receiveFailure &&
                  item.error == message &&
                  !item.locallyCanceled) {
                item.receiveFailureReported = true;
                unawaited(save());
              }
              return result;
            })
            .catchError((Object _) {
              _receiveErrorReports.remove('${item.id}:$message');
              return <String, dynamic>{};
            }),
      );
    });
  }

  Future<void> _receiveFile(
    DockEntry item, {
    bool preferDirect = false,
    String? routeOverride,
  }) async {
    if (item.locallyCanceled ||
        item.locallyPaused ||
        item.relayConfirmationPending)
      return;
    await _receiveDirectoryMigration?.future;
    if (!busyFiles.add(item.fileId)) return;
    final epoch = generation,
        a = api!.forOperation(TransferOperation.current!),
        p = profile!;
    if (routeOverride == 'relay' ||
        item.receiveRoutePreference.isEmpty &&
            p.receiveRoutePreference == 'relay') {
      item.relayConfirmed = true;
    }
    final mode = item.offerRoutePreference != 'auto'
        ? item.offerRoutePreference
        : routeOverride ??
              (item.receiveRoutePreference.isEmpty
                  ? p.receiveRoutePreference
                  : item.receiveRoutePreference);
    item.receiveRoutePreference = mode;
    final supportsDirect = info['features']?['direct'] == true || rtc != null;
    final allowCellular = cellularUploads;
    File? temporary;
    ReceiveFileHandle? destinationHandle;
    String managedTemporaryLocation = '';
    File? destination;
    var directAttempt = false;
    var preparingDestination = false;
    var discardPartial = false;
    await _gate.enter(stopped: TransferOperation.current?.stopped.future);
    if (TransferOperation.current?.isStopped == true) {
      _gate.leave();
      return;
    }
    final connectionDeadline = RouteDeadline();
    Future<_PreparedRoutes>? preparedRoutes;
    _PreparedRoutes? readyRoutes;
    var routesFinished = false;
    if (!item.isDirectory && mode != 'relay' && supportsDirect) {
      // Start discovered-address probes before the center metadata request,
      // local file checks and persistent writes, not after those round trips.
      preparedRoutes = _prepareRouteProbes(
        item,
        mode,
        allowCellular,
        connectionDeadline,
      );
      unawaited(
        preparedRoutes.then<void>(
          (value) {
            readyRoutes = value;
            if (routesFinished) unawaited(value.probes.close());
          },
          onError: (Object _, StackTrace __) {
            /* The route await reports this error if needed. */
          },
        ),
      );
    }
    try {
      if (epoch != generation ||
          disposed ||
          item.status == 'canceled' ||
          item.locallyPaused)
        return;
      item.error = '';
      final t = preparedRoutes == null
          ? await a.call('GET', '/transfers/${item.transferId}')
          : await ConnectionWindow(connectionDeadline.remaining)
                .run(() => a.call('GET', '/transfers/${item.transferId}'));
      _requireSession(epoch, a, p);
      final remote = (t['transfer']['files'] as List).firstWhere(
        (f) => f['fileId'] == item.fileId,
      );
      if (['canceled', 'rejected', 'expired'].contains(remote['status'])) {
        item.status = remote['status'];
        item.relayConfirmationPending = false;
        item.relayPendingBeforeAccept = false;
        return;
      }
      if (item.isDirectory) {
        preparingDestination = true;
        final store = await _savedStore();
        var base = store?.receiveDestinationLocation ?? '';
        if (base.isEmpty) {
          base = '${(await documentsDirectory()).path}/GlobalSend';
          await Directory(base).create(recursive: true);
        }
        item.localPath = await ReceiveDestination.folderDirectory(
          destinationLocation: base,
          transferKey: '${p.key}:${item.transferId}',
          relativePath: item.relativePath,
        );
        await save();
        await a.call('POST', '${fileRoute(item)}/received', {});
        item.status = 'received';
        item.progress = 1;
        await _rememberSavedFile(
          item,
          p,
          receivedAt: DateTime.now(),
          managedLocation: true,
        );
        return;
      }
      if (!supportsDirect && (mode == 'lan' || mode == 'public')) {
        throw StateError('直连不可用，无法满足手动路径');
      }
      if (item.localPath.isNotEmpty &&
          await ReceivedFileAccess.exists(item.localPath)) {
        final savedSource = await ReceivedFileAccess.open(item.localPath);
        try {
          final saved = savedSource.file;
          if (await saved.length() == item.size &&
              (await sha256.bind(saved.openRead()).first).toString() ==
                  remote['sha256']) {
            await a.call('POST', '${fileRoute(item)}/received', {
              'transport': ['lan', 'public', 'direct'].contains(item.route)
                  ? 'direct'
                  : 'relay',
            });
            item.status = 'received';
            item.progress = 1;
            await _rememberSavedFile(item, p);
            return;
          }
        } finally {
          await savedSource.close();
        }
      }
      item.localPath = '';
      preparingDestination = true;
      final store = await _savedStore();
      final resumeManaged =
          item.partialPath.isNotEmpty &&
          await ReceiveDestination.isOwned(item.partialPath) &&
          (await ReceiveDestination.stat(item.partialPath)).exists;
      var customDirectory = store?.receiveDestinationLocation ?? '';
      if (item.relativePath.isNotEmpty) {
        if (customDirectory.isEmpty) {
          customDirectory = '${(await documentsDirectory()).path}/GlobalSend';
          await Directory(customDirectory).create(recursive: true);
        }
        final parts = folderRelativePath(item.relativePath).split('/');
        customDirectory = await ReceiveDestination.folderDirectory(
          destinationLocation: customDirectory,
          transferKey: '${p.key}:${item.transferId}',
          relativePath: parts.take(parts.length - 1).join('/'),
        );
      }
      final defaultPartial = resumeManaged
          ? null
          : item.relativePath.isNotEmpty
          ? null
          : await _defaultPartial(item, p);
      if (resumeManaged ||
          customDirectory.isNotEmpty && defaultPartial == null) {
        destinationHandle = resumeManaged
            ? await ReceiveDestination.openHandle(
                item.partialPath,
                writable: true,
              )
            : await ReceiveDestination.create(
                destinationLocation: customDirectory,
                name: '${safeName(item.title)}.part',
              );
        managedTemporaryLocation = destinationHandle.location;
        temporary = File(destinationHandle.ioPath);
        item.partialPath = managedTemporaryLocation;
      } else {
        var dir = Directory(
          '${(await documentsDirectory()).path}/GlobalSend/${p.key}/${safeName(p.deviceId)}/${safeName(item.fileId)}',
        );
        _requireSession(epoch, a, p);
        await dir.create(recursive: true);
        destination = File('${dir.path}/${safeName(item.title)}');
        if (defaultPartial != null) {
          destination = File(
            defaultPartial.path.substring(0, defaultPartial.path.length - 5),
          );
        }
        if (await destination.exists()) {
          if (await destination.length() == item.size &&
              (await sha256.bind(destination.openRead()).first).toString() ==
                  remote['sha256']) {
            item.localPath = destination.path;
            await a.call('POST', '${fileRoute(item)}/received', {
              'transport':
                  remote['transport'] ??
                  (['lan', 'public', 'direct'].contains(item.route)
                      ? 'direct'
                      : 'relay'),
            });
            item.status = 'received';
            item.receivedBytes = item.size;
            await _rememberSavedFile(item, p);
            return;
          }
          dir = Directory('${dir.path}/attempt-${newId()}');
          await dir.create(recursive: true);
          destination = File('${dir.path}/${safeName(item.title)}');
        }
        temporary = File('${destination.path}.part');
        item.partialPath = temporary.path;
      }
      // Persist the canonical location before network I/O so a restarted client
      // can resume the same app-created partial in its chosen destination.
      await save();
      _requireSession(epoch, a, p);
      item.status = 'downloading';
      preparingDestination = false;
      changed();
      void progress(int n) {
        if (n > item.size) throw const FormatException('接收数据超过声明大小');
        if (epoch != generation ||
            item.status == 'canceled' ||
            item.locallyPaused) {
          throw const FileSystemException('接收已取消');
        }
        item.progress = item.size == 0 ? 1 : n / item.size;
        item.recordTransferBytes(n);
        item.receivedBytes = n;
        changed();
      }

      if ((mode == 'relay' || mode == 'auto' && !supportsDirect) &&
          ['accepted', 'uploading'].contains(remote['status'])) {
        if (needsRelayConsent(item)) {
          markRelayPending(item);
          return;
        }
        if (remote['transport'] != 'relay') {
          await a.call('POST', '${fileRoute(item)}/relay', {});
        }
        _requireSession(epoch, a, p);
        item.route = 'relay';
        item.routeDetail = mode == 'relay' ? '手动选择中继，等待发送方上传' : '直连不可用，使用中继';
        item.status = 'accepted';
        return;
      }
      if (mode != 'relay' &&
          (preferDirect || remote['transport'] != 'relay') &&
          ['accepted', 'uploading'].contains(remote['status'])) {
        directAttempt = true;
        item.route = 'direct';
        await _pullByStages(
          item,
          temporary,
          remote['sha256'],
          mode,
          allowCellular,
          epoch,
          a,
          p,
          progress,
          // Preflight overlaps metadata and disk preparation. Slow local IO
          // must not consume a proven path's actual connection budget.
          connectionDeadline: RouteDeadline(),
          preparedRoutes: preparedRoutes,
        );
      } else {
        if (mode == 'lan' || mode == 'public') {
          throw StateError('此文件已走中继，与手动直连约束不兼容；可重试或取消后重新发送');
        }
        if (needsRelayConsent(item)) {
          markRelayPending(item);
          return;
        }
        item.route = 'relay';
        if (mode == 'relay' || item.routeDetail.isEmpty) {
          item.routeDetail = mode == 'relay' ? '手动选择中继' : '当前使用中继';
        }
        final j = await a.call(
          'POST',
          '${fileRoute(item)}/download-ticket',
          {},
        );
        await a.download(
          j['downloadPath'],
          temporary,
          progress,
          expectedSha256: remote['sha256'],
          expectedSize: item.size,
        );
      }
      if (epoch != generation ||
          item.status == 'canceled' ||
          item.locallyPaused)
        return;
      if (await temporary.length() != item.size ||
          (await sha256.bind(temporary.openRead()).first).toString() !=
              remote['sha256']) {
        discardPartial = true;
        throw const FormatException('文件完整性校验失败');
      }
      if (destinationHandle != null) {
        await ReceiveDestination.closeHandle(destinationHandle.handle);
        destinationHandle = null;
        temporary = null;
        final completed = await ReceiveDestination.rename(
          managedTemporaryLocation,
          safeName(item.title),
        );
        item.localPath = completed.location;
      } else {
        await temporary.rename(destination!.path);
        item.localPath = destination.path;
        temporary = null;
      }
      item.partialPath = '';
      item.receivedBytes = item.size;
      await _rememberSavedFile(
        item,
        p,
        receivedAt: DateTime.now(),
        managedLocation: managedTemporaryLocation.isNotEmpty,
      );
      await a.call('POST', '${fileRoute(item)}/received', {
        if (directAttempt) 'transport': 'direct',
      });
      item.status = 'received';
      item.progress = 1;
    } catch (e) {
      if (epoch == generation &&
          item.status != 'canceled' &&
          TransferOperation.current?.isStopped != true &&
          !item.locallyPaused &&
          e is! TransferStopped) {
        final storageFailure =
            preparingDestination &&
            (e is FileSystemException || e is PlatformException);
        if (storageFailure) {
          item.status = 'failed';
          item.error = e is PlatformException ? (e.message ?? e.code) : '$e';
          item.receiveFailure = true;
          item.receiveFailureReported = false;
          changed();
          _reportReceiveFailure(item);
        } else if (directAttempt && mode == 'auto' && item.localPath.isEmpty) {
          if (needsRelayConsent(item)) {
            markRelayPending(item);
            return;
          }
          try {
            await a.call('POST', '${fileRoute(item)}/relay', {});
            item.status = 'accepted';
            item.route = 'relay';
            item.routeDetail = '局域网与公网直连不可用，已切换中继：$e';
          } catch (_) {
            item.status = 'failed';
            item.error = '$e';
          }
        } else {
          item.status = 'failed';
          item.error = '$e';
        }
      }
    } finally {
      routesFinished = true;
      if (readyRoutes != null) await readyRoutes!.probes.close();
      _gate.leave();
      if (destinationHandle != null) {
        try {
          if (temporary != null && await temporary.exists()) {
            item.receivedBytes = await temporary.length();
          }
        } finally {
          await ReceiveDestination.closeHandle(destinationHandle.handle);
          destinationHandle = null;
          temporary = null;
        }
      }
      if (managedTemporaryLocation.isNotEmpty && item.localPath.isEmpty) {
        if (discardPartial || item.status == 'canceled') {
          await ReceiveDestination.delete(managedTemporaryLocation);
          item.partialPath = '';
          item.receivedBytes = 0;
        } else {
          item.partialPath = managedTemporaryLocation;
        }
      }
      if (temporary != null && await temporary.exists()) {
        if (discardPartial || item.status == 'canceled') {
          await temporary.delete();
          item.partialPath = '';
          item.receivedBytes = 0;
        } else {
          item.receivedBytes = await temporary.length();
          item.partialPath = temporary.path;
        }
      }
      busyFiles.remove(item.fileId);
      if (epoch == generation) {
        await save();
        changed();
      }
    }
  }

  void stopConnections({
    bool preserveStaging = false,
    bool clearNotifications = false,
  }) {
    for (final operation in _fileOperations.values)
      unawaited(operation.cancel());
    for (final waiters in _sourceGateWaits.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
    _socketAttempt++;
    _deviceGraceTimer?.cancel();
    recentDevices.clear();
    _deviceRevision++;
    devices = [];
    sharedDocument.reset();
    latestReceipt = null;
    pendingReceipts.clear();
    nativeDismissedReceiptIds.clear();
    _receiptSequence.clear();
    _receiptVersions.clear();
    _notificationScope = '';
    if (clearNotifications) {
      unawaited(receivedNotifications.clear().catchError((Object _) {}));
    }
    _startTransportsOnConnect = false;
    if (!preserveStaging) {
      final removed = List<String>.from(stagedFiles);
      stagedFiles.clear();
      stagedTexts.clear();
      stagedTargetStates.clear();
      _stagedTargetProgress.clear();
      stagedDirectoryNames.clear();
      for (final path in removed) {
        unawaited(_releaseTemporarySource(path));
      }
    }
    _stopClipboard();
    busyFiles.clear();
    for (final operation in nativeOperations.values) {
      unawaited(NetworkBridge.cancel(operation));
    }
    nativeOperations.clear();
    _sendingPush.clear();
    _startedPushes.clear();
    _sendingRtc.clear();
    _startedRtc.clear();
    _pendingRtc.clear();
    _rtcNetwork.clear();
    for (final timer in routeTimers.values) {
      timer.cancel();
    }
    routeTimers.clear();
    peerHeartbeat?.cancel();
    rtcHeartbeat?.cancel();
    unawaited(rtcProbes?.close());
    rtcProbes = null;
    unawaited(reverseHttpsProbes?.close());
    reverseHttpsProbes = null;
    unawaited(rtc?.close());
    rtc = null;
    peer?.close();
    peer = null;
    reconnect?.cancel();
    poll?.cancel();
    socket?.close();
    socket = null;
    api?.close();
    connected = false;
    _updateReachability();
  }

  @override
  void dispose() {
    _restoreTimer?.cancel();
    _dockSubscription?.cancel();
    _clipboardSubscription?.cancel();
    _ephemeralCleanup?.cancel();
    disposed = true;
    generation++;
    stopConnections();
    receivedNotifications.dispose();
    backgroundReceive.dispose();
    reachability.dispose();
    appearance.dispose();
    updates.dispose();
    super.dispose();
  }
}
