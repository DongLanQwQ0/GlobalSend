import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/device_usage.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/models.dart';

class UsageApi extends CenterApi {
  UsageApi() : super('https://fixture.invalid', token: 'fixture');
  bool fail = false;
  String event = '';
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool auth = true,
  ]) async {
    event = (body as Map)['eventId'];
    if (fail) throw StateError('synthetic failure');
    return {};
  }
}

class UsageController extends SendController {
  @override
  Future<void> safeReconcile() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('frequency is identity based, retry-idempotent, stable for ties and round-trips', () {
    final usage = DeviceUsage();
    final peers = [
      for (final id in ['a', 'b', 'c', 'b'])
        {'deviceId': id, 'name': 'Same name', 'online': true},
    ];
    expect(usage.record('b', 'text:1'), true);
    expect(usage.record('b', 'text:1'), false);
    usage.record('c', 'file:1');
    usage.record('c', 'file:2');
    final restarted = DeviceUsage()
      ..restore(jsonDecode(jsonEncode(usage.toJson())));
    expect(restarted.rank(peers).map((x) => x['deviceId']), ['c', 'b', 'a']);
    restarted.record('a', 'text:2');
    expect(restarted.rank(peers).map((x) => x['deviceId']), ['c', 'a', 'b']);
  });
  test('production send records only accepted sends, persists, retains offline grace and excludes self', () async {
    final parent = await Directory('../artifacts/tmp/device-usage117')
        .create(recursive: true);
    final folder = await parent.createTemp('native-');
    final api = UsageApi();
    final c = UsageController()
      ..root = folder
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      )
      ..connected = true;
    final profile = c.profile!;
    c.profiles.add(profile);
    c.discoveryNow = () => 1000;
    c.updateDiscoveredDevices([
      for (final id in ['self', 'a', 'b'])
        {'deviceId': id, 'online': true, 'name': 'Same'},
    ]);
    try {
      api.fail = true;
      await expectLater(c.sendText('b', 'fixture'), throwsStateError);
      expect(c.deviceUsage.operations, isEmpty);
      final retryId = api.event;
      api.fail = false;
      await c.sendText('b', 'fixture');
      expect(api.event, retryId);
      expect(c.deviceUsage.operations['b'], {'text:$retryId'});
      expect(c.sendablePeers.map((x) => x['deviceId']), ['b', 'a']);
      c.updateDiscoveredDevices([
        {'deviceId': 'a', 'online': true},
      ]);
      expect(c.sendablePeers.map((x) => x['deviceId']), ['b', 'a']);
      final restored = UsageController()
        ..root = folder
        ..profile = profile;
      try {
        await restored.save();
        expect(restored.deviceUsage.toJson(), c.deviceUsage.toJson());
      } finally {
        restored.dispose();
      }
      c.discoveryNow = () => 32000;
      expect(c.sendablePeers.map((x) => x['deviceId']), ['a']);
    } finally {
      c.dispose();
      await c.persistenceIdle;
      await folder.delete(recursive: true);
    }
  });
}
