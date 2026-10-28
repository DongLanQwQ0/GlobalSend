import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/app_updates.dart';
import 'package:globalsend/vault.dart';

class QuietUpdates extends AppUpdates {
  @override
  Future<void> initialize(File file) async {}
}

class LoopbackHttp extends HttpOverrides {}

class FixtureVault extends PlatformVault {
  @override
  Future<String?> read({required String key}) async => 'fixture-token';
  @override
  Future<void> write({required String key, required String value}) async {}
}

class LibraryFailureController extends SendController {
  LibraryFailureController(Directory root)
    : super(
        stateDirectory: () async => root,
        documentsDirectory: () async => Directory('${root.path}/documents'),
        ipAddresses: () async => [],
        vault: FixtureVault(),
        updates: QuietUpdates(),
      );
  final libraryGate = Completer<void>();
  int starts = 0;
  @override
  Future<void> refreshSavedFiles({bool cleanup = false}) async {
    await libraryGate.future;
    throw PlatformException(
      code: 'RECEIVE_DIRECTORY',
      message: 'missing external document',
    );
  }

  @override
  Future<void> start() async {
    starts++;
    connected = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a blocked or failing library cannot prevent restoring the existing login',
    () async {
      final parent = await Directory('build/test-tmp/provider-login')
          .create(recursive: true);
      final root = await parent.createTemp('case-');
      final center = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      center.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'protocolVersion': 1, 'instanceId': 'fixture'}),
        );
        await request.response.close();
      });
      final profile = ServerProfile(
        baseUrl: 'http://127.0.0.1:${center.port}',
        instanceId: 'fixture',
        deviceId: 'original-device',
        groupId: 'original-group',
      );
      final original = DockEntry(
        id: 'kept-history',
        kind: 'text',
        title: 'text',
        source: 'phone',
        text: 'keep my history',
      );
      await File('${root.path}/profiles.json')
          .writeAsString(jsonEncode([profile.toJson()]));
      await File('${root.path}/${profile.storageKey}.json').writeAsString(
        jsonEncode({
          'dock': [original.toJson()],
        }),
      );
      final c = LibraryFailureController(root);
      addTearDown(() async {
        if (!c.libraryGate.isCompleted) c.libraryGate.complete();
        c.dispose();
        await c.persistenceIdle;
        await center.close(force: true);
        await root.delete(recursive: true);
      });
      await HttpOverrides.runWithHttpOverrides(c.init, LoopbackHttp());
      expect(c.libraryGate.isCompleted, false);
      expect(c.starts, 1);
      expect(c.connected, true);
      expect(c.profile!.deviceId, 'original-device');
      expect(c.profile!.groupId, 'original-group');
      expect(c.api!.token, 'fixture-token');
      final reported = Completer<void>();
      c.addListener(() {
        if (c.savedFilesIssue.isNotEmpty && !reported.isCompleted)
          reported.complete();
      });
      c.libraryGate.complete();
      await reported.future;
      await c.localLibraryIdle;
      expect(c.connected, true);
      expect(c.credentialProblem, null);
      expect(c.historyDock.any((entry) => entry.id == original.id), true);
      expect(c.message, isNot(contains('本地配置读取失败')));
      expect(c.savedFilesIssue, isNot(contains('PlatformException')));
    },
  );
  test(
    'one unavailable provider does not stop pruning confirmed missing files',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReceiveDestination.channel, (
        call,
      ) async {
        final location = (call.arguments as Map)['location'];
        if (location == 'content://fixture/denied') {
          throw PlatformException(
            code: 'RECEIVE_DIRECTORY',
            message: 'permission denied',
          );
        }
        return {
          'location': location,
          'name': 'file.jpg',
          'size': 10,
          'exists': location != 'content://fixture/missing',
        };
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          ReceiveDestination.channel,
          null,
        ),
      );
      final c = SendController();
      addTearDown(c.dispose);
      for (final id in ['denied', 'missing', 'healthy']) {
        c.dock.add(
          DockEntry(
            id: id,
            kind: 'file',
            title: '$id.jpg',
            source: 'phone',
            status: 'received',
            localPath: 'content://fixture/$id',
          ),
        );
      }
      await c.pruneSentReferences();
      expect(c.dock.map((entry) => entry.id), ['denied', 'healthy']);
    },
  );
}
