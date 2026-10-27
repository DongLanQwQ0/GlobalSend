import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/local_history.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/vault.dart';

class HistoryFixtureVault extends PlatformVault {
  @override
  Future<String?> read({required String key}) async => null;
}

class HistorySnapshotApi extends CenterApi {
  HistorySnapshotApi(this.events)
    : super('https://fixture.invalid', token: 'fixture');
  final List<Map<String, dynamic>> events;
  final patches = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path == '/devices') return {'devices': <dynamic>[]};
    if (path.startsWith('/events?'))
      return {'events': events, 'cursor': 20, 'hasMore': false};
    if (path == '/transfers') return {'transfers': <dynamic>[]};
    if (method == 'PATCH') {
      patches.add(path);
      return {
        'event': {
          'type': 'text.updated',
          'sourceDeviceId': 'old-peer',
          'cursor': 21,
          'payload': {
            'sourceEventId': 'edited',
            'text': (body as Map)['text'],
            'editedAt': '2030-01-01T00:00:00Z',
          },
        },
      };
    }
    throw StateError('Unexpected fixture request $method $path');
  }
}

class HistoryApi extends CenterApi {
  HistoryApi() : super('https://current.invalid', token: 'public-fixture');
  int calls = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls++;
    throw StateError('A local history action must not call the current group');
  }
}

DockEntry text(String id, {bool outgoing = true}) => DockEntry(
  id: id,
  kind: 'text',
  title: '文本',
  source: 'old-peer',
  text: '保留的正文 $id',
  outgoing: outgoing,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  setUp(() async {
    final parent = await Directory('build/test-tmp/local-history')
        .create(recursive: true);
    directory = await parent.createTemp('case-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('imports ordinary, orphaned and recovery records without decrypting or copying files', () async {
    final p = ServerProfile(
      baseUrl: 'https://old.invalid',
      instanceId: 'old',
      deviceId: 'old-device',
    );
    final original = await File('${directory.path}/original.txt')
        .writeAsString('original');
    final sent = DockEntry(
      id: 'file',
      kind: 'file',
      title: 'original.txt',
      source: 'self',
      fileId: 'file',
      outgoing: true,
      status: 'sent',
    );
    await File('${directory.path}/${p.storageKey}.json').writeAsString(
      jsonEncode({
        'dock': [
          text('old').toJson(),
          sent.toJson(),
          text('legacy-hidden').toJson(),
        ],
        'hiddenDockIds': ['legacy-hidden'],
        'sources': {'file': original.path},
      }),
    );
    final orphanKey = profileKey('https://orphan.invalid', 'orphan');
    await File('${directory.path}/$orphanKey.json').writeAsString(
      jsonEncode({
        'dock': [text('orphan').toJson()],
      }),
    );
    final snapshot = await Directory(
      '${directory.path}/credential-recovery/snapshot',
    ).create(recursive: true);
    await File('${snapshot.path}/manifest.json').writeAsString(
      jsonEncode({'format': 1, 'profileKey': p.key, 'profile': p.toJson()}),
    );
    await File('${snapshot.path}/history.json').writeAsString(
      jsonEncode({
        'dock': [text('old').toJson(), text('snapshot').toJson()],
      }),
    );
    final store = LocalHistoryStore(directory);
    await store.load([p]);
    expect(store.records.values.map((record) => record.entry.id).toSet(), {
      'old',
      'file',
      'orphan',
      'snapshot',
    });
    expect(store.records['${p.key}:file']!.entry.localPath, original.path);
    store.remove('${p.key}:old');
    await store.save();
    final reloaded = LocalHistoryStore(directory);
    await reloaded.load([p]);
    expect(reloaded.records.containsKey('${p.key}:old'), false);
    expect(await original.readAsString(), 'original');
  });

  test('switching groups keeps one local history and old edits and removal stay local', () async {
    final p = ServerProfile(
      baseUrl: 'https://center.invalid',
      instanceId: 'center',
      deviceId: 'old',
      groupId: 'first',
    );
    final controller =
        SendController(
            documentsDirectory: () async => directory,
            stateDirectory: () async => directory,
          )
          ..root = directory
          ..profile = p
          ..profiles = [p]
          ..dock = [text('before')];
    addTearDown(controller.dispose);
    await controller.save();
    p.deviceId = 'new';
    p.groupId = 'second';
    controller.dock = [text('after')];
    final api = HistoryApi();
    controller.api = api;
    await controller.save();
    expect(controller.historyDock.map((entry) => entry.id).toSet(), {
      'before',
      'after',
    });
    final old = controller.historyDock.singleWhere(
      (entry) => entry.id == 'before',
    );
    expect(controller.isLocalHistory(old), true);
    await controller.editSentText(old, '本地继续编辑');
    expect(old.text, '本地继续编辑');
    await controller.stageHistoryEntry(old);
    expect(controller.stagedTexts, ['本地继续编辑']);
    await controller.removeHistoryEntries([old]);
    expect(controller.historyDock.map((entry) => entry.id), ['after']);
    expect(api.calls, 0);
    final store = LocalHistoryStore(directory);
    await store.load([p]);
    expect(
      store.records.values.any((record) => record.entry.id == 'before'),
      false,
    );
  });

  test('a missing archived original disappears without deleting another external original', () async {
    final p = ServerProfile(
      baseUrl: 'https://center.invalid',
      instanceId: 'center',
    );
    final original = await File('${directory.path}/external.bin')
        .writeAsBytes([1, 2, 3]);
    final entry = DockEntry(
      id: 'sent-file',
      kind: 'file',
      title: 'external.bin',
      source: 'self',
      outgoing: true,
      fileId: 'sent-file',
      localPath: original.path,
      status: 'sent',
    );
    final controller =
        SendController(
            documentsDirectory: () async => directory,
            stateDirectory: () async => directory,
          )
          ..root = directory
          ..profile = p
          ..profiles = [p]
          ..dock = [entry];
    addTearDown(controller.dispose);
    await controller.save();
    controller.dock = [];
    final archived = controller.historyDock.single;
    await controller.deleteDockEntry(archived);
    expect(await original.exists(), true);
    final missing = DockEntry(
      id: 'missing',
      kind: 'file',
      title: 'gone.bin',
      source: 'self',
      outgoing: true,
      localPath: '${directory.path}/gone.bin',
      status: 'sent',
    );
    controller.dock = [missing];
    await controller.save();
    controller.dock = [];
    await controller.pruneSentReferences();
    expect(controller.historyDock, isEmpty);
  });

  test('restoring A after B retains archived edits and tombstones against stale events and snapshots', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      expect(request.headers.value('Authorization'), isNull);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'protocolVersion': 1,
          'instanceId': request.uri.path.contains('/b/') ? 'B' : 'A',
        }),
      );
      await request.response.close();
    });
    final a = ServerProfile(
      baseUrl: '$base/a',
      instanceId: 'A',
      deviceId: 'old-peer',
    );
    final b = ServerProfile(
      baseUrl: '$base/b',
      instanceId: 'B',
      deviceId: 'other',
    );
    SendController makeController() =>
        SendController(
            documentsDirectory: () async => directory,
            stateDirectory: () async => directory,
            vault: HistoryFixtureVault(),
          )
          ..root = directory
          ..profiles = [a, b];
    final c = makeController()
      ..profile = a
      ..dock = [text('edited'), text('deleted')];
    addTearDown(c.dispose);
    await c.save();
    final staleState = await File('${directory.path}/${a.storageKey}.json')
        .readAsString();
    await c.connect(b.baseUrl, development: true);
    final archived = c.historyDock.singleWhere((entry) => entry.id == 'edited');
    await c.editSentText(archived, '本地修改保留');
    await c.deleteDockEntry(
      c.historyDock.singleWhere((entry) => entry.id == 'deleted'),
    );
    // Simulate the retained recovery snapshot, which must never undo deletion.
    final snapshot = await Directory(
      '${directory.path}/credential-recovery/stale',
    ).create(recursive: true);
    await File('${snapshot.path}/manifest.json').writeAsString(
      jsonEncode({'format': 1, 'profileKey': a.key, 'profile': a.toJson()}),
    );
    await File('${snapshot.path}/history.json').writeAsString(staleState);
    await c.connect(a.baseUrl, development: true);
    expect(c.dock.map((entry) => entry.id), ['edited']);
    expect(c.dock.single.text, '本地修改保留');
    // Even an unmerged late state/capture cannot overwrite canonical content.
    c.dock = (jsonDecode(staleState)['dock'] as List)
        .map((value) => DockEntry.fromJson(value))
        .toList();
    await c.save();
    expect(c.dock.single.text, '本地修改保留');
    final late = HistorySnapshotApi([
      for (final id in ['edited', 'deleted'])
        {
          'type': 'text.created',
          'eventId': id,
          'sourceDeviceId': 'old-peer',
          'targetDeviceId': 'someone-else',
          'cursor': 10,
          'payload': {'text': '旧快照', 'editedAt': ''},
        },
      {
        'type': 'text.updated',
        'sourceDeviceId': 'old-peer',
        'cursor': 20,
        'payload': {
          'sourceEventId': 'edited',
          'text': '旧事件',
          'editedAt': '2020-01-01T00:00:00Z',
        },
      },
    ]);
    c.api = late;
    c.dock = [];
    await c.reconcile();
    expect(c.dock.map((entry) => entry.id), ['edited']);
    expect(c.dock.single.text, '本地修改保留');
    c.updateTransfer({
      'sourceDeviceId': 'old-peer',
      'transferId': 'stale',
      'files': [
        {'fileId': 'deleted'},
      ],
    });
    expect(c.dock.length, 1);
    // A subsequent explicit active edit is authorized only in A and clears the
    // local-only overlay, allowing the new server-confirmed value to persist.
    await c.editSentText(c.dock.single, '主动更新');
    expect(late.patches, ['/texts/edited']);
    expect(c.dock.single.text, '主动更新');
    await c.persistenceIdle;
    // Global history commits first. If the process stops before the session
    // file replacement, its older revision must still not win on restart.
    await File('${directory.path}/${a.storageKey}.json')
        .writeAsString(staleState);
    final restarted = makeController();
    addTearDown(restarted.dispose);
    await restarted.connect(a.baseUrl, development: true);
    expect(restarted.dock.map((entry) => entry.id), ['edited']);
    expect(restarted.dock.single.text, '主动更新');
    final store = LocalHistoryStore(directory);
    await store.load([a, b]);
    expect(store.isHidden(a.key, 'deleted'), true);
    expect(store.records['${a.key}:edited']!.entry.text, '主动更新');
  });

  test(
    'speed measures byte deltas and never counts an existing resumed prefix',
    () {
      expect(bytesLabel(1024), '1.0 KiB');
      expect(bytesLabel(1048576), '1.0 MiB');
      final entry = DockEntry(
        id: 'rate',
        kind: 'file',
        title: 'file',
        source: 'peer',
      );
      entry.recordTransferBytes(1000000, nowMicros: 0);
      expect(entry.transferBytesPerSecond, 0);
      entry.recordTransferBytes(1002048, nowMicros: 1000000);
      expect(entry.transferBytesPerSecond, 2048);
      entry.recordTransferBytes(0, nowMicros: 2000000);
      expect(entry.transferBytesPerSecond, 0);
    },
  );
}
