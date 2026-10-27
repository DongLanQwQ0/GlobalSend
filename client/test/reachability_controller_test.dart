import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/reachability.dart';

class TrackingMonitor extends ReachabilityMonitor {
  bool started = false, closed = false;
  List<Map<String, dynamic>> seen = [];
  String seenCenter = '';
  bool seenOnline = false, seenCellular = false;
  @override
  void start() {
    started = true;
  }

  @override
  void update({
    required List<Map<String, dynamic>> onlineDevices,
    required String centerUrl,
    required bool online,
    required bool cellular,
  }) {
    seen = onlineDevices;
    seenCenter = centerUrl;
    seenOnline = online;
    seenCellular = cellular;
  }

  @override
  void dispose() {
    closed = true;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('controller starts monitor and follows online peers, cellular setting and disconnect', () async {
    final parent = await Directory('build/test-tmp').create(recursive: true);
    final root = await parent.createTemp('reachability-controller-');
    final monitor = TrackingMonitor();
    final c = SendController(
      stateDirectory: () async => Directory('${root.path}/state')..createSync(),
      documentsDirectory: () async =>
          Directory('${root.path}/files')..createSync(),
      reachability: monitor,
    );
    try {
      await c.init();
      expect(monitor.started, isTrue);
      c.api = CenterApi('http://127.0.0.1:8787');
      c.profile = ServerProfile(
        baseUrl: c.api!.baseUrl,
        instanceId: 'test',
        deviceId: 'self',
      );
      c.connected = true;
      c.devices = [
        {'deviceId': 'self', 'online': true},
        {'deviceId': 'phone', 'online': true},
        {'deviceId': 'offline', 'online': false},
      ];
      c.changed();
      expect(monitor.seen.map((device) => device['deviceId']), ['phone']);
      expect(monitor.seenCenter, c.api!.baseUrl);
      expect(monitor.seenOnline, isTrue);
      c.cellularUploads = true;
      c.changed();
      expect(monitor.seenCellular, isTrue);
      await c.handleServerMessage({
        'type': 'presence',
        'deviceId': 'phone',
        'online': false,
      });
      expect(monitor.seen, isEmpty);
      c.stopConnections();
      expect(monitor.seenOnline, isFalse);
    } finally {
      c.dispose();
      expect(monitor.closed, isTrue);
      await root.delete(recursive: true);
    }
  });
}
