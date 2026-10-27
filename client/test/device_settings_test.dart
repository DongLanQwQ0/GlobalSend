import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

class DeviceApi extends CenterApi {
  DeviceApi() : super('http://127.0.0.1', token: 'unchanged-token');
  String? method, path;
  Object? body;
  bool reject = false;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    this.method = method;
    this.path = path;
    this.body = body;
    if (reject) throw ApiException(500, '保存失败');
    return {
      'device': {
        'deviceId': 'self',
        'name': (body as Map)['name'],
        'online': true,
        'platform': 'windows',
        'revoked': false,
      },
    };
  }
}

class DeviceController extends SendController {
  DeviceController({super.deviceName});
  int saves = 0, refreshes = 0;
  @override
  Future<void> save() async {
    saves++;
  }

  @override
  Future<void> safeReconcile() async {
    refreshes++;
  }
}

class NameEnrollmentController extends DeviceController {
  NameEnrollmentController({super.deviceName});
  String enrolled = '';
  @override
  Future<void> adoptEnrollment(Map<String, dynamic> result, String name) async {
    enrolled = name;
  }
}

void main() {
  test('Windows default name is the current Windows username', () async {
    expect(
      await SystemBridge.deviceName(),
      String.fromCharCodes(
        Platform.environment['USERNAME']!.trim().runes.take(80),
      ),
    );
  }, skip: !Platform.isWindows);

  test('reading a default name never renames a saved identity; restoring it is explicit', () async {
    final api = DeviceApi();
    final c = DeviceController(deviceName: () async => 'DESKTOP-ACTUAL')
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'test',
        deviceId: 'self',
        name: '自定义名称',
      );
    addTearDown(c.dispose);
    expect(await c.systemDeviceName(), 'DESKTOP-ACTUAL');
    expect(c.profile!.name, '自定义名称');
    expect(api.method, isNull);
    expect(await c.useSystemDeviceName(), 'DESKTOP-ACTUAL');
    expect([api.method, api.path], ['PATCH', '/devices/me']);
    expect(c.profile!.deviceId, 'self');
  });

  test(
    'new enrollment fills an empty name but retains an explicitly entered name',
    () async {
      var reads = 0;
      final api = DeviceApi();
      final c =
          NameEnrollmentController(
              deviceName: () async {
                reads++;
                return '我的 vivo';
              },
            )
            ..api = api
            ..profile = ServerProfile(baseUrl: api.baseUrl, instanceId: 'test');
      addTearDown(c.dispose);
      await c.enrollGroup('', '1234567890');
      expect((api.body as Map)['name'], '我的 vivo');
      expect(c.enrolled, '我的 vivo');
      await c.enrollGroup('自定义名称', 'a-valid-group-key-for-test');
      expect((api.body as Map)['name'], '自定义名称');
      expect(reads, 1);
      api.method = null;
      await expectLater(c.enrollGroup('', '123456789'), throwsFormatException);
      expect(api.method, isNull);
    },
  );

  test('a delayed system-name reset cannot rename the next session', () async {
    final pending = Completer<String>();
    final first = DeviceApi(), second = DeviceApi();
    final c = DeviceController(deviceName: () => pending.future)
      ..api = first
      ..profile = ServerProfile(
        baseUrl: first.baseUrl,
        instanceId: 'first',
        deviceId: 'first',
        name: '旧组名称',
      );
    addTearDown(c.dispose);
    final resetting = c.useSystemDeviceName();
    final rejected = expectLater(resetting, throwsStateError);
    c.generation++;
    c.api = second;
    c.profile = ServerProfile(
      baseUrl: second.baseUrl,
      instanceId: 'second',
      deviceId: 'second',
      name: '新组名称',
    );
    pending.complete('系统设备');
    await rejected;
    expect(first.method, isNull);
    expect(second.method, isNull);
    expect(c.profile!.name, '新组名称');
    first.close();
  });
  test(
    'presence changes retain peer names and exclude revoked devices',
    () async {
      final c = DeviceController()
        ..connected = true
        ..profile = ServerProfile(
          baseUrl: 'http://127.0.0.1',
          instanceId: 'test',
          deviceId: 'self',
        )
        ..devices = [
          {'deviceId': 'self', 'name': '电脑', 'online': true},
          {'deviceId': 'phone', 'name': '手机', 'online': true},
          {'deviceId': 'offline', 'name': '平板', 'online': false},
          {'deviceId': 'revoked', 'online': true, 'revoked': true},
        ];
      addTearDown(c.dispose);
      expect(c.onlinePeers.map((d) => d['deviceId']), ['phone']);
      await c.handleServerMessage({
        'type': 'presence',
        'deviceId': 'phone',
        'online': false,
      });
      expect(c.onlinePeers, isEmpty);
      expect(c.devices[1]['name'], '手机');
      await c.handleServerMessage({
        'type': 'presence',
        'deviceId': 'offline',
        'online': true,
      });
      expect(c.onlinePeers.map((d) => d['deviceId']), ['offline']);
      c.connected = false;
      expect(c.onlinePeers, isEmpty);
      expect(
        c.devices.map((device) => device['deviceId']),
        ['self', 'phone', 'offline'],
      );
    },
  );

  test(
    'new peers and changed device metadata refresh the device snapshot',
    () async {
      final c = DeviceController();
      addTearDown(c.dispose);
      await c.handleServerMessage({
        'type': 'presence',
        'deviceId': 'new',
        'online': true,
      });
      await c.handleServerMessage({'type': 'devices.changed'});
      expect(c.refreshes, 2);
    },
  );

  test(
    'rename persists the server name without changing device identity',
    () async {
      final api = DeviceApi();
      final c = DeviceController()
        ..api = api
        ..profile = ServerProfile(
          baseUrl: api.baseUrl,
          instanceId: 'test',
          deviceId: 'self',
          name: '旧名称',
        )
        ..devices = [
          {'deviceId': 'self', 'name': '旧名称'},
        ];
      addTearDown(c.dispose);
      await c.renameDevice('  我的电脑  ');
      expect([api.method, api.path], ['PATCH', '/devices/me']);
      expect(api.body, {'name': '我的电脑'});
      expect(c.profile!.name, '我的电脑');
      expect(c.devices.single['name'], '我的电脑');
      expect(c.profile!.deviceId, 'self');
      expect(api.token, 'unchanged-token');
      expect(c.saves, 1);
    },
  );

  test('a failed rename keeps the last saved name', () async {
    final api = DeviceApi()..reject = true;
    final c = DeviceController()
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'test',
        deviceId: 'self',
        name: '旧名称',
      );
    addTearDown(c.dispose);
    await expectLater(c.renameDevice('新名称'), throwsA(isA<ApiException>()));
    expect(c.profile!.name, '旧名称');
    expect(c.saves, 0);
  });
}
