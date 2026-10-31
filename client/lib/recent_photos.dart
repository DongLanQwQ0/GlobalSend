import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'directories.dart';

class SuggestedPhoto {
  const SuggestedPhoto(this.id, this.thumbnail);
  final String id;
  final Uint8List thumbnail;
}

abstract class RecentPhotoLibrary {
  Future<bool> permission({required bool request});
  Future<List<SuggestedPhoto>> readSince(DateTime since, Set<String> handled);
  Future<String?> filePath(String id);
}

class DevicePhotoLibrary implements RecentPhotoLibrary {
  static const permissionOption = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: false,
    ),
  );

  @override
  Future<bool> permission({required bool request}) async {
    final state = request
        ? await PhotoManager.requestPermissionExtend(
            requestOption: permissionOption,
          )
        : await PhotoManager.getPermissionState(
            requestOption: permissionOption,
          );
    return state.hasAccess;
  }

  @override
  Future<List<SuggestedPhoto>> readSince(
    DateTime since,
    Set<String> handled,
  ) async {
    final assets = await PhotoManager.getAssetListPaged(
      page: 0,
      pageCount: 24,
      type: RequestType.common,
      filterOption: FilterOptionGroup(
        createTimeCond: DateTimeCond(min: since, max: DateTime.now()),
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    final suggestions = <SuggestedPhoto>[];
    for (final asset in assets) {
      if (handled.contains(asset.id) || !await asset.isLocallyAvailable()) {
        continue;
      }
      final thumbnail = await asset.thumbnailDataWithSize(
        const ThumbnailSize(180, 180),
      );
      if (thumbnail != null) {
        suggestions.add(SuggestedPhoto(asset.id, thumbnail));
      }
      if (suggestions.length == 6) break;
    }
    return suggestions;
  }

  @override
  Future<String?> filePath(String id) async {
    final asset = await AssetEntity.fromId(id);
    return (await asset?.file)?.path;
  }
}

/// Per-installation suggestions, independent of group changes and transfer
/// history. Full-size photo access happens only when the user adds an item.
class RecentPhotos extends ChangeNotifier {
  RecentPhotos({
    RecentPhotoLibrary? library,
    Future<Directory> Function()? directory,
    bool? supported,
    DateTime Function()? now,
    this.suggestionDuration = const Duration(seconds: 30),
    this.suggestInApp = true,
  }) : library = library ?? DevicePhotoLibrary(),
       directory = directory ?? appDataDirectory,
       supported = supported ?? (Platform.isAndroid || Platform.isIOS),
       now = now ?? DateTime.now;

  final RecentPhotoLibrary library;
  final Future<Directory> Function() directory;
  final bool supported;
  final DateTime Function() now;
  final Duration suggestionDuration;
  final bool suggestInApp;
  bool enabled = true, permissionGranted = false;
  String? problem;
  List<SuggestedPhoto> items = [];
  final Set<String> _handled = {};
  bool _asked = false, _visible = false, _disposed = false;
  bool _busy = false, _again = false;
  DateTime? _since;
  Future<void>? _loaded;
  Timer? _timer;
  Timer? _suggestionTimer;
  bool _suggestedThisRun = false;
  Future<void> _writes = Future.value();

  @visibleForTesting
  Future<void> get pendingWrites => _writes;

  Future<void> openSettings() => PhotoManager.openSetting();

  void setVisible(bool visible) {
    if (!supported || _disposed || _visible == visible) return;
    _visible = visible;
    _timer?.cancel();
    if (visible) {
      unawaited(refresh());
      _timer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (enabled) unawaited(refresh());
      });
    }
  }

  Future<File> _stateFile() async =>
      File('${(await directory()).path}/recent-photo-suggestions.json');

  Future<void> _load() async {
    final file = await _stateFile();
    if (await file.exists()) {
      final state = jsonDecode(await file.readAsString()) as Map;
      enabled = state['enabled'] as bool;
      _asked = state['asked'] as bool;
      if (!suggestInApp && (state['mediaPermissionVersion'] as int? ?? 1) < 2) {
        _asked = false; // Upgrade the old image-only permission request once.
      }
      _since = DateTime.parse(state['since'] as String);
      _handled.addAll((state['handled'] as List).cast<String>());
    } else {
      _since = now().subtract(const Duration(minutes: 10));
    }
  }

  Future<void> _save() {
    final contents = jsonEncode({
      'enabled': enabled,
      'asked': _asked,
      'mediaPermissionVersion': 2,
      'since': _since!.toIso8601String(),
      'handled': _handled.toList(),
    });
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      final file = await _stateFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(contents, flush: true);
    });
  }

  Future<void> setEnabled(bool value) async {
    await (_loaded ??= _load());
    enabled = value;
    if (!value) {
      items = [];
      problem = null;
    }
    await _save();
    _changed();
    if (value && _visible) await refresh();
  }

  Future<void> refresh() async {
    if (!supported || !_visible || _disposed || _suggestedThisRun) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      await (_loaded ??= _load());
      if (!enabled || !_visible || _disposed || _suggestedThisRun) return;
      final request = !_asked;
      if (request) {
        await _save();
        if (!enabled || !_visible || _disposed) return;
        _asked = true;
      }
      permissionGranted = await library.permission(request: request);
      if (request) await _save();
      if (!permissionGranted) {
        items = [];
        problem = '未获得照片访问权限';
        return;
      }
      // Android's persistent native dock owns discovery and presentation. Keep
      // this object for the existing switch/permission flow, without consuming
      // new media IDs or showing a competing main-page prompt.
      if (!suggestInApp) {
        items = [];
        problem = null;
        return;
      }
      if (!enabled || !_visible || _disposed) return;
      final oldest = now().subtract(const Duration(days: 1));
      final since = _since!.isAfter(oldest) ? _since! : oldest;
      final found = await library.readSince(since, Set.of(_handled));
      if (_visible && enabled && !_disposed) {
        items = found.where((item) => !_handled.contains(item.id)).toList();
        problem = null;
        if (items.isNotEmpty) {
          _suggestedThisRun = true;
          _handled.addAll(items.map((item) => item.id));
          while (_handled.length > 256) {
            _handled.remove(_handled.first);
          }
          _since = now();
          _suggestionTimer = Timer(suggestionDuration, () {
            items = [];
            _changed();
          });
          await _save();
        }
      }
    } catch (_) {
      problem = '暂时无法检查新图片';
    } finally {
      _busy = false;
      _changed();
      if (_again) {
        _again = false;
        unawaited(refresh());
      }
    }
  }

  Future<void> dismiss(Iterable<String> ids) async {
    final dismissed = ids.toSet();
    _handled.addAll(dismissed);
    while (_handled.length > 256) {
      _handled.remove(_handled.first);
    }
    items.removeWhere((item) => dismissed.contains(item.id));
    _changed();
    await _save();
  }

  Future<void> add(String id, Future<void> Function(String) stage) async {
    final path = await library.filePath(id);
    if (path == null) {
      await dismiss([id]);
      return;
    }
    // This can be the original gallery file. Never register it as a temporary
    // transfer file, or remove it when clearing the pending-send list.
    await stage(path);
    await dismiss([id]);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _suggestionTimer?.cancel();
    super.dispose();
  }
}
