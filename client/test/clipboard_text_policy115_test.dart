import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'clipboard_image_center_integration_test.dart'
    show RealTransportBinding, clipboardEvent;

void main() {
  RealTransportBinding();
  test('automatic text uses real center limits, writes the selected receiver, and reports rejection without keyword or 8KB filters', () async {
    final parent = await Directory('../artifacts/tmp/clipboard-text115')
        .create(recursive: true);
    final work = await parent.createTemp('center-');
    final process = await Process.start('node', [
      '--import',
      '../server/node_modules/tsx/dist/loader.mjs',
      'tool/start_test_center.mjs',
      work.absolute.path,
    ]);
    final log = File('${work.path}/center.log').openWrite();
    final stderr = process.stderr.transform(utf8.decoder).listen(log.write);
    final base =
        (jsonDecode(
              await process.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .firstWhere((line) => line.startsWith('{'))
                  .timeout(const Duration(seconds: 10)),
            ) as Map)['url']
            as String;
    final clients = <SendController>[];
    final writes = <Map<String, dynamic>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'writeClipboard')
        writes.add(Map<String, dynamic>.from(call.arguments as Map));
      return null;
    });
    Future<void> until(
      bool Function() condition,
      Future<void> Function() refresh,
    ) async {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!condition()) {
        if (DateTime.now().isAfter(deadline))
          throw StateError(
            'Text sync did not converge: ${clients.map((client) => {'status': client.clipboardStatus, 'error': client.clipboardError, 'message': client.message, 'connected': client.connected, 'enabled': client.clipboardEnabled, 'slotLength': client.clipboardSlot?.text.length}).toList()}, writes=${writes.length}',
          );
        await refresh();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    try {
      final info = await CenterApi(base).call('GET', '/info', null, false);
      for (var index = 0; index < 3; index++) {
        final api = CenterApi(base);
        final session = await api.call('POST', '/devices/enroll', {
          'name': 'Isolated text fixture $index',
          'platform': 'windows',
          'groupKey': 'clipboard-text-policy115',
        }, false);
        api.token = session['deviceToken'];
        final state = await Directory('${work.path}/state-$index').create();
        final c =
            SendController(
                stateDirectory: () async => state,
                documentsDirectory: () async =>
                    Directory('${work.path}/files-$index'),
                ipAddresses: () async => [],
              )
              ..root = state
              ..api = api
              ..info = info
              ..profile = ServerProfile(
                baseUrl: base,
                instanceId: info['instanceId'],
                deviceId: session['device']['deviceId'],
                groupId: session['groupId'],
              );
        c.profiles.add(c.profile!);
        clients.add(c);
        await c.clipboard.load(state);
        await c.openSocket(c.generation);
      }
      final source = clients[0], target = clients[1], unselected = clients[2];
      source.devices = [
        {
          'deviceId': target.profile!.deviceId,
          'name': 'Selected',
          'online': true,
        },
      ];
      source.stagedTexts.add('Unrelated draft stays');
      await source.setClipboardSync(true, target.profile!.deviceId);
      const keywords =
          'Example documentation: 验证码=123456; token=fixture-only; password=not-a-real-secret';
      final longText = List.filled(4000, '正文示例').join();
      expect(utf8.encode(longText).length, greaterThan(8192));
      final limit = info['limits']['maxTextLength'] as int;
      final cases = [keywords, longText, List.filled(limit, 'x').join()];
      var sequence = 11500;
      for (final text in cases) {
        stdout.writeln(
          'Clipboard text fixture case: ${text.length} UTF-16 units, ${utf8.encode(text).length} bytes',
        );
        final previous = writes.length;
        await clipboardEvent({'sequence': ++sequence, 'text': text});
        await until(() => writes.length > previous, () async {
          await target.reconcile();
          await source.reconcile();
        });
        expect(target.clipboardSlot?.text, text);
        expect(writes.last['text'], text);
        expect(writes.last['originDeviceId'], source.profile!.deviceId);
        expect(writes.last['private'], isTrue);
        expect(target.dock.where((entry) => !entry.autoClipboard), isEmpty);
        expect(target.receiptSerial, 0);
        expect(target.pendingReceipts, isEmpty);
        expect(source.stagedTexts, ['Unrelated draft stays']);
      }
      final lastValue = target.clipboardSlot!.text, writeCount = writes.length;
      // Real center rejects over its protocol limit; the old slot remains usable.
      await clipboardEvent({
        'sequence': ++sequence,
        'text': List.filled(limit + 1, 'z').join(),
      });
      await until(
        () => source.clipboardStatus == '同步失败',
        () async => target.reconcile(),
      );
      expect(source.clipboardError, isNotEmpty);
      expect(target.clipboardSlot!.text, lastValue);
      expect(writes, hasLength(writeCount));
      // Explicit OS privacy and our own origin marker still cancel forwarding.
      await clipboardEvent({
        'sequence': ++sequence,
        'text': 'Pending should be cancelled',
      });
      await clipboardEvent({
        'sequence': ++sequence,
        'text': 'OS private',
        'private': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await clipboardEvent({
        'sequence': ++sequence,
        'text': 'Remote echo',
        'marker': 'origin/event',
      });
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(writes, hasLength(writeCount));
      final notForThisDevice = await unselected.api!.call(
        'GET',
        '/events?after=0&limit=100',
      );
      expect(
        (notForThisDevice['events'] as List).where(
          (event) => event['type'] == 'text.created',
        ),
        isEmpty,
      );
      await File('${parent.path}/result.json').writeAsString(
        jsonEncode({
          'realCenter': true,
          'keywordsDelivered': true,
          'longUnicodeBytes': utf8.encode(longText).length,
          'protocolLimit': limit,
          'exactBoundaryDelivered': true,
          'overLimitReported': true,
          'selectedReceiverOnly': true,
          'receiverWrites': writes.length,
          'ordinaryReceipts': target.receiptSerial,
          'realOsClipboardAccess': false,
        }),
        flush: true,
      );
    } finally {
      for (final client in clients) client.dispose();
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await stderr.cancel();
      await log.close();
      messenger.setMockMethodCallHandler(SystemBridge.channel, null);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
