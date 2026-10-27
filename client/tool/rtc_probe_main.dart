import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = Directory(args.single)..createSync(recursive: true);
  try {
    final pc = await createPeerConnection({
      'iceServers': <Object>[],
      'sdpSemantics': 'unified-plan',
    });
    final candidates = <Map<String, dynamic>>[];
    final errors = <String>[];
    var connectionState = '', channelState = '', received = 0, messages = 0;
    RTCDataChannel? channel;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty == true) {
        candidates.add(candidate.toMap());
      }
    };
    pc.onConnectionState = (state) => connectionState = state.name;
    pc.onDataChannel = (value) {
      channel = value;
      value.onDataChannelState = (state) => channelState = state.name;
      value.onMessage = (message) async {
        try {
          messages++;
          if (message.isBinary) {
            final bytes = message.binary;
            for (var i = 0; i < bytes.length; i++) {
              if (bytes[i] != (received + i) % 251) {
                throw StateError('Binary order/content mismatch');
              }
            }
            received += bytes.length;
            await value.send(RTCDataChannelMessage.fromBinary(bytes));
          } else {
            await value.send(RTCDataChannelMessage('native:${message.text}'));
          }
        } catch (error) {
          errors.add('$error');
        }
      };
    };
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    await File('${root.path}/control.json').writeAsString(
      jsonEncode({'url': 'http://127.0.0.1:${server.port}'}),
      flush: true,
    );
    server.listen((request) async {
      try {
        final body = request.method == 'POST'
            ? jsonDecode(await utf8.decoder.bind(request).join())
            : null;
        Object? result;
        switch (request.uri.path) {
          case '/state':
            result = {
              'candidates': candidates,
              'connectionState': connectionState,
              'channelState': channelState,
              'receivedBytes': received,
              'messages': messages,
              'errors': errors,
            };
          case '/offer':
            await pc.setRemoteDescription(
              RTCSessionDescription(body['sdp'], body['type']),
            );
            final answer = await pc.createAnswer();
            await pc.setLocalDescription(answer);
            result = answer.toMap();
          case '/candidate':
            await pc.addCandidate(
              RTCIceCandidate(
                body['candidate'],
                body['sdpMid'],
                body['sdpMLineIndex'],
              ),
            );
            result = {'ok': true};
          case '/close':
            await channel?.close();
            await pc.close();
            result = {'ok': true};
            Timer(const Duration(milliseconds: 200), () => exit(0));
          default:
            request.response.statusCode = 404;
            result = {'error': 'Unknown probe endpoint'};
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
      } catch (error) {
        errors.add('$error');
        request.response.statusCode = 500;
        request.response.write(jsonEncode({'error': '$error'}));
      } finally {
        await request.response.close();
      }
    });
    runApp(const SizedBox.shrink());
  } catch (error, stack) {
    await File('${root.path}/startup-error.txt')
        .writeAsString('$error\n$stack');
    exit(1);
  }
}
