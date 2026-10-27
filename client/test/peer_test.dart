import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/peer.dart';

void main() {
  test(
    'deprecated site-local IPv6 stays in LAN publication and connection stages',
    () async {
      final values = ['https://[fec0::2]:1234', 'https://[feff::2]:1234'];
      for (final value in values) {
        expect(PeerTransport.privateCandidate(value), true);
      }
      final stages = await PeerTransport.candidateStages(values);
      expect(stages.lan, values);
      expect(stages.public, isEmpty);
    },
  );
  test('peer requires exact certificate, nonce challenge and consumed center grant before streaming', () async {
    final testRoot = Directory('build/test-tmp');
    await testRoot.create(recursive: true);
    final folder = await testRoot.createTemp('globalsend-peer-');
    final source = File('${folder.path}/source.bin');
    final bytes = List<int>.generate(300000, (i) => i % 251);
    final hash = sha256.convert(bytes).toString();
    await source.writeAsBytes(bytes);
    final center = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var used = false, validated = 0;
    center.listen((r) async {
      final body = jsonDecode(await utf8.decoder.bind(r).join());
      if (r.uri.path.endsWith('/verify')) {
        validated++;
        if (r.headers.value('authorization') != 'Bearer sender-private' ||
            body['ticket'] != 'once' ||
            used) {
          r.response.statusCode = 403;
          r.response.write('{"error":{"message":"denied"}}');
        } else {
          used = true;
          r.response.write(
            jsonEncode({
              'size': bytes.length,
              'fileId': 'file',
              'transferId': 'batch',
              'sha256': hash,
            }),
          );
        }
      } else {
        r.response.write('{}');
      }
      await r.response.close();
    });
    final api = CenterApi(
      'http://127.0.0.1:${center.port}',
      token: 'sender-private',
    );
    final peer = PeerTransport(api, (id) => id == 'file' ? source.path : null);
    try {
      await peer.start(createPeerIdentity('test'), loopbackOnly: true);
      expect(peer.fingerprint.length, 64);
      final route = await PeerTransport.probeCandidates(
        peer.candidates,
        peer.fingerprint,
        'challenge',
      );
      expect(validated, 0);
      final wrong = PeerTransport.pinnedClient(List.filled(64, '0').join());
      try {
        await expectLater(() async {
          final r = await wrong.getUrl(Uri.parse('$route/probe?nonce=a'));
          await r.close();
        }, throwsA(isA<HandshakeException>()));
      } finally {
        wrong.close(force: true);
      }
      final destination = File('${folder.path}/received.bin');
      await destination.writeAsBytes(bytes.take(12345).toList());
      var progress = 0;
      int? firstProgress;
      await PeerTransport.pull(
        '$route/',
        peer.fingerprint,
        'once',
        'batch',
        'file',
        destination,
        (n) {
          firstProgress ??= n;
          progress = n;
        },
        expectedSha256: hash,
        expectedSize: bytes.length,
        sourceAddress: '127.0.0.1',
      );
      expect(await destination.readAsBytes(), bytes);
      expect(progress, bytes.length);
      expect(firstProgress, 12345);
      expect(validated, 1);
      await expectLater(
        PeerTransport.pull(
          route,
          peer.fingerprint,
          'once',
          'batch',
          'file',
          destination,
          (_) {},
        ),
        throwsA(isA<HttpException>()),
      );
      expect(validated, 2);
    } finally {
      await peer.close();
      api.close();
      await center.close(force: true);
      if (!folder.absolute.path.startsWith(
        '${testRoot.absolute.path}${Platform.pathSeparator}',
      )) {
        throw StateError('Unsafe test cleanup path');
      }
      await folder.delete(recursive: true);
    }
  });
}
