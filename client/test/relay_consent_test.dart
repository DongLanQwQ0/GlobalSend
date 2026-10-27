import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

class PolicyApi extends CenterApi {
  PolicyApi() : super('https://fixture.invalid', token: 'fixture');
  final calls = <String>[];
  String preference = 'relay';
  final files = <Map<String, dynamic>>[
    {
      'fileId': 'large',
      'name': '大文件.bin',
      'size': 1048577,
      'sha256': 'fixture',
      'status': 'offered',
      'offset': 0,
    },
    {
      'fileId': 'small',
      'name': '小文件.txt',
      'size': 12,
      'sha256': 'fixture',
      'status': 'offered',
      'offset': 0,
    },
  ];
  Map<String, dynamic> get transfer => {
    'transferId': 'batch',
    'sourceDeviceId': 'sender',
    'targetDeviceId': 'receiver',
    'routePreference': preference,
    'files': files,
  };
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    if (path == '/devices') return {'devices': []};
    if (path.startsWith('/events?')) {
      return {'events': [], 'cursor': 0, 'hasMore': false};
    }
    if (path == '/transfers') {
      return {
        'transfers': [transfer],
      };
    }
    if (path == '/transfers/batch') return {'transfer': transfer};
    if (path.endsWith('/accept')) {
      final ids = (body as Map)['fileIds'] as List;
      for (final f in files) {
        f['status'] = ids.contains(f['fileId']) ? 'accepted' : 'rejected';
        if (preference == 'relay') f['transport'] = 'relay';
      }
      return {'transfer': transfer};
    }
    if (path.endsWith('/direct-ticket')) return {'candidates': <String>[]};
    if (path.endsWith('/relay')) {
      for (final f in files) {
        f['transport'] = 'relay';
      }
      return {};
    }
    if (path.endsWith('/cancel')) return {};
    throw StateError('Unexpected fixture request: $method $path');
  }
}

class PolicyController extends SendController {
  PolicyController(Directory dir) : super(documentsDirectory: () async => dir);
  @override
  Future<void> safeReconcile() async {} // explicit reconcile calls control replay in these state-machine tests
}

void main() {
  test('large forced-relay batch waits intact, survives replay/preferences, explicit accept includes small item', () async {
    final a = PolicyApi();
    final c = PolicyController(Directory('build/test-tmp/policy'))
      ..api = a
      ..profile = ServerProfile(
        baseUrl: a.baseUrl,
        instanceId: 'fixture',
        deviceId: 'receiver',
        relayConfirmMiB: 1,
      )
      ..info = {
        'features': {'direct': true},
      };
    try {
      await c.reconcile();
      expect(a.calls.where((s) => s.endsWith('/accept')), isEmpty);
      expect(
        c.dock.every(
          (d) => d.relayPendingBeforeAccept && d.relayConfirmationPending,
        ),
        isTrue,
      );
      c.dock = c.dock.map((d) => DockEntry.fromJson(d.toJson())).toList();
      c.profile!.receiveRoutePreference = 'relay';
      await c.reconcile();
      expect(a.calls.where((s) => s.endsWith('/accept')), isEmpty);
      await c.approveReceive(c.dock.first, ['large', 'small']);
      expect(a.files.every((f) => f['status'] == 'accepted'), isTrue);
      expect(
        c.dock.every((d) => d.relayConfirmed && !d.relayConfirmationPending),
        isTrue,
      );
    } finally {
      c.dispose();
    }
  });
  test('direct fallback waits above threshold, explicit relay resumes once; small file stays automatic', () async {
    final folder = await Directory('build/test-tmp')
        .createTemp('relay-policy-');
    final a = PolicyApi()..preference = 'auto';
    for (final f in a.files) {
      f['status'] = 'accepted';
    }
    final c = PolicyController(folder)
      ..api = a
      ..profile = ServerProfile(
        baseUrl: a.baseUrl,
        instanceId: 'fixture',
        deviceId: 'receiver',
        relayConfirmMiB: 1,
      )
      ..info = {
        'features': {'direct': true},
      };
    DockEntry item(String id) => DockEntry(
      id: id,
      kind: 'file',
      title: '$id.bin',
      source: 'sender',
      fileId: id,
      transferId: 'batch',
      status: 'accepted',
      size: id == 'large' ? 1048577 : 12,
    );
    final big = item('large'), small = item('small');
    c.dock = [big, small];
    try {
      await c.receive(big);
      expect(big.relayConfirmationPending, isTrue);
      expect(a.calls.where((s) => s.endsWith('/relay')), isEmpty);
      expect(a.calls.where((s) => s.endsWith('/direct-ticket')).length, 2);
      await c.receive(small);
      expect(a.calls.where((s) => s.endsWith('/small/relay')).length, 1);
      await c.approveRelay(big);
      expect(a.calls.where((s) => s.endsWith('/large/relay')).length, 1);
      expect(big.relayConfirmed, isTrue);
      expect(big.relayConfirmationPending, isFalse);
      await c.cancel(big);
      a.files.first['status'] = 'accepted';
      c.updateTransfer(a.transfer);
      await c.receive(big);
      await c.approveRelay(big);
      expect(big.status, 'canceled');
      expect(a.calls.where((s) => s.endsWith('/large/relay')).length, 1);
    } finally {
      c.dispose();
    }
  });
  test('explicit local relay approves large files, cellular and threshold persist without size cap', () async {
    final a = PolicyApi();
    final c = PolicyController(Directory('build/test-tmp/policy'))
      ..api = a
      ..profile = ServerProfile(
        baseUrl: a.baseUrl,
        instanceId: 'fixture',
        deviceId: 'receiver',
        receiveRoutePreference: 'relay',
        relayConfirmMiB: 1,
      )
      ..info = {
        'features': {'direct': true},
      };
    try {
      await c.reconcile();
      expect(a.files.every((f) => f['status'] == 'accepted'), isTrue);
      await c.setCellularAllowed(true);
      await c.setRelayConfirmMiB(64);
      final restored = ServerProfile.fromJson(c.profile!.toJson());
      expect(restored.cellularAllowed, isTrue);
      expect(restored.relayConfirmMiB, 64);
      expect(
        ServerProfile(baseUrl: a.baseUrl, instanceId: 'new').cellularAllowed,
        isFalse,
      );
    } finally {
      c.dispose();
    }
  });
}
