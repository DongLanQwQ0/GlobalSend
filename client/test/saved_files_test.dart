import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files.dart';
import 'package:globalsend/receive_destination.dart';

ServerProfile profile() => ServerProfile(
  baseUrl: 'https://fixture.invalid',
  instanceId: 'library',
  deviceId: 'receiver',
  groupId: 'one',
);

Future<Directory> fixtureDirectory() async {
  final parent = await Directory('build/test-tmp/saved-files')
      .create(recursive: true);
  final folder = await parent.createTemp('case-');
  ReceiveDestination.registryDirectoryForTesting = () async =>
      Directory('${folder.path}/registry');
  addTearDown(() => folder.delete(recursive: true));
  addTearDown(() => ReceiveDestination.registryDirectoryForTesting = null);
  return folder;
}

Future<DockEntry> savedEntry(
  Directory documents,
  ServerProfile p,
  String id, {
  int size = 4,
  DateTime? modified,
}) async {
  final file = File(
    '${documents.path}/GlobalSend/${p.key}/${p.deviceId}/$id/$id.txt',
  );
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List.filled(size, 65));
  if (modified != null) await file.setLastModified(modified);
  return DockEntry(
    id: id,
    kind: 'file',
    title: '$id.txt',
    source: 'sender',
    transferId: 'transfer-$id',
    fileId: id,
    size: size,
    localPath: file.path,
    status: 'received',
  );
}

class LibraryApi extends CenterApi {
  LibraryApi() : super('https://fixture.invalid', token: 'test');
  final calls = <String>[];
  Map<String, dynamic>? offered;
  bool failReceipt = false;
  final content = [1, 2, 3, 4];

  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    if (path == '/transfers' && method == 'POST') {
      offered = Map<String, dynamic>.from(body as Map);
      return {
        'transfer': {
          ...offered!,
          'sourceDeviceId': 'receiver',
          'files': (offered!['files'] as List)
              .map(
                (value) => {...value as Map, 'status': 'offered', 'offset': 0},
              )
              .toList(),
        },
      };
    }
    if (path.endsWith('/download-ticket')) {
      return {'downloadPath': '/api/v1/downloads/fixture'};
    }
    if (path.endsWith('/received')) {
      if (failReceipt) throw StateError('receipt unavailable');
      return {};
    }
    if (path == '/transfers/incoming') {
      return {
        'transfer': {
          'files': [
            {
              'fileId': 'received',
              'status': 'ready',
              'transport': 'relay',
              'sha256': sha256.convert(content).toString(),
            },
          ],
        },
      };
    }
    throw StateError('Unexpected request: $method $path');
  }

  @override
  Future<void> download(
    String path,
    File destination,
    void Function(int) progress, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    await destination.writeAsBytes(content);
    progress(content.length);
  }
}

class OfflineLibraryController extends SendController {
  OfflineLibraryController(Directory folder)
    : super(
        documentsDirectory: () async => Directory('${folder.path}/documents'),
        stateDirectory: () async => Directory('${folder.path}/state'),
      );
  @override
  Future<void> connect(String address, {bool development = false}) async =>
      throw const SocketException('fixture is offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cleanup combines selected categories with strict size thresholds and persists filters', () async {
    final folder = await fixtureDirectory(), p = profile();
    final documents = Directory('${folder.path}/documents');
    final store = SavedFilesStore(
      indexFile: File('${folder.path}/library.json'),
      documentsDirectory: documents,
    );
    final now = DateTime(2026, 10, 25);
    for (final item in [
      ('photo', 'photo.png', 1048577),
      ('small', 'small.png', 1048576),
      ('notes', 'notes.txt', 1048577),
    ]) {
      final entry = await savedEntry(documents, p, item.$1, size: item.$3);
      final saved = (await store.register(
        profile: p,
        entry: entry,
        receivedAt: now.subtract(const Duration(days: 2)),
      ))!;
      await store.rename(saved.id, item.$2);
    }
    expect(store.cleanupFilter.categories, {
      SavedFileCategory.image,
      SavedFileCategory.text,
    });
    expect(store.cleanupFilter.sizeRule, SavedFileSizeRule.atMost);
    expect(store.cleanupFilter.sizeMiB * 1048576, 500000);
    await store.setCleanupFilter(
      SavedFileCleanupFilter(
        categories: {SavedFileCategory.image},
        sizeRule: SavedFileSizeRule.greater,
        sizeMiB: 1,
      ),
    );
    final restarted = SavedFilesStore(
      indexFile: store.indexFile,
      documentsDirectory: documents,
    );
    await restarted.load();
    expect(restarted.cleanupFilter.categories, {SavedFileCategory.image});
    expect(restarted.cleanupFilter.sizeMiB, 1);
    expect((await restarted.prune(now)).map((file) => file.fileId), ['photo']);
    expect(restarted.items.map((file) => file.fileId).toSet(), {
      'small',
      'notes',
    });
    await restarted.setCleanupFilter(SavedFileCleanupFilter(categories: {}));
    expect(await restarted.prune(now), isEmpty);
    final zero = SavedFile(
      id: 'zero',
      profileKey: p.key,
      deviceId: p.deviceId,
      groupId: p.groupId,
      transferId: 'zero',
      fileId: 'zero',
      path: '',
      name: 'zero.txt',
      size: 0,
      receivedAtMillis: now.millisecondsSinceEpoch,
    );
    expect(
      SavedFileCleanupFilter(
        sizeRule: SavedFileSizeRule.greater,
        sizeMiB: 0,
      ).matches(zero),
      false,
    );
    expect(
      SavedFileCleanupFilter(
        sizeRule: SavedFileSizeRule.any,
        sizeMiB: 100,
      ).matches(zero),
      true,
    );
    await restarted.setCleanupFilter(
      SavedFileCleanupFilter(
        categories: {SavedFileCategory.text},
        sizeRule: SavedFileSizeRule.smaller,
        sizeMiB: 2,
      ),
    );
    expect((await restarted.prune(now)).map((file) => file.fileId), ['notes']);
    expect(savedFileCategory('clip.MP4'), SavedFileCategory.video);
    expect(savedFileCategory('sound.flac'), SavedFileCategory.audio);
    expect(savedFileCategory('backup.7z'), SavedFileCategory.archive);
    expect(savedFileCategory('slides.pdf'), SavedFileCategory.other);
  });

  test('saved files keep reception order, renamed display names and receipt times across restart', () async {
    final folder = await fixtureDirectory(), p = profile();
    final documents = Directory('${folder.path}/documents');
    final store = SavedFilesStore(
      indexFile: File('${folder.path}/library.json'),
      documentsDirectory: documents,
    );
    final old = DateTime(2026, 10, 20, 10),
        newer = old.add(const Duration(hours: 1));
    final a = await savedEntry(documents, p, 'a', size: 8, modified: old);
    final b = await savedEntry(documents, p, 'b', size: 3, modified: newer);
    final first = (await store.register(profile: p, entry: a))!;
    await store.register(profile: p, entry: b);
    await store.rename(first.id, '中文新名称.txt');
    final restarted = SavedFilesStore(
      indexFile: store.indexFile,
      documentsDirectory: documents,
    );
    await restarted.load();
    expect(restarted.items.first.receivedAt, old);
    expect(restarted.items.first.name, '中文新名称.txt');
    expect(restarted.items.first.path, File(a.localPath).absolute.path);
    expect(
      sortSavedFiles(restarted.items, SavedFilesSort.newest).first.fileId,
      'b',
    );
    expect(
      sortSavedFiles(restarted.items, SavedFilesSort.oldest).first.fileId,
      'a',
    );
    expect(
      sortSavedFiles(restarted.items, SavedFilesSort.largest).first.fileId,
      'a',
    );
    expect(
      sortSavedFiles(restarted.items, SavedFilesSort.smallest).first.fileId,
      'b',
    );
    expect(
      sortSavedFiles(restarted.items, SavedFilesSort.name).first.fileId,
      'b',
    );
  });

  test('24-hour default expires at the receipt boundary and custom seven days persists without immediate deletion', () async {
    final folder = await fixtureDirectory(), p = profile();
    final documents = Directory('${folder.path}/documents');
    final store = SavedFilesStore(
      indexFile: File('${folder.path}/library.json'),
      documentsDirectory: documents,
    );
    final now = DateTime(2026, 10, 25, 12);
    final old = await savedEntry(documents, p, 'old');
    final recent = await savedEntry(documents, p, 'recent');
    await store.register(
      profile: p,
      entry: old,
      receivedAt: now.subtract(const Duration(hours: 24)),
    );
    await store.register(
      profile: p,
      entry: recent,
      receivedAt: now
          .subtract(const Duration(hours: 24))
          .add(const Duration(milliseconds: 1)),
    );
    expect(store.retentionHours, 24);
    expect((await store.prune(now)).map((file) => file.fileId), ['old']);
    expect(await File(old.localPath).exists(), false);
    expect(await File(recent.localPath).exists(), true);
    await store.setRetentionHours(7 * 24);
    final restarted = SavedFilesStore(
      indexFile: store.indexFile,
      documentsDirectory: documents,
    );
    await restarted.load();
    expect(restarted.retentionHours, 168);
    expect(await restarted.prune(now.add(const Duration(days: 5))), isEmpty);
    await restarted.setRetentionHours(1);
    expect(await File(recent.localPath).exists(), true);
    expect(await restarted.prune(now, removeExpired: false), isEmpty);
    expect((await restarted.prune(now)).single.fileId, 'recent');
  });

  test('cleanup and manual delete touch only the indexed receiver copy, never sources or exported copies', () async {
    final folder = await fixtureDirectory(), p = profile();
    final documents = Directory('${folder.path}/documents');
    final store = SavedFilesStore(
      indexFile: File('${folder.path}/library.json'),
      documentsDirectory: documents,
    );
    final entry = await savedEntry(documents, p, 'owned');
    final export = await File(entry.localPath)
        .copy('${folder.path}/exported.txt');
    final source = await File('${folder.path}/source.txt')
        .writeAsString('source');
    final outside = DockEntry(
      id: 'outside',
      kind: 'file',
      title: 'exported.txt',
      source: 'sender',
      fileId: 'outside',
      localPath: export.path,
    );
    expect(await store.register(profile: p, entry: outside), isNull);
    final sent = DockEntry(
      id: 'sent',
      kind: 'file',
      title: 'source.txt',
      source: 'receiver',
      fileId: 'sent',
      localPath: source.path,
      outgoing: true,
    );
    expect(await store.register(profile: p, entry: sent), isNull);
    final item = (await store.register(profile: p, entry: entry))!;
    await store.remove([item.id]);
    expect(await File(entry.localPath).exists(), false);
    expect(await export.exists(), true);
    expect(await source.readAsString(), 'source');
    // An indexed path that was replaced with an outside copy must not broaden
    // deletion ownership when the catalog is read after restart.
    final changed = {
      ...item.toJson(),
      'path': export.path,
      'receivedAtMillis': 0,
    };
    await store.indexFile.writeAsString(
      jsonEncode({
        'retentionHours': 24,
        'files': [changed],
      }),
    );
    final restarted = SavedFilesStore(
      indexFile: store.indexFile,
      documentsDirectory: documents,
    );
    await restarted.prune(DateTime.now());
    expect(await export.exists(), true);
  });

  test('offline startup restores the scoped library and migrates legacy copies without using a center session', () async {
    final folder = await fixtureDirectory(), p = profile();
    final documents = Directory('${folder.path}/documents'),
        state = await Directory('${folder.path}/state').create();
    final recent = await savedEntry(
      documents,
      p,
      'recent',
      modified: DateTime.now().subtract(const Duration(hours: 2)),
    );
    final expired = await savedEntry(
      documents,
      p,
      'expired',
      modified: DateTime.now().subtract(const Duration(days: 2)),
    );
    await File('${state.path}/profiles.json')
        .writeAsString(jsonEncode([p.toJson()]));
    await File('${state.path}/recent-center.json')
        .writeAsString(jsonEncode({'profileKey': p.key}));
    await File('${state.path}/${p.key}.json').writeAsString(
      jsonEncode({
        'dock': [recent.toJson(), expired.toJson()],
      }),
    );
    final c = OfflineLibraryController(folder);
    addTearDown(c.dispose);
    await c.init();
    await c.localLibraryIdle;
    expect(c.profile!.key, p.key);
    expect(c.api, isNull);
    expect(c.connected, false);
    expect(c.savedFiles.single.fileId, 'recent');
    expect(await File(expired.localPath).exists(), false);
    expect(c.dock.where((entry) => entry.fileId == 'expired'), isEmpty);
    await c.renameSavedFile(c.savedFiles.single.id, '离线重命名.txt');
    await c.setSavedFileRetentionHours(72);
    c.dock.clear();
    await c.save();
    final restarted = OfflineLibraryController(folder);
    addTearDown(restarted.dispose);
    await restarted.init();
    await restarted.localLibraryIdle;
    expect(restarted.savedFiles.single.name, '离线重命名.txt');
    expect(restarted.savedFileRetentionHours, 72);
    restarted.profile = ServerProfile(
      baseUrl: p.baseUrl,
      instanceId: p.instanceId,
      deviceId: p.deviceId,
      groupId: 'other',
    );
    expect(restarted.savedFiles.single.fileId, 'recent');
  });

  test('forward uses a new offer with the renamed filename and existing route preference, not an expired ticket', () async {
    final folder = await fixtureDirectory(), p = profile();
    p.sendRoutePreference = 'lan';
    final documents = Directory('${folder.path}/documents');
    final entry = await savedEntry(documents, p, 'library');
    final a = LibraryApi();
    final c = SendController(documentsDirectory: () async => documents)
      ..root = Directory('${folder.path}/state')
      ..profile = p
      ..profiles = [p]
      ..api = a
      ..connected = true
      ..devices = [
        {'deviceId': 'peer', 'name': 'Phone', 'online': true},
      ]
      ..dock = [entry]
      ..info = {
        'features': {'routePreference': true},
        'limits': {'maxFileSize': 1024},
      };
    addTearDown(c.dispose);
    await c.refreshSavedFiles();
    final id = c.savedFiles.single.id;
    await c.renameSavedFile(id, '转发的新文件名.txt');
    c.dock.clear();
    await c.forwardSavedFiles('peer', [id]);
    expect(a.calls, ['POST /transfers']);
    expect(a.offered!['targetDeviceId'], 'peer');
    expect(a.offered!['routePreference'], 'lan');
    expect((a.offered!['files'] as List).single['name'], '转发的新文件名.txt');
    expect(c.sources.values.single, File(entry.localPath).absolute.path);
    expect(c.savedFiles.single.id, id);
    expect(await File(entry.localPath).exists(), true);
  });

  test('a completed receiver copy reaches the library even when its center receipt fails', () async {
    final folder = await fixtureDirectory(),
        p = profile(),
        a = LibraryApi()..failReceipt = true;
    final c =
        SendController(
            documentsDirectory: () async =>
                Directory('${folder.path}/documents'),
          )
          ..root = Directory('${folder.path}/state')
          ..profile = p
          ..profiles = [p]
          ..api = a
          ..info = {
            'features': {'direct': false},
          };
    addTearDown(c.dispose);
    final entry = DockEntry(
      id: 'received',
      kind: 'file',
      title: '收到的文件.txt',
      source: 'sender',
      transferId: 'incoming',
      fileId: 'received',
      size: 4,
    );
    c.dock = [entry];
    await c.receive(entry);
    expect(await File(entry.localPath).readAsBytes(), [1, 2, 3, 4]);
    expect(c.savedFiles.single.fileId, 'received');
    expect(
      DateTime.now().difference(c.savedFiles.single.receivedAt).inSeconds,
      lessThan(5),
    );
  });
}
