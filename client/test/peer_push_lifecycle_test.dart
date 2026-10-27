import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/peer_receive.dart';

void main() {
  test('stopping a streaming push closes its writer before another attempt resumes the same partial', () async {
    final folder = await (await Directory(
      'build/test-tmp',
    ).create(recursive: true)).createTemp('push-lifecycle-');
    final file = File('${folder.path}/received.part');
    final bytes = List<int>.generate(256000, (i) => i % 251);
    final prefixWritten = Completer<void>();
    final old = PeerReceiveSlot(
      transferId: 't',
      fileId: 'f',
      attemptId: 'old',
      file: file,
      size: bytes.length,
      offset: 0,
      onProgress: (count) {
          if (count >= 4000 && !prefixWritten.isCompleted) {
          prefixWritten.complete();
          }
      },
    );
    PeerReceiveSlot? next;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    server.listen((request) async {
      request.response.persistentConnection = false;
      final slot = request.uri.path == '/old' ? old : next!;
      await slot.receive(request, {
        'attemptId': slot.attemptId,
        'offset': slot.offset,
        'size': slot.size,
      });
      await request.response.close();
    });
    try {
      final first = await client.putUrl(
        Uri.parse('http://127.0.0.1:${server.port}/old'),
      );
      first.contentLength = bytes.length;
      first.bufferOutput = false;
      first.add(bytes.take(4000).toList());
      await first.flush();
      await prefixWritten.future.timeout(const Duration(seconds: 5));
      await old.stop().timeout(const Duration(seconds: 5));
      expect(await old.completed, isNotNull);
      final offset = await file.length();
      expect(offset, 4000);
      next = PeerReceiveSlot(
        transferId: 't',
        fileId: 'f',
        attemptId: 'next',
        file: file,
        size: bytes.length,
        offset: offset,
        onProgress: (_) {},
      );
      // A late write on the old socket must not enter the new receive slot.
      try {
        first.add(List.filled(bytes.length - offset, 99));
        final response = await first.close();
        await response.drain<void>();
      } catch (_) {
        /* The old socket may already have been closed by the server. */
      }
      expect(await file.length(), offset);
      final second = await client.putUrl(
        Uri.parse('http://127.0.0.1:${server.port}/next'),
      );
      second.contentLength = bytes.length - offset;
      second.add(bytes.sublist(offset));
      final response = await second.close();
      await response.drain<void>();
      expect(response.statusCode, 200);
      expect(await next.completed, isNull);
      expect(await file.readAsBytes(), bytes);
    } finally {
      await old.stop();
      await next?.stop();
      client.close(force: true);
      await server.close(force: true);
      await folder.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 25)));
}
