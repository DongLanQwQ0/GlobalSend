import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/rtc_connection.dart';
import 'package:globalsend/rtc_probe.dart';

// Isolated, hidden consumer. No product profile, file offer or storage.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = Directory(args.single)..createSync(recursive: true);
  CenterApi? api;
  RtcProbeMonitor? monitor;
  var created = 0, closed = 0, channelsClosed = 0;
  try {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    await File('${root.path}/control.json').writeAsString(
      jsonEncode({'url': 'http://127.0.0.1:${server.port}'}),
      flush: true,
    );
    server.listen((request) async {
      try {
        final body = request.method == 'POST'
            ? jsonDecode(await utf8.decoder.bind(request).join())
                  as Map<String, dynamic>
            : <String, dynamic>{};
        Object result = {'ok': true};
        switch (request.uri.path) {
          case '/configure':
            await monitor?.close();
            api?.close();
            api = CenterApi(body['base'], token: body['token']);
            monitor = RtcProbeMonitor(
              api!,
              body['deviceId'],
              connectionFactory:
                  ({
                    required scope,
                    required allowCellular,
                    required iceServers,
                  }) async {
                    if (allowCellular || iceServers.isNotEmpty) {
                      throw StateError(
                        'Idle probe attempted paid-network activation',
                      );
                    }
                    final pc = await createRtcProbeConnection(
                      scope: scope,
                      allowCellular: allowCellular,
                      iceServers: iceServers,
                    );
                    created++;
                    return _Connection(
                      pc,
                      () => closed++,
                      () => channelsClosed++,
                    );
                  },
            );
          case '/presence':
            monitor!.update(
              online: body['online'] == true,
              foreground: body['foreground'] == true,
              devices: List<Map<String, dynamic>>.from(body['devices']),
            );
          case '/refresh':
            unawaited(monitor!.signalChanged());
          case '/invalidate':
            unawaited(monitor!.invalidate());
          case '/state':
            result = {
              'active': monitor?.active ?? false,
              'session': monitor?.hasActiveSession ?? false,
              'created': created,
              'closed': closed,
              'channelsClosed': channelsClosed,
              'results': monitor?.results ?? [],
            };
          case '/shutdown':
            await monitor?.close();
            api?.close();
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'ok': true}));
            await request.response.close();
            await server.close(force: true);
            exit(0);
          default:
            throw StateError('Unknown fixture command');
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
        await request.response.close();
      } catch (error, stack) {
        request.response.statusCode = 500;
        request.response.write(jsonEncode({'error': '$error\n$stack'}));
        await request.response.close();
      }
    });
  } catch (error, stack) {
    await File('${root.path}/startup-error.txt')
        .writeAsString('$error\n$stack');
    exit(1);
  }
}

class _Connection implements RtcDataConnection {
  _Connection(this.pc, this.closed, this.channelClosed);
  final RtcDataConnection pc;
  final void Function() closed, channelClosed;
  Future<void>? _closing;
  @override
  set onIceCandidate(void Function(RTCIceCandidate)? v) =>
      pc.onIceCandidate = v;
  @override
  set onConnectionState(void Function(RTCPeerConnectionState)? v) =>
      pc.onConnectionState = v;
  @override
  set onNetwork(void Function(String, String)? v) => pc.onNetwork = v;
  @override
  set onDataChannel(void Function(RtcDataChannel)? v) => pc.onDataChannel =
      v == null ? null : (c) => v(_Channel(c, channelClosed));
  @override
  Future<RTCSessionDescription> createOffer(Map<String, dynamic> v) =>
      pc.createOffer(v);
  @override
  Future<RTCSessionDescription> createAnswer(Map<String, dynamic> v) =>
      pc.createAnswer(v);
  @override
  Future<void> setLocalDescription(RTCSessionDescription v) =>
      pc.setLocalDescription(v);
  @override
  Future<void> setRemoteDescription(RTCSessionDescription v) =>
      pc.setRemoteDescription(v);
  @override
  Future<void> addCandidate(RTCIceCandidate v) => pc.addCandidate(v);
  @override
  Future<RtcDataChannel> createDataChannel(String label) async =>
      _Channel(await pc.createDataChannel(label), channelClosed);
  @override
  Future<void> authorizeData() => pc.authorizeData();
  @override
  Future<void> close() => _closing ??= () async {
    await pc.close();
    closed();
  }();
}

class _Channel implements RtcDataChannel {
  _Channel(this.channel, this.closed);
  final RtcDataChannel channel;
  final void Function() closed;
  Future<void>? _closing;
  @override
  String? get label => channel.label;
  @override
  RTCDataChannelState? get state => channel.state;
  @override
  set onDataChannelState(void Function(RTCDataChannelState)? v) =>
      channel.onDataChannelState = v;
  @override
  set onMessage(void Function(RTCDataChannelMessage)? v) =>
      channel.onMessage = v;
  @override
  Future<int> getBufferedAmount() => channel.getBufferedAmount();
  @override
  Future<void> send(RTCDataChannelMessage v) => channel.send(v);
  @override
  Future<void> close() => _closing ??= () async {
    await channel.close();
    closed();
  }();
}
