import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/rtc_transport.dart';

import 'saved_files_test.dart' show fixtureDirectory;

class RtcControllerApi extends CenterApi {
  RtcControllerApi(this.bytes)
    : super('https://fixture.invalid', token: 'fixture');
  final List<int> bytes;
  final List<String> calls = [];
  Map<String, dynamic>? receipt;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    if (method == 'GET' && path == '/transfers/transfer') {
      return {
        'transfer': {
          'files': [
            {
              'fileId': 'file',
              'status': 'accepted',
              'transport': null,
              'sha256': sha256.convert(bytes).toString(),
            },
          ],
        },
      };
    }
    if (path.endsWith('/direct-ticket')) {
      throw ApiException(409, 'No HTTPS listener');
    }
    if (path.endsWith('/received')) {
      receipt = Map<String, dynamic>.from(body as Map);
    }
    return {};
  }
}

/// Tests controller routing and storage. Native/browser socket interoperability
/// is exercised by the separate production-transport headless acceptance.
class ControllerRtc extends RtcFileTransport {
  ControllerRtc(super.api, this.bytes, this.availableScope);
  final List<int> bytes;
  final String? availableScope;
  final List<String> attempts = [], destinations = [];
  final List<int> offsets = [];
  @override
  Future<void> receive({
    required String fileRoute,
    required String attemptId,
    required String scope,
    required File destination,
    required int size,
    required void Function(int) onProgress,
  }) async {
    attempts.add(scope);
    destinations.add(destination.path);
    final offset = await destination.exists() ? await destination.length() : 0;
    offsets.add(offset);
    if (scope != availableScope) {
      await destination.writeAsBytes(bytes.sublist(0, 12345));
      onProgress(12345);
      throw StateError('Fixture scope unreachable');
    }
    final sink = destination.openWrite(mode: FileMode.append);
    sink.add(bytes.sublist(offset));
    await sink.flush();
    await sink.close();
    onProgress(size);
  }
}

class HandoffRtc extends RtcFileTransport {
  HandoffRtc(super.api);
  final first = Completer<void>();
  final sends = <String>[];
  bool oldClosed = false;
  @override
  Future<void> send({
    required String fileRoute,
    required Map<String, dynamic> attempt,
    required File source,
    required int size,
    required void Function(int) onProgress,
  }) async {
    sends.add(attempt['attemptId']);
    if (sends.length == 1) {
      await first.future;
    } else {
      expect(oldClosed, isTrue);
      onProgress(size);
    }
  }

  @override
  Future<void> cancelFile(String fileId) async {
    oldClosed = true;
    if (!first.isCompleted) {
      first.completeError(StateError('Superseded RTC route'));
    }
  }
}

class RevokingRtc extends RtcFileTransport {
  RevokingRtc(super.api);
  final stopped = Completer<void>();
  bool revoking = false;
  @override
  Future<void> revokeCellular() {
    revoking = true;
    return stopped.future;
  }
}

void main() {
  test('turning cellular off updates permission immediately and awaits RTC owner shutdown', () async {
    final folder = await fixtureDirectory();
    final api = RtcControllerApi([1]);
    final rtc = RevokingRtc(api);
    final controller = SendController()
      ..api = api
      ..rtc = rtc
      ..cellularUploads = true
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        cellularAllowed: true,
      )
      ..root = Directory('${folder.path}/state');
    addTearDown(controller.dispose);
    var done = false;
    final turningOff = controller
        .setCellularAllowed(false)
        .then((_) => done = true);
    expect(controller.cellularUploads, false);
    expect(controller.profile!.cellularAllowed, false);
    expect(rtc.revoking, true);
    await Future<void>.delayed(Duration.zero);
    expect(done, false);
    rtc.stopped.complete();
    await turningOff;
    expect(done, true);
  });
  Future<(SendController, DockEntry, RtcControllerApi, ControllerRtc)> fixture(
    String? availableScope, {
    bool https = true,
  }) async {
    final folder = await fixtureDirectory();
    final bytes = List<int>.generate(70000, (i) => i % 251);
    final api = RtcControllerApi(bytes);
    final rtc = ControllerRtc(api, bytes, availableScope);
    final p = ServerProfile(
      baseUrl: api.baseUrl,
      instanceId: 'fixture',
      deviceId: 'receiver',
    );
    final controller =
        SendController(
            documentsDirectory: () async =>
                Directory('${folder.path}/received'),
          )
          ..api = api
          ..rtc = rtc
          ..info = {
            'features': {'direct': https, 'rtcDataChannels': true},
          }
          ..profile = p
          ..root = Directory('${folder.path}/state')
          ..devices = [
            {
              'deviceId': 'sender',
              'rtc': {
                'scopes': ['lan', 'public'],
              },
            },
          ];
    final item = DockEntry(
      id: 'file',
      kind: 'file',
      title: 'received.bin',
      source: 'sender',
      transferId: 'transfer',
      fileId: 'file',
      size: bytes.length,
      status: 'accepted',
    );
    controller.dock = [item];
    addTearDown(controller.dispose);
    return (controller, item, api, rtc);
  }

  test('RTC uses LAN then public and keeps the same on-disk partial before final receipt', () async {
    final (controller, item, api, rtc) = await fixture('public', https: false);
    await controller.receive(item);
    expect(rtc.attempts, ['lan', 'public']);
    expect(rtc.offsets, [0, 12345]);
    expect(rtc.destinations.toSet(), hasLength(1));
    expect(item.status, 'received');
    expect(item.route, 'public');
    expect(await File(item.localPath).readAsBytes(), api.bytes);
    expect(api.receipt, {'transport': 'direct'});
    expect(api.calls.any((value) => value.endsWith('/relay')), isFalse);
    expect(controller.savedFiles, hasLength(1));
  });

  test('recent public RTC success is preferred only after LAN and never adds a second file attempt', () async {
    final (controller, item, api, rtc) = await fixture('public');
    final now = DateTime.now();
    controller.reachability.devices = controller.devices;
    controller.reachability.setRtcResults('receiver', [
      {
        'initiatorDeviceId': 'receiver',
        'responderDeviceId': 'sender',
        'scope': 'public',
        'success': true,
        'elapsedMs': 2,
        'checkedAt': now.toIso8601String(),
        'expiresAt': now.add(const Duration(minutes: 2)).toIso8601String(),
      },
    ]);
    await controller.receive(item);
    expect(rtc.attempts, ['lan', 'public']);
    // LAN still attempts HTTPS first. Public then uses its successful RTC hint
    // before a redundant HTTPS grant, without skipping actual file receipt.
    expect(api.calls.where((c) => c.endsWith('/direct-ticket')), hasLength(1));
    expect(item.status, 'received');
    expect(api.receipt, {'transport': 'direct'});
  });

  test('manual LAN failure preserves its partial and never selects public or relay', () async {
    final (controller, item, api, rtc) = await fixture(null);
    await controller.receive(item, routeOverride: 'lan');
    expect(rtc.attempts, ['lan']);
    expect(item.status, 'failed');
    expect(item.error, contains('Fixture scope unreachable'));
    expect(await File(item.partialPath).length(), 12345);
    expect(api.calls.any((value) => value.endsWith('/relay')), isFalse);
    expect(api.receipt, isNull);
  });

  test(
    'auto may request relay only after both direct RTC scopes fail',
    () async {
      final (controller, item, api, rtc) = await fixture(null);
      await controller.receive(item);
      expect(rtc.attempts, ['lan', 'public']);
      expect(item.route, 'relay');
      expect(item.status, 'accepted');
      expect(api.calls.last, 'POST /transfers/transfer/files/file/relay');
      expect(await File(item.partialPath).length(), 12345);
    },
  );

  test('a new RTC route arriving during source shutdown starts without waiting for a periodic sync', () async {
    final folder = await fixtureDirectory();
    final api = RtcControllerApi([1, 2, 3]);
    final rtc = HandoffRtc(api);
    final file = await File('${folder.path}/source.bin')
        .writeAsBytes([1, 2, 3]);
    final controller = SendController()
      ..api = api
      ..rtc = rtc
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'sender',
      )
      ..root = Directory('${folder.path}/state')
      ..sources = {'file': file.path};
    addTearDown(controller.dispose);
    Map<String, dynamic> transfer(String attempt) => {
      'transferId': 'transfer',
      'sourceDeviceId': 'sender',
      'targetDeviceId': 'receiver',
      'files': [
        {
          'fileId': 'file',
          'name': 'source.bin',
          'size': 3,
          'offset': 0,
          'status': 'accepted',
          'transport': 'direct',
          'rtc': {
            'attemptId': attempt,
            'scope': attempt == 'first' ? 'lan' : 'public',
            'offset': 0,
            'state': 'negotiating',
          },
        },
      ],
    };
    Future<void> until(bool Function() condition) async {
      for (var index = 0; index < 100 && !condition(); index++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(condition(), isTrue);
    }

    controller.updateTransfer(transfer('first'));
    await until(() => rtc.sends.isNotEmpty);
    controller.updateTransfer(transfer('next'));
    await until(() => rtc.sends.length == 2 && controller.busyFiles.isEmpty);
    expect(rtc.sends, ['first', 'next']);
    expect(controller.dock.single.status, 'awaitingReceipt');
    expect(controller.dock.single.route, 'public');
    // Source completion persists asynchronously after releasing busyFiles.
    // Consume that write before this fixture's directory is removed.
    await controller.save();
  });
}
