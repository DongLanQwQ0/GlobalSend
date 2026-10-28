import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/saved_files.dart';

import 'saved_files_test.dart' show fixtureDirectory, profile;

class FolderReuseApi extends CenterApi {
  FolderReuseApi() : super('https://fixture.invalid', token: 'fixture');
  final calls = <String>[];
  Map<String, dynamic>? reuseBody;
  List<Map<String, dynamic>> receipts = [];
  String? failure;
  final receivedAt = DateTime.now().toUtc().toIso8601String();
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    if (path.contains('/folders/') && path.endsWith('/reuse')) {
      reuseBody = Map<String, dynamic>.from(body as Map);
      receipts = [
        for (final value in reuseBody!['files'] as List)
          {
            ...Map<String, dynamic>.from(value),
            'status': 'received',
            'reused': true,
            'receivedAt': receivedAt,
            'offset': 0,
          },
      ];
      if (failure != null)
        throw ApiException(
          409,
          'already streaming',
          response: {
            'error': {'code': failure},
          },
        );
      return {'files': receipts};
    }
    if (path.endsWith('/accept')) return {};
    throw StateError(
      'No file payload or route call should be needed: $method $path',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<
    (
      SendController,
      FolderReuseApi,
      List<DockEntry>,
      List<DockEntry>,
      Directory,
    )
  >
  setup({bool feature = true}) async {
    final work = await fixtureDirectory(),
        owner = profile(),
        inbox = await Directory('${work.path}/inbox').create();
    final api = FolderReuseApi(),
        c =
            SendController(
                documentsDirectory: () async =>
                    Directory('${work.path}/documents'),
              )
              ..root = Directory('${work.path}/state')
              ..profile = owner
              ..profiles = [owner]
              ..api = api
              ..info = {
                'features': {
                  'folderReuse': feature,
                  'fileReuse': true,
                  'direct': true,
                },
              };
    addTearDown(() async {
      c.dispose();
      await c.persistenceIdle;
    });
    final specs = [
      ('资料', true, ''),
      ('资料/空目录', true, ''),
      ('资料/sub', true, ''),
      ('资料/sub/a.txt', false, 'body'),
    ];
    final originals = <DockEntry>[];
    for (var i = 0; i < specs.length; i++) {
      final (relative, directory, text) = specs[i];
      String path;
      if (directory) {
        path = await ReceiveDestination.folderDirectory(
          destinationLocation: inbox.path,
          transferKey: 'old',
          relativePath: relative,
        );
      } else {
        final parent = await ReceiveDestination.folderDirectory(
          destinationLocation: inbox.path,
          transferKey: 'old',
          relativePath: '资料/sub',
        );
        final handle = await ReceiveDestination.create(
          destinationLocation: parent,
          name: 'a.txt',
        );
        path = handle.location;
        await File(handle.ioPath).writeAsString(text);
      }
      originals.add(
        DockEntry(
          id: 'old-$i',
          transferId: 'old',
          fileId: 'old-$i',
          kind: 'file',
          title: relative.split('/').last,
          source: 'sender',
          status: 'received',
          localPath: path,
          relativePath: relative,
          entryKind: directory ? 'directory' : 'file',
          size: utf8.encode(text).length,
          contentDigest: sha256.convert(utf8.encode(text)).toString(),
          receivedAtMillis: DateTime.now()
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        ),
      );
    }
    c.dock = originals;
    await c.refreshSavedFiles();
    expect(c.savedFiles.length, 4);
    final incoming = [
      for (var i = 0; i < specs.length; i++)
        DockEntry(
          id: 'again-$i',
          transferId: 'again',
          fileId: 'again-$i',
          kind: 'file',
          title: i == 0 ? '新名字' : specs[i].$1.split('/').last,
          source: 'other',
          status: 'offered',
          relativePath: '新名字${specs[i].$1.substring(2)}',
          entryKind: specs[i].$2 ? 'directory' : 'file',
          size: utf8.encode(specs[i].$3).length,
          contentDigest: sha256.convert(utf8.encode(specs[i].$3)).toString(),
        ),
    ];
    c.dock = [...incoming, ...originals];
    return (c, api, originals, incoming, inbox);
  }

  test('complete retained tree is reused as one directory with one timestamp and no copy, accept or data', () async {
    final (c, api, old, incoming, inbox) = await setup();
    final savedIds = c.savedFiles.map((item) => item.id).toSet();
    final before = await File(old.last.localPath).lastModified();
    c.profile!.relayConfirmMiB = 0;
    c.info['features']['direct'] = false;
    await c.acceptSelected(
      incoming.first,
      incoming.map((entry) => entry.fileId).toList(),
      reconcileAfter: false,
    );
    expect(api.calls, ['POST /transfers/again/folders/again-0/reuse']);
    expect(api.reuseBody!['files'], hasLength(4));
    expect(
      incoming.map((entry) => entry.localPath),
      old.map((entry) => entry.localPath),
    );
    expect(
      incoming.every(
        (entry) => entry.status == 'received' && entry.progress == 1,
      ),
      true,
    );
    expect(c.savedFiles.map((item) => item.id).toSet(), savedIds);
    expect(
      c.savedFiles.every(
        (item) =>
            item.receivedAtMillis ==
            DateTime.parse(api.receivedAt).millisecondsSinceEpoch,
      ),
      true,
    );
    expect(await File(old.last.localPath).lastModified(), before);
    expect((await inbox.list().toList()).length, 1);
    expect(await Directory('${old.first.localPath}/空目录').exists(), true);
    expect(await File(old.last.localPath).readAsString(), 'body');
    final reopened = SavedFilesStore(
      indexFile: File('${c.root!.path}/saved-files.json'),
      documentsDirectory: await c.documentsDirectory(),
    );
    await reopened.load();
    expect(reopened.items.length, 4);
  });
  for (final changed in [
    'same-size bytes',
    'missing empty directory',
    'extra file',
  ]) {
    test(
      '$changed prevents whole-folder reuse without splitting into old loose files',
      () async {
        final (c, api, old, incoming, _) = await setup();
        if (changed == 'same-size bytes')
          await File(old.last.localPath).writeAsString('BODY');
        if (changed == 'missing empty directory')
          await Directory(old[1].localPath).delete();
        if (changed == 'extra file')
          await File('${old.first.localPath}/user-added.txt')
              .writeAsString('user');
        await c.acceptSelected(
          incoming.first,
          incoming.map((entry) => entry.fileId).toList(),
          reconcileAfter: false,
        );
        expect(api.calls, ['POST /transfers/again/accept']);
        expect(incoming.every((entry) => entry.localPath.isEmpty), true);
      },
    );
  }
  test('a partial selection and old centers use the existing folder receive contract', () async {
    for (final feature in [false, true]) {
      final (c, api, _, incoming, _) = await setup(feature: feature);
      await c.acceptSelected(
        incoming.first,
        feature
            ? [incoming.first.fileId]
            : incoming.map((entry) => entry.fileId).toList(),
        reconcileAfter: false,
      );
      expect(api.calls, ['POST /transfers/again/accept']);
    }
  });
  test('a stale accepted-folder race restores every path instead of mixing two roots', () async {
    final (c, api, _, incoming, _) = await setup();
    api.failure = 'TRANSFER_STARTED';
    await c.acceptSelected(
      incoming.first,
      incoming.map((entry) => entry.fileId).toList(),
      reconcileAfter: false,
    );
    expect(api.calls, [
      'POST /transfers/again/folders/again-0/reuse',
      'POST /transfers/again/accept',
    ]);
    expect(incoming.every((entry) => entry.localPath.isEmpty), true);
  });
  test('pause on one member suppresses reuse of the entire root', () async {
    final (c, api, _, incoming, _) = await setup();
    incoming.last.locallyPaused = true;
    incoming.last.status = 'paused';
    await c.acceptSelected(
      incoming.first,
      incoming.map((entry) => entry.fileId).toList(),
      reconcileAfter: false,
    );
    expect(api.calls, isEmpty);
  });

  test('lost folder acknowledgement preserves all bindings for one receipt recovery', () async {
    final (c, api, old, incoming, _) = await setup();
    api.failure = 'ACK_LOST';
    await expectLater(
      c.acceptSelected(
        incoming.first,
        incoming.map((entry) => entry.fileId).toList(),
        reconcileAfter: false,
      ),
      throwsA(isA<ApiException>()),
    );
    expect(
      incoming.map((entry) => entry.localPath),
      old.map((entry) => entry.localPath),
    );
    final state = jsonDecode(
      await File('${c.root!.path}/${c.profile!.storageKey}.json')
          .readAsString(),
    );
    expect(
      (state['dock'] as List)
          .where((value) => value['transferId'] == 'again')
          .every((value) => (value['localPath'] as String).isNotEmpty),
      true,
    );
    c.updateTransfer({
      'transferId': 'again',
      'sourceDeviceId': 'sender',
      'targetDeviceId': c.profile!.deviceId,
      'files': [
        for (var i = 0; i < incoming.length; i++)
          {
            ...api.receipts[i],
            'name': incoming[i].title,
            'relativePath': incoming[i].relativePath,
            'entryKind': incoming[i].entryKind,
            'sha256': incoming[i].contentDigest,
          },
      ],
    });
    await c.refreshSavedFiles();
    expect(incoming.every((entry) => entry.status == 'received'), true);
    expect(c.savedFiles.length, 4);
    expect(
      c.savedFiles.every(
        (item) =>
            item.receivedAtMillis ==
            DateTime.parse(api.receivedAt).millisecondsSinceEpoch,
      ),
      true,
    );
    await c.persistenceIdle;
  });

  test('Android document-tree matching reads original URI leases and keeps an unavailable tree indexed', () async {
    final work = await fixtureDirectory(),
        owner = profile(),
        payload = File('${work.path}/provider-bytes');
    await payload.writeAsString('body');
    final store = SavedFilesStore(
      indexFile: File('${work.path}/uri-index.json'),
      documentsDirectory: work,
    );
    final originals = [
      DockEntry(
        id: 'root',
        transferId: 'old',
        fileId: 'root',
        kind: 'file',
        title: '资料',
        source: 'sender',
        status: 'received',
        relativePath: '资料',
        entryKind: 'directory',
        localPath: 'content://retained/document/root',
      ),
      DockEntry(
        id: 'empty',
        transferId: 'old',
        fileId: 'empty',
        kind: 'file',
        title: '空',
        source: 'sender',
        status: 'received',
        relativePath: '资料/空',
        entryKind: 'directory',
        localPath: 'content://retained/document/empty',
      ),
      DockEntry(
        id: 'body',
        transferId: 'old',
        fileId: 'body',
        kind: 'file',
        title: 'a.txt',
        source: 'sender',
        status: 'received',
        relativePath: '资料/a.txt',
        localPath: 'content://retained/document/body',
        size: 4,
        contentDigest: sha256.convert(utf8.encode('body')).toString(),
      ),
    ];
    var opened = 0, closed = 0, available = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReceiveDestination.channel, (
      call,
    ) async {
      final location = call.arguments['location'] as String? ?? '';
      if (call.method == 'isOwned') return true;
      if (call.method == 'stat')
        return {
          'location': location,
          'name': location.split('/').last,
          'size': location.endsWith('/body') ? 4 : 0,
          'exists': true,
        };
      if (call.method == 'open') {
        opened++;
        return {
          'location': location,
          'ioPath': payload.path,
          'handle': 'original-lease',
          'name': 'a.txt',
          'size': 4,
        };
      }
      if (call.method == 'close') {
        closed++;
        return null;
      }
      throw StateError('Unexpected document call: ${call.method}');
    });
    messenger.setMockMethodCallHandler(DockPlatform.channel, (call) async {
      expect(call.method, 'directoryEntries');
      if (!available) throw PlatformException(code: 'GRANT_UNAVAILABLE');
      return [
        for (final entry in originals)
          {
            'location': entry.localPath,
            'relativePath': entry.relativePath,
            'entryKind': entry.entryKind,
          },
      ];
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(ReceiveDestination.channel, null),
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(DockPlatform.channel, null),
    );
    for (final entry in originals)
      await store.register(profile: owner, entry: entry, managedLocation: true);
    final incoming = [
      for (final entry in originals)
        DockEntry(
          id: 'new-${entry.id}',
          transferId: 'again',
          fileId: 'new-${entry.fileId}',
          kind: 'file',
          title: entry.title,
          source: 'sender',
          relativePath: entry.relativePath,
          entryKind: entry.entryKind,
          size: entry.size,
          contentDigest: entry.contentDigest,
        ),
    ];
    final matched = await store.reusableFolder(incoming);
    expect(matched!.length, 3);
    expect(matched['new-body']!.path, originals.last.localPath);
    expect(opened, 1);
    expect(closed, 1);
    available = false;
    expect(await store.reusableFolder(incoming), isNull);
    expect(store.items.length, 3);
    expect(await payload.readAsString(), 'body');
  });
}
