import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/local_ip_addresses.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/reverse_https_probe.dart';

import 'fast_routes_test.dart' show FastApi, FastController;

class MeasuredReverse extends ReverseHttpsProbes {
  MeasuredReverse(CenterApi api, this.scope, {required this.warm})
    : super(
        api,
        localAddresses: () async => <LocalIpAddress>[],
        cellularAllowed: () => false,
        periodic: false,
      );
  final String scope;
  final bool warm;
  final started = <String>[];
  Map<String, dynamic> result(String phase) => {
    'tested': true,
    'reachable': phase == scope,
    'cellular': false,
    'elapsedMs': 10,
  };
  @override
  Map<String, dynamic>? cached(String id, String phase) =>
      warm ? result(phase) : null;
  @override
  Future<Map<String, dynamic>?> check(
    String id,
    String phase, {
    Duration limit = const Duration(seconds: 1),
  }) async {
    started.add(phase);
    if (!warm) await Future<void>.delayed(const Duration(milliseconds: 40));
    return result(phase);
  }
}

class ReverseReceiveApi extends FastApi {
  ReverseReceiveApi(
    this.bytes, {
    required String candidate,
    required String fingerprint,
  }) : super(
         sha256.convert(bytes).toString(),
         candidate: candidate,
         fingerprint: fingerprint,
       );
  final List<int> bytes;
  late PeerTransport receiver;
  late MeasuredReverse measurements;
  final uploads = <Future<void>>[];
  final uploadStatuses = <int>[];
  String attempt = '';
  int offset = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path == '/transfers/t')
      expect(measurements.started.toSet(), {'lan', 'public'});
    if (path.endsWith('/direct-push')) {
      calls.add('$method $path');
      final data = body as Map;
      attempt = data['attemptId'];
      offset = data['offset'];
      uploads.add(() async {
        final client = HttpClient()
          ..badCertificateCallback = (cert, host, port) =>
              certificateFingerprint(cert.pem) == receiver.fingerprint;
        try {
          final request = await client.putUrl(
            Uri.parse('${receiver.candidates.first}/push/t/f/$attempt'),
          );
          request.headers.set('X-GlobalSend-Ticket', 'fixture');
          request.contentLength = bytes.length - offset;
          request.add(bytes.sublist(offset));
          final response = await request.close();
          uploadStatuses.add(response.statusCode);
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
      }());
      return {};
    }
    if (path == '/push-tickets/verify')
      return {'attemptId': attempt, 'offset': offset, 'size': bytes.length};
    // The polling response preserves the active reverse file attempt.
    final response = await super.call(method, path, body, authenticated);
    if (path == '/transfers/t' && attempt.isNotEmpty) {
      (response['transfer']['files'] as List).first['directPush'] = {
        'attemptId': attempt,
        'state': 'connecting',
      };
    }
    return response;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Map<String, String> identity;
  setUpAll(() => identity = createPeerIdentity('parallel-reverse-fixture'));

  for (final scope in ['lan', 'public']) {
    for (final warm in [true, false]) {
      test(
        '$scope ${warm ? 'warm' : 'cold'} reverse writes real TLS file without waiting for stalled forward',
        () async {
          final parent = await Directory('build/test-tmp/parallel-transport')
              .create(recursive: true);
          final directory = await parent.createTemp('case-');
          ReceiveDestination.registryDirectoryForTesting = () async =>
              Directory('${directory.path}/registry');
          final stalled = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final sockets = <Socket>[];
          stalled.listen(sockets.add);
          final bytes = utf8.encode(
            'parallel readiness chooses a single reverse writer',
          );
          final api = ReverseReceiveApi(
            bytes,
            candidate: 'https://127.0.0.1:${stalled.port}',
            fingerprint: certificateFingerprint(identity['certificate']!),
          );
          final measurements = MeasuredReverse(api, scope, warm: warm);
          api.measurements = measurements;
          final receiver = PeerTransport(api, (_) => null, pushEnabled: true);
          api.receiver = receiver;
          await receiver.start(identity, loopbackOnly: true);
          final controller =
              FastController(
                  directory,
                  stages: (values) async => (
                    lan: scope == 'lan' ? values : <String>[],
                    public: scope == 'public' ? values : <String>[],
                  ),
                )
                ..api = api
                ..profile = ServerProfile(
                  baseUrl: api.baseUrl,
                  instanceId: 'fixture',
                  deviceId: 'self',
                )
                ..peer = receiver
                ..reverseHttpsProbes = measurements
                ..info = {
                  'features': {'direct': true, 'directPush': true},
                }
                ..devices = [
                  {
                    'deviceId': 'sender',
                    'peer': {
                      'candidates': [api.candidate],
                      'certificateSha256': api.fingerprint,
                      'push': true,
                      'httpsProbe': true,
                    },
                  },
                ];
          final entry = DockEntry(
            id: 'f',
            kind: 'file',
            title: 'reverse.bin',
            source: 'sender',
            transferId: 't',
            fileId: 'f',
            size: bytes.length,
            status: 'accepted',
          );
          controller.dock = [entry];
          try {
            final watch = Stopwatch()..start();
            await controller.receive(entry);
            await Future.wait(api.uploads);
            print(
              'PARALLEL_REVERSE_TIMING $scope warm=$warm ${watch.elapsedMilliseconds}ms',
            );
            expect(
              entry.status,
              'received',
              reason: '${entry.error} ${api.calls}',
            );
            expect(entry.route, scope);
            expect(api.uploadStatuses, [200]);
            expect(await File(entry.localPath).readAsBytes(), bytes);
            expect(
              api.calls.where((value) => value.endsWith('/direct-ticket')),
              isEmpty,
            );
            expect(
              api.calls.where((value) => value.endsWith('/relay')),
              isEmpty,
            );
            expect(watch.elapsedMilliseconds, lessThan(1000));
          } finally {
            controller.dispose();
            await measurements.close();
            receiver.close();
            for (final socket in sockets) socket.destroy();
            await stalled.close();
            ReceiveDestination.registryDirectoryForTesting = null;
            await directory.delete(recursive: true);
          }
        },
      );
    }
  }
}
