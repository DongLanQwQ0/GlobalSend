import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/vault.dart';

// This is a deliberately long-lived live-device fixture, not a normal CI test.
// No OS credential, clipboard, window or Android bridge is exercised here.
class FixtureVault extends PlatformVault {
  final values = <String, String>{};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async { values[key] = value; }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('live Windows headless peer waits for real-device consumer and explicit stop', () async {
    final workspace = Directory('../artifacts/live-native-peer').absolute;
    await workspace.create(recursive: true);
    final fixture = jsonDecode(await File('../artifacts/live-device-session.json').readAsString()) as Map;
    final samples = Directory('${workspace.path}/samples'); await samples.create(recursive: true);
    final large = File('${samples.path}/发送样本-2.5MiB.bin');
    await large.writeAsBytes(List<int>.generate(2621441, (index) => index % 251), flush: true);
    final chinese = File('${samples.path}/中文文件.txt');
    await chinese.writeAsString('GlobalSend 真实 vivo 接收样本：中文、空格与多文件。\n', flush: true);
    final empty = File('${samples.path}/empty.bin'); await empty.writeAsBytes([], flush: true);
    final files = [large.path, chinese.path, empty.path];
    final controller = SendController(
      documentsDirectory: () async => Directory('${workspace.path}/received'),
      vault: FixtureVault(),
    )..root = Directory('${workspace.path}/state');
    final stop = Completer<void>();
    HttpServer? control;
    final controlToken = newId();
    final offers = File('${workspace.path}/offers.jsonl');
    Map<String, dynamic> status() => {
      'deviceId': controller.profile?.deviceId,
      'name': 'Windows headless network probe',
      'connected': controller.connected,
      'connection': controller.connection,
      'message': controller.message,
      'peerAlive': controller.peer?.server != null,
      'candidates': controller.peer?.candidates ?? [],
      'devices': controller.devices.map((device) => {
        'deviceId': device['deviceId'], 'name': device['name'], 'online': device['online'],
      }).toList(),
      'files': controller.dock.where((item) => item.kind == 'file').map((item) => {
        'fileId': item.fileId, 'transferId': item.transferId, 'name': item.title,
        'size': item.size, 'status': item.status, 'outgoing': item.outgoing,
        'route': item.route, 'routeDetail': item.routeDetail, 'error': item.error,
        'localPath': item.localPath, 'targetDeviceId': item.targetDeviceId,
      }).toList(),
    };
    try {
      await controller.connect(fixture['base']);
      await controller.enrollGroup('Windows headless network probe', fixture['groupKey']);
      if (controller.peer?.server == null) throw StateError('Peer listener did not start: ${controller.peerStatus}');
      control = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      control.listen((request) async {
        var stopAfterReply = false;
        request.response.headers.contentType = ContentType.json;
        try {
          if (request.headers.value('x-live-peer-control') != controlToken) {
            request.response.statusCode = 401; request.response.write('{"error":"Control token required"}'); return;
          }
          if (request.method == 'GET' && request.uri.path == '/status') {
            await controller.safeReconcile(); request.response.write(jsonEncode(status()));
          } else if (request.method == 'POST' && request.uri.path == '/offer') {
            final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            final target = body['targetDeviceId'] as String;
            final mode = body['routePreference'] as String? ?? 'auto';
            if (!['auto', 'lan', 'public', 'relay'].contains(mode)) throw const FormatException('Unknown route mode');
            final kind = body['kind'] ?? 'multi';
            final selected = switch (kind) { 'multi' => files, 'large' => [large.path], 'empty' => [empty.path], _ => throw const FormatException('Unknown fixture kind') };
            final before = controller.dock.map((item) => item.fileId).toSet();
            await controller.offer(target, selected, routePreferenceOverride: mode);
            final created = controller.dock.where((item) => item.kind == 'file' && item.outgoing && !before.contains(item.fileId)).map((item) => {'fileId': item.fileId, 'transferId': item.transferId, 'name': item.title, 'size': item.size}).toList();
            final record = {'createdAt': DateTime.now().toIso8601String(), 'targetDeviceId': target, 'routePreference': mode, 'files': created};
            await offers.writeAsString('${jsonEncode(record)}\n', mode: FileMode.append, flush: true);
            request.response.write(jsonEncode(record));
          } else if (request.method == 'POST' && request.uri.path == '/peer/close') {
            controller.peerHeartbeat?.cancel();
            await controller.peer?.close(); controller.peer = null;
            request.response.write('{"peerAlive":false}');
          } else if (request.method == 'POST' && request.uri.path == '/peer/reopen') {
            controller.peerHeartbeat?.cancel(); await controller.peer?.close(); controller.peer = null;
            await controller.startPeer(); request.response.write(jsonEncode(status()));
          } else if (request.method == 'POST' && request.uri.path == '/stop') {
            request.response.write('{"stopping":true}');
            stopAfterReply = true;
          } else { request.response.statusCode = 404; request.response.write('{"error":"Unknown control endpoint"}'); }
        } catch (error) {
          request.response.statusCode = 500; request.response.write(jsonEncode({'error': '$error'}));
        } finally {
          await request.response.close();
          if (stopAfterReply && !stop.isCompleted) stop.complete();
        }
      });
      final ready = {
        'controlUrl': 'http://127.0.0.1:${control.port}', 'controlToken': controlToken,
        'deviceId': controller.profile!.deviceId, 'name': 'Windows headless network probe',
        'pid': pid, 'base': fixture['base'], 'candidates': controller.peer!.candidates,
        'samples': [for (final file in [large, chinese, empty]) {'path': file.path, 'size': await file.length()}],
      };
      await File('${workspace.path}/control.json').writeAsString(jsonEncode(ready), flush: true);
      stdout.writeln('LIVE_NATIVE_PEER_READY ${workspace.path}/control.json');
      await stop.future;
    } finally {
      await control?.close(force: true);
      controller.dispose();
      await File('${workspace.path}/stopped.json').writeAsString(jsonEncode({'stoppedAt': DateTime.now().toIso8601String()}), flush: true);
    }
  }, timeout: const Timeout(Duration(hours: 4)));
}
