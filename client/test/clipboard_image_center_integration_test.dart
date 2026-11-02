import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/system_bridge.dart';

import 'center_integration_test.dart' show until;

class RealTransportBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Future<void> clipboardEvent(Map<String, dynamic> value) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('clipboardChanged', value),
        ),
        (_) => done.complete(),
      );
  await done.future;
}

void main() {
  RealTransportBinding();
  test('automatic screenshot uses real center and LAN file pipeline, then writes target clipboard once without drafts or echo', () async {
    final parent = await Directory('../artifacts/tmp/clipboard-image101')
        .create(recursive: true);
    final work = await parent.createTemp('center-');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a2ioAAAAASUVORK5CYII=',
    );
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${work.path}/registry');
    final process = await Process.start('node', [
      '--import',
      '../server/node_modules/tsx/dist/loader.mjs',
      'tool/start_test_center.mjs',
      work.absolute.path,
    ]);
    final log = File('${work.path}/center.log').openWrite();
    final errors = process.stderr.transform(utf8.decoder).listen(log.write);
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final base =
        (jsonDecode(
              await lines
                  .firstWhere((line) => line.startsWith('{'))
                  .timeout(const Duration(seconds: 10)),
            ) as Map)['url']
            as String;
    final clients = <SendController>[];
    final writes = <Map>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    PeerTransport? peer;
    SendController? target;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'readClipboard') {
        final arguments = call.arguments as Map;
        expect(arguments['expectedSequence'], 1001);
        expect(arguments['imageOnly'], isTrue);
        final path = (arguments['bitmapPath'] as String).replaceAll(
          '.bmp',
          '.png',
        );
        await File(path).writeAsBytes(png);
        return {
          'paths': [path],
          'texts': <String>[],
          'temporaryPaths': [path],
        };
      }
      if (call.method == 'writeClipboardImage') {
        final value = Map<String, dynamic>.from(call.arguments as Map);
        expect(await File(value['path'] as String).readAsBytes(), png);
        writes.add(value);
        await clipboardEvent({
          'sequence': 1002,
          'kind': 'image',
          'private': true,
          'marker': '${value['originDeviceId']}/${value['sourceEventId']}',
        });
        return true;
      }
      return null;
    });
    try {
      for (var i = 0; i < 3; i++) {
        final api = CenterApi(base);
        final info = await api.call('GET', '/info', null, false);
        final session = await api.call('POST', '/devices/enroll', {
          'name': 'Same name',
          'platform': 'windows',
          'groupKey': 'clipboard-image101',
        }, false);
        api.token = session['deviceToken'];
        final state = await Directory('${work.path}/state-$i').create();
        final c =
            SendController(
                stateDirectory: () async => state,
                documentsDirectory: () async =>
                    Directory('${work.path}/files-$i'),
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
        clients.add(c);
        await c.openSocket(c.generation);
      }
      final source = clients[0];
      source.profile!.sendRoutePreference = 'lan';
      target = clients[1];
      final unselected = clients[2];
      source.devices = [
        {
          'deviceId': target.profile!.deviceId,
          'name': 'Same name',
          'online': true,
        },
      ];
      source.stagedTexts.add('keep draft');
      source.stagedFiles.add('${work.path}/unrelated.txt');
      await source.setClipboardSync(true, target.profile!.deviceId);
      // Receiving is independent of publishing: no reverse sender switch or target.
      expect(target.clipboardEnabled, false);
      expect(target.clipboardReceiveEnabled, true);
      await target.clipboard.load(target.root!);
      peer = PeerTransport(source.api!, (id) => source.sources[id]);
      await peer.start(
        createPeerIdentity('clipboard-image101'),
        loopbackOnly: true,
      );
      source.peer = peer;
      final ordinary = await File('${work.path}/ordinary.png')
          .writeAsBytes(png);
      await source.offer(target.profile!.deviceId, [ordinary.path]);
      await until(
        () => target!.dock.any(
          (entry) => !entry.autoClipboard && entry.status == 'received',
        ),
        () async {
          await source.reconcile();
          await target!.reconcile();
        },
      );
      final ordinaryReceived = target.dock.singleWhere(
        (entry) => !entry.autoClipboard,
      );
      final originalPath = ordinaryReceived.localPath;
      final serial = target.receiptSerial,
          receiptCount = target.pendingReceipts.length;
      await clipboardEvent({
        'sequence': 1001,
        'kind': 'image',
        'text': '',
        'private': false,
        'marker': '',
      });
      try {
        await until(
          () {
            if (source.clipboardError.isNotEmpty)
              throw StateError(source.clipboardError);
            return target!.clipboardSlot?.status == 'received' &&
                writes.length == 1;
          },
          () async {
            await source.reconcile();
            await target!.reconcile();
          },
        );
      } catch (_) {
        final evidence = {
          'sourceStatus': source.clipboardStatus,
          'sourceError': source.clipboardError,
          'sourceDock': source.dock.map((entry) => entry.toJson()).toList(),
          'targetDock': target.dock.map((entry) => entry.toJson()).toList(),
          'writes': writes,
          'transfers': await source.api!.call('GET', '/transfers'),
        };
        await File('${work.path}/failure.json')
            .writeAsString(jsonEncode(evidence));
        stdout.writeln(jsonEncode(evidence));
        rethrow;
      }
      final received = target.clipboardSlot!;
      expect(target.clipboardSlot?.localPath, received.localPath);
      expect(target.historyDock.map((entry) => entry.id), [
        ordinaryReceived.id,
      ]);
      expect(await File(originalPath).readAsBytes(), png);
      expect(target.pendingReceipts.length, receiptCount);
      expect(target.receiptSerial, serial);
      expect(received.localPath, contains('clipboard-slot-cache'));
      expect(received.title, endsWith('.png'));
      expect(received.route, 'lan');
      expect(await File(received.localPath).readAsBytes(), png);
      expect(writes.single['originDeviceId'], source.profile!.deviceId);
      expect(writes.single['sourceEventId'], received.transferId);
      expect(source.stagedTexts, ['keep draft']);
      expect(source.stagedFiles, ['${work.path}/unrelated.txt']);
      expect(unselected.dock, isEmpty);
      expect(
        (await unselected.api!.call('GET', '/transfers'))['transfers'],
        isEmpty,
      );
      await source.reconcile();
      await target.reconcile();
      await target.reconcile();
      expect(writes, hasLength(1));
      expect(
        (await source.api!.call('GET', '/transfers'))['transfers'],
        hasLength(2),
      );
      await target.stageClipboardSlot();
      final staged = target.stagedFiles.single;
      expect(staged, isNot(received.localPath));
      await target.clipboard.receive(
        DockEntry(
          id: 'next-text',
          kind: 'text',
          title: 'text',
          source: 'another-source',
          text: 'new clipboard',
          status: 'ready',
          autoClipboard: true,
          createdAtMillis: received.createdAtMillis + 1,
          originDeviceId: 'another-source',
          sourceEventId: 'next-text',
        ),
      );
      expect(await File(staged).readAsBytes(), png);
      expect(await File(originalPath).readAsBytes(), png);
      expect(await File(received.localPath).exists(), false);
      stdout.writeln(
        'Clipboard image production pipeline evidence: ${work.absolute.path}',
      );
    } finally {
      for (final client in clients) client.dispose();
      await peer?.close();
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await errors.cancel();
      await log.close();
      messenger.setMockMethodCallHandler(SystemBridge.channel, null);
      ReceiveDestination.registryDirectoryForTesting = null;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
