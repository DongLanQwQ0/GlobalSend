import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'receive_destination.dart';
import 'received_file_access.dart';

enum SavedFilesSort { newest, oldest, name, largest, smallest }

enum SavedFileCategory { image, video, audio, text, archive, other }

enum SavedFileSizeRule { any, greater, smaller }

SavedFileCategory savedFileCategory(String name) {
  final extension = name.split('.').last.toLowerCase();
  for (final entry in <SavedFileCategory, Set<String>>{
    SavedFileCategory.image: {
      'png',
      'jpg',
      'jpeg',
      'webp',
      'gif',
      'bmp',
      'heic',
      'heif',
      'tif',
      'tiff',
      'svg',
    },
    SavedFileCategory.video: {
      'mp4',
      'mov',
      'mkv',
      'webm',
      'avi',
      '3gp',
      'flv',
      'wmv',
      'm4v',
    },
    SavedFileCategory.audio: {
      'mp3',
      'wav',
      'flac',
      'aac',
      'm4a',
      'ogg',
      'opus',
      'wma',
      'aiff',
    },
    SavedFileCategory.text: {
      'txt',
      'md',
      'markdown',
      'log',
      'json',
      'jsonl',
      'csv',
      'tsv',
      'xml',
      'yaml',
      'yml',
      'ini',
      'conf',
      'config',
      'toml',
      'html',
      'htm',
      'css',
      'js',
      'ts',
      'dart',
      'java',
      'kt',
      'py',
      'c',
      'cpp',
      'h',
      'sh',
      'ps1',
    },
    SavedFileCategory.archive: {
      'zip',
      'rar',
      '7z',
      'tar',
      'gz',
      'bz2',
      'xz',
      'tgz',
      'zst',
    },
  }.entries) {
    if (entry.value.contains(extension)) return entry.key;
  }
  return SavedFileCategory.other;
}

class SavedFileCleanupFilter {
  SavedFileCleanupFilter({
    Set<SavedFileCategory>? categories,
    this.sizeRule = SavedFileSizeRule.any,
    this.sizeMiB = 0,
  }) : categories = Set.unmodifiable(
         categories ?? SavedFileCategory.values.toSet(),
       );
  final Set<SavedFileCategory> categories;
  final SavedFileSizeRule sizeRule;
  final double sizeMiB;
  bool matches(SavedFile file) {
    if (!categories.contains(savedFileCategory(file.name))) return false;
    final bytes = sizeMiB * 1024 * 1024;
    return switch (sizeRule) {
      SavedFileSizeRule.any => true,
      SavedFileSizeRule.greater => file.size > bytes,
      SavedFileSizeRule.smaller => file.size < bytes,
    };
  }

  Map<String, dynamic> toJson() => {
    'categories': categories.map((category) => category.name).toList(),
    'sizeRule': sizeRule.name,
    'sizeMiB': sizeMiB,
  };
  factory SavedFileCleanupFilter.fromJson(Map<String, dynamic> json) =>
      SavedFileCleanupFilter(
        categories: (json['categories'] as List)
            .map((name) => SavedFileCategory.values.byName(name))
            .toSet(),
        sizeRule: SavedFileSizeRule.values.byName(json['sizeRule']),
        sizeMiB: (json['sizeMiB'] as num).toDouble(),
      );
}

class SavedFile {
  const SavedFile({
    required this.id,
    required this.profileKey,
    required this.deviceId,
    required this.groupId,
    required this.transferId,
    required this.fileId,
    required this.path,
    required this.name,
    required this.size,
    required this.receivedAtMillis,
    this.managedLocation = false,
    this.directory = false,
    this.relativePath = '',
  });

  static const defaultRetentionHours = 24;
  final String id, profileKey, deviceId, groupId, transferId, fileId;
  final String path, name;
  final int size, receivedAtMillis;
  final bool managedLocation;
  final bool directory;
  final String relativePath;
  DateTime get receivedAt =>
      DateTime.fromMillisecondsSinceEpoch(receivedAtMillis);
  DateTime expiresAt(int retentionHours) =>
      receivedAt.add(Duration(hours: retentionHours));
  bool expiredAt(DateTime now, int retentionHours) =>
      !now.isBefore(expiresAt(retentionHours));

  SavedFile renamed(String value) => SavedFile(
    id: id,
    profileKey: profileKey,
    deviceId: deviceId,
    groupId: groupId,
    transferId: transferId,
    fileId: fileId,
    path: path,
    name: value,
    size: size,
    receivedAtMillis: receivedAtMillis,
    managedLocation: managedLocation,
    directory: directory,
    relativePath: relativePath,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'profileKey': profileKey,
    'deviceId': deviceId,
    'groupId': groupId,
    'transferId': transferId,
    'fileId': fileId,
    'path': path,
    'name': name,
    'size': size,
    'receivedAtMillis': receivedAtMillis,
    'managedLocation': managedLocation,
    'directory': directory,
    'relativePath': relativePath,
  };

  factory SavedFile.fromJson(Map<String, dynamic> value) => SavedFile(
    id: value['id'],
    profileKey: value['profileKey'],
    deviceId: value['deviceId'],
    groupId: value['groupId'] ?? '',
    transferId: value['transferId'],
    fileId: value['fileId'],
    path: value['path'],
    name: value['name'],
    size: value['size'],
    receivedAtMillis: value['receivedAtMillis'],
    managedLocation: value['managedLocation'] ?? false,
    directory: value['directory'] ?? false,
    relativePath: value['relativePath'] ?? '',
  );
}

List<SavedFile> sortSavedFiles(Iterable<SavedFile> files, SavedFilesSort sort) {
  final result = files.toList();
  int byNewest(SavedFile a, SavedFile b) {
    final order = b.receivedAtMillis.compareTo(a.receivedAtMillis);
    return order == 0 ? a.id.compareTo(b.id) : order;
  }

  result.sort((a, b) {
    final int order;
    switch (sort) {
      case SavedFilesSort.newest:
        return byNewest(a, b);
      case SavedFilesSort.oldest:
        order = a.receivedAtMillis.compareTo(b.receivedAtMillis);
      case SavedFilesSort.name:
        order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case SavedFilesSort.largest:
        order = b.size.compareTo(a.size);
      case SavedFilesSort.smallest:
        order = a.size.compareTo(b.size);
    }
    return order == 0 ? byNewest(a, b) : order;
  });
  return result;
}

/// Indexes only the copies written by the receiver, independently of the
/// center's shorter-lived transfer history. It never scans arbitrary files.
class SavedFilesStore {
  SavedFilesStore({required this.indexFile, required this.documentsDirectory});

  final File indexFile;
  final Directory documentsDirectory;
  final Map<String, SavedFile> _items = {};
  int retentionHours = SavedFile.defaultRetentionHours;
  SavedFileCleanupFilter cleanupFilter = SavedFileCleanupFilter();
  String receiveDestinationLocation = '', receiveDestinationLabel = '';
  Future<void>? _loading;
  Future<void> _tail = Future<void>.value();
  List<SavedFile> get items => List.unmodifiable(_items.values);

  Future<void> load() => _loading ??= () async {
    if (!await indexFile.exists()) return;
    final decoded = jsonDecode(await indexFile.readAsString());
    final List values;
    if (decoded is List) {
      values = decoded;
    } else {
      retentionHours =
          decoded['retentionHours'] as int? ?? SavedFile.defaultRetentionHours;
      if (decoded['cleanupFilter'] != null) {
        cleanupFilter = SavedFileCleanupFilter.fromJson(
          Map<String, dynamic>.from(decoded['cleanupFilter']),
        );
      }
      receiveDestinationLocation = decoded['receiveDestinationLocation'] ?? '';
      receiveDestinationLabel = decoded['receiveDestinationLabel'] ?? '';
      values = decoded['files'] as List;
    }
    for (final value in values) {
      final item = SavedFile.fromJson(Map<String, dynamic>.from(value));
      _items[item.id] = item;
    }
  }();

  Future<T> _write<T>(Future<T> Function() action) {
    final pending = _tail.catchError((Object _) {}).then((_) async {
      await load();
      return action();
    });
    _tail = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
  }

  Future<void> _persist() async {
    await indexFile.parent.create(recursive: true);
    final temporary = File('${indexFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'retentionHours': retentionHours,
        'cleanupFilter': cleanupFilter.toJson(),
        'receiveDestinationLocation': receiveDestinationLocation,
        'receiveDestinationLabel': receiveDestinationLabel,
        'files': _items.values.map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );
    await temporary.rename(indexFile.path);
  }

  Directory ownedDirectory(SavedFile item) => Directory(
    '${documentsDirectory.path}/GlobalSend/${safeName(item.profileKey)}/${safeName(item.deviceId)}/${safeName(item.fileId)}',
  );

  String _comparable(String path) =>
      Platform.isWindows ? path.replaceAll('/', '\\').toLowerCase() : path;

  bool _inside(String file, String directory) =>
      _comparable(file)
          .startsWith('${_comparable(directory)}${Platform.pathSeparator}');

  Future<bool> ownsExisting(SavedFile item) async {
    if (item.managedLocation) {
      return await ReceiveDestination.isOwned(item.path) &&
          (await ReceiveDestination.stat(item.path)).exists;
    }
    final file = File(item.path), scope = ownedDirectory(item);
    if (!await file.exists() || !await scope.exists()) return false;
    final documents = await documentsDirectory.resolveSymbolicLinks();
    final resolvedScope = await scope.resolveSymbolicLinks();
    final managedRoot = Directory('$documents/GlobalSend').absolute.path;
    if (!_inside(resolvedScope, managedRoot)) return false;
    return _inside(await file.resolveSymbolicLinks(), resolvedScope);
  }

  Future<SavedFile?> register({
    required ServerProfile profile,
    required DockEntry entry,
    DateTime? receivedAt,
    bool managedLocation = false,
  }) => _write(() async {
    if (entry.outgoing || entry.kind != 'file' || entry.localPath.isEmpty) {
      return null;
    }
    final id =
        '${profile.key}:${profile.deviceId}:${profile.groupId}:${entry.transferId}:${entry.fileId}';
    final existing = _items[id];
    if (existing != null &&
        existing.path == ReceivedFileAccess.canonical(entry.localPath) &&
        await ownsExisting(existing)) {
      return existing;
    }
    _items.remove(id);
    if (!await ReceivedFileAccess.exists(entry.localPath)) return null;
    final file = File(entry.localPath);
    final managed =
        managedLocation || await ReceiveDestination.isOwned(entry.localPath);
    final size = entry.isDirectory
        ? 0
        : managed
        ? (await ReceiveDestination.stat(entry.localPath)).size
        : await file.length();
    final item = SavedFile(
      id: id,
      profileKey: profile.key,
      deviceId: profile.deviceId,
      groupId: profile.groupId,
      transferId: entry.transferId,
      fileId: entry.fileId,
      path: ReceivedFileAccess.canonical(entry.localPath),
      name: entry.title,
      size: size,
      // Older clients had no received-at field; their completed copy's mtime
      // is the best available timestamp and is fixed on first migration.
      receivedAtMillis:
          (receivedAt ?? (managed ? DateTime.now() : await file.lastModified()))
              .millisecondsSinceEpoch,
      managedLocation: managed,
      directory: entry.isDirectory,
      relativePath: entry.relativePath,
    );
    if (!await ownsExisting(item)) return null;
    _items[id] = item;
    await _persist();
    return item;
  });

  Future<void> rename(String id, String name) => _write(() async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 160 || safeName(clean) != clean) {
      throw const FormatException('名称不能含路径或特殊字符，最多 160 字');
    }
    final item = _items[id];
    if (item == null) throw StateError('文件已移除');
    _items[id] = item.renamed(clean);
    await _persist();
  });

  Future<void> setRetentionHours(int hours) => _write(() async {
    if (hours < 1) throw const FormatException('清理时长至少 1 小时');
    retentionHours = hours;
    await _persist();
  });

  Future<void> setCleanupFilter(SavedFileCleanupFilter filter) =>
      _write(() async {
        if (!filter.sizeMiB.isFinite || filter.sizeMiB < 0) {
          throw const FormatException('文件大小不能为负数');
        }
        cleanupFilter = filter;
        await _persist();
      });

  Future<void> setReceiveDestination(String location, String label) =>
      _write(() async {
        receiveDestinationLocation = location;
        receiveDestinationLabel = label;
        await _persist();
      });

  Future<bool> _delete(
    SavedFile item, {
    List<SavedFile>? removed,
    bool recursive = true,
  }) async {
    if (item.directory && recursive) {
      final children =
          _items.values
              .where(
                (child) =>
                    child.id != item.id &&
                    child.profileKey == item.profileKey &&
                    child.deviceId == item.deviceId &&
                    child.transferId == item.transferId &&
                    child.relativePath.startsWith('${item.relativePath}/'),
              )
              .toList()
            ..sort(
              (a, b) => b.relativePath.length.compareTo(a.relativePath.length),
            );
      for (final child in children) {
        if (!await ownsExisting(child) ||
            await _delete(child, removed: removed)) {
          _items.remove(child.id);
          removed?.add(child);
        }
      }
    }
    if (item.managedLocation) {
      return ReceiveDestination.delete(item.path);
    } else {
      await File(item.path).delete();
      return true;
    }
  }

  Future<List<SavedFile>> remove(Iterable<String> ids) => _write(() async {
    final removed = <SavedFile>[];
    for (final id in ids.toSet()) {
      final item = _items[id];
      if (item == null) continue;
      if (await ownsExisting(item) && !await _delete(item, removed: removed))
        continue;
      _items.remove(id);
      removed.add(item);
    }
    if (removed.isNotEmpty) await _persist();
    return removed;
  });

  Future<List<SavedFile>> prune(DateTime now, {bool removeExpired = true}) =>
      _write(() async {
        final removed = <SavedFile>[];
        final items = _items.values.toList()
          ..sort(
            (a, b) => b.relativePath.length.compareTo(a.relativePath.length),
          );
        for (final item in items) {
          if (!_items.containsKey(item.id)) continue;
          final owned = await ownsExisting(item);
          if (owned &&
              (!removeExpired ||
                  !item.expiredAt(now, retentionHours) ||
                  !cleanupFilter.matches(item))) {
            continue;
          }
          // Cleanup filters apply to each file, not to an enclosing directory.
          // Empty directories are removed only after eligible children expire.
          if (owned && !await _delete(item, recursive: false)) continue;
          _items.remove(item.id);
          removed.add(item);
        }
        if (removed.isNotEmpty) await _persist();
        return removed;
      });
}
