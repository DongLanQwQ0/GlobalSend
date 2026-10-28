import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/url_intents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('real center HTTP and WS: native RPC, launch fence, caller isolation and separate history', () async {
    final baseFolder = Directory('build/test-tmp/url-intents-center');
    await baseFolder.create(recursive: true);
    final folder = await baseFolder.createTemp('case-');
    final process = await Process.start(
      'node',
      ['tool/start_test_center.mjs', folder.absolute.path],
      environment: {
        'GLOBALSEND_TEST_BOOTSTRAP': 'url-intent-integration-bootstrap',
      },
    );
    final log = File('${folder.path}/server-stderr.log').openWrite();
    final logSubscription = process.stderr.listen(log.add);
    final clients = <CenterApi>[],
        sockets = <WebSocket>[],
        integrations = <UrlIntentIntegration>[];
    try {
      final startup = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final base = jsonDecode(startup)['url'] as String;
      Future<({CenterApi api, String id})> enroll(
        String name,
        String platform,
      ) async {
        final api = CenterApi(base);
        clients.add(api);
        final row = await api.call('POST', '/devices/enroll', {
          'name': name,
          'platform': platform,
          'groupKey': 'url-intent-integration-group',
        }, false);
        api.token = row['deviceToken'];
        return (api: api, id: row['device']['deviceId'] as String);
      }

      final source = await enroll('Chrona phone', 'android'),
          target = await enroll('Windows target', 'windows');
      await target.api.call('POST', '/devices/me/capabilities', {
        'folderTransfer': true,
        'openUrlIntentV1': true,
      });
      final targetSignals = <String>[];
      for (final device in [source, target]) {
        final ticket = await device.api.call('POST', '/session/ws-ticket', {});
        final uri = device.api
            .uri('/ws')
            .replace(
              scheme: 'ws',
              queryParameters: {'ticket': ticket['ticket']},
            );
        final socket = await WebSocket.connect(uri.toString());
        sockets.add(socket);
        final hello = Completer<void>();
        socket.listen((raw) {
          final event = jsonDecode(raw as String);
          if (event['type'] == 'hello' && !hello.isCompleted) hello.complete();
          if (device.id == target.id)
            targetSignals.add(event['type'] as String);
        });
        await hello.future.timeout(const Duration(seconds: 5));
      }
      List<Map<String, dynamic>> devices = [];
      Future<void> refresh() async {
        devices = List<Map<String, dynamic>>.from(
          (await source.api.call('GET', '/devices'))['devices'],
        );
      }

      await refresh();
      final sender = UrlIntentIntegration(
        session: () => UrlIntentSession(
          api: source.api,
          scope: 'source',
          deviceId: source.id,
          supported: true,
        ),
        devices: () => devices,
        refreshDevices: refresh,
        changed: () {},
        platform: 'windows',
        openWebUrl: (_) async => fail('Source cannot launch'),
      );
      integrations.add(sender);
      await sender.initialize(File('${folder.path}/source.json'));
      var launches = 0;
      UrlIntentIntegration makeReceiver() => UrlIntentIntegration(
        session: () => UrlIntentSession(
          api: target.api,
          scope: 'target',
          deviceId: target.id,
          supported: true,
        ),
        devices: () => [],
        refreshDevices: () async {},
        changed: () {},
        platform: 'windows',
        openWebUrl: (url) async {
          expect(url.toString(), 'http://10.194.43.84:8765/');
          launches++;
        },
      );
      var receiver = makeReceiver();
      integrations.add(receiver);
      await receiver.initialize(File('${folder.path}/target.json'));
      const requestId = '11111111-2222-3333-4444-555555555555';
      Future<Map<String, dynamic>> local(
        String method, {
        String caller = 'com.donglan.chrona',
      }) => sender.handleLocalRequest({
        'callerAppId': caller,
        'request': {
          'v': 1,
          'requestId': requestId,
          'method': method,
          'targetDeviceId': target.id,
          'url': 'http://10.194.43.84:8765/',
          'expiresInMs': 120000,
        },
      });
      final created = await local('send_open_url');
      expect(created['ok'], true);
      expect(created['result']['state'], 'queued');
      for (
        var attempts = 0;
        !targetSignals.contains('url_intents.changed') && attempts < 100;
        attempts++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(targetSignals, contains('url_intents.changed'));
      await receiver.synchronize();
      expect(launches, 1);
      expect((await local('status'))['result']['state'], 'launch_accepted');
      expect(
        (await local('status', caller: 'other.application'))['error']['code'],
        'request_not_found',
      );
      expect(
        (await local('send_open_url'))['result']['state'],
        'launch_accepted',
      );
      receiver.dispose();
      receiver = makeReceiver();
      integrations.add(receiver);
      await receiver.initialize(File('${folder.path}/target.json'));
      await receiver.synchronize();
      expect(launches, 1);
      final events = await target.api.call('GET', '/events');
      expect(events['events'], isEmpty);
      final records =
          jsonDecode(
                await File('${folder.path}/target.json').readAsString(),
              )['records']
              as Map;
      expect(records.values.single['state'], 'launch_accepted');
      expect(records.values.single.containsKey('url'), false);
    } finally {
      for (final integration in integrations) {
        integration.dispose();
      }
      for (final socket in sockets) {
        await socket.close();
      }
      for (final api in clients) {
        api.close();
      }
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await logSubscription.cancel();
      await log.close();
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
