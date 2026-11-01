import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

class SourceApi extends CenterApi {
  SourceApi() : super('https://center.invalid', token: 'fixture');
  final publishes = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (method == 'PUT' && path == '/clipboard/files')
      publishes.add(Map<String, dynamic>.from(body as Map));
    return path == '/clipboard/files/pulls'
        ? {'pulls': []}
        : path == '/clipboard/files'
        ? {'offers': []}
        : {};
  }
}

class SourceController extends SendController {
  final sent = <(String, List<String>)>[];
  @override
  Future<void> offer(
    String target,
    List<String> paths, {
    String? routePreferenceOverride,
    Map<String, String>? displayNames,
  }) async {
    sent.add((target, paths.toList()));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native file-copy events remain active when text synchronization stops, without touching drafts', () async {
    final root = await Directory('../artifacts/tmp/copied-files-client')
        .create(recursive: true);
    final directory = await root.createTemp('controller-');
    final file = await File('${directory.path}/copied.txt')
        .writeAsString('fixture');
    final api = SourceApi(), c = SourceController();
    final watches = <bool>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'clipboardWatch')
        watches.add((call.arguments as Map)['enabled'] as bool);
      if (call.method == 'clipboardFilePaths') return <String>[];
      return null;
    });
    try {
      c.api = api;
      c.profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      );
      c.connected = true;
      c.info = {
        'features': {'copiedFiles': true},
      };
      c.devices = [
        {'deviceId': 'phone', 'name': 'Phone', 'online': true},
      ];
      c.stagedTexts.add('keep this draft');
      await c.copiedFiles.connect(api, self: 'self', supported: true);
      await c.setCopiedFilePush(true, []);
      expect(c.copiedFiles.enabled, isTrue);
      expect(c.copiedFiles.sourceReady, isFalse);
      expect(watches.last, isFalse);
      expect(api.publishes, isEmpty);
      await c.setClipboardSync(true, 'phone');
      await c.setCopiedFilePush(true, ['phone']);
      await c.setClipboardSync(false, '');
      await Future<void>.delayed(Duration.zero);
      expect(watches.last, isTrue);
      final delivered = Completer<void>();
      messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('clipboardChanged', {
            'files': [file.path],
            'text': '',
            'sequence': 123,
            'private': false,
            'marker': '',
          }),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
      for (var i = 0; i < 100 && api.publishes.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(api.publishes, hasLength(1));
      final offer = api.publishes.single;
      expect(offer['targetDeviceIds'], ['phone']);
      expect((offer['items'] as List).single['name'], 'copied.txt');
      expect(c.stagedTexts, ['keep this draft']);
      expect(c.stagedFiles, isEmpty);
      expect(c.sent, isEmpty);
      await c.handleServerMessage({
        'type': 'clipboard.files.pull',
        'sourceDeviceId': 'self',
        'targetDeviceId': 'phone',
        'offerId': offer['offerId'],
        'requestId': 'pull',
        'itemIds': [(offer['items'] as List).single['id']],
      });
      expect(c.sent, hasLength(1));
      expect(c.sent.single.$1, 'phone');
      expect(c.sent.single.$2, [file.path]);
      expect(c.stagedTexts, ['keep this draft']);
      expect(c.stagedFiles, isEmpty);
    } finally {
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      api.client.close(force: true);
      messenger.setMockMethodCallHandler(SystemBridge.channel, null);
      await directory.delete(recursive: true);
    }
  });
}
