import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/rtc_transport.dart';

// Hidden test consumer of the production transport. Only synthetic credentials
// and files in the supplied project-local run directory are used.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final root = Directory(args.single)..createSync(recursive: true);
  CenterApi? api;
  RtcFileTransport? transport;
  Future<void>? operation;
  var state = 'idle', progress = 0, error = '';
  final destination = File('${root.path}/received.part');
  final source = File('${root.path}/source.bin');
  Future<void> fixture(File file, int size) async {
    final sink = file.openWrite();
    try {
      for (var offset = 0; offset < size; offset += 16384) {
        final length = size - offset < 16384 ? size - offset : 16384;
        sink.add(List.generate(length, (i) => (offset + i) % 251));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  void start(Future<void> Function() action) {
    if (state == 'running') {
      throw StateError('Another fixture operation is active');
    }
    state = 'running';
    progress = 0;
    error = '';
    operation = (() async {
      try {
        await action();
        state = 'done';
      } catch (failure, stack) {
        error = '$failure\n$stack';
        state = 'failed';
      }
    })();
  }

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
            await transport?.close();
            api?.close();
            api = CenterApi(
              body['base'] as String,
              token: body['token'] as String,
            );
            transport = RtcFileTransport(api!);
          case '/prepare':
            if (state == 'running') throw StateError('Fixture is busy');
            await fixture(source, body['size'] as int);
            await fixture(destination, body['offset'] as int? ?? 0);
          case '/receive':
            start(
              () => transport!.receive(
                fileRoute: body['fileRoute'] as String,
                attemptId: body['attemptId'] as String,
                scope: body['scope'] as String,
                destination: destination,
                size: body['size'] as int,
                onProgress: (count) => progress = count,
              ),
            );
          case '/send':
            start(
              () => transport!.send(
                fileRoute: body['fileRoute'] as String,
                attempt: Map<String, dynamic>.from(body['attempt'] as Map),
                source: source,
                size: body['size'] as int,
                onProgress: (count) => progress = count,
              ),
            );
          case '/state':
            result = {
              'state': state,
              'progress': progress,
              'error': error,
              'destination': destination.path,
              'source': source.path,
            };
          case '/close':
            await transport?.close();
            await operation;
            api?.close();
            Timer(const Duration(milliseconds: 200), () => exit(0));
          default:
            request.response.statusCode = 404;
            result = {'error': 'Unknown synthetic fixture endpoint'};
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(result));
      } catch (failure) {
        request.response.statusCode = 500;
        request.response.write(jsonEncode({'error': '$failure'}));
      } finally {
        await request.response.close();
      }
    });
    runApp(const SizedBox.shrink());
  } catch (failure, stack) {
    await File('${root.path}/startup-error.txt')
        .writeAsString('$failure\n$stack');
    exit(1);
  }
}
