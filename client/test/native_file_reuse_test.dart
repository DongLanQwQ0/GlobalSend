import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files.dart';

import 'saved_files_test.dart' show fixtureDirectory, profile, savedEntry;

class ReuseApi extends CenterApi {
  ReuseApi() : super('https://fixture.invalid', token: 'fixture');
  final calls = <String>[];
  Map<String, dynamic>? reusedBody;
  String? reuseError;
  final receivedAt = DateTime.now().toUtc().toIso8601String();

  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    if (path.endsWith('/reuse')) {
      reusedBody = Map<String, dynamic>.from(body as Map);
      if (reuseError != null) {
        throw ApiException(
          409,
          'already started',
          response: {
            'error': {'code': reuseError},
          },
        );
      }
      return {
        'file': {
          'fileId': 'again',
          'status': 'received',
          'transport': 'direct',
          'reused': true,
          'receivedAt': receivedAt,
        },
      };
    }
    if (path.endsWith('/accept')) return {};
    throw StateError('Unexpected payload or route request: $method $path');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(SendController, ReuseApi, DockEntry, DockEntry)> setup({
    bool feature = true,
    bool legacyDigest = false,
  }) async {
    final folder = await fixtureDirectory(), owner = profile();
    final documents = Directory('${folder.path}/documents');
    final original = await savedEntry(documents, owner, 'original');
    original.contentDigest = legacyDigest
        ? ''
        : sha256.convert([65, 65, 65, 65]).toString();
    original.receivedAtMillis = DateTime.now()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    final api = ReuseApi();
    final c = SendController(documentsDirectory: () async => documents)
      ..root = Directory('${folder.path}/state')
      ..profile = owner
      ..profiles = [owner]
      ..api = api
      ..info = {
        'features': {'fileReuse': feature, 'direct': true},
      }
      ..dock = [original];
    addTearDown(c.dispose);
    await c.refreshSavedFiles();
    // The same client can change groups/server identity and retain its files.
    c.profile = ServerProfile(
      baseUrl: owner.baseUrl,
      instanceId: 'new-center',
      deviceId: 'new-device',
      groupId: 'new-group',
    );
    c.profiles.add(c.profile!);
    final incoming = DockEntry(
      id: 'again',
      fileId: 'again',
      transferId: 'new',
      kind: 'file',
      title: 'renamed-file.txt',
      source: 'other-source',
      size: 4,
      status: 'offered',
      contentDigest: sha256.convert([65, 65, 65, 65]).toString(),
    );
    c.dock.insert(0, incoming);
    return (c, api, original, incoming);
  }

  test('repeated file refreshes one saved owner and time, without accept/data/route or copying', () async {
    final (c, api, original, incoming) = await setup();
    final savedId = c.savedFiles.single.id;
    final originalModified = await File(original.localPath).lastModified();
    await c.acceptSelected(incoming, [incoming.fileId], reconcileAfter: false);
    expect(api.calls, ['POST /transfers/new/files/again/reuse']);
    expect(api.reusedBody, {'sha256': incoming.contentDigest, 'size': 4});
    expect(incoming.status, 'received');
    expect(incoming.progress, 1);
    expect(incoming.localPath, File(original.localPath).absolute.path);
    expect(c.savedFiles.single.id, savedId);
    expect(
      c.savedFiles.single.receivedAtMillis,
      DateTime.parse(api.receivedAt).millisecondsSinceEpoch,
    );
    expect(original.receivedAtMillis, incoming.receivedAtMillis);
    expect(await File(original.localPath).lastModified(), originalModified);
    await c.refreshSavedFiles();
    expect(c.savedFiles, hasLength(1));
    final restarted = SavedFilesStore(
      indexFile: File('${c.root!.path}/saved-files.json'),
      documentsDirectory: await c.documentsDirectory(),
    );
    await restarted.load();
    expect(restarted.items.single.contentDigest, incoming.contentDigest);
    expect(
      await restarted.prune(DateTime.now().add(const Duration(hours: 23))),
      isEmpty,
    );
    await c.deleteSavedFiles([savedId]);
    expect(await File(original.localPath).exists(), false);
    expect(c.dock.where((entry) => !entry.outgoing), isEmpty);
  });

  test('legacy saved entry without digest is verified and reused', () async {
    final (c, api, _, incoming) = await setup(legacyDigest: true);
    await c.acceptSelected(incoming, [incoming.fileId], reconcileAfter: false);
    expect(api.calls.single, endsWith('/reuse'));
    expect(c.savedFiles.single.contentDigest, incoming.contentDigest);
  });

  test(
    'local reuse precedes relay confirmation and repeated accept clicks',
    () async {
      final (c, api, _, incoming) = await setup();
      c.profile!.relayConfirmMiB = 0;
      c.info['features']['direct'] = false;
      incoming.offerRoutePreference = 'relay';
      await Future.wait([
        c.acceptSelected(incoming, [incoming.fileId], reconcileAfter: false),
        c.acceptSelected(incoming, [incoming.fileId], reconcileAfter: false),
      ]);
      expect(api.calls, ['POST /transfers/new/files/again/reuse']);
      expect(incoming.relayConfirmationPending, false);
      expect(incoming.status, 'received');
    },
  );

  for (final removed in [false, true]) {
    test(
      '${removed ? 'deleted' : 'modified same-size'} local bytes use ordinary transfer',
      () async {
        final (c, api, original, incoming) = await setup();
        if (removed) {
          await File(original.localPath).delete();
        } else {
          await File(original.localPath).writeAsBytes([66, 66, 66, 66]);
        }
        await c.acceptSelected(incoming, [
          incoming.fileId,
        ], reconcileAfter: false);
        expect(api.calls, ['POST /transfers/new/accept']);
        expect(incoming.localPath, isEmpty);
      },
    );
  }

  test(
    'old center remains on ordinary accept without new feature prerequisite',
    () async {
      final (c, api, _, incoming) = await setup(feature: false);
      await c.acceptSelected(incoming, [
        incoming.fileId,
      ], reconcileAfter: false);
      expect(api.calls, ['POST /transfers/new/accept']);
    },
  );

  test(
    'folder member never reuses an unrelated ordinary-file location',
    () async {
      final (c, api, _, incoming) = await setup();
      incoming.relativePath = 'folder/renamed-file.txt';
      await c.acceptSelected(incoming, [
        incoming.fileId,
      ], reconcileAfter: false);
      expect(api.calls, ['POST /transfers/new/accept']);
    },
  );

  test(
    'payload already started falls back without retaining cached binding',
    () async {
      final (c, api, _, incoming) = await setup();
      api.reuseError = 'TRANSFER_STARTED';
      await c.acceptSelected(incoming, [
        incoming.fileId,
      ], reconcileAfter: false);
      expect(api.calls, [
        'POST /transfers/new/files/again/reuse',
        'POST /transfers/new/accept',
      ]);
      expect(incoming.localPath, isEmpty);
    },
  );

  test('received server snapshot recovers local receipt time after lost acknowledgement', () async {
    final (c, api, original, incoming) = await setup();
    incoming.localPath = original.localPath;
    c.updateTransfer({
      'transferId': 'new',
      'sourceDeviceId': 'other-source',
      'targetDeviceId': c.profile!.deviceId,
      'files': [
        {
          'fileId': 'again',
          'name': incoming.title,
          'size': 4,
          'offset': 0,
          'status': 'received',
          'transport': 'direct',
          'sha256': incoming.contentDigest,
          'reused': true,
          'receivedAt': api.receivedAt,
        },
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await c.refreshSavedFiles();
    expect(c.savedFiles, hasLength(1));
    expect(
      c.savedFiles.single.receivedAtMillis,
      DateTime.parse(api.receivedAt).millisecondsSinceEpoch,
    );
  });
}
