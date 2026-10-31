import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'receive_destination.dart';
import 'received_file_access.dart';
import 'folder_transfer.dart';
import 'dock_platform.dart';

enum SavedFilesSort { newest, oldest, name, largest, smallest }

enum SavedFileCategory { image, video, audio, text, archive, other }

enum SavedFileSizeRule { any, greater, smaller, atMost }

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
    this.sizeRule = SavedFileSizeRule.atMost,
    this.sizeMiB = 500000 / 1048576,
  }) : categories = Set.unmodifiable(
         categories ?? {SavedFileCategory.image, SavedFileCategory.text},
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
      SavedFileSizeRule.atMost => file.size <= bytes,
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
    this.contentDigest = '',
  });

  static const defaultRetentionHours = 24;
  final String id, profileKey, deviceId, groupId, transferId, fileId;
  final String path, name;
  final int size, receivedAtMillis;
  final bool managedLocation;
  final bool directory;
  final String relativePath;
  final String contentDigest;
  DateTime get receivedAt =>
      DateTime.fromMillisecondsSinceEpoch(receivedAtMillis);
  DateTime expiresAt(int retentionHours) =>
      receivedAt.add(Duration(hours: retentionHours));
  bool expiredAt(DateTime now, int retentionHours) =>
      !now.isBefore(expiresAt(retentionHours));

  SavedFile summarized(int totalSize) => SavedFile(
    id: id,
    profileKey: profileKey,
    deviceId: deviceId,
    groupId: groupId,
    transferId: transferId,
    fileId: fileId,
    path: path,
    name: name,
    size: totalSize,
    receivedAtMillis: receivedAtMillis,
    managedLocation: managedLocation,
    directory: directory,
    relativePath: relativePath,
    contentDigest: contentDigest,
  );

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
    contentDigest: contentDigest,
  );

  SavedFile relocated(String location, {int? currentSize}) => SavedFile(
    id: id,
    profileKey: profileKey,
    deviceId: deviceId,
    groupId: groupId,
    transferId: transferId,
    fileId: fileId,
    path: location,
    name: name,
    size: currentSize ?? size,
    receivedAtMillis: receivedAtMillis,
    managedLocation: true,
    directory: directory,
    relativePath: relativePath,
    contentDigest: contentDigest,
  );

  SavedFile refreshed({required int receivedAtMillis, String? digest}) =>
      SavedFile(
        id: id,
        profileKey: profileKey,
        deviceId: deviceId,
        groupId: groupId,
        transferId: transferId,
        fileId: fileId,
        path: path,
        name: name,
        size: size,
        receivedAtMillis: receivedAtMillis,
        managedLocation: managedLocation,
        directory: directory,
        relativePath: relativePath,
        contentDigest: digest ?? contentDigest,
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
    'contentDigest': contentDigest,
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
    contentDigest: value['contentDigest'] ?? '',
  );
}

/// The library exposes a received tree as one folder, while its index retains
/// every original path for cleanup, relocation and transfer reuse.
List<SavedFile> folderLibraryCards(Iterable<SavedFile> files) {
  final values = files.toList();
  String key(SavedFile file) =>
      '${file.profileKey}:${file.transferId}:${file.relativePath.split('/').first}';
  final totals = <String, int>{
    for (final file in values)
      if (file.directory &&
          file.relativePath.isNotEmpty &&
          !file.relativePath.contains('/'))
        key(file): 0,
  };
  for (final file in values) {
    if (totals.containsKey(key(file)))
      totals[key(file)] = totals[key(file)]! + file.size;
  }
  return [
    for (final file in values)
      if (!totals.containsKey(key(file)))
        file
      else if (file.directory && !file.relativePath.contains('/'))
        file.summarized(totals[key(file)]!),
  ];
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
  int migrationSkippedFiles = 0;
  final Map<String, String> relocatedLocations = {};
  final List<SavedFile> _obsoleteLocations = [];
  int get migrationCleanupPending => _obsoleteLocations.length;
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
      relocatedLocations.addAll(
        Map<String, String>.from(decoded['relocatedLocations'] ?? {}),
      );
      _obsoleteLocations.addAll(
        (decoded['obsoleteLocations'] as List? ?? []).map(
          (value) => SavedFile.fromJson(Map<String, dynamic>.from(value)),
        ),
      );
      values = decoded['files'] as List;
    }
    for (final value in values) {
      final item = SavedFile.fromJson(Map<String, dynamic>.from(value));
      _items[item.id] = item;
    }
    if (relocatedLocations.isNotEmpty)
      await ReceiveDestination.relocateFolderRoots(relocatedLocations);
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
        'relocatedLocations': relocatedLocations,
        'obsoleteLocations': _obsoleteLocations
            .map((item) => item.toJson())
            .toList(),
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
    if (!await ReceivedFileAccess.exists(item.path) || !await scope.exists())
      return false;
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
    entry.localPath = relocatedLocations[entry.localPath] ?? entry.localPath;
    if (entry.outgoing || entry.kind != 'file' || entry.localPath.isEmpty) {
      return null;
    }
    final id =
        '${profile.key}:${profile.deviceId}:${profile.groupId}:${entry.transferId}:${entry.fileId}';
    final canonicalPath = ReceivedFileAccess.canonical(entry.localPath);
    // A repeated delivery references the same owned file, not another copy.
    // Keep one cleanup owner even when the new transfer/profile has a new ID.
    final existing =
        _items[id] ??
        _items.values.where((item) => item.path == canonicalPath).firstOrNull;
    if (existing != null &&
        existing.path == canonicalPath &&
        await ownsExisting(existing)) {
      final time =
          receivedAt?.millisecondsSinceEpoch ??
          (entry.receivedAtMillis > 0 ? entry.receivedAtMillis : null);
      final digest = entry.contentDigest;
      if (time != null && time > existing.receivedAtMillis ||
          digest.isNotEmpty && digest != existing.contentDigest) {
        final updated = existing.refreshed(
          receivedAtMillis: time != null && time > existing.receivedAtMillis
              ? time
              : existing.receivedAtMillis,
          digest: digest.isNotEmpty ? digest : null,
        );
        _items[existing.id] = updated;
        await _persist();
        return updated;
      }
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
          (receivedAt ??
                  (entry.receivedAtMillis > 0
                      ? DateTime.fromMillisecondsSinceEpoch(
                          entry.receivedAtMillis,
                        )
                      : managed
                      ? DateTime.now()
                      : await file.lastModified()))
              .millisecondsSinceEpoch,
      managedLocation: managed,
      directory: entry.isDirectory,
      relativePath: entry.relativePath,
      contentDigest: entry.contentDigest,
    );
    if (!await ownsExisting(item)) return null;
    _items[id] = item;
    await _persist();
    return item;
  });

  /// Verify the actual retained bytes before acknowledging a repeated offer.
  /// Folder members are matched only as a complete tree by reusableFolder,
  /// never individually across unrelated roots.
  Future<SavedFile?> reusableFile(DockEntry entry) => _write(() async {
    if (entry.isDirectory ||
        entry.relativePath.isNotEmpty ||
        entry.contentDigest.isEmpty)
      return null;
    for (final candidate in _items.values.toList()) {
      if (candidate.directory ||
          candidate.relativePath.isNotEmpty ||
          candidate.size != entry.size ||
          candidate.contentDigest.isNotEmpty &&
              candidate.contentDigest != entry.contentDigest)
        continue;
      ReceivedFileAccess? access;
      try {
        if (!await ownsExisting(candidate)) continue;
        access = await ReceivedFileAccess.open(candidate.path);
        if (await access.file.length() != entry.size) continue;
        final digest = (await sha256.bind(access.file.openRead()).first)
            .toString();
        if (digest == entry.contentDigest) return candidate;
      } on FileSystemException {
        // A removed/changed/unreadable local copy is not a reusable delivery.
      } on PlatformException {
        // Revoked provider access must use the ordinary receive destination.
      } finally {
        await access?.close();
      }
    }
    return null;
  });

  /// Match one retained root, never a collection of unrelated saved leaves.
  /// The actual tree must match too: an added/deleted empty directory matters.
  Future<Map<String, SavedFile>?> reusableFolder(
    List<DockEntry> entries,
  ) => _write(() async {
    if (entries.isEmpty) return null;
    final rootName = entries.first.relativePath.split('/').first;
    final offered = {
      for (final entry in entries)
        entry.relativePath.split('/').skip(1).join('/'): entry,
    };
    if (offered.length != entries.length ||
        offered['']?.isDirectory != true ||
        entries.any((entry) => entry.relativePath.split('/').first != rootName))
      return null;
    final roots = _items.values
        .where(
          (item) =>
              item.directory &&
              item.relativePath.isNotEmpty &&
              !item.relativePath.contains('/'),
        )
        .toList();
    for (final root in roots) {
      try {
        if (!await ownsExisting(root)) continue;
        final saved = {
          for (final item in _items.values.where(
            (item) =>
                item.profileKey == root.profileKey &&
                item.deviceId == root.deviceId &&
                item.groupId == root.groupId &&
                item.transferId == root.transferId &&
                (item.relativePath == root.relativePath ||
                    item.relativePath.startsWith('${root.relativePath}/')),
          ))
            item.relativePath.split('/').skip(1).join('/'): item,
        };
        if (saved.length != offered.length ||
            offered.keys.any(
              (key) =>
                  saved[key] == null ||
                  saved[key]!.directory != offered[key]!.isDirectory ||
                  !saved[key]!.directory &&
                      (saved[key]!.size != offered[key]!.size ||
                          saved[key]!.contentDigest.isNotEmpty &&
                              saved[key]!.contentDigest !=
                                  offered[key]!.contentDigest),
            ))
          continue;
        final actual = ReceivedFileAccess.isContentUri(root.path)
            ? (await DockPlatform.directoryEntries(root.path))
                  .map(FolderEntry.fromMap)
                  .toList()
            : await readFolderEntries(root.path);
        final tree = {
          for (final entry in actual)
            entry.relativePath.split('/').skip(1).join('/'): entry,
        };
        if (tree.length != offered.length ||
            offered.keys.any(
              (key) =>
                  tree[key] == null ||
                  tree[key]!.directory != offered[key]!.isDirectory ||
                  _comparable(
                        ReceivedFileAccess.canonical(tree[key]!.location),
                      ) !=
                      _comparable(saved[key]!.path),
            ))
          continue;
        var identical = true;
        for (final entry in offered.entries) {
          // The indexed owners and actual root tree already match. Opening
          // each file proves current read access; do not reread the entire
          // ownership registry once for every member of a large folder.
          if (entry.value.isDirectory) continue;
          final access = await ReceivedFileAccess.open(saved[entry.key]!.path);
          try {
            if (await access.file.length() != entry.value.size ||
                (await sha256.bind(access.file.openRead()).first).toString() !=
                    entry.value.contentDigest) {
              identical = false;
              break;
            }
          } finally {
            await access.close();
          }
        }
        if (identical)
          return {
            for (final entry in offered.entries)
              entry.value.fileId: saved[entry.key]!,
          };
      } on FileSystemException {
        // A changed or unavailable root needs a normal new folder receive.
      } on PlatformException {
        // A revoked document grant is not a retained, readable directory.
      }
    }
    return null;
  });

  /// Refresh the existing cleanup owners in one index write, not N full saves.
  Future<Map<String, SavedFile>> refreshReusedFolder(
    Map<String, SavedFile> matched,
    List<DockEntry> entries,
    DateTime receivedAt,
  ) => _write(() async {
    final updated = <String, SavedFile>{};
    for (final entry in entries) {
      final item = _items[matched[entry.fileId]!.id];
      if (item == null) continue; // Respect a user's intervening removal.
      final next = item.refreshed(
        receivedAtMillis:
            receivedAt.millisecondsSinceEpoch > item.receivedAtMillis
            ? receivedAt.millisecondsSinceEpoch
            : item.receivedAtMillis,
        digest: entry.contentDigest,
      );
      _items[item.id] = next;
      updated[entry.fileId] = next;
    }
    if (updated.isNotEmpty) await _persist();
    return updated;
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

  Future<void> setReceiveDestination(
    String location,
    String label, {
    void Function(int done, int total)? onProgress,
    Future<void> Function()? onCommitted,
  }) => _write(() async {
    migrationSkippedFiles = 0;
    if (_obsoleteLocations.isNotEmpty) {
      await _finishMigrationCleanup();
      if (_obsoleteLocations.any(
        (item) => !item.directory && !item.path.startsWith('content://'),
      )) {
        throw const FileSystemException('部分旧文件尚未移除，请关闭占用文件的程序后重试');
      }
    }
    if (_comparable(location) == _comparable(receiveDestinationLocation)) {
      receiveDestinationLabel = label;
      await _persist();
      return;
    }
    final base = location.isEmpty
        ? '${documentsDirectory.path}/GlobalSend'
        : location;
    if (!base.startsWith('content://'))
      await Directory(base).create(recursive: true);
    final originals = <SavedFile>[];
    for (final item in _items.values) {
      try {
        if (await ownsExisting(item)) originals.add(item);
      } on PlatformException {
        // An unavailable old provider must not trap the receive destination.
        // Keep this item's original durable reference for a later recovery.
        migrationSkippedFiles++;
      } on FileSystemException {
        migrationSkippedFiles++;
      }
    }
    originals.sort(
      (a, b) => a.relativePath.length.compareTo(b.relativePath.length),
    );
    final moved = <SavedFile>[];
    final copiedLocations = <String, SavedFile>{};
    final created = <String>[];
    final directories = <String>[];
    try {
      for (final item in originals) {
        final existingCopy = copiedLocations[item.path];
        if (existingCopy != null) {
          moved.add(
            item.relocated(existingCopy.path, currentSize: existingCopy.size),
          );
          onProgress?.call(moved.length, originals.length);
          continue;
        }
        final relative = item.relativePath.isEmpty
            ? item.name
            : item.relativePath;
        final transfer =
            'migration:$base:${item.profileKey}:${item.deviceId}:${item.groupId}:${item.transferId}';
        String target;
        var currentSize = item.size;
        ReceivedFileAccess? source;
        if (!item.directory) {
          try {
            source = await ReceivedFileAccess.open(item.path);
            final probe = await source.file.open();
            try {
              currentSize = await probe.length();
            } finally {
              await probe.close();
            }
            await source.close();
            source = null;
          } on PlatformException {
            await source?.close();
            migrationSkippedFiles++;
            moved.add(item);
            continue;
          } on FileSystemException {
            await source?.close();
            migrationSkippedFiles++;
            moved.add(item);
            continue;
          }
        }
        if (item.directory) {
          target = await ReceiveDestination.folderDirectory(
            destinationLocation: base,
            transferKey: transfer,
            relativePath: relative,
          );
          directories.add(target);
        } else {
          var parent = base;
          final parts = item.relativePath.split('/');
          if (parts.length > 1) {
            parent = await ReceiveDestination.folderDirectory(
              destinationLocation: base,
              transferKey: transfer,
              relativePath: parts.take(parts.length - 1).join('/'),
            );
            directories.add(parent);
          }
          final handle = await ReceiveDestination.create(
            destinationLocation: parent,
            name: item.name,
          );
          target = handle.location;
          created.add(target);
          try {
            source = await ReceivedFileAccess.open(item.path);
            await source.file.openRead().pipe(File(handle.ioPath).openWrite());
          } finally {
            await source?.close();
            await ReceiveDestination.closeHandle(handle.handle);
          }
          if ((await ReceiveDestination.stat(target)).size != currentSize) {
            throw FileSystemException('文件迁移未完成，原文件已保留', item.path);
          }
        }
        final next = item.relocated(target, currentSize: currentSize);
        moved.add(next);
        copiedLocations[item.path] = next;
        onProgress?.call(moved.length, originals.length);
      }
    } catch (_) {
      for (final path in [
        ...created.reversed,
        ...directories.reversed.toSet(),
      ]) {
        await ReceiveDestination.delete(path);
      }
      rethrow;
    }
    final previousLocation = receiveDestinationLocation;
    final previousLabel = receiveDestinationLabel;
    final previousAliases = Map<String, String>.from(relocatedLocations);
    final previousObsolete = _obsoleteLocations.toList();
    final migratedOriginals = <SavedFile>[];
    for (var index = 0; index < originals.length; index++) {
      final old = originals[index], next = moved[index];
      if (old.path == next.path) continue;
      migratedOriginals.add(old);
      _items[old.id] = next;
      relocatedLocations.updateAll(
        (key, value) => value == old.path ? next.path : value,
      );
      relocatedLocations[old.path] = next.path;
    }
    receiveDestinationLocation = location;
    receiveDestinationLabel = label;
    _obsoleteLocations.addAll(migratedOriginals);
    try {
      // Commit every new reference before removing any old bytes. The
      // pending-old list survives interruption and is safe to retry.
      await _persist();
    } catch (_) {
      for (final item in originals) {
        _items[item.id] = item;
      }
      relocatedLocations
        ..clear()
        ..addAll(previousAliases);
      _obsoleteLocations
        ..clear()
        ..addAll(previousObsolete);
      receiveDestinationLocation = previousLocation;
      receiveDestinationLabel = previousLabel;
      for (final path in [
        ...created.reversed,
        ...directories.reversed.toSet(),
      ]) {
        await ReceiveDestination.delete(path);
      }
      rethrow;
    }
    await ReceiveDestination.relocateFolderRoots(relocatedLocations);
    await onCommitted?.call();
    for (final item in moved.where((item) => !item.directory)) {
      unawaited(ReceiveDestination.publish(item.path));
    }
    await _finishMigrationCleanup();
    if (_obsoleteLocations.any(
      (item) => !item.directory && !item.path.startsWith('content://'),
    )) {
      throw const FileSystemException('文件已迁移，部分旧文件被占用，关闭占用程序后重试清理');
    }
  });

  Future<void> finishMigrationCleanup() => _write(_finishMigrationCleanup);

  Future<void> _finishMigrationCleanup() async {
    final pending = _obsoleteLocations.toList()
      ..sort((a, b) => b.relativePath.length.compareTo(a.relativePath.length));
    for (final item in pending) {
      try {
        if (await ownsExisting(item) && !await _delete(item, recursive: false))
          continue;
        _obsoleteLocations.remove(item);
      } on FileSystemException {
        // Keep the journal entry while another application owns a file handle.
      } on Exception {
        // SAF provider failures keep the old reference for an explicit retry.
      }
    }
    await _persist();
  }

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
          bool owned;
          try {
            owned = await ownsExisting(item);
          } on FileSystemException {
            // An unavailable external directory is not a deleted document.
            continue;
          } on PlatformException {
            continue;
          }
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
