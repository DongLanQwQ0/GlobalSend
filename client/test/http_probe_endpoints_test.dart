import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/reachability.dart';

void main() {
  setUp(() => HttpOverrides.global = null);
  test('peer probe reports the connected source and target socket without changing source binding', () async {
    final identity = createPeerIdentity('probe-endpoints');
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity['certificate']!))
      ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
    final pin = certificateFingerprint(identity['certificate']!);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final seenPorts = <int>[];
    server.listen((request) async {
      seenPorts.add(request.connectionInfo!.remotePort);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'nonce': request.uri.queryParameters['nonce'],
          'certificateSha256': pin,
        }),
      );
      await request.response.close();
    });
    try {
      for (final source in [null, '127.0.0.1']) {
        ProbeEndpoints? observed;
        final result = await probePeerAddress(
          'https://127.0.0.1:${server.port}',
          pin,
          false,
          sourceAddress: source,
          onConnected: (value) => observed = value,
        );
        expect(result.reachable, isTrue, reason: result.error);
        expect(observed!.sourceEndpoint, '127.0.0.1:${seenPorts.last}');
        expect(observed!.targetEndpoint, '127.0.0.1:${server.port}');
      }
      ProbeEndpoints? unverified;
      final wrong = await probePeerAddress(
        'https://127.0.0.1:${server.port}',
        '0' * 64,
        false,
        onConnected: (value) => unverified = value,
      );
      expect(wrong.reachable, isFalse);
      expect(
        unverified,
        isNull,
        reason: 'a connected TCP socket is not a verified peer receipt',
      );
    } finally {
      await server.close(force: true);
    }
  });

  test('center readiness reports its actual endpoints and keeps HTTP failure unconnected', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var sourcePort = 0;
    server.listen((request) async {
      sourcePort = request.connectionInfo!.remotePort;
      request.response.statusCode = request.uri.path == '/ready' ? 200 : 503;
      request.response.write('{}');
      await request.response.close();
    });
    try {
      ProbeEndpoints? observed;
      final success = await probeCenter(
        'http://127.0.0.1:${server.port}/ready',
        '',
        false,
        onConnected: (value) => observed = value,
      );
      expect(success.reachable, isTrue, reason: success.error);
      expect(observed!.sourceEndpoint, '127.0.0.1:$sourcePort');
      expect(observed!.targetEndpoint, '127.0.0.1:${server.port}');
      observed = null;
      final failed = await probeCenter(
        'http://127.0.0.1:${server.port}/failed',
        '',
        false,
        onConnected: (value) => observed = value,
      );
      expect(failed.reachable, isFalse);
      expect(observed, isNull);
      expect(probeEndpoint(InternetAddress('::1'), 8787), '[::1]:8787');
    } finally {
      await server.close(force: true);
    }
  });
}
