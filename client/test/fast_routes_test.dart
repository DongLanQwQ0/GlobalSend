import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/connection_window.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/reachability.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/rtc_connection.dart';
import 'package:globalsend/rtc_transport.dart';
import 'package:globalsend/candidate_routes.dart';

import 'rtc_android_bridge_test.dart' show PendingPeer;

class FastApi extends CenterApi {
  FastApi(
    this.hash, {
    this.candidate = '',
    this.fingerprint = '',
    this.candidates,
  }) : super('https://fixture.invalid', token: 'fixture');
  final String hash, candidate, fingerprint;
  final List<String>? candidates;
  final calls = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    if (path == '/transfers/t')
      return {
        'transfer': {
          'files': [
            <String, dynamic>{
              'fileId': 'f',
              'status': 'accepted',
              'transport': null,
              'sha256': hash,
            },
          ],
        },
      };
    if (path.endsWith('/direct-ticket'))
      return {
        'candidates': candidates ?? [candidate],
        'certificateSha256': fingerprint,
        'ticket': 'fixture-ticket',
      };
    if (path.endsWith('/rtc')) return {'rtc': <String, dynamic>{}};
    return {};
  }
}

class FastController extends SendController {
  FastController(
    Directory directory, {
    ReachabilityMonitor? monitor,
    CandidateStages? stages,
    this.prepareDelay = Duration.zero,
  }) : super(
         documentsDirectory: () async => directory,
         reachability: monitor,
         addressStages:
             stages ?? (values) async => (lan: values, public: values),
       );
  final Duration prepareDelay;
  bool prepared = false;
  @override
  Future<void> save() async {
    if (!prepared && dock.any((item) => item.partialPath.isNotEmpty)) {
      prepared = true;
      await Future<void>.delayed(prepareDelay);
    }
  }
}

class DelayedMetadataApi extends FastApi {
  DelayedMetadataApi(super.hash);
  final metadataArrived = Completer<void>();
  final releaseMetadata = Completer<void>();
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path == '/transfers/t') {
      metadataArrived.complete();
      await releaseMetadata.future;
    }
    return super.call(method, path, body, authenticated);
  }
}

class SourcePairMonitor extends ReachabilityMonitor {
  SourcePairMonitor(this.routes)
    : super(
        stages: (values) async => (lan: values, public: <String>[]),
        probe: (_, _, _) async => (reachable: true, elapsedMs: 3, error: ''),
        relayProbe: (_, _, _) async =>
            (reachable: true, elapsedMs: 3, error: ''),
      );
  final List<CandidateRoute> routes;
  @override
  List<CandidateRoute>? plannedRoutes(
    List<String> addresses, {
    bool cellular = false,
  }) => routes;
}

class RefreshPeer extends PeerTransport {
  RefreshPeer(CenterApi api, this.order, this.gate) : super(api, (_) => null);
  final List<String> order;
  final Future<void> gate;
  @override
  Future<void> publish() async {
    order.add('publish-addresses');
    await gate;
  }
}

class RefreshRtc extends RtcFileTransport {
  RefreshRtc(super.api, this.order);
  final List<String> order;
  @override
  Future<void> publish() async {
    order.add('publish-rtc');
  }
}

class RefreshMonitor extends ReachabilityMonitor {
  RefreshMonitor(this.order);
  final List<String> order;
  @override
  Future<void> refresh() async {
    order.add('probe');
  }
}

class RefreshController extends SendController {
  RefreshController(this.order) : super(reachability: RefreshMonitor(order));
  final List<String> order;
  @override
  Future<void> reconcile() async {
    order.add('snapshot');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory directory;
  late Map<String, String> identity;
  setUpAll(() {
    identity = createPeerIdentity('fast-route-fixture');
  });
  setUp(() async {
    // Route ordering may reach RTC before this file's explicit late-create
    // fixture. Do not poison its process-wide initialization with a missing
    // host plugin; this suite supplies no real platform WebRTC engine.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const method = MethodChannel('FlutterWebRTC.Method');
    messenger.setMockMethodCallHandler(method, (_) async => <String, Object>{});
    addTearDown(() => messenger.setMockMethodCallHandler(method, null));
    final parent = await Directory('build/test-tmp/fast-routes')
        .create(recursive: true);
    directory = await parent.createTemp('case-');
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${directory.path}/registry');
  });
  tearDown(() async {
    ReceiveDestination.registryDirectoryForTesting = null;
    await directory.delete(recursive: true);
  });

  test('receive probes discovered IPs while metadata is pending and uses the same deadline', () async {
    final api = DelayedMetadataApi('unused');
    final fingerprint = certificateFingerprint(identity['certificate']!);
    final security = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity['certificate']!))
      ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      security,
    );
    final probeArrived = Completer<void>();
    server.listen((request) async {
      if (!probeArrived.isCompleted) probeArrived.complete();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'nonce': request.uri.queryParameters['nonce'],
          'certificateSha256': fingerprint,
        }),
      );
      await request.response.close();
    });
    // A healthy probe endpoint with metadata deliberately held by the center.
    final controller = FastController(directory)
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      )
      ..info = {
        'features': {'direct': true},
      }
      ..devices = [
        {
          'deviceId': 'sender',
          'peer': {
            'candidates': ['https://127.0.0.1:${server.port}'],
            'certificateSha256': fingerprint,
          },
        },
      ];
    final entry = DockEntry(
      id: 'f',
      kind: 'file',
      title: 'fixture.bin',
      source: 'sender',
      transferId: 't',
      fileId: 'f',
      size: 10,
      status: 'accepted',
    );
    controller.dock = [entry];
    final watch = Stopwatch()..start();
    final receiving = controller.receive(entry);
    await api.metadataArrived.future;
    // The real endpoint logs probes independently of the center RPC.
    await probeArrived.future.timeout(const Duration(milliseconds: 400));
    expect(api.releaseMetadata.isCompleted, false);
    await receiving;
    expect(watch.elapsedMilliseconds, lessThan(1450));
    expect(entry.status, 'failed');
    api.releaseMetadata.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(entry.status, 'failed');
    expect(entry.localPath, isEmpty);
    controller.dispose();
    await server.close(force: true);
  });

  test('live relay begins receiving while the sender is still uploading', () async {
    final content = utf8.encode('abcdef'),
        hash = sha256.convert(utf8.encode('abcdef')).toString();
    final uploaded = Completer<void>(), firstBytes = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var liveRequested = false, downloadStarted = false, firstFlushed = false;
    server.listen((request) async {
      if (request.uri.path == '/api/v1/downloads/live-fixture') {
        downloadStarted = true;
        request.response.bufferOutput = false;
        request.response.contentLength = content.length;
        request.response.add(content.sublist(0, 3));
        await request.response.flush();
        firstFlushed = true;
        await uploaded.future;
        request.response.add(content.sublist(3));
      } else {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/download-ticket')) {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          liveRequested = body['live'] == true;
          request.response.write(
            jsonEncode({'downloadPath': '/api/v1/downloads/live-fixture'}),
          );
        } else if (request.uri.path == '/api/v1/transfers/t') {
          request.response.write(
            jsonEncode({
              'transfer': {
                'files': [
                  {
                    'fileId': 'f',
                    'status': 'uploading',
                    'transport': 'relay',
                    'sha256': hash,
                  },
                ],
              },
            }),
          );
        } else
          request.response.write('{}');
      }
      await request.response.close();
    });
    final api = CenterApi('http://127.0.0.1:${server.port}');
    final controller = FastController(directory)
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      )
      ..info = {
        'features': {'direct': false, 'relayStreaming': true},
      };
    final entry = DockEntry(
      id: 'f',
      kind: 'file',
      title: 'live.bin',
      source: 'sender',
      transferId: 't',
      fileId: 'f',
      size: 6,
      status: 'accepted',
    );
    controller.dock = [entry];
    controller.addListener(() {
      if (entry.receivedBytes >= 3 && !firstBytes.isCompleted)
        firstBytes.complete();
    });
    try {
      final receiving = controller.receive(entry, routeOverride: 'relay');
      await firstBytes.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError(
          'status=${entry.status}, error=${entry.error}, route=${entry.routeDetail}, liveRequested=$liveRequested, downloadStarted=$downloadStarted, firstFlushed=$firstFlushed, received=${entry.receivedBytes}',
        ),
      );
      expect(uploaded.isCompleted, false);
      expect(liveRequested, true);
      expect(entry.status, 'downloading');
      uploaded.complete();
      await receiving;
      expect(entry.status, 'received');
      expect(await File(entry.localPath).readAsBytes(), content);
    } finally {
      if (!uploaded.isCompleted) uploaded.complete();
      controller.dispose();
      await server.close(force: true);
    }
  });

  test('all candidate probes begin together instead of 200ms-per-address staggering', () async {
    final api = FastApi('');
    final peer = PeerTransport(api, (_) => null);
    await peer.start(identity, loopbackOnly: true);
    final stalled = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    stalled.listen(sockets.add);
    try {
      final watch = Stopwatch()..start();
      final candidate = await PeerTransport.probeCandidates(
        [
          ...List.filled(8, 'https://127.0.0.1:${stalled.port}'),
          peer.candidates.single,
        ],
        peer.fingerprint,
        'parallel-fixture',
      );
      expect(candidate, peer.candidates.single);
      expect(watch.elapsedMilliseconds, lessThan(800));
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await stalled.close();
      await peer.close();
      api.close();
    }
  });

  for (final scenario in [(true, 0), (false, 0), (true, 650)]) {
    final preferLan = scenario.$1, prepareMs = scenario.$2;
    test(
      'cached ${preferLan ? 'LAN' : 'public'} with ${prepareMs}ms preparation transfers without reprobe or tiny timeout slices',
      () async {
        final bytes = utf8.encode('verified route contents');
        final hash = sha256.convert(bytes).toString();
        final pin = certificateFingerprint(identity['certificate']!);
        final security = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(identity['certificate']!))
          ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          security,
        );
        final stalled = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final sockets = <Socket>[];
        stalled.listen(sockets.add);
        var probes = 0;
        server.listen((request) async {
          try {
            if (request.uri.path == '/probe') {
              probes++;
              request.response.statusCode =
                  500; // Reprobing this cached path is a regression.
            } else {
              // More than the old 1/N slice; a warm path must still get a chance.
              await Future<void>.delayed(
                Duration(milliseconds: preferLan && prepareMs == 0 ? 700 : 220),
              );
              request.response.contentLength = bytes.length;
              request.response.add(bytes);
            }
            await request.response.close();
          } catch (_) {}
        });
        final good = 'https://127.0.0.1:${server.port}',
            bad = 'https://127.0.0.1:${stalled.port}';
        final api = FastApi(hash, candidate: good, fingerprint: pin);
        final monitor = ReachabilityMonitor(
          stages: (_) async => (
            lan: preferLan ? [good] : [bad],
            public: preferLan ? [bad] : [good],
          ),
          probe: (address, _, _) async =>
              (reachable: address == good, elapsedMs: 100, error: ''),
          relayProbe: (_, _, _) async =>
              (reachable: true, elapsedMs: 2, error: ''),
        );
        final device = <String, dynamic>{
          'deviceId': 'sender',
          'online': true,
          'peer': {
            'candidates': [good, bad],
            'certificateSha256': pin,
            'push': true,
          },
          'rtc': {
            'scopes': ['lan', 'public'],
          },
        };
        monitor.update(
          onlineDevices: [device],
          centerUrl: api.baseUrl,
          online: true,
          cellular: false,
        );
        await monitor.refresh();
        if (preferLan && prepareMs == 0)
          monitor.setRtcResults('self', [
            {
              'initiatorDeviceId': 'self',
              'responderDeviceId': 'sender',
              'scope': 'lan',
              'success': true,
              'elapsedMs': 200,
              'checkedAt': DateTime.now().toIso8601String(),
              'expiresAt': DateTime.now()
                  .add(const Duration(seconds: 30))
                  .toIso8601String(),
            },
          ]);
        final controller =
            FastController(
                directory,
                monitor: monitor,
                prepareDelay: Duration(milliseconds: prepareMs),
                stages: (values) async => (
                  lan: values
                      .where((v) => v == (preferLan ? good : bad))
                      .toList(),
                  public: values
                      .where((v) => v == (preferLan ? bad : good))
                      .toList(),
                ),
              )
              ..api = api
              ..profile = ServerProfile(
                baseUrl: api.baseUrl,
                instanceId: 'fixture',
                deviceId: 'self',
              )
              ..info = {
                'features': {'direct': true, 'directPush': true},
              }
              ..devices = [device];
        // Both alternative transports are present, but must not shrink a
        // verified HTTPS path to 1/6 of the deadline.
        controller.peer = PeerTransport(api, (_) => null, pushEnabled: true);
        controller.rtc = RtcFileTransport(api);
        final entry = DockEntry(
          id: 'f',
          kind: 'file',
          title: 'verified.bin',
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
          print(
            'VERIFIED_ROUTE_TIMING ${jsonEncode({'scope': preferLan ? 'lan' : 'public', 'preparationMs': prepareMs, 'elapsedMs': watch.elapsedMilliseconds, 'probeRequests': probes, 'status': entry.status})}',
          );
          expect(
            entry.status,
            'received',
            reason: '${entry.error} ${entry.routeDetail} ${api.calls}',
          );
          expect(entry.route, preferLan ? 'lan' : 'public');
          expect(probes, 0);
          expect(api.calls.where((call) => call.endsWith('/relay')), isEmpty);
          expect(watch.elapsedMilliseconds, lessThan(1200));
          expect(await File(entry.localPath).readAsBytes(), bytes);
        } finally {
          controller.dispose();
          for (final socket in sockets) socket.destroy();
          await stalled.close();
          await server.close(force: true);
        }
      },
    );
  }

  for (final stalledFirst in [false, true]) {
    test(
      'a stale cached ${stalledFirst ? 'timed-out endpoint' : 'source'} falls through to another measured pair without relay',
      () async {
        final bytes = utf8.encode('another source still works');
        final pin = certificateFingerprint(identity['certificate']!);
        final context = SecurityContext()
          ..useCertificateChainBytes(utf8.encode(identity['certificate']!))
          ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
        );
        var probes = 0;
        server.listen((request) async {
          if (request.uri.path == '/probe') {
            probes++;
            request.response.statusCode = 500;
          } else {
            request.response.contentLength = bytes.length;
            request.response.add(bytes);
          }
          await request.response.close();
        });
        final endpoint = 'https://127.0.0.1:${server.port}';
        final stalled = stalledFirst
            ? await ServerSocket.bind(InternetAddress.loopbackIPv4, 0)
            : null;
        final sockets = <Socket>[];
        stalled?.listen(sockets.add);
        final missing = CandidateRoute(
          address: stalledFirst
              ? 'https://127.0.0.1:${stalled!.port}'
              : endpoint,
          lan: true,
          sourceAddress: stalledFirst ? '' : '192.0.2.123',
        );
        final fallback = CandidateRoute(address: endpoint, lan: true);
        final monitor = SourcePairMonitor([missing, fallback]);
        final api = FastApi(
          sha256.convert(bytes).toString(),
          candidate: endpoint,
          fingerprint: pin,
          candidates: [missing.address, endpoint],
        );
        final device = <String, dynamic>{
          'deviceId': 'sender',
          'online': true,
          'peer': {
            'candidates': [missing.address, endpoint],
            'certificateSha256': pin,
          },
        };
        monitor.update(
          onlineDevices: [device],
          centerUrl: api.baseUrl,
          online: true,
          cellular: false,
        );
        await monitor.refresh();
        final report = monitor.captureReporter('sender');
        report(missing, (reachable: true, elapsedMs: 1, error: ''));
        report(fallback, (reachable: true, elapsedMs: 2, error: ''));
        final controller = FastController(directory, monitor: monitor)
          ..api = api
          ..profile = ServerProfile(
            baseUrl: api.baseUrl,
            instanceId: 'fixture',
            deviceId: 'self',
          )
          ..info = {
            'features': {'direct': true},
          }
          ..devices = [device];
        final entry = DockEntry(
          id: 'f',
          kind: 'file',
          title: 'fallback.bin',
          source: 'sender',
          transferId: 't',
          fileId: 'f',
          size: bytes.length,
          status: 'accepted',
        );
        controller.dock = [entry];
        try {
          await controller.receive(entry);
          expect(
            entry.status,
            'received',
            reason: '${entry.error} ${entry.routeDetail}',
          );
          expect(probes, 0);
          expect(
            api.calls.where((call) => call.endsWith('/direct-ticket')),
            hasLength(2),
          );
          expect(api.calls.where((call) => call.endsWith('/relay')), isEmpty);
          expect(
            monitor
                .verifiedRoutes('sender', [missing.address, endpoint], pin)
                .any((r) => r.key == missing.key),
            false,
          );
          expect(await File(entry.localPath).readAsBytes(), bytes);
        } finally {
          controller.dispose();
          for (final socket in sockets) socket.destroy();
          await stalled?.close();
          await server.close(force: true);
        }
      },
    );
  }

  for (final mode in ['auto', 'lan']) {
    test(
      '$mode shares one second across failed scopes, with relay only for auto',
      () async {
        final stalled = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final sockets = <Socket>[];
        stalled.listen(sockets.add);
        final candidate = 'https://127.0.0.1:${stalled.port}';
        final api = FastApi(
          'unused',
          candidate: candidate,
          fingerprint: certificateFingerprint(identity['certificate']!),
        );
        final controller = FastController(directory)
          ..api = api
          ..profile = ServerProfile(
            baseUrl: api.baseUrl,
            instanceId: 'fixture',
            deviceId: 'self',
          )
          ..info = {
            'features': {'direct': true},
          }
          ..devices = [
            {
              'deviceId': 'sender',
              'peer': {
                'candidates': [candidate],
                'certificateSha256': api.fingerprint,
              },
            },
          ];
        final entry = DockEntry(
          id: 'f',
          kind: 'file',
          title: 'fixture.bin',
          source: 'sender',
          transferId: 't',
          fileId: 'f',
          size: 10,
          status: 'accepted',
        );
        controller.dock = [entry];
        try {
          final watch = Stopwatch()..start();
          await controller.receive(entry, routeOverride: mode);
          expect(watch.elapsedMilliseconds, lessThan(1450));
          expect(
            api.calls.where((call) => call.endsWith('/relay')).length,
            mode == 'auto' ? 1 : 0,
          );
          expect(entry.status, mode == 'auto' ? 'accepted' : 'failed');
          expect(entry.route, mode == 'auto' ? 'relay' : 'direct');
          expect(
            await directory
                .list(recursive: true)
                .where((file) => file is File && file.path.endsWith('.part'))
                .length,
            0,
          );
        } finally {
          controller.dispose();
          for (final socket in sockets) {
            socket.destroy();
          }
          await stalled.close();
        }
      },
    );
  }

  test('a connected direct stream keeps its original partial and may transfer longer than one second', () async {
    final bytes = utf8.encode('prefix and remaining file');
    final hash = sha256.convert(bytes).toString();
    final fingerprint = certificateFingerprint(identity['certificate']!);
    final security = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity['certificate']!))
      ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      security,
    );
    String? range;
    server.listen((request) async {
      try {
        if (request.uri.path == '/probe') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'nonce': request.uri.queryParameters['nonce'],
              'certificateSha256': fingerprint,
            }),
          );
        } else {
          range = request.headers.value(HttpHeaders.rangeHeader);
          request.response.statusCode = 206;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 6-${bytes.length - 1}/${bytes.length}',
          );
          request.response.headers.set(
            HttpHeaders.etagHeader,
            '"sha256-$hash"',
          );
          request.response.contentLength = bytes.length - 6;
          request.response.add(bytes.sublist(6, 7));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          request.response.add(bytes.sublist(7));
        }
        await request.response.close();
      } catch (_) {
        /* Canceled probe sockets close normally. */
      }
    });
    final candidate = 'https://127.0.0.1:${server.port}';
    final api = FastApi(hash, candidate: candidate, fingerprint: fingerprint);
    final p = ServerProfile(
      baseUrl: api.baseUrl,
      instanceId: 'fixture',
      deviceId: 'self',
    );
    final controller = FastController(directory)
      ..api = api
      ..profile = p
      ..info = {
        'features': {'direct': true},
      }
      ..devices = [
        {
          'deviceId': 'sender',
          'peer': {
            'candidates': [candidate],
            'certificateSha256': fingerprint,
          },
        },
      ];
    final partial = File(
      '${directory.path}/GlobalSend/${p.key}/self/f/fixture.bin.part',
    );
    await partial.parent.create(recursive: true);
    await partial.writeAsBytes(bytes.take(6).toList());
    final entry = DockEntry(
      id: 'f',
      kind: 'file',
      title: 'fixture.bin',
      source: 'sender',
      transferId: 't',
      fileId: 'f',
      size: bytes.length,
      status: 'accepted',
      partialPath: partial.path,
    );
    controller.dock = [entry];
    try {
      await controller.receive(entry);
      expect(
        entry.status,
        'received',
        reason: '${entry.error} ${entry.routeDetail} ${api.calls}',
      );
      expect(entry.route, 'lan');
      expect(range, 'bytes=6-');
      expect(await File(entry.localPath).readAsBytes(), bytes);
      expect(api.calls.any((call) => call.endsWith('/relay')), false);
    } finally {
      controller.dispose();
      await server.close(force: true);
    }
  });

  test('expired HTTP signaling is physically canceled and late replies cannot replace relay state', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>(), release = Completer<void>();
    server.listen((request) async {
      if (!arrived.isCompleted) arrived.complete();
      await release.future;
      try {
        request.response.write('{"route":"old-direct"}');
        await request.response.close();
      } catch (_) {}
    });
    final api = CenterApi('http://127.0.0.1:${server.port}');
    var route = 'connecting';
    final attempt = ConnectionWindow(const Duration(milliseconds: 100));
    final running = attempt.run(() async {
      final result = await api.call('GET', '/late');
      route = result['route'];
    });
    await arrived.future;
    await expectLater(running, throwsA(isA<TimeoutException>()));
    route = 'relay';
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(route, 'relay');
    expect(attempt.canceled, true);
    api.close();
    await server.close(force: true);
  });

  test('a late native RTC create is fenced before opening a writer or altering resumed relay bytes', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const method = MethodChannel('FlutterWebRTC.Method');
    messenger.setMockMethodCallHandler(method, (_) async => <String, Object>{});
    addTearDown(() => messenger.setMockMethodCallHandler(method, null));
    final creating = Completer<RtcDataConnection>(),
        started = Completer<void>();
    final api = FastApi('');
    final transport = RtcFileTransport(
      api,
      connectionFactory:
          ({required scope, required allowCellular, required iceServers}) {
            started.complete();
            return creating.future;
          },
    );
    final partial = await File('${directory.path}/rtc.part')
        .writeAsBytes([1, 2]);
    final attempt = ConnectionWindow(const Duration(milliseconds: 150));
    final running = attempt.run(
      () => transport.receive(
        fileRoute: '/transfers/t/files/f',
        attemptId: 'old',
        scope: 'lan',
        destination: partial,
        size: 4,
        onProgress: (_) => fail('Expired RTC must not report data'),
      ),
    );
    await started.future;
    await expectLater(running, throwsA(isA<TimeoutException>()));
    await partial.writeAsBytes([3, 4], mode: FileMode.append);
    final pc = PendingPeer();
    creating.complete(pc);
    for (var i = 0; i < 50 && pc.closes == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(pc.closes, 1);
    pc.release.complete();
    await transport.close();
    expect(await partial.readAsBytes(), [1, 2, 3, 4]);
    api.close();
  });

  test(
    'failed native RTC creation still retires cleanly before fallback',
    () async {
      final api = FastApi('');
      final transport = RtcFileTransport(
        api,
        connectionFactory:
            ({
              required scope,
              required allowCellular,
              required iceServers,
            }) async {
              throw StateError('fixture native create failed');
            },
      );
      final partial = await File('${directory.path}/failed-create.part')
          .writeAsBytes([1, 2]);
      try {
        await expectLater(
          transport.receive(
            fileRoute: '/transfers/t/files/f',
            attemptId: 'failed',
            scope: 'lan',
            destination: partial,
            size: 4,
            onProgress: (_) => fail('no RTC bytes expected'),
          ),
          throwsA(isA<StateError>()),
        );
        await transport.close();
        expect(await partial.readAsBytes(), [1, 2]);
      } finally {
        await transport.close();
        api.close();
      }
    },
  );

  test('refresh publishes new local candidates before reading the group and coalesces concurrent requests', () async {
    final order = <String>[], gate = Completer<void>();
    final api = FastApi('');
    final controller = RefreshController(order)
      ..api = api
      ..connected = true
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      );
    controller.peer = RefreshPeer(api, order, gate.future);
    controller.rtc = RefreshRtc(api, order);
    final first = controller.refreshGroupDevices(),
        second = controller.refreshGroupDevices();
    expect(identical(first, second), true);
    await Future<void>.delayed(Duration.zero);
    expect(order, ['publish-addresses']);
    gate.complete();
    await first;
    expect(order, ['publish-addresses', 'publish-rtc', 'snapshot', 'probe']);
    controller.dispose();
  });

  test('automatic reference checks remove missing received cards but retain live partials and external originals', () async {
    final external = await File('${directory.path}/original.bin')
        .writeAsBytes([1]);
    final partial = await File('${directory.path}/in-flight.part')
        .writeAsBytes([2]);
    final controller = FastController(directory)
      ..dock = [
        DockEntry(
          id: 'gone',
          kind: 'file',
          title: 'gone',
          source: 'peer',
          status: 'received',
          localPath: '${directory.path}/missing',
        ),
        DockEntry(
          id: 'busy',
          kind: 'file',
          title: 'busy',
          source: 'peer',
          status: 'downloading',
          partialPath: partial.path,
        ),
        DockEntry(
          id: 'sent',
          kind: 'file',
          title: 'sent',
          source: 'self',
          outgoing: true,
          status: 'sent',
          localPath: external.path,
        ),
      ];
    await controller.pruneSentReferences();
    expect(controller.dock.map((entry) => entry.id), ['busy', 'sent']);
    expect(await external.exists(), true);
    expect(await partial.exists(), true);
    controller.dispose();
  });
}
