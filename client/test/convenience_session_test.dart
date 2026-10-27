import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/vault.dart';

class MemoryVault extends PlatformVault {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async { values[key] = value; }
}

class RestoreController extends SendController {
  RestoreController(PlatformVault vault) : super(vault: vault);
  bool started = false;
  @override
  Future<void> start() async { started = true; }
}

class PausedSaveController extends SendController {
  final saved = Completer<void>();
  @override
  Future<void> save() => saved.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These are real loopback controller tests, not mocked image-fetch widgets.
  HttpOverrides.global = null;
  test('startup restores the recent login without sending its token to a replaced instance', () async {
    final directory = Directory(Platform.environment['GLOBALSEND_DATA_DIR']!);
    if (!directory.absolute.uri.toString().startsWith(Directory('build/test-tmp').absolute.uri.toString())) {
      throw StateError('Startup test needs its own directory inside build/test-tmp.');
    }
    await directory.create(recursive: true);
    var instance = 'original';
    final auth = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      auth.add(request.headers.value('authorization'));
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'protocolVersion': 1, 'instanceId': instance}));
      await request.response.close();
    });
    final p = ServerProfile(baseUrl: 'http://127.0.0.1:${server.port}', instanceId: instance, deviceId: 'saved-device', groupId: 'saved-group', autoReceive: false);
    await File('${directory.path}/profiles.json').writeAsString(jsonEncode([p.toJson()]));
    await File('${directory.path}/recent-center.json').writeAsString(jsonEncode({'profileKey': p.key}));
    final vault = MemoryVault()..values['token_${p.key}'] = 'saved-token';
    final first = RestoreController(vault);
    RestoreController? replacement;
    try {
      await first.init();
      expect(first.started, isTrue);
      expect(first.api!.token, 'saved-token');
      expect(first.profile!.autoReceive, isFalse);
      first.dispose();
      instance = 'reinstalled';
      replacement = RestoreController(vault);
      await replacement.init();
      expect(replacement.started, isFalse);
      expect(replacement.profile!.instanceId, 'reinstalled');
      expect(replacement.api!.token, isEmpty);
      expect(auth, [null, null]);
    } finally {
      if (!first.disposed) first.dispose();
      replacement?.dispose();
      await server.close(force: true);
    }
  }, skip: Platform.environment['GLOBALSEND_DATA_DIR'] == null ? 'Set GLOBALSEND_DATA_DIR to an isolated project build/test-tmp directory.' : false);

  test('switching session during save does not send the old text to the new center', () async {
    var requests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async { requests++; request.response.write('{}'); await request.response.close(); });
    final old = CenterApi('http://127.0.0.1:${server.port}', token: 'old');
    final c = PausedSaveController()
      ..api = old
      ..profile = ServerProfile(baseUrl: old.baseUrl, instanceId: 'old', deviceId: 'old-device');
    try {
      final sending = c.sendText('old-target', 'old-session text');
      final rejected = expectLater(sending, throwsStateError);
      c.generation++;
      c.api = CenterApi(old.baseUrl, token: 'new');
      c.profile = ServerProfile(baseUrl: old.baseUrl, instanceId: 'new', deviceId: 'new-device');
      c.pendingTexts = {};
      c.saved.complete();
      await rejected;
      expect(requests, 0);
      expect(c.pendingTexts, isEmpty);
    } finally { c.dispose(); old.close(); await server.close(force: true); }
  });

  test('late unauthorized response cannot revoke a newer active session', () async {
    final requested = Completer<void>(), release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requested.complete(); await release.future;
      request.response.statusCode = 401;
      request.response.write('{"error":{"message":"old token revoked"}}');
      await request.response.close();
    });
    final old = CenterApi('http://127.0.0.1:${server.port}', token: 'old');
    final c = SendController()..api = old
      ..profile = ServerProfile(baseUrl: old.baseUrl, instanceId: 'old', deviceId: 'old-device');
    try {
      final syncing = c.safeReconcile();
      await requested.future;
      c.generation++;
      c.api = CenterApi(old.baseUrl, token: 'new-token');
      c.profile = ServerProfile(baseUrl: old.baseUrl, instanceId: 'new', deviceId: 'new-device');
      c.connection = 'new active session';
      release.complete(); await syncing;
      expect(c.api!.token, 'new-token');
      expect(c.connection, 'new active session');
      expect(c.message, isEmpty);
    } finally { c.dispose(); old.close(); await server.close(force: true); }
  });
}
