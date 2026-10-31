import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';

import 'directories.dart';
import 'dock_platform.dart';

class SuggestedPhoto {
  const SuggestedPhoto(
    this.id,
    this.thumbnail, {
    this.path,
    this.name = '',
    this.suggestedAt = 0,
  });
  final String id;
  final Uint8List thumbnail;
  final String? path;
  final String name;
  final int suggestedAt;
}

abstract class RecentPhotoFeed {
  Stream<void> get changes;
  Future<List<SuggestedPhoto>> read();
  Future<void> setActive(bool active);
  Future<void> setShowing(Set<String> ids, {bool interacting = false});
  Future<void> dismiss(Iterable<String> ids);
  Future<void> drag(String id);
}

/// Android's sending page and floating shelf observe the same native candidates.
class AndroidRecentPhotoFeed implements RecentPhotoFeed {
  @override
  Stream<void> get changes => DockPlatform.events
      .where((event) => event['type'] == 'mediaSuggestionsChanged')
      .map((_) {});
  @override
  Future<List<SuggestedPhoto>> read() async =>
      (await DockPlatform.channel.invokeListMethod<Map>('mediaSuggestions') ??
              [])
          .map(
            (item) => SuggestedPhoto(
              item['id'] as String,
              item['thumbnail'] as Uint8List,
              path: item['path'] as String,
              name: item['name'] as String,
              suggestedAt: item['suggestedAt'] as int? ?? 0,
            ),
          )
          .toList();
  @override
  Future<void> setActive(bool active) =>
      DockPlatform.channel.invokeMethod('mainMediaActive', {'active': active});
  @override
  Future<void> setShowing(Set<String> ids, {bool interacting = false}) =>
      DockPlatform.channel.invokeMethod('mainMediaShowing', {
        'ids': ids.toList(),
        'interacting': interacting,
      });
  @override
  Future<void> dismiss(Iterable<String> ids) => DockPlatform.channel
      .invokeMethod('dismissMediaSuggestions', {'ids': ids.toList()});
  @override
  Future<void> drag(String id) async {
    await DockPlatform.channel.invokeMethod('dragMediaSuggestion', {'id': id});
  }
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
        suggestions.add(
          SuggestedPhoto(
            asset.id,
            thumbnail,
            suggestedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
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
    this.feed,
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
  final RecentPhotoFeed? feed;
  StreamSubscription<void>? _feedChanges;
  Set<String> _showing = {};
  bool _interacting = false;
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
    if (feed != null) {
      if (visible) {
        _feedChanges = feed!.changes.listen((_) => unawaited(refresh()));
        unawaited(refresh());
      } else {
        unawaited(_feedChanges?.cancel());
        _feedChanges = null;
        setShowing({});
        unawaited(_deactivateFeed());
      }
      return;
    }
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
      if ((feed != null || !suggestInApp) &&
          (state['mediaPermissionVersion'] as int? ?? 1) < 2) {
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
      if (feed != null) {
        await feed!.dismiss(items.map((item) => item.id));
        await _deactivateFeed();
      }
      items = [];
      problem = null;
    }
    await _save();
    _changed();
    if (value && _visible) await refresh();
  }

  Future<void> refresh() async {
    if (!supported ||
        !_visible ||
        _disposed ||
        feed == null && _suggestedThisRun)
      return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      await (_loaded ??= _load());
      if (!enabled ||
          !_visible ||
          _disposed ||
          feed == null && _suggestedThisRun)
        return;
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
      if (feed != null && _visible && enabled && !_disposed) {
        await feed!.setActive(true);
        final found = await feed!.read();
        if (_visible && enabled && !_disposed) {
          items = found;
          problem = null;
        }
        return;
      }
      // Keep the permission/settings flow for callers that explicitly hide suggestions.
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
    if (feed != null) {
      await feed!.dismiss(dismissed);
      items.removeWhere((item) => dismissed.contains(item.id));
      _changed();
      return;
    }
    _handled.addAll(dismissed);
    while (_handled.length > 256) {
      _handled.remove(_handled.first);
    }
    items.removeWhere((item) => dismissed.contains(item.id));
    _changed();
    await _save();
  }

  Future<void> add(String id, Future<void> Function(String) stage) async {
    final path =
        items.where((item) => item.id == id).firstOrNull?.path ??
        (feed == null ? await library.filePath(id) : null);
    if (path == null) {
      await dismiss([id]);
      return;
    }
    // This can be the original gallery file. Never register it as a temporary
    // transfer file, or remove it when clearing the pending-send list.
    await stage(path);
    await dismiss([id]);
  }

  void setShowing(Set<String> ids, {bool interacting = false}) {
    if (feed == null || setEquals(ids, _showing) && interacting == _interacting)
      return;
    _showing = Set.of(ids);
    _interacting = interacting;
    unawaited(_reportShowing());
  }

  Future<void> _reportShowing() async {
    try {
      await feed!.setShowing(_showing, interacting: _interacting);
    } catch (_) {
      problem = '无法更新媒体建议';
      _changed();
    }
  }

  Future<void> _deactivateFeed() async {
    try {
      await feed!.setActive(false);
    } catch (_) {
      problem = '无法更新媒体建议';
      _changed();
    }
  }

  Future<void> drag(String id) async {
    if (feed != null) await feed!.drag(id);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _suggestionTimer?.cancel();
    unawaited(_feedChanges?.cancel());
    if (feed != null) unawaited(_deactivateFeed());
    super.dispose();
  }
}
