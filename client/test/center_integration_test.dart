import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/receive_destination.dart';

Future<void> until(
  bool Function() condition,
  Future<void> Function() refresh,
) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 20)) {
      throw StateError('Integration state did not converge');
    }
    await refresh();
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }
}

void main() {
  test('real center + two native controllers: WS text, pinned direct file and unreachable-peer relay fallback', () async {
    final testRoot = Directory('build/test-tmp');
    await testRoot.create(recursive: true);
    final folder = await testRoot.createTemp('full-stack-');
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${folder.path}/registry');
    final bootstrap = newId();
    final groupKey = newGroupKey();
    final process = await Process.start(
      'node',
      ['tool/start_test_center.mjs', folder.absolute.path],
      environment: {'GLOBALSEND_TEST_BOOTSTRAP': bootstrap},
    );
    final log = File('${folder.path}/center-stderr.log').openWrite();
    final stderrSubscription = process.stderr.listen(log.add);
    SendController? sender, receiver;
    PeerTransport? peer;
    try {
      final startup = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final base = jsonDecode(startup)['url'] as String;
      expect(base, isNot(contains(':8787')));
      final first = CenterApi(base);
      final info = await first.call('GET', '/info', null, false);
      final a = await first.call('POST', '/devices/enroll', {
        'name': 'Dart test A',
        'platform': 'windows',
        'groupKey': groupKey,
      }, false);
      first.token = a['deviceToken'];
      expect(a['createdGroup'], isTrue);
      final second = CenterApi(base);
      final b = await second.call('POST', '/devices/enroll', {
        'name': 'Dart test B',
        'platform': 'android',
        'groupKey': groupKey,
      }, false);
      second.token = b['deviceToken'];
      expect(b['createdGroup'], isFalse);
      expect(a['groupId'], b['groupId']);
      final isolated = CenterApi(base);
      try {
        final third = await isolated.call('POST', '/devices/enroll', {
          'name': 'Different group',
          'platform': 'other',
          'groupKey': newGroupKey(),
        }, false);
        expect(third['groupId'], isNot(a['groupId']));
        await expectLater(
          first.call('POST', '/texts', {
            'eventId': newId(),
            'targetDeviceId': third['device']['deviceId'],
            'text': 'must not cross groups',
          }),
          throwsA(isA<ApiException>()),
        );
      } finally {
        isolated.close();
      }

      sender =
          SendController(
              documentsDirectory: () async =>
                  Directory('${folder.path}/a-files'),
            )
            ..api = first
            ..info = info
            ..profile = ServerProfile(
              baseUrl: base,
              instanceId: info['instanceId'],
              deviceId: a['device']['deviceId'],
            )
            ..root = Directory('${folder.path}/a-state');
      receiver =
          SendController(
              documentsDirectory: () async =>
                  Directory('${folder.path}/b-files'),
            )
            ..api = second
            ..info = info
            ..profile = ServerProfile(
              baseUrl: base,
              instanceId: info['instanceId'],
              deviceId: b['device']['deviceId'],
            )
            ..root = Directory('${folder.path}/b-state');
      final source = sender, target = receiver;
      Future<void> refresh() async {
        await source.reconcile();
        await target.reconcile();
      }

      await source.openSocket(source.generation);
      await target.openSocket(target.generation);
      expect(source.connected && target.connected, isTrue);
      await source.sendText(target.profile!.deviceId, 'A → B：真实中心文本');
      await until(
        () => target.dock.any((d) => d.text == 'A → B：真实中心文本'),
        refresh,
      );
      await target.sendText(source.profile!.deviceId, 'B → A：独立回复');
      await until(
        () => source.dock.any((d) => d.text == 'B → A：独立回复'),
        refresh,
      );

      peer = PeerTransport(first, (id) => source.sources[id]);
      await peer.start(
        createPeerIdentity('integration-source'),
        loopbackOnly: true,
      );
      final bytes = List<int>.generate(1200000, (i) => i % 251);
      final file = File('${folder.path}/direct-中文.bin');
      await file.writeAsBytes(bytes);
      await source.offer(target.profile!.deviceId, [file.path]);
      await until(
        () => target.dock.any(
          (d) => d.kind == 'file' && d.title == 'direct-中文.bin',
        ),
        refresh,
      );
      final direct = target.dock.firstWhere((d) => d.title == 'direct-中文.bin');
      await until(() => direct.status == 'received', refresh);
      expect(target.profile!.autoReceive, isTrue);
      expect(direct.route, 'lan');
      expect(await File(direct.localPath).readAsBytes(), bytes);
      var remote = await first.call('GET', '/transfers/${direct.transferId}');
      expect(remote['transfer']['files'][0]['transport'], 'direct');
      expect(remote['transfer']['files'][0]['offset'], 0);
      expect(remote['transfer']['files'][0]['status'], 'received');

      // Keep the center's authenticated candidate, but make its peer genuinely unreachable.
      await peer.close();
      target.profile!.autoReceive = false;
      final fallbackFile = File('${folder.path}/fallback.bin');
      await fallbackFile.writeAsBytes(bytes);
      await source.offer(target.profile!.deviceId, [fallbackFile.path]);
      await until(
        () => target.dock.any((d) => d.title == 'fallback.bin'),
        refresh,
      );
      final relay = target.dock.firstWhere((d) => d.title == 'fallback.bin');
      await refresh();
      expect(relay.status, 'offered');
      expect(relay.localPath, isEmpty);
      await target.acceptSelected(relay, [relay.fileId]);
      await until(() => relay.status == 'received', refresh);
      expect(relay.route, 'relay');
      expect(relay.routeDetail, contains('局域网直连不可用'));
      expect(relay.routeDetail, contains('公网直连不可用'));
      expect(relay.status, 'received');
      expect(await File(relay.localPath).readAsBytes(), bytes);
      remote = await first.call('GET', '/transfers/${relay.transferId}');
      expect(remote['transfer']['files'][0]['transport'], 'relay');
      expect(remote['transfer']['files'][0]['offset'], bytes.length);
      expect(remote['transfer']['files'][0]['status'], 'received');

      // A manually constrained LAN offer must fail rather than quietly using
      // the relay after the same peer has become unreachable.
      target.profile!.autoReceive = true;
      final manualFile = File('${folder.path}/manual-lan.bin');
      await manualFile.writeAsBytes(bytes.take(10000).toList());
      await source.offer(target.profile!.deviceId, [
        manualFile.path,
      ], routePreferenceOverride: 'lan');
      await until(
        () => target.dock.any(
          (d) => d.title == 'manual-lan.bin' && d.status == 'failed',
        ),
        refresh,
      );
      final manual = target.dock.firstWhere((d) => d.title == 'manual-lan.bin');
      expect(manual.offerRoutePreference, 'lan');
      expect(manual.localPath, isEmpty);
      remote = await first.call('GET', '/transfers/${manual.transferId}');
      expect(remote['transfer']['files'][0]['transport'], 'direct');
      expect(remote['transfer']['files'][0]['offset'], 0);

      // Changing route creates one new offer using the original file reference,
      // and cancels only the constrained item without asking for another picker.
      await source.reconcile();
      final outgoing = source.dock.firstWhere((d) => d.fileId == manual.fileId);
      await source.resendWithRoute(outgoing, 'relay');
      await until(
        () => target.dock.any(
          (d) =>
              d.title == 'manual-lan.bin' &&
              d.fileId != manual.fileId &&
              d.status == 'received',
        ),
        refresh,
      );
      final resent = target.dock.firstWhere(
        (d) => d.title == 'manual-lan.bin' && d.fileId != manual.fileId,
      );
      expect(resent.offerRoutePreference, 'relay');
      expect(resent.route, 'relay');
      expect(
        await File(resent.localPath).readAsBytes(),
        bytes.take(10000).toList(),
      );
      remote = await first.call('GET', '/transfers/${manual.transferId}');
      expect(remote['transfer']['files'][0]['status'], 'canceled');
    } finally {
      sender?.dispose();
      receiver?.dispose();
      await peer?.close();
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await stderrSubscription.cancel();
      await log.close();
      ReceiveDestination.registryDirectoryForTesting = null;
      if (!folder.absolute.path.startsWith(
        '${testRoot.absolute.path}${Platform.pathSeparator}',
      )) {
        throw StateError('Unsafe integration cleanup path');
      }
      // Keep this synthetic full-stack state under ignored project build/ for diagnosis.
      stdout.writeln('Full-stack test evidence: ${folder.absolute.path}');
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
