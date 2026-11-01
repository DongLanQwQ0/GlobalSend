import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'github_updates.dart';
import 'update_download.dart';

class AppBuildInfo {
  const AppBuildInfo({
    required this.platform,
    required this.architecture,
    required this.version,
  });
  final UpdatePlatform? platform;
  final String architecture;
  final AppReleaseVersion? version;
  // Flutter generates these from the build's pubspec/--build-name/--build-number,
  // including release AOT builds. They are not a second hardcoded app version.
  factory AppBuildInfo.current() => AppBuildInfo(
    platform: Platform.isWindows
        ? UpdatePlatform.windows
        : Platform.isAndroid
        ? UpdatePlatform.android
        : Platform.isIOS
        ? UpdatePlatform.ios
        : null,
    architecture: switch (Abi.current()) {
      Abi.windowsArm64 => 'arm64',
      Abi.windowsX64 => 'x64',
      Abi.androidArm64 => 'arm64-v8a',
      Abi.androidArm => 'armeabi-v7a',
      Abi.androidX64 => 'x86_64',
      Abi.androidIA32 => 'x86',
      _ => '',
    },
    version: AppReleaseVersion.parse(
      const String.fromEnvironment('FLUTTER_BUILD_NAME'),
      build: int.tryParse(const String.fromEnvironment('FLUTTER_BUILD_NUMBER')),
    ),
  );
  String get label => version?.full ?? '版本未知';
}

typedef UpdateNotifier = Future<bool> Function(PlatformUpdate update);
typedef UpdateInstaller = Future<Map<String, dynamic>> Function(
  PlatformUpdate update,
  File package, {
  required bool explicit,
});
typedef UpdateReadyNotifier = Future<bool> Function(
  PlatformUpdate update,
  File package,
);

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    AppBuildInfo? build,
    UpdateFeed? feed,
    UpdateNotifier? notify,
    UpdateDownloader? downloader,
    UpdateInstaller? install,
    UpdateReadyNotifier? notifyReady,
    bool automaticDownload = true,
    DateTime Function()? now,
  }) : build = build ?? AppBuildInfo.current(),
       feed = feed ?? GitHubUpdateFeed(),
       _notify = notify ?? _nativeNotify,
       downloader = downloader ?? HttpUpdateDownloader(),
       _install = install ?? _nativeInstall,
       _notifyReady = notifyReady ?? _nativeReadyNotify,
       autoDownload = automaticDownload,
       now = now ?? DateTime.now;
  static const channel = MethodChannel('dev.globalsend/system');
  static const interval = Duration(hours: 6);
  final AppBuildInfo build;
  final UpdateFeed feed;
  final UpdateNotifier _notify;
  final UpdateDownloader downloader;
  final UpdateInstaller _install;
  final UpdateReadyNotifier _notifyReady;
  final DateTime Function() now;
  PlatformUpdate? available;
  bool busy = false, foreground = true, _disposed = false, _started = false;
  bool? notificationsAllowed;
  String error = '', _notified = '', _dismissed = '';
  DateTime? checkedAt, _attemptedAt;
  File? _file;
  Timer? _timer;
  Future<void>? _checking;
  Future<void> _writes = Future.value();
  bool autoCheck = true, autoDownload;
  bool downloading = false, installing = false;
  int downloadedBytes = 0, downloadBytes = 0;
  File? package;
  PlatformUpdate? _packageOffer;
  String _installedAttempt = '', _readyNotified = '';
  bool _permissionPending = false, _downloadExplicit = false;
  bool _waitingForForeground = false, _exitExplicit = false;
  bool _manualInstallRequested = false;
  Future<void>? _downloading, _installing;
  DateTime? _progressAt;
  bool Function()? canInstall;
  Future<void> Function()? beforeInstall;

  bool get supportsInstall =>
      build.platform == UpdatePlatform.android ||
      build.platform == UpdatePlatform.windows;
  bool get installable =>
      available != null &&
      supportsInstall &&
      (build.platform == UpdatePlatform.android ||
          available!.assetName.toLowerCase().endsWith('.zip'));
  bool get ready =>
      package != null &&
      _packageOffer?.notificationKey == available?.notificationKey;
  double? get progress =>
      downloadBytes > 0 ? downloadedBytes / downloadBytes : null;
  String get actionLabel => downloading
      ? '下载中…'
      : installing
      ? '更新中…'
      : error.isNotEmpty
      ? ready
            ? '重试安装'
            : '重试下载'
      : ready
      ? '安装更新'
      : '下载更新';

  bool get showBanner =>
      available != null && _dismissed != available!.notificationKey;
  String get status => error.isNotEmpty
      ? error
      : downloading
      ? '正在下载 ${(100 * (progress ?? 0)).floor()}%'
      : installing
      ? '正在准备更新…'
      : ready && _permissionPending
      ? '请允许安装本应用，然后返回继续'
      : ready && _waitingForForeground
      ? '新版已下载，返回应用继续安装'
      : ready &&
            _installedAttempt == available?.notificationKey &&
            build.platform == UpdatePlatform.android
      ? '安装程序已打开，请在系统中确认'
      : ready
      ? !autoDownload
            ? '新版已下载，可手动安装'
            : build.platform == UpdatePlatform.windows && foreground
            ? '新版已下载，转入后台后自动更新'
            : '新版已下载，等待空闲安装'
      : busy
      ? '正在检查…'
      : error.isNotEmpty
      ? error
      : available != null
      ? '发现 ${available!.version.display}'
      : checkedAt == null
      ? build.label
      : '${build.label} · 已是最新';
  static Future<bool> _nativeNotify(PlatformUpdate update) async =>
      await channel.invokeMethod<bool>('notifyUpdate', update.toJson()) == true;
  String _failureMessage(Object failure) => switch (failure) {
    PlatformException error => error.message ?? '系统无法完成更新',
    HttpException error => error.message,
    SocketException _ => '网络连接中断',
    FileSystemException error => error.message,
    _ => failure.toString(),
  };
  static Future<bool> _nativeReadyNotify(
    PlatformUpdate update,
    File package,
  ) async =>
      await channel.invokeMethod<bool>('notifyUpdate', {
        ...update.toJson(),
        'ready': true,
        'path': package.path,
      }) ==
      true;
  static Future<Map<String, dynamic>> _nativeInstall(
    PlatformUpdate update,
    File package, {
    required bool explicit,
  }) async => Map<String, dynamic>.from(
    await channel.invokeMethod<Map>('installUpdate', {
          'path': package.path,
          'version': update.version.name,
          'build': update.version.build,
          'assetName': update.assetName,
          'explicit': explicit,
        }) ??
        const {'state': 'ready'},
  );

  File? _packageFile(PlatformUpdate offer) {
    final file = _file;
    if (file == null) return null;
    final name = offer.assetName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return File(
      '${file.parent.path}/updates/${offer.platform.name}-${offer.version.full}-$name',
    );
  }

  Future<void> initialize(File file) async {
    if (_started || _disposed) return;
    _started = true;
    _file = file;
    // This advisory cache must not become a prerequisite for opening the app
    // or recovering the user's identity/history.
    try {
      if (await file.exists()) {
        final value = jsonDecode(await file.readAsString());
        if (value is Map) {
          _notified = value['notified'] is String ? value['notified'] : '';
          _dismissed = value['dismissed'] is String ? value['dismissed'] : '';
          autoCheck = value['autoCheck'] != false;
          autoDownload = value['autoDownload'] is bool
              ? value['autoDownload'] as bool
              : autoDownload;
          _installedAttempt = value['installedAttempt'] as String? ?? '';
          _permissionPending = value['permissionPending'] == true;
          _waitingForForeground = value['waitingForForeground'] == true;
          _manualInstallRequested = value['manualInstallRequested'] == true;
          final saved = value['package'];
          if (saved is Map &&
              build.version != null &&
              saved['platform'] == build.platform?.name &&
              saved['asset'] is String &&
              saved['downloadUrl'] is String &&
              saved['releaseUrl'] is String &&
              saved['size'] is int) {
            final version = AppReleaseVersion.parse(
              saved['version'] as String? ?? '',
              build: saved['build'] as int?,
            );
            if (version != null) {
              final offer = PlatformUpdate(
                platform: build.platform!,
                version: version,
                assetName: saved['asset'] as String,
                downloadUrl: saved['downloadUrl'] as String,
                releaseUrl: saved['releaseUrl'] as String,
                size: saved['size'] as int,
              );
              final local = _packageFile(offer)!;
              if (version.compareTo(build.version!) > 0 &&
                  await local.exists() &&
                  await local.length() == offer.size) {
                package = local;
                _packageOffer = offer;
                available = offer;
              } else if (version.compareTo(build.version!) <= 0 &&
                  await local.exists()) {
                await local.delete();
                _installedAttempt = '';
                _permissionPending = false;
              }
            }
          }
        }
      }
    } on FormatException {
      /* Old/incomplete cache: check normally. */
    } on FileSystemException {
      /* Updates remain usable without this cache. */
    }
    if (_disposed) return;
    await _readWindowsResult();
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
    if (build.platform == UpdatePlatform.ios)
      unawaited(refreshNotificationPermission());
    unawaited(check());
    unawaited(_processAvailable());
    if (_permissionPending || _waitingForForeground || _manualInstallRequested)
      unawaited(_tryInstall(resumed: true));
  }

  void setForeground(bool value) {
    final resumed = value && !foreground;
    final changed = value != foreground;
    foreground = value;
    if (changed && !_disposed) notifyListeners();
    if (resumed && _started) {
      unawaited(check());
      unawaited(_readWindowsResult());
    }
    unawaited(_tryInstall(resumed: resumed));
  }

  Future<void> check({bool manual = false}) {
    if (_disposed) return Future.value();
    if (!manual && !autoCheck) return Future.value();
    if (_checking != null) return _checking!;
    if (build.platform == null || build.version == null) {
      if (manual) {
        error = '无法读取当前版本';
        notifyListeners();
      }
      return Future.value();
    }
    if (!manual &&
        _attemptedAt != null &&
        now().difference(_attemptedAt!) < interval)
      return Future.value();
    final work = _check(manual);
    _checking = work;
    return work.whenComplete(() {
      if (identical(_checking, work)) _checking = null;
    });
  }

  Future<void> _check(bool manual) async {
    busy = true;
    error = '';
    _attemptedAt = now();
    notifyListeners();
    unawaited(_save());
    try {
      final releases = await feed.releases();
      final offer = await selectPlatformUpdate(
        releases: releases,
        platform: build.platform!,
        installed: build.version!,
        architecture: build.architecture,
        loadManifest: feed.manifest,
      );
      if (_disposed) return;
      available = offer ?? (ready ? _packageOffer : null);
      checkedAt = now();
      if (manual) _dismissed = '';
      notifyListeners();
      if (!foreground &&
          offer != null &&
          offer.notificationKey != _notified &&
          !(autoDownload && installable)) {
        try {
          if (await _notify(offer) && !_disposed)
            _notified = offer.notificationKey;
        } on PlatformException {
          /* The visible in-app offer remains available. */
        } on MissingPluginException {
          /* Unsupported development host. */
        }
      }
      await _save();
    } catch (_) {
      if (!_disposed && manual) error = '暂时无法检查更新，请稍后重试';
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
    if (!_disposed && (manual || autoCheck)) unawaited(_processAvailable());
  }

  Future<void> setAutoCheck(bool value) async {
    autoCheck = value;
    notifyListeners();
    await _save();
    if (value) unawaited(check());
  }

  Future<void> setAutoDownload(bool value) async {
    autoDownload = value;
    if (!value && !_downloadExplicit) downloader.cancel();
    notifyListeners();
    await _save();
    if (value) unawaited(_processAvailable());
  }

  /// Called by real transfer state changes, not a polling timer.
  void activityChanged() {
    if (!_disposed) unawaited(_tryInstall());
  }

  void installDeferred() {
    _installedAttempt = '';
    unawaited(_save());
    if (!_disposed) notifyListeners();
  }

  Future<bool> prepareExit() async {
    if (_disposed || canInstall?.call() == false) return false;
    if (!_exitExplicit && (!autoDownload || foreground)) return false;
    await beforeInstall?.call();
    return !_disposed &&
        canInstall?.call() != false &&
        (_exitExplicit || autoDownload && !foreground);
  }

  Future<void> _processAvailable() async {
    if (_disposed || !autoDownload || !installable || _file == null) return;
    if (!ready)
      await downloadAndInstall();
    else
      await _tryInstall();
  }

  Future<void> downloadAndInstall({bool explicit = false}) {
    if (_disposed || !installable || _file == null) return Future.value();
    if (explicit) {
      _manualInstallRequested = true;
      unawaited(_save());
    }
    if (ready) return _tryInstall(explicit: explicit);
    if (_downloading != null) return _downloading!;
    final offer = available!, destination = _packageFile(available!)!;
    _downloadExplicit = explicit;
    final work = _download(offer, destination, explicit);
    _downloading = work;
    return work.whenComplete(() {
      if (identical(_downloading, work)) _downloading = null;
      if (!_disposed && available?.notificationKey != offer.notificationKey)
        unawaited(_processAvailable());
    });
  }

  Future<void> redownload() async {
    if (_disposed || downloading || installing || !installable) return;
    final old = package ?? _packageFile(available!);
    package = null;
    _packageOffer = null;
    _installedAttempt = '';
    _permissionPending = _waitingForForeground = false;
    if (old != null) {
      if (await old.exists()) await old.delete();
      final partial = File('${old.path}.part');
      if (await partial.exists()) await partial.delete();
    }
    await _save();
    await downloadAndInstall(explicit: true);
  }

  Future<void> _download(
    PlatformUpdate offer,
    File destination,
    bool explicit,
  ) async {
    downloading = true;
    error = '';
    downloadedBytes = 0;
    downloadBytes = offer.size;
    notifyListeners();
    try {
      final result = await downloader.download(offer, destination, (
        received,
        total,
      ) {
        if (_disposed) return;
        downloadedBytes = received;
        downloadBytes = total;
        final stamp = now();
        if (received == total ||
            _progressAt == null ||
            stamp.difference(_progressAt!) >=
                const Duration(milliseconds: 120)) {
          _progressAt = stamp;
          notifyListeners();
        }
      });
      if (_disposed || available?.notificationKey != offer.notificationKey)
        return;
      final previous = package;
      package = result;
      _packageOffer = offer;
      if (previous != null &&
          previous.path != result.path &&
          await previous.exists())
        await previous.delete();
      _installedAttempt = '';
      _permissionPending = false;
      await _save();
      if (!foreground && _readyNotified != offer.notificationKey) {
        try {
          if (await _notifyReady(offer, result))
            _readyNotified = offer.notificationKey;
        } on PlatformException {
          /* A ready package remains in the app. */
        } on MissingPluginException {
          /* Development host. */
        }
      }
    } on UpdateDownloadCanceled {
      /* Turning automatic updates off keeps the partial. */
    } catch (failure) {
      if (!_disposed) error = '更新下载失败：${_failureMessage(failure)}';
    } finally {
      downloading = false;
      if (!_disposed) notifyListeners();
    }
    if (!_disposed && ready && (autoDownload || explicit))
      await _tryInstall(explicit: explicit);
  }

  Future<void> _tryInstall({bool explicit = false, bool resumed = false}) {
    if (_disposed ||
        !ready ||
        !installable ||
        _installing != null ||
        downloading)
      return _installing ?? Future.value();
    if ((_permissionPending || _waitingForForeground) && !resumed && !explicit)
      return Future.value();
    final requested = explicit || _manualInstallRequested;
    if (!requested &&
        (!autoDownload ||
            build.platform == UpdatePlatform.windows && foreground ||
            build.platform == UpdatePlatform.android && !foreground ||
            _installedAttempt == available!.notificationKey &&
                !_permissionPending &&
                !_waitingForForeground))
      return Future.value();
    if (canInstall?.call() == false) return Future.value();
    final work = _apply(requested);
    _installing = work;
    return work.whenComplete(() {
      if (identical(_installing, work)) _installing = null;
    });
  }

  Future<void> _apply(bool explicit) async {
    final offer = available!, local = package!;
    installing = true;
    error = '';
    notifyListeners();
    try {
      if (canInstall?.call() == false) return;
      await beforeInstall?.call();
      if (_disposed || canInstall?.call() == false) return;
      if (!explicit &&
          (!autoDownload ||
              build.platform == UpdatePlatform.windows && foreground ||
              build.platform == UpdatePlatform.android && !foreground))
        return;
      _exitExplicit = explicit;
      _waitingForForeground = false;
      _installedAttempt = offer.notificationKey;
      await _save();
      final result = await _install(offer, local, explicit: explicit);
      _permissionPending = result['state'] == 'permission-required';
      _waitingForForeground =
          result['state'] == 'ready' &&
          build.platform == UpdatePlatform.android;
      if (result['state'] == 'started' || result['state'] == 'failed')
        _manualInstallRequested = false;
      // Installation refusal/cancellation remains visible for an explicit retry;
      // don't reopen the installer for every unrelated device/transfer event.
      if (result['state'] == 'failed')
        error = result['message'] as String? ?? '更新失败，请重试';
      await _save();
    } catch (failure) {
      _manualInstallRequested = false;
      _permissionPending = false;
      if (!_disposed) error = '无法安装更新：${_failureMessage(failure)}';
      await _save();
    } finally {
      installing = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _readWindowsResult() async {
    if (build.platform != UpdatePlatform.windows || _file == null) return;
    final receipt = File(
      '${_file!.parent.path}/updates/windows-update-result.json',
    );
    if (!await receipt.exists()) return;
    try {
      final value = jsonDecode(await receipt.readAsString()) as Map;
      if (value['state'] == 'ready' &&
          value['version'] == _packageOffer?.version.name &&
          value['build'] == _packageOffer?.version.build) {
        _installedAttempt = '';
      }
      if ((value['state'] == 'failed' || value['state'] == 'rolled-back') &&
          value['version'] == _packageOffer?.version.name &&
          value['build'] == _packageOffer?.version.build) {
        error = value['message'] as String? ?? '更新未完成，可重试';
        if (!_disposed) notifyListeners();
      }
    } on FormatException {
      /* A helper may still be writing its next state. */
    } on FileSystemException {
      /* Check the receipt again when the app resumes. */
    }
  }

  void presented() {
    final offer = available;
    if (_disposed || offer == null || _notified == offer.notificationKey)
      return;
    _notified = offer.notificationKey;
    unawaited(_save());
  }

  void dismiss() {
    _dismissed = available?.notificationKey ?? '';
    notifyListeners();
    unawaited(_save());
  }

  Future<void> requestNotificationPermission() async {
    if (build.platform == UpdatePlatform.ios) {
      notificationsAllowed = await channel.invokeMethod<bool>(
        'updateNotificationPermission',
        {'explicit': true},
      );
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> refreshNotificationPermission() async {
    try {
      notificationsAllowed = await channel.invokeMethod<bool>(
        'updateNotificationPermission',
        {'explicit': false},
      );
    } on PlatformException {
      notificationsAllowed = false;
    } on MissingPluginException {
      notificationsAllowed = false;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _save() {
    final file = _file;
    if (file == null || _disposed) return Future.value();
    final data = jsonEncode({
      'attemptedAt': _attemptedAt?.toIso8601String(),
      'notified': _notified,
      'dismissed': _dismissed,
      'autoCheck': autoCheck,
      'autoDownload': autoDownload,
      'installedAttempt': _installedAttempt,
      'permissionPending': _permissionPending,
      'waitingForForeground': _waitingForForeground,
      'manualInstallRequested': _manualInstallRequested,
      if (_packageOffer != null) 'package': _packageOffer!.toJson(),
    });
    return _writes = _writes
        .catchError((Object _) {})
        .then((_) => file.writeAsString(data, flush: true))
        .then((_) {})
        .catchError(
          (Object _) {},
        ); // A failed cache save must not block reception.
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    feed.close();
    downloader.cancel();
    super.dispose();
  }
}
