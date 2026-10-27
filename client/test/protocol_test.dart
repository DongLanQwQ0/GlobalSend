import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

void main() {
  test(
    'native API preserves prefix, isolates bearer and refuses redirects',
    () async {
      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        requests.add('${r.uri.path}:${r.headers.value('authorization')}');
        if (r.uri.path.endsWith('/redirect')) {
          r.response.statusCode = 302;
          r.response.headers.set('location', 'http://127.0.0.1:1/leak');
        }
        r.response.headers.contentType = ContentType.json;
        r.response.write('{}');
        await r.response.close();
      });
      final api = CenterApi(
        'http://127.0.0.1:${server.port}/Prefix',
        token: 'private',
      );
      try {
        await api.call('GET', '/info', null, false);
        await api.call('GET', '/devices');
        await expectLater(
          api.call('GET', '/redirect'),
          throwsA(isA<ApiException>()),
        );
        expect(requests[0], '/Prefix/api/v1/info:null');
        expect(requests[1], '/Prefix/api/v1/devices:Bearer private');
        expect(requests.length, 3);
      } finally {
        api.close();
        await server.close(force: true);
      }
    },
  );
  test(
    'event replay is idempotent while manual duplicate text remains separate',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var acknowledgements = 0;
      server.listen((r) async {
        Object response = {};
        if (r.uri.path.endsWith('/devices')) response = {'devices': []};
        if (r.uri.path.endsWith('/events')) {
          response = {
            'events': [
              for (final id in ['one', 'two'])
                {
                  'eventId': id,
                  'type': 'text.created',
                  'sourceDeviceId': 'sender',
                  'targetDeviceId': 'receiver',
                  'payload': {'text': '相同正文'},
                },
            ],
            'cursor': 2,
            'hasMore': false,
          };
        }
        if (r.uri.path.endsWith('/ack')) acknowledgements++;
        if (r.uri.path.endsWith('/transfers')) response = {'transfers': []};
        r.response.headers.contentType = ContentType.json;
        r.response.write(jsonEncode(response));
        await r.response.close();
      });
      final c = SendController()
        ..profile = ServerProfile(
          baseUrl: 'http://127.0.0.1:${server.port}',
          instanceId: 'test',
          deviceId: 'receiver',
        )
        ..api = CenterApi('http://127.0.0.1:${server.port}', token: 'token');
      try {
        await c.reconcile();
        await c.reconcile();
        expect(c.dock.length, 2);
        expect(c.profile!.cursor, 2);
        expect(acknowledgements, 4);
        expect(c.dock.every((e) => e.text == '相同正文'), isTrue);
      } finally {
        c.dispose();
        await server.close(force: true);
      }
    },
  );
  test('file received ACK occurs only after streaming length and digest validation', () async {
    final testRoot = Directory('build/test-tmp');
    await testRoot.create(recursive: true);
    final folder = await testRoot.createTemp('globalsend-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bytes = utf8.encode('跨设备的文件内容');
    var corrupt = true, received = 0;
    final hash = sha256.convert(bytes).toString();
    server.listen((r) async {
      if (r.uri.path.contains('/downloads/')) {
        r.response.add(corrupt ? [1, 2, 3] : bytes);
        await r.response.close();
        return;
      }
      Object response = {};
      if (r.uri.path.endsWith('/transfers/batch')) {
        response = {
          'transfer': {
            'files': [
              {'fileId': 'file', 'sha256': hash},
            ],
          },
        };
      }
      if (r.uri.path.endsWith('/download-ticket')) {
        response = {'downloadPath': '/api/v1/downloads/short-ticket'};
      }
      if (r.uri.path.endsWith('/received')) received++;
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode(response));
      await r.response.close();
    });
    final c = SendController(documentsDirectory: () async => folder)
      ..profile = ServerProfile(
        baseUrl: 'http://127.0.0.1:${server.port}',
        instanceId: 'test',
      )
      ..api = CenterApi('http://127.0.0.1:${server.port}', token: 'token');
    final entry = DockEntry(
      id: 'file',
      kind: 'file',
      title: '../../CON.txt',
      source: 'sender',
      transferId: 'batch',
      fileId: 'file',
      size: bytes.length,
    );
    try {
      await c.receive(entry);
      expect(entry.status, 'failed');
      expect(received, 0);
      expect(entry.localPath, isEmpty);
      corrupt = false;
      await c.receive(entry);
      expect(entry.status, 'received');
      expect(received, 1);
      expect(await File(entry.localPath).readAsBytes(), bytes);
      expect(entry.localPath, contains('file_CON.txt'));
    } finally {
      c.dispose();
      await server.close(force: true);
      if (!folder.absolute.path.startsWith(
        '${testRoot.absolute.path}${Platform.pathSeparator}',
      )) {
        throw StateError('Unsafe test cleanup path');
      }
      await folder.delete(recursive: true);
    }
  });
}
