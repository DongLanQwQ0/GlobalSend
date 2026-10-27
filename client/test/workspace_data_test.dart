import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/group_shared_text.dart';
import 'package:globalsend/models.dart';

class SharedApi extends CenterApi {
  SharedApi() : super('http://fixture', token: 'test');
  Map<String, dynamic> document = {
    'text': '',
    'revision': 0,
    'updatedBy': '',
    'updatedAt': '',
    'mutationId': '',
  };
  int writes = 0;
  Completer<void>? wait;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    expect(path, '/group/shared-text');
    if (method == 'GET') return {...document};
    writes++;
    final request = body as Map;
    if (request['baseRevision'] != document['revision']) {
      throw ApiException(
        409,
        '冲突',
        response: {
          'current': {...document},
        },
      );
    }
    document = {
      'text': request['text'],
      'revision': (document['revision'] as int) + 1,
      'updatedBy': 'self',
      'updatedAt': '2026-10-25T00:00:00Z',
      'mutationId': request['mutationId'],
    };
    await wait?.future;
    return {...document};
  }
}

class FolderApi extends CenterApi {
  FolderApi() : super('https://fixture', token: 'test');
  final List<Map<String, dynamic>> transfers = [];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    expect(method, 'POST');
    expect(path, '/transfers');
    final request = Map<String, dynamic>.from(body as Map);
    final transfer = {
      ...request,
      'sourceDeviceId': 'self',
      'files': [
        for (final file in request['files'])
          {
            ...Map<String, dynamic>.from(file),
            'status': 'offered',
            'offset': 0,
            'transport': 'direct',
          },
      ],
    };
    transfers.add(transfer);
    return {'transfer': transfer};
  }
}

Future<Directory> fixture() async {
  final parent = await Directory('build/test-tmp/workspace-data')
      .create(recursive: true);
  final directory = await parent.createTemp('case-');
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'shared text conflict retains draft and both explicit resolutions work',
    () async {
      final api = SharedApi();
      final editor = GroupSharedText(onChanged: () {})
        ..connect(api, enabled: true);
      addTearDown(editor.reset);
      addTearDown(api.close);
      await editor.refresh();
      editor.setDraft('本地草稿');
      api.document = {
        ...api.document,
        'text': '另一台设备',
        'revision': 1,
        'mutationId': 'other',
      };
      await editor.save();
      expect(editor.text, '本地草稿');
      expect(editor.remoteText, '另一台设备');
      expect(editor.conflict, isTrue);
      await editor.keepMine();
      expect(api.document['text'], '本地草稿');
      expect(editor.conflict, isFalse);
      editor.setDraft('尚未提交');
      editor.applyRemote({
        ...api.document,
        'text': '远端更新',
        'revision': 3,
        'mutationId': 'remote',
      });
      editor.useRemote();
      expect(editor.text, '远端更新');
      expect(editor.dirty, isFalse);
    },
  );

  test(
    'shared text preserves typing during own PUT and reconnects dirty text',
    () async {
      final api = SharedApi()..wait = Completer<void>();
      final editor = GroupSharedText(onChanged: () {})
        ..connect(api, enabled: true);
      addTearDown(editor.reset);
      addTearDown(api.close);
      editor.setDraft('第一段');
      final pending = editor.save();
      editor.setDraft('第一段继续写');
      editor.applyRemote(api.document);
      api.wait!.complete();
      await pending;
      expect(editor.text, '第一段继续写');
      expect(editor.dirty, isTrue);
      expect(editor.conflict, isFalse);
      editor.disconnected();
      editor.setDraft('离线草稿');
      expect(editor.status, '离线待同步');
      editor.connect(api, enabled: true);
      await editor.refresh();
      await editor.save();
      expect(api.document['text'], '离线草稿');
      expect(editor.dirty, isFalse);
    },
  );

  test('directory staging preserves hierarchy and empty directories, then removes only archive', () async {
    final directory = await fixture();
    final source = await Directory('${directory.path}/资料').create();
    await Directory('${source.path}/空目录').create();
    await Directory('${source.path}/nested').create();
    final original = await File('${source.path}/nested/正文.html')
        .writeAsString('<h1>原文</h1>');
    final c = SendController(
      stateDirectory: () async => Directory('${directory.path}/state'),
    );
    addTearDown(c.dispose);
    await c.stageInputs([source.path], []);
    final archivePath = c.stagedFiles.single;
    expect(c.stagedDirectoryNames[archivePath], '资料');
    final archive = ZipDecoder().decodeBytes(
      await File(archivePath).readAsBytes(),
    );
    expect(
      archive.files.map((file) => file.name),
      containsAll(['资料/', '资料/空目录/', '资料/nested/正文.html']),
    );
    expect(
      utf8.decode(archive.findFile('资料/nested/正文.html')!.content),
      '<h1>原文</h1>',
    );
    await c.removeStagedFile(archivePath);
    expect(await File(archivePath).exists(), isFalse);
    expect(await original.readAsString(), '<h1>原文</h1>');
  });

  test('sent files are external references and deleted originals do not reappear on reconcile', () async {
    final directory = await fixture();
    final original = await File('${directory.path}/source.txt')
        .writeAsString('source');
    final c = SendController()
      ..profile = ServerProfile(
        baseUrl: 'https://fixture',
        instanceId: 'test',
        deviceId: 'self',
      )
      ..root = await Directory('${directory.path}/state').create();
    addTearDown(c.dispose);
    final item = DockEntry(
      id: 'file-id',
      kind: 'file',
      title: 'source.txt',
      source: 'self',
      fileId: 'file-id',
      transferId: 'transfer',
      status: 'received',
      outgoing: true,
      localPath: original.path,
    );
    c.sources[item.fileId] = original.path;
    c.dock = [item];
    await c.deleteDockEntry(item);
    expect(await original.readAsString(), 'source');
    c.updateTransfer({
      'transferId': 'transfer',
      'sourceDeviceId': 'self',
      'targetDeviceId': 'other',
      'files': [
        {'fileId': item.fileId},
      ],
    });
    expect(c.dock, isEmpty);
    final another = DockEntry(
      id: 'missing',
      kind: 'file',
      title: 'source.txt',
      source: 'self',
      fileId: 'missing',
      outgoing: true,
      localPath: original.path,
    );
    c.dock.add(another);
    c.sources['missing'] = original.path;
    await original.delete();
    await c.pruneSentReferences();
    expect(c.dock, isEmpty);
    expect(c.sources, isEmpty);
    final persisted = jsonDecode(
      await File('${c.root!.path}/${c.profile!.key}.json').readAsString(),
    );
    expect(persisted['hiddenDockIds'], containsAll(['file-id', 'missing']));
  });

  test('folder archive survives other active sends, releases on completion and requeues from original', () async {
    final directory = await fixture();
    final source = await Directory('${directory.path}/folder').create();
    await File('${source.path}/source.txt').writeAsString('original');
    final api = FolderApi();
    final c =
        SendController(
            stateDirectory: () async => Directory('${directory.path}/state'),
          )
          ..root = await Directory('${directory.path}/state').create()
          ..api = api
          ..profile = ServerProfile(
            baseUrl: api.baseUrl,
            instanceId: 'test',
            deviceId: 'self',
          )
          ..info = {
            'limits': {'maxFileSize': 1048576},
            'features': <String, dynamic>{},
          };
    addTearDown(c.dispose);
    await c.stageDirectory(source.path);
    final archive = c.stagedFiles.single;
    await c.sendStaged('one');
    await c.stageInputs([archive], []);
    await c.sendStaged('two');
    Map<String, dynamic> completed(Map<String, dynamic> original) => {
      ...original,
      'files': [
        for (final file in original['files'])
          {...Map<String, dynamic>.from(file), 'status': 'received'},
      ],
    };
    c.updateTransfer(completed(api.transfers.first));
    await c.pruneSentReferences();
    expect(await File(archive).exists(), isTrue);
    expect(c.sources, hasLength(2));
    c.updateTransfer(completed(api.transfers.last));
    await c.pruneSentReferences();
    expect(await File(archive).exists(), isFalse);
    expect(c.sources, isEmpty);
    expect(
      c.dock.every(
        (entry) =>
            entry.sourceReference == source.absolute.path &&
            entry.localPath == source.absolute.path,
      ),
      isTrue,
    );
    await c.requeueDockEntry(c.dock.first);
    expect(c.stagedFiles.single, isNot(archive));
    expect(await File(c.stagedFiles.single).exists(), isTrue);
    await c.removeStagedFile(c.stagedFiles.single);
    expect(await File('${source.path}/source.txt').readAsString(), 'original');
  });

  test('dock timestamps persist, old snapshots keep an unknown time rather than fake today', () {
    final entry = DockEntry(
      id: 'one',
      kind: 'text',
      title: '消息',
      source: 'self',
      createdAtMillis: 123,
      receivedAtMillis: 456,
    );
    final decoded = DockEntry.fromJson(entry.toJson());
    expect(decoded.createdAtMillis, 123);
    expect(decoded.receivedAtMillis, 456);
    final old = entry.toJson()
      ..remove('createdAtMillis')
      ..remove('receivedAtMillis');
    expect(DockEntry.fromJson(old).createdAtMillis, 0);
  });
}
