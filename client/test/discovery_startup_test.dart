import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/rtc_transport.dart';

class PublishedPeer extends PeerTransport {
  PublishedPeer(CenterApi api) : super(api, (_) => null);
  @override
  Future<void> publish() async {
    await api.call('POST', '/devices/me/peer', {});
  }
}

class PublishedRtc extends RtcFileTransport {
  PublishedRtc(super.api);
  @override
  Future<void> publish() async {
    await api.call('POST', '/devices/me/rtc', {
      'scopes': ['lan', 'public'],
    });
  }
}

class StartupController extends SendController {
  int peerStarts = 0, rtcStarts = 0;
  @override
  Future<void> startPeer() async {
    peerStarts++;
    peer = PublishedPeer(api!);
    await peer!.publish();
  }

  @override
  Future<void> startRtc() async {
    rtcStarts++;
    rtc = PublishedRtc(api!);
    await rtc!.publish();
  }

  @override
  Future<void> safeReconcile() async {}
}

void main() {
  test('startup and reconnect publish addresses only after WS hello, without re-enrolling', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final connections = StreamController<WebSocket>();
    final sockets = <WebSocket>[];
    final published = <String>[];
    var helloSent = false, earlyPublish = false, enrollments = 0;
    server.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((_) {});
        connections.add(socket);
        return;
      }
      final path = request.uri.path;
      if (request.method == 'POST') await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      if (path.endsWith('/ws-ticket')) {
        request.response.write('{"ticket":"fixture"}');
      } else {
        if (path.endsWith('/enroll')) enrollments++;
        if (path.endsWith('/peer') || path.endsWith('/rtc')) {
          earlyPublish |= !helloSent;
          published.add(path.split('/').last);
        }
        request.response.write('{}');
      }
      await request.response.close();
    });
    final api = CenterApi(
      'http://127.0.0.1:${server.port}',
      token: 'retained-token',
    );
    final controller = StartupController()
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
        name: '保留自定义名',
      );
    final incoming = StreamIterator(connections.stream);
    try {
      final starting = controller.start();
      expect(await incoming.moveNext(), isTrue);
      expect(published, isEmpty);
      expect(controller.connected, false);
      helloSent = true;
      incoming.current.add(
        jsonEncode({'type': 'hello', 'deviceId': 'self', 'protocolVersion': 1}),
      );
      await starting;
      expect(published, ['peer', 'rtc']);
      expect(earlyPublish, false);
      controller.devices = [
        {
          'deviceId': 'peer',
          'online': true,
          'peer': {
            'candidates': ['old-address'],
          },
        },
      ];
      await incoming.current.close();
      for (var i = 0; i < 100 && controller.connected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(controller.devices.single['peer']['candidates'], ['old-address']);
      expect(controller.devices.single['online'], false);
      expect(controller.sendablePeers.single['deviceId'], 'peer');
      expect(controller.onlinePeers, isEmpty);
      helloSent = false;
      final reconnecting = controller.openSocket(controller.generation);
      expect(await incoming.moveNext(), isTrue);
      expect(published, ['peer', 'rtc']);
      helloSent = true;
      incoming.current.add(
        jsonEncode({'type': 'hello', 'deviceId': 'self', 'protocolVersion': 1}),
      );
      await reconnecting;
      expect(controller.onlinePeers, isEmpty);
      expect(published, ['peer', 'rtc', 'peer', 'rtc']);
      expect(controller.peerStarts, 1);
      expect(controller.rtcStarts, 1);
      expect(enrollments, 0);
      expect(api.token, 'retained-token');
      expect(controller.profile!.name, '保留自定义名');
    } finally {
      controller.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await incoming.cancel();
      await connections.close();
      await server.close(force: true);
    }
  });
}
