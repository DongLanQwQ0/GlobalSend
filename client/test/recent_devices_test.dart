import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/recent_devices.dart';

void main() {
  final online = <String, dynamic>{
    'deviceId': 'phone',
    'name': '手机',
    'online': true,
    'peer': {
      'candidates': ['https://[2408::1]:8788'],
    },
    'rtc': {
      'scopes': ['public'],
    },
  };
  test('offline grace retains addresses for exactly 30s without extending on snapshots', () {
    final recent = RecentDevices();
    var devices = recent.merge([], [online], 1000);
    devices = recent.merge(devices, [], 2000);
    expect(devices.single['online'], false);
    expect(devices.single['peer'], online['peer']);
    expect(recent.available(devices.single, 31999), true);
    devices = recent.merge(devices, [], 31000);
    expect(recent.deadlines['phone'], 32000);
    expect(recent.available(devices.single, 32000), false);
    expect(recent.merge(devices, [], 32000), isEmpty);
  });
  test('offline history is hidden; reconnect updates once and new disconnect gets new deadline', () {
    final recent = RecentDevices();
    final history = recent.merge([], [
      {...online, 'online': false},
    ], 1000);
    expect(recent.available(history.single, 1000), false);
    expect(history.single['peer'], null);
    var devices = recent.merge(history, [online], 2000);
    devices = recent.merge(devices, [], 3000);
    devices = recent.merge(devices, [
      {...online, 'name': '新名称'},
    ], 4000);
    expect(devices.single['name'], '新名称');
    expect(recent.deadlines, isEmpty);
    devices = recent.merge(devices, [], 5000);
    expect(recent.deadlines['phone'], 35000);
    expect(
      recent.merge(devices, [
        {...online, 'revoked': true},
      ], 6000),
      isEmpty,
    );
    recent.clear();
    expect(recent.deadlines, isEmpty);
  });
}
