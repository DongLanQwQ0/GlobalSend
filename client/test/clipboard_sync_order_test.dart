import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'clipboard_image_center_integration_test.dart' show clipboardEvent;

class ClipboardApi extends CenterApi {
  ClipboardApi() : super('http://127.0.0.1:1', token: 'fixture');
  final sent = <Map>[];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path == '/texts' || path == '/transfers')
      sent.add({'path': path, ...body as Map});
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('empty/private replacements cancel pending text; newer text suppresses in-flight screenshot and removes only its snapshot', () async {
    final root = await Directory('../artifacts/tmp/clipboard-image101')
        .create(recursive: true);
    final work = await root.createTemp('order-');
    final api = ClipboardApi();
    final c = SendController(stateDirectory: () async => work)
      ..root = work
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      )
      ..connected = true
      ..devices = [
        {'deviceId': 'target', 'name': 'Target', 'online': true},
      ]
      ..info = {
        'features': {'clipboardImages': true},
      };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final reading = Completer<void>(), release = Completer<void>();
    String? snapshot;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'readClipboard') {
        snapshot = (call.arguments as Map)['bitmapPath'] as String;
        await File(snapshot!).writeAsBytes([1, 2, 3]);
        reading.complete();
        await release.future;
        return {
          'paths': [snapshot!],
          'temporaryPaths': [snapshot!],
        };
      }
      return null;
    });
    try {
      await c.setClipboardSync(true, 'target');
      await clipboardEvent({'sequence': 1, 'text': 'old text'});
      await clipboardEvent({'sequence': 2, 'text': ''});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(api.sent, isEmpty);
      await clipboardEvent({'sequence': 3, 'text': 'also old'});
      await clipboardEvent({'sequence': 4, 'text': 'private', 'private': true});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(api.sent, isEmpty);
      await clipboardEvent({'sequence': 5, 'kind': 'image'});
      await reading.future.timeout(const Duration(seconds: 3));
      await clipboardEvent({'sequence': 6, 'text': 'latest'});
      release.complete();
      final watch = Stopwatch()..start();
      while (api.sent.isEmpty && watch.elapsedMilliseconds < 2000)
        await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(api.sent, hasLength(1));
      expect(api.sent.single['path'], '/texts');
      expect(api.sent.single['text'], 'latest');
      expect(await File(snapshot!).exists(), isFalse);
      expect(c.sources, isEmpty);
      expect(c.stagedTexts, isEmpty);
      expect(c.stagedFiles, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      c.dispose();
      messenger.setMockMethodCallHandler(SystemBridge.channel, null);
      await work.delete(recursive: true);
    }
  });
}
