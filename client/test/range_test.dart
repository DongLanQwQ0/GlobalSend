import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';

void main() {
  test('relay resumes with matching 206, rewrites on 200, rejects a wrong append offset', () async {
    final root = Directory('build/test-tmp'); await root.create(recursive: true);
    final folder = await root.createTemp('native-range-');
    final bytes = List<int>.generate(140000, (index) => index % 251);
    final hash = sha256.convert(bytes).toString();
    final partial = File('${folder.path}/received.part');
    final ranges = <String?>[], validators = <String?>[];
    var responseMode = 'resume';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      validators.add(request.headers.value(HttpHeaders.ifRangeHeader));
      request.response.headers.set(HttpHeaders.etagHeader, '"sha256-$hash"');
      if (responseMode == 'rewrite') {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      } else {
        request.response.statusCode = 206;
        final start = responseMode == 'wrong-offset' ? 0 : 12345;
        request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${bytes.length - 1}/${bytes.length}');
        request.response.contentLength = bytes.length - start;
        request.response.add(bytes.sublist(start));
      }
      await request.response.close();
    });
    final api = CenterApi('http://127.0.0.1:${server.port}');
    try {
      await partial.writeAsBytes(bytes.take(12345).toList());
      await api.download('/api/v1/downloads/first', partial, (_) {}, expectedSha256: hash, expectedSize: bytes.length);
      expect(await partial.readAsBytes(), bytes);
      responseMode = 'rewrite';
      await partial.writeAsBytes(bytes.take(12345).toList());
      await api.download('/api/v1/downloads/new-ticket', partial, (_) {}, expectedSha256: hash, expectedSize: bytes.length);
      expect(await partial.readAsBytes(), bytes);
      responseMode = 'wrong-offset';
      await partial.writeAsBytes(bytes.take(12345).toList());
      await expectLater(api.download('/api/v1/downloads/another-ticket', partial, (_) {}, expectedSha256: hash, expectedSize: bytes.length), throwsFormatException);
      expect(await partial.readAsBytes(), bytes.take(12345).toList());
      expect(ranges, List.filled(3, 'bytes=12345-'));
      expect(validators, List.filled(3, '"sha256-$hash"'));
    } finally { api.close(); await server.close(force: true); }
  });
}
