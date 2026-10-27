import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/candidate_routes.dart';
import 'package:globalsend/local_ip_addresses.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/reachability.dart';

List<LocalIpAddress> fixtureAddresses() => addressesFromInterfaces([
  {
    'id': 'wifi',
    'name': 'wlan0',
    'kind': 'Wi-Fi',
    'internet': false,
    'addresses': ['10.171.176.71', '2001:da8:e000:9::c847'],
  },
  {
    'id': 'ims',
    'name': 'rmnet_data1',
    'kind': 'IMS 通话网络',
    'internet': false,
    'addresses': ['240e:573:830:d260:b049:cff:fea4:3751'],
  },
  {
    'id': 'vpn',
    'name': 'tun0',
    'kind': 'VPN',
    'internet': true,
    'addresses': ['10.8.0.2', '198.18.0.1'],
  },
]);

void main() {
  test('documents decision cancellation while a source-bound TLS handshake has not completed', () async {
    final identity = createPeerIdentity('bound-handshake-diagnostic');
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final hello = Completer<void>(), closed = Completer<void>();
    final sockets = <Socket>[];
    listener.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (bytes) {
          if (!hello.isCompleted) hello.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    final stop = ProbeCancellation();
    try {
      final work = probePeerAddress(
        'https://127.0.0.1:${listener.port}',
        certificateFingerprint(identity['certificate']!),
        false,
        sourceAddress: '127.0.0.1',
        cancellation: stop,
      );
      await hello.future.timeout(const Duration(seconds: 2));
      final watch = Stopwatch()..start();
      await stop.cancel();
      expect(
        (await work.timeout(const Duration(milliseconds: 300))).reachable,
        false,
      );
      final decisionMs = watch.elapsedMilliseconds;
      final physicallyClosed = await Future.any([
        closed.future.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 350), () => false),
      ]);
      await File(
        '../artifacts/reports/source-bound-tls-cancel-diagnostic.json',
      ).writeAsString(
        jsonEncode({
          'cancelDecisionMs': decisionMs,
          'tcpClosedWithin350ms': physicallyClosed,
          'stage': 'TCP connected, peer never answered TLS ClientHello',
          'cleanup': 'fixture closes owned server sockets after observation',
        }),
      );
    } finally {
      await stop.cancel();
      for (final socket in sockets) socket.destroy();
      await listener.close();
    }
  });

  test('candidate pairs retain routed campus/private VPN paths and exclude only explicit unusable sources', () {
    final local = fixtureAddresses();
    expect(
      local.where(isPublishableLocalAddress).map((ip) => ip.address),
      containsAll(['10.171.176.71', '2001:da8:e000:9::c847', '10.8.0.2']),
    );
    expect(
      local
          .where(isPublishableLocalAddress)
          .any((ip) => ip.source!.kind == 'IMS 通话网络'),
      false,
    );
    expect(
      local
          .where(isPublishableLocalAddress)
          .any((ip) => ip.address == '198.18.0.1'),
      false,
    );
    final routes = planCandidateRoutes([
      'https://10.195.39.39:44719',
      'https://[240e:473:8a0:acd:58ae:9dff:fe61:c089]:44719',
      'https://[240e:573:830:d260:b049:cff:fea4:3751]:44719', // Unknown remote source must not be guessed to be IMS.
      'https://198.18.0.1:8787', 'https://127.0.0.2:8787', 'https://[::1]:8787',
    ], local);
    expect(
      routes.any(
        (r) =>
            r.address.contains('10.195.39.39') &&
            r.sourceAddress == '10.171.176.71' &&
            r.lan,
      ),
      true,
    );
    expect(
      routes.any(
        (r) =>
            r.address.contains('10.195.39.39') && r.sourceAddress == '10.8.0.2',
      ),
      true,
    );
    expect(routes.any((r) => r.address.contains('240e:573:830')), true);
    expect(routes.any((r) => r.sourceAddress.contains('240e:573:830')), false);
    expect(
      routes.any(
        (r) =>
            r.address.contains('198.18') ||
            r.address.contains('127.') ||
            r.address.contains('[::1]'),
      ),
      false,
    );
    for (final r in routes.where((r) => r.sourceAddress.isNotEmpty)) {
      expect(
        InternetAddress(r.sourceAddress).type,
        literalCandidateAddress(r.address)!.type,
      );
    }
  });

  test('missing IPv6 prunes normal pairs but not a permitted cellular Network lease', () {
    final local = sortLocalIpAddresses(['10.0.0.2']);
    const v6 = 'https://[240e::2]:8787';
    expect(planCandidateRoutes([v6], local), isEmpty);
    final routes = planCandidateRoutes(
      [v6],
      local,
      androidCellular: true,
      allowCellular: true,
    );
    expect(routes, hasLength(1));
    expect(routes.single.cellular, true);
    expect(routes.single.sourceAddress, isEmpty);
    expect(routes.single.sourceName, '蜂窝网络（系统绑定）');
  });

  test('same-prefix IPv6 is a LAN hint and other explicit source pairs remain public', () {
    final routes = planCandidateRoutes([
      'https://[2001:da8:e000:9::2]:8787',
    ], sortLocalIpAddresses(['2001:da8:e000:9::1', '240e::1']));
    expect(
      routes.singleWhere((r) => r.sourceAddress == '2001:da8:e000:9::1').lan,
      true,
    );
    expect(routes.singleWhere((r) => r.sourceAddress == '240e::1').lan, false);
  });

  test('parallel measured pairs are cached for actual source binding and invalidated on failure/network change', () async {
    var local = fixtureAddresses();
    final attempted = <String>[];
    final monitor =
        ReachabilityMonitor(
            localAddresses: () async => local,
            routeProbe: (route, _, stop) async {
              attempted.add(route.key);
              return (
                reachable: route.sourceAddress == '10.171.176.71',
                elapsedMs: 5,
                error: '',
              );
            },
            relayProbe: (_, _, _) async =>
                (reachable: true, elapsedMs: 7, error: ''),
          )
          ..connected = true
          ..center = 'https://center.invalid'
          ..devices = [
            {
              'deviceId': 'phone',
              'peer': {
                'candidates': ['https://10.195.39.39:44719'],
                'certificateSha256': 'pin',
              },
            },
          ];
    addTearDown(monitor.dispose);
    await monitor.refresh();
    expect(attempted, hasLength(3));
    expect(
      monitor.sourceFor('phone', 'https://10.195.39.39:44719'),
      '10.171.176.71',
    );
    final oldReporter = monitor.captureReporter('phone');
    monitor.markFailed(
      'phone',
      'https://10.195.39.39:44719',
      sourceAddress: '10.171.176.71',
    );
    oldReporter(
      const CandidateRoute(
        address: 'https://10.195.39.39:44719',
        lan: true,
        sourceAddress: '10.171.176.71',
      ),
      (reachable: true, elapsedMs: 1, error: ''),
    );
    expect(monitor.sourceFor('phone', 'https://10.195.39.39:44719'), isNull);
    expect(
      monitor.prioritize('phone', [
        'https://10.195.39.39:44719',
        'https://10.195.39.40:44719',
      ], ReachabilityScope.lan),
      ['https://10.195.39.40:44719', 'https://10.195.39.39:44719'],
    );
    local = sortLocalIpAddresses(['10.171.176.72']);
    attempted.clear();
    await monitor.refreshDevice('phone');
    expect(attempted.any((r) => r.contains('10.171.176.71')), false);
    expect(
      monitor.forDevice('phone').any((r) => r.sourceAddress == '10.171.176.71'),
      false,
    );
  });

  test('metadata publication filters IMS/reserved yet uploads empty lists to withdraw stale addresses', () async {
    final center = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final publications = <Map<String, dynamic>>[];
    center.listen((request) async {
      publications.add(
        Map<String, dynamic>.from(
          jsonDecode(await utf8.decoder.bind(request).join()),
        ),
      );
      request.response.write('{}');
      await request.response.close();
    });
    var local = fixtureAddresses();
    final api = CenterApi('http://127.0.0.1:${center.port}');
    final peer = PeerTransport(
      api,
      (_) => null,
      addressReader: () async => local,
    );
    try {
      await peer.start(createPeerIdentity('source-publication-fixture'));
      final values = List<String>.from(publications.single['candidates']);
      expect(values.any((v) => v.contains('10.171.176.71')), true);
      expect(values.any((v) => v.contains('10.8.0.2')), true);
      expect(
        values.any((v) => v.contains('240e:573') || v.contains('198.18')),
        false,
      );
      local = [];
      await peer.publish();
      expect(publications.last['candidates'], isEmpty);
      expect(peer.candidates, isEmpty);
    } finally {
      await peer.close();
      api.close();
      await center.close(force: true);
    }
  });

  test('pinned TLS probe uses the selected source IP rather than ignoring the pair', () async {
    final identity = createPeerIdentity('source-binding-fixture');
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity['certificate']!))
      ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final pin = certificateFingerprint(identity['certificate']!);
    final sources = <String>[];
    server.listen((request) async {
      sources.add(request.connectionInfo!.remoteAddress.address);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'nonce': request.uri.queryParameters['nonce'],
          'certificateSha256': pin,
        }),
      );
      await request.response.close();
    });
    final url = 'https://127.0.0.1:${server.port}';
    try {
      expect(
        await PeerTransport.probeCandidates(
          [url],
          pin,
          'source-binding',
          sourceAddresses: {url: '127.0.0.1'},
        ),
        url,
      );
      expect(sources, ['127.0.0.1']);
      await expectLater(
        PeerTransport.probeCandidates(
          [url],
          pin,
          'must-not-connect',
          sourceAddresses: {url: '192.0.2.99'},
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<Exception>()),
      );
      expect(sources, hasLength(1));
    } finally {
      await server.close(force: true);
    }
  });

  test('canceling a source-bound probe closes the actual HTTPS socket after handshake', () async {
    final identity = createPeerIdentity('bound-cancellation-fixture');
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity['certificate']!))
      ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final requested = Completer<void>(), closed = Completer<void>();
    final sockets = <SecureSocket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (bytes) {
          if (!requested.isCompleted) requested.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    final stop = ProbeCancellation();
    try {
      final work = probePeerAddress(
        'https://127.0.0.1:${server.port}',
        certificateFingerprint(identity['certificate']!),
        false,
        sourceAddress: '127.0.0.1',
        cancellation: stop,
      );
      await requested.future.timeout(const Duration(seconds: 2));
      await stop.cancel();
      expect(
        (await work.timeout(const Duration(milliseconds: 500))).reachable,
        false,
      );
      await closed.future.timeout(const Duration(seconds: 1));
    } finally {
      await stop.cancel();
      for (final socket in sockets) socket.destroy();
      await server.close();
    }
  });

  test(
    'concurrent target and all-device checks share one OS address snapshot',
    () async {
      final reading = Completer<List<LocalIpAddress>>();
      var reads = 0;
      final monitor =
          ReachabilityMonitor(
              localAddresses: () {
                reads++;
                return reading.future;
              },
              routeProbe: (route, _, _) async =>
                  (reachable: true, elapsedMs: 3, error: ''),
              relayProbe: (_, _, _) async =>
                  (reachable: true, elapsedMs: 4, error: ''),
            )
            ..connected = true
            ..center = 'https://center.invalid'
            ..devices = [
              {
                'deviceId': 'one',
                'peer': {
                  'candidates': ['https://10.195.1.1:8787'],
                  'certificateSha256': 'pin',
                },
              },
              {
                'deviceId': 'two',
                'peer': {
                  'candidates': ['https://10.195.1.2:8787'],
                  'certificateSha256': 'pin',
                },
              },
            ];
      addTearDown(monitor.dispose);
      final one = monitor.refreshDevice('one'), all = monitor.refresh();
      expect(reads, 1);
      reading.complete(sortLocalIpAddresses(['10.171.1.1']));
      await Future.wait([one, all]);
      expect(reads, 1);
      expect(
        monitor
            .forDevice('one')
            .where((r) => r.scope != ReachabilityScope.relay),
        hasLength(2),
      );
      expect(
        monitor
            .forDevice('two')
            .where((r) => r.scope != ReachabilityScope.relay),
        hasLength(2),
      );
    },
  );

  test('offline interface changes still invoke control reconnection without probing files', () async {
    var changes = 0, probes = 0;
    final monitor = ReachabilityMonitor(
      networkSignature: () async => 'new-network',
      onNetworkChanged: () async {
        changes++;
      },
      probe: (_, _, _) async {
        probes++;
        return (reachable: true, elapsedMs: 1, error: '');
      },
    );
    addTearDown(monitor.dispose);
    await monitor.tick();
    expect(changes, 1);
    expect(probes, 0);
    expect(monitor.connected, false);
    await monitor.tick();
    expect(changes, 1);
  });

  test('changed advertised candidates cancel the prior pass and cannot be restored by a late reply', () async {
    final started = Completer<void>(), pending = Completer<ProbeResult>();
    final monitor =
        ReachabilityMonitor(
            localAddresses: () async => sortLocalIpAddresses(['10.171.1.1']),
            routeProbe: (route, _, stop) {
              if (route.address.contains('10.195.1.1')) {
                if (!started.isCompleted) started.complete();
                return pending.future;
              }
              return Future.value((reachable: true, elapsedMs: 4, error: ''));
            },
            relayProbe: (_, _, _) async =>
                (reachable: true, elapsedMs: 3, error: ''),
          )
          ..connected = true
          ..center = 'https://center.invalid'
          ..devices = [
            {
              'deviceId': 'phone',
              'peer': {
                'candidates': ['https://10.195.1.1:8787'],
                'certificateSha256': 'pin',
              },
            },
          ];
    addTearDown(monitor.dispose);
    final old = monitor.refresh();
    await started.future;
    monitor.update(
      onlineDevices: [
        {
          'deviceId': 'phone',
          'peer': {
            'candidates': ['https://10.195.1.2:8787'],
            'certificateSha256': 'pin',
          },
        },
      ],
      centerUrl: monitor.center,
      online: true,
      cellular: false,
    );
    expect(
      monitor.forDevice('phone').any((r) => r.address.contains('10.195.1.1')),
      false,
    );
    await old;
    pending.complete((reachable: true, elapsedMs: 1, error: ''));
    await Future<void>.delayed(Duration.zero);
    expect(
      monitor.forDevice('phone').any((r) => r.address.contains('10.195.1.1')),
      false,
    );
    expect(
      monitor
          .forDevice('phone')
          .where((r) => r.address.contains('10.195.1.2'))
          .every((r) => r.reachable),
      true,
    );
  });
}
