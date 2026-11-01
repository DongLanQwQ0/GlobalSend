import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  Stream<void> get changes => const Stream.empty();
  Future<Set<String>> availableIds(Set<String> ids) async => ids;
  Future<bool> permission({required bool request});
  Future<List<SuggestedPhoto>> readSince(DateTime since, Set<String> handled);
  Future<String?> filePath(String id);
}

class DevicePhotoLibrary implements RecentPhotoLibrary {
  late final _changes = StreamController<void>.broadcast(
    onListen: () {
      PhotoManager.addChangeCallback(_libraryChanged);
      unawaited(PhotoManager.startChangeNotify());
    },
    onCancel: () {
      PhotoManager.removeChangeCallback(_libraryChanged);
      unawaited(PhotoManager.stopChangeNotify());
    },
  );
  void _libraryChanged(MethodCall _) => _changes.add(null);
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Future<Set<String>> availableIds(Set<String> ids) async {
    final available = <String>{};
    for (final id in ids) {
      final asset = await AssetEntity.fromId(id);
      if (asset != null &&
          await asset.exists &&
          await asset.isLocallyAvailable()) {
        available.add(id);
      }
    }
    return available;
  }

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
    final suggestions = <SuggestedPhoto>[];
    final suggestedAt = DateTime.now().millisecondsSinceEpoch;
    for (var page = 0; suggestions.length < 6; page++) {
      final assets = await PhotoManager.getAssetListPaged(
        page: page,
        pageCount: 24,
        type: RequestType.common,
        filterOption: FilterOptionGroup(
          createTimeCond: DateTimeCond(min: since, max: DateTime.now()),
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
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
              name: await asset.titleAsync,
              suggestedAt: suggestedAt,
            ),
          );
        }
        if (suggestions.length == 6) break;
      }
      if (assets.length < 24) break;
    }
    return suggestions;
  }

  @override
  Future<String?> filePath(String id) async {
    final asset = await AssetEntity.fromId(id);
    // Keep HEIC/video bytes and their original suffix, rather than requesting
    // PhotoManager's converted JPEG representation.
    return (await asset?.originFile)?.path;
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
  Timer? _suggestionTimer;
  final _remaining = <String, int>{};
  final _suggestedAt = <String, int>{};
  final _clock = Stopwatch()..start();
  int? _visibleSince;
  // A replacement screen can start loading before the disposed screen's last
  // asynchronous write completes. Keep that handoff ordered across instances.
  static Future<void> _stateWrites = Future.value();
  Future<void> _writes = Future.value();

  @visibleForTesting
  Future<void> get pendingWrites => _writes;

  Future<void> openSettings() => PhotoManager.openSetting();

  void setVisible(bool visible) {
    if (!supported || _disposed || _visible == visible) return;
    _spendVisibleTime();
    _visible = visible;
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
    } else {
      _showing = {};
      _interacting = false;
      _rescheduleExpiry();
      unawaited(_feedChanges?.cancel());
      _feedChanges = null;
      unawaited(_save());
    }
  }

  Future<File> _stateFile() async =>
      File('${(await directory()).path}/recent-photo-suggestions.json');

  Future<void> _load() async {
    await _stateWrites;
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
      for (final pending in state['pending'] as List? ?? const []) {
        final id = pending['id'] as String;
        _remaining[id] = pending['remainingMs'] as int;
        _suggestedAt[id] = pending['suggestedAt'] as int;
      }
    } else {
      _since = now().subtract(const Duration(minutes: 10));
    }
  }

  Future<void> _save() {
    if (_since == null) return Future.value();
    final contents = jsonEncode({
      'enabled': enabled,
      'asked': _asked,
      'mediaPermissionVersion': 2,
      'since': _since!.toIso8601String(),
      'handled': _handled.toList(),
      'pending': [
        for (final id in _remaining.keys)
          {
            'id': id,
            'remainingMs': _remaining[id],
            'suggestedAt': _suggestedAt[id],
          },
      ],
    });
    return _writes = _stateWrites = _stateWrites.catchError((Object _) {}).then(
      (_) async {
        final file = await _stateFile();
        await file.parent.create(recursive: true);
        await file.writeAsString(contents, flush: true);
      },
    );
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
      _remaining.clear();
      _suggestedAt.clear();
      _showing = {};
      _rescheduleExpiry();
      problem = null;
    }
    await _save();
    _changed();
    if (value && _visible) await refresh();
  }

  Future<void> refresh() async {
    if (!supported || !_visible || _disposed) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      await (_loaded ??= _load());
      if (!enabled || !_visible || _disposed) return;
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
        setShowing({});
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
      _feedChanges ??= library.changes.listen((_) => unawaited(refresh()));
      final available = await library.availableIds(_remaining.keys.toSet());
      if (!_visible || !enabled || _disposed) return;
      final removed = _remaining.keys.toSet().difference(available);
      _forget(removed);
      final oldest = now().subtract(const Duration(days: 1));
      final since = _since!.isAfter(oldest) ? _since! : oldest;
      final found = await library.readSince(
        since,
        _handled.difference(_remaining.keys.toSet())
          ..addAll(items.map((item) => item.id)),
      );
      if (_visible && enabled && !_disposed) {
        for (final photo in found) {
          // A dismissal can happen while Photos is answering the scan.
          if (_handled.contains(photo.id) &&
              !_remaining.containsKey(photo.id)) {
            continue;
          }
          if (items.any((item) => item.id == photo.id)) continue;
          _remaining.putIfAbsent(
            photo.id,
            () => suggestionDuration.inMilliseconds,
          );
          final stamp = _suggestedAt.putIfAbsent(
            photo.id,
            () => photo.suggestedAt > 0
                ? photo.suggestedAt
                : now().millisecondsSinceEpoch,
          );
          items.add(
            SuggestedPhoto(
              photo.id,
              photo.thumbnail,
              path: photo.path,
              name: photo.name,
              suggestedAt: stamp,
            ),
          );
          _handled.add(photo.id);
        }
        final order = {for (var i = 0; i < items.length; i++) items[i].id: i};
        items.sort((a, b) {
          final byTime = b.suggestedAt.compareTo(a.suggestedAt);
          return byTime != 0 ? byTime : order[a.id]!.compareTo(order[b.id]!);
        });
        problem = null;
        _trimHandled();
        _rescheduleExpiry();
        await _save();
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
    _spendVisibleTime();
    _handled.addAll(dismissed);
    _forget(dismissed);
    _trimHandled();
    _rescheduleExpiry();
    _changed();
    await _save();
  }

  Future<void> add(String id, Future<void> Function(String) stage) async {
    final path = await sourcePath(id);
    if (path == null) {
      await dismiss([id]);
      return;
    }
    // This can be the original gallery file. Never register it as a temporary
    // transfer file, or remove it when clearing the pending-send list.
    await stage(path);
    await dismiss([id]);
  }

  Future<String?> sourcePath(String id) async =>
      items.where((item) => item.id == id).firstOrNull?.path ??
      (feed == null ? await library.filePath(id) : null);

  void setShowing(Set<String> ids, {bool interacting = false}) {
    if (setEquals(ids, _showing) && interacting == _interacting) return;
    _spendVisibleTime();
    _showing = Set.of(ids);
    _interacting = interacting;
    if (feed != null) {
      unawaited(_reportShowing());
    } else {
      _rescheduleExpiry();
    }
  }

  void _trimHandled() {
    while (_handled.length > 256) {
      final old = _handled
          .where((id) => !_remaining.containsKey(id))
          .firstOrNull;
      if (old == null) break;
      _handled.remove(old);
    }
  }

  void _forget(Set<String> ids) {
    items.removeWhere((item) => ids.contains(item.id));
    for (final id in ids) {
      _remaining.remove(id);
      _suggestedAt.remove(id);
    }
  }

  void _spendVisibleTime() {
    final start = _visibleSince;
    _visibleSince = null;
    if (start == null) return;
    final elapsed = _clock.elapsedMilliseconds - start;
    for (final id in _showing) {
      if (_remaining.containsKey(id)) {
        _remaining[id] = _remaining[id]! - elapsed;
      }
    }
  }

  void _rescheduleExpiry() {
    _suggestionTimer?.cancel();
    if (feed != null) return;
    _spendVisibleTime();
    final expired = _remaining.keys.where((id) => _remaining[id]! <= 0).toSet();
    _forget(expired);
    final active = _showing.where(_remaining.containsKey);
    if (!_visible || !enabled || _interacting || active.isEmpty || _disposed) {
      return;
    }
    _visibleSince = _clock.elapsedMilliseconds;
    final delay = active
        .map((id) => _remaining[id]!)
        .reduce((a, b) => a < b ? a : b);
    _suggestionTimer = Timer(Duration(milliseconds: delay), () {
      _rescheduleExpiry();
      _changed();
      unawaited(_save());
    });
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
    _spendVisibleTime();
    // Screen disposal can bypass setVisible(false). Persist the last visible
    // interval through the same serialized writer before releasing the model.
    if (feed == null) unawaited(_save());
    _disposed = true;
    _suggestionTimer?.cancel();
    unawaited(_feedChanges?.cancel());
    if (feed != null) unawaited(_deactivateFeed());
    super.dispose();
  }
}
