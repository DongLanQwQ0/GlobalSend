import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'github_updates.dart';

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

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    AppBuildInfo? build,
    UpdateFeed? feed,
    UpdateNotifier? notify,
    DateTime Function()? now,
  }) : build = build ?? AppBuildInfo.current(),
       feed = feed ?? GitHubUpdateFeed(),
       _notify = notify ?? _nativeNotify,
       now = now ?? DateTime.now;
  static const channel = MethodChannel('dev.globalsend/system');
  static const interval = Duration(hours: 6);
  final AppBuildInfo build;
  final UpdateFeed feed;
  final UpdateNotifier _notify;
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

  bool get showBanner =>
      available != null && _dismissed != available!.notificationKey;
  String get status => busy
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
        }
      }
    } on FormatException {
      /* Old/incomplete cache: check normally. */
    } on FileSystemException {
      /* Updates remain usable without this cache. */
    }
    if (_disposed) return;
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
    if (build.platform == UpdatePlatform.ios)
      unawaited(refreshNotificationPermission());
    unawaited(check());
  }

  void setForeground(bool value) {
    final resumed = value && !foreground;
    final changed = value != foreground;
    foreground = value;
    if (changed && !_disposed) notifyListeners();
    if (resumed && _started) unawaited(check());
  }

  Future<void> check({bool manual = false}) {
    if (_disposed) return Future.value();
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
      available = offer;
      checkedAt = now();
      if (manual) _dismissed = '';
      notifyListeners();
      if (!foreground && offer != null && offer.notificationKey != _notified) {
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
    super.dispose();
  }
}
