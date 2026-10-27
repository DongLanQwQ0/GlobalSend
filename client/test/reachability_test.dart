import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/reachability.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/candidate_routes.dart';

void main() {
  test('target refresh measures only the selected peer and retains other cached checks', () async {
    var now = DateTime(2026, 10, 27, 12, 30);
    final calls = <String>[];
    final monitor =
        ReachabilityMonitor(
            clock: () => now,
            stages: (values) async => (lan: values, public: <String>[]),
            probe: (address, _, _) async {
              calls.add(address);
              return (reachable: true, elapsedMs: 4, error: '');
            },
            relayProbe: (address, _, _) async {
              calls.add(address);
              return (reachable: true, elapsedMs: 7, error: '');
            },
          )
          ..center = 'https://center.invalid'
          ..connected = true
          ..devices = [
            {
              'deviceId': 'selected',
              'peer': {
                'candidates': ['https://192.168.1.2:8787'],
                'certificateSha256': 'pin',
              },
            },
            {
              'deviceId': 'other',
              'peer': {
                'candidates': ['https://192.168.1.3:8787'],
                'certificateSha256': 'pin',
              },
            },
          ];
    addTearDown(monitor.dispose);
    await monitor.refresh();
    final other = monitor.forDevice('other').first;
    final allChecked = monitor.lastChecked;
    now = now.add(const Duration(seconds: 10));
    calls.clear();
    await monitor.refreshDevice('selected');
    expect(
      calls,
      unorderedEquals([
        'https://192.168.1.2:8787',
        'https://center.invalid/health/ready',
      ]),
    );
    expect(monitor.forDevice('other').first, same(other));
    expect(monitor.forDevice('selected').first.checkedAt, now);
    expect(
      monitor.lastChecked,
      allChecked,
    ); // Target refresh must not postpone other peers' periodic checks.
    expect(monitor.checkingDevice('selected'), false);
  });

  test('target pass starts all candidate paths in parallel and cancels at one total second', () async {
    final started = <String>[];
    final canceled = <String>[];
    final pending = <Completer<ProbeResult>>[];
    final monitor =
        ReachabilityMonitor(
            cellularCapable: true,
            stages: (_) async => (
              lan: ['https://192.168.1.2:8787'],
              public: ['https://[240e::2]:8787'],
            ),
            cancelableProbe: (address, _, cellular, stop) {
              final label = '$address/${cellular ? 'cellular' : 'default'}';
              started.add(label);
              stop.onCancel(() => canceled.add(label));
              final wait = Completer<ProbeResult>();
              pending.add(wait);
              return wait.future;
            },
            relayProbe: (_, _, _) async =>
                (reachable: true, elapsedMs: 5, error: ''),
          )
          ..center = 'https://center.invalid'
          ..connected = true
          ..allowCellular = true
          ..devices = [
            {
              'deviceId': 'selected',
              'peer': {
                'candidates': ['advertised'],
                'certificateSha256': 'pin',
              },
            },
          ];
    addTearDown(monitor.dispose);
    final checking = monitor.refreshDevice('selected');
    expect(identical(checking, monitor.refreshDevice('selected')), true);
    await Future<void>.delayed(Duration.zero);
    expect(
      started,
      unorderedEquals([
        'https://192.168.1.2:8787/default',
        'https://[240e::2]:8787/default',
        'https://[240e::2]:8787/cellular',
      ]),
    );
    await checking.timeout(const Duration(milliseconds: 1400));
    expect(canceled, unorderedEquals(started));
    expect(
      monitor
          .forDevice('selected')
          .where((r) => r.scope != ReachabilityScope.relay)
          .every((r) => !r.reachable && r.error == '检测超时（1 秒）'),
      true,
    );
    expect(monitor.forDevice('selected'), hasLength(4));
    for (final wait in pending)
      wait.complete((reachable: true, elapsedMs: 1, error: ''));
    await Future<void>.delayed(Duration.zero);
    expect(
      monitor.forDevice('selected').where((r) => r.reachable),
      hasLength(1),
    );
  });

  test(
    'a slower all-peer pass cannot overwrite a newer selected-peer measurement',
    () async {
      final old = Completer<ProbeResult>(), started = Completer<void>();
      var first = true;
      final monitor =
          ReachabilityMonitor(
              stages: (values) async => (lan: values, public: <String>[]),
              probe: (address, _, _) {
                if (address.contains('192.168.1.2') && first) {
                  first = false;
                  started.complete();
                  return old.future;
                }
                return Future.value((reachable: true, elapsedMs: 3, error: ''));
              },
              relayProbe: (_, _, _) async =>
                  (reachable: true, elapsedMs: 2, error: ''),
            )
            ..center = 'https://center.invalid'
            ..connected = true
            ..devices = [
              {
                'deviceId': 'selected',
                'peer': {
                  'candidates': ['https://192.168.1.2:8787'],
                  'certificateSha256': 'pin',
                },
              },
              {
                'deviceId': 'other',
                'peer': {
                  'candidates': ['https://192.168.1.3:8787'],
                  'certificateSha256': 'pin',
                },
              },
            ];
      addTearDown(monitor.dispose);
      final all = monitor.refresh();
      await started.future;
      monitor.captureReporter('selected')(
        const CandidateRoute(address: 'https://192.168.1.2:8787', lan: true),
        (reachable: true, elapsedMs: 3, error: ''),
      );
      old.complete((reachable: false, elapsedMs: 600, error: 'older result'));
      await all;
      expect(monitor.forDevice('selected').every((r) => r.reachable), true);
      expect(monitor.forDevice('selected').first.elapsedMs, 3);
      expect(monitor.forDevice('other'), hasLength(2));
    },
  );
  test('offline presence cancels an active probe immediately without waiting for its network result', () async {
    final started = Completer<void>();
    final pending = Completer<ProbeResult>();
    var stopped = false, publicProbes = 0;
    final monitor =
        ReachabilityMonitor(
            stages: (_) async => (lan: ['lan'], public: ['public']),
            cancelableProbe:
                (address, fingerprint, cellular, cancellation) async {
                  if (address == 'public') publicProbes++;
                  cancellation.onCancel(() {
                    stopped = true;
                  });
                  if (!started.isCompleted) started.complete();
                  return pending.future;
                },
          )
          ..center = 'https://fixture.invalid'
          ..connected = true
          ..devices = [
            {
              'deviceId': 'peer',
              'online': true,
              'peer': {'certificateSha256': 'pin', 'candidates': []},
            },
          ];
    addTearDown(monitor.dispose);
    final checking = monitor.refresh();
    await started.future;
    monitor.update(
      onlineDevices: [],
      centerUrl: monitor.center,
      online: true,
      cellular: false,
    );
    expect(stopped, true);
    expect(monitor.results, isEmpty);
    await checking.timeout(const Duration(seconds: 1));
    expect(publicProbes, 1); // All plausible paths already started in parallel.
    pending.complete((reachable: true, elapsedMs: 1, error: ''));
    await Future<void>.delayed(Duration.zero);
    expect(monitor.results, isEmpty);
  });
  test(
    'withdrawing an online peer closes the actual pinned TLS probe socket',
    () async {
      final identity = createPeerIdentity('probe-cancellation-fixture');
      final context = SecurityContext()
        ..useCertificateChainBytes(identity['certificate']!.codeUnits)
        ..usePrivateKeyBytes(identity['privateKey']!.codeUnits);
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
      final address = 'https://127.0.0.1:${server.port}';
      final monitor =
          ReachabilityMonitor(
              stages: (_) async => (lan: [address], public: <String>[]),
            )
            ..center = 'https://fixture.invalid'
            ..connected = true
            ..devices = [
              {
                'deviceId': 'peer',
                'online': true,
                'peer': {
                  'certificateSha256': certificateFingerprint(
                    identity['certificate']!,
                  ),
                  'candidates': [address],
                },
              },
            ];
      try {
        final checking = monitor.refresh();
        await requested.future.timeout(const Duration(seconds: 5));
        monitor.update(
          onlineDevices: [],
          centerUrl: monitor.center,
          online: true,
          cellular: false,
        );
        await checking.timeout(const Duration(seconds: 1));
        await closed.future.timeout(const Duration(seconds: 3));
        expect(monitor.results, isEmpty);
      } finally {
        monitor.dispose();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      }
    },
  );
  test(
    'expired advertised IPs leave the cache and are not probed again',
    () async {
      var now = DateTime(2026, 10, 25), probes = 0;
      final monitor =
          ReachabilityMonitor(
              clock: () => now,
              stages: (_) async => (lan: ['address'], public: <String>[]),
              probe: (_, _, _) async {
                probes++;
                return (reachable: true, elapsedMs: 1, error: '');
              },
              relayProbe: (_, _, _) async =>
                  (reachable: true, elapsedMs: 1, error: ''),
            )
            ..center = 'https://fixture.invalid'
            ..connected = true
            ..devices = [
              {
                'deviceId': 'peer',
                'online': true,
                'peer': {
                  'certificateSha256': 'pin',
                  'candidates': ['address'],
                  'expiresAt': now
                      .add(const Duration(minutes: 30))
                      .toIso8601String(),
                },
              },
            ];
      addTearDown(monitor.dispose);
      await monitor.refresh();
      expect(probes, 1);
      now = now.add(const Duration(minutes: 31));
      expect(
        monitor
            .forDevice('peer')
            .where((value) => value.scope != ReachabilityScope.relay),
        isEmpty,
      );
      await monitor.refresh();
      expect(probes, 1);
    },
  );
  test(
    'checks all paths in parallel and sorts reachable paths by scope',
    () async {
      final calls = <String>[];
      final monitor = ReachabilityMonitor(
        stages: (_) async => (
          lan: ['https://192.168.1.2:1', 'https://[2001:db8::2]:1'],
          public: ['https://[2001:db8::2]:1', 'https://8.8.8.8:1'],
        ),
        probe: (address, fingerprint, cellular) async {
          calls.add('${cellular ? 'cell' : 'default'}:$address');
          return (
            reachable: !address.contains('192.168'),
            elapsedMs: 12,
            error: address.contains('192.168') ? 'timeout' : '',
          );
        },
        relayProbe: (address, _, _) async {
          calls.add('relay');
          return (reachable: true, elapsedMs: 30, error: '');
        },
        cellularCapable: true,
      );
      addTearDown(monitor.dispose);
      monitor.devices = [
        {
          'deviceId': 'peer',
          'peer': {
            'candidates': ['unused'],
            'certificateSha256': 'pin',
          },
        },
      ];
      monitor.center = 'https://center';
      monitor.connected = true;
      monitor.allowCellular = true;
      await monitor.refresh();
      expect(
        calls,
        unorderedEquals([
          'default:https://192.168.1.2:1',
          'default:https://[2001:db8::2]:1',
          'default:https://8.8.8.8:1',
          'cell:https://[2001:db8::2]:1',
          'cell:https://8.8.8.8:1',
          'relay',
        ]),
      );
      expect(
        calls.where((call) => call == 'default:https://[2001:db8::2]:1'),
        hasLength(1),
      );
      final reachable = monitor
          .forDevice('peer')
          .where((check) => check.reachable)
          .toList();
      expect(reachable.map((check) => check.scope), [
        ReachabilityScope.lan,
        ReachabilityScope.public,
        ReachabilityScope.public,
        ReachabilityScope.public,
        ReachabilityScope.relay,
      ]);
      expect(monitor.forDevice('peer').last.error, 'timeout');
    },
  );

  test('network changes refresh early and stale cache cannot override candidate order', () async {
    var now = DateTime(2026, 10, 25), network = 'wifi', rounds = 0;
    var publications = 0;
    final monitor = ReachabilityMonitor(
      clock: () => now,
      networkSignature: () async => network,
      onNetworkChanged: () async {
        publications++;
      },
      stages: (_) async => (lan: ['slow', 'fast'], public: <String>[]),
      probe: (address, _, _) async =>
          (reachable: address == 'fast', elapsedMs: 10, error: 'timeout'),
      relayProbe: (_, _, _) async {
        rounds++;
        return (reachable: true, elapsedMs: 5, error: '');
      },
    );
    addTearDown(monitor.dispose);
    monitor.devices = [
      {
        'deviceId': 'peer',
        'peer': {'candidates': [], 'certificateSha256': 'pin'},
      },
    ];
    monitor.center = 'https://center';
    monitor.connected = true;
    await monitor.tick();
    expect(rounds, 1);
    await monitor.tick();
    expect(rounds, 1);
    expect(
      monitor.prioritize('peer', ['slow', 'fast'], ReachabilityScope.lan),
      ['fast', 'slow'],
    );
    network = 'cell';
    await monitor.tick();
    expect(rounds, 2);
    now = now.add(const Duration(minutes: 1));
    await monitor.tick();
    expect(rounds, 3);
    expect(publications, 2);
    now = now.add(const Duration(minutes: 3));
    expect(
      monitor.prioritize('peer', ['slow', 'fast'], ReachabilityScope.lan),
      ['slow', 'fast'],
    );
  });

  test('fresh reachable addresses use latency and unknown addresses retain their order', () async {
    final monitor = ReachabilityMonitor(
      stages: (_) async => (lan: ['slow', 'fast'], public: <String>[]),
      probe: (address, _, _) async =>
          (reachable: true, elapsedMs: address == 'slow' ? 50 : 5, error: ''),
      relayProbe: (_, _, _) async => (reachable: true, elapsedMs: 1, error: ''),
    );
    addTearDown(monitor.dispose);
    monitor.devices = [
      {
        'deviceId': 'peer',
        'peer': {'candidates': [], 'certificateSha256': 'pin'},
      },
    ];
    monitor.center = 'https://center';
    monitor.connected = true;
    await monitor.refresh();
    expect(
      monitor.prioritize('peer', [
        'unknown-2',
        'slow',
        'unknown-1',
        'fast',
      ], ReachabilityScope.lan),
      ['fast', 'slow', 'unknown-2', 'unknown-1'],
    );
    expect(
      monitor.prioritize('peer', ['slow', 'fast'], ReachabilityScope.public),
      ['fast', 'slow'],
    );
  });

  test('disconnect discards an in-flight result and does not probe offline devices', () async {
    final release =
        Completer<({bool reachable, int elapsedMs, String error})>();
    final monitor = ReachabilityMonitor(
      stages: (_) async => (lan: ['address'], public: <String>[]),
      probe: (_, _, _) => release.future,
      relayProbe: (_, _, _) async => (reachable: true, elapsedMs: 1, error: ''),
    );
    addTearDown(monitor.dispose);
    monitor.devices = [
      {
        'deviceId': 'peer',
        'peer': {'candidates': [], 'certificateSha256': 'pin'},
      },
    ];
    monitor.center = 'https://center';
    monitor.connected = true;
    final checking = monitor.refresh();
    await Future<void>.delayed(Duration.zero);
    monitor.update(
      onlineDevices: [],
      centerUrl: 'https://center',
      online: false,
      cellular: false,
    );
    release.complete((reachable: true, elapsedMs: 1, error: ''));
    await checking;
    expect(monitor.results, isEmpty);
  });
}
