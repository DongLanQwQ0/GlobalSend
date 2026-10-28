import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/candidate_routes.dart';
import 'package:globalsend/connection_window.dart';
import 'package:globalsend/local_ip_addresses.dart';
import 'package:globalsend/reachability.dart';
import 'package:globalsend/route_probes.dart';

void main() {
  const public = 'https://[240e::2]:9443';
  const automatic = CandidateRoute(address: public, lan: false);
  const wifi = CandidateRoute(
    address: public,
    lan: false,
    sourceAddress: '2001:da8::1',
  );
  const cellular = CandidateRoute(address: public, lan: false, cellular: true);
  const success = (reachable: true, elapsedMs: 20, error: '');

  test('warm cellular is ready immediately while all unmeasured NIC pairs start together', () async {
    final starts = <String>[];
    final pending = <String, Completer<ProbeResult>>{};
    final checks = RouteProbes(
      [public],
      [public],
      'pin',
      const Duration(seconds: 1),
      routes: [automatic, wifi, cellular],
      verified: [cellular],
      probe: (route, pin, stop) {
        starts.add(route.key);
        return (pending[route.key] = Completer<ProbeResult>()).future;
      },
    );
    addTearDown(checks.close);
    expect(starts, [automatic.key, wifi.key]);
    final chosen = await checks
        .firstRoute([public])
        .timeout(const Duration(milliseconds: 100));
    expect(chosen?.cellular, true);
    expect(chosen?.key, cellular.key);
    checks.discard(cellular);
    final retry = checks.firstRoute([public]);
    pending[wifi.key]!.complete(success);
    expect((await retry)!.sourceAddress, wifi.sourceAddress);
    expect(checks.readyRoute([public])!.key, wifi.key);
  });

  test(
    'cold NIC and cellular probes race without waiting for the default path',
    () async {
      final starts = <String>[];
      final checks = RouteProbes(
        [public],
        [public],
        'pin',
        const Duration(seconds: 1),
        routes: [automatic, wifi, cellular],
        probe: (route, pin, stop) {
          starts.add(route.key);
          return route.cellular
              ? Future<ProbeResult>.delayed(
                  const Duration(milliseconds: 50),
                  () => success,
                )
              : Completer<ProbeResult>().future;
        },
      );
      addTearDown(checks.close);
      expect(starts, [automatic.key, wifi.key, cellular.key]);
      final route = await checks
          .firstRoute([public])
          .timeout(const Duration(milliseconds: 250));
      expect(route!.cellular, true);
    },
  );

  test('LAN selection does not mistake a faster public source for a local IPv6 path', () async {
    const local = CandidateRoute(
      address: public,
      lan: true,
      sourceAddress: '240e::1',
    );
    final checks = RouteProbes(
      [public],
      [],
      'pin',
      const Duration(seconds: 1),
      routes: [wifi, local],
      verified: [wifi],
      probe: (route, _, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return success;
      },
    );
    addTearDown(checks.close);
    expect((await checks.firstRoute([public], lan: true))!.key, local.key);
    expect(checks.readyRoute([public])!.key, wifi.key);
  });

  test(
    'warm paths retain the measured source and discard only the failed pair',
    () async {
      final checks = RouteProbes(
        [public],
        [public],
        'pin',
        const Duration(seconds: 1),
        routes: [automatic, wifi, cellular],
        verified: [wifi, cellular],
        probe: (_, _, _) => Completer<ProbeResult>().future,
      );
      addTearDown(checks.close);
      expect(
        (await checks.firstRoute([public]))!.sourceAddress,
        wifi.sourceAddress,
      );
      checks.discard(wifi);
      expect((await checks.firstRoute([public]))!.key, cellular.key);
    },
  );

  test('refresh retains a fresh path, renewal does not discard it, expiry and pin changes do', () async {
    var now = DateTime(2026, 10, 27, 14);
    Completer<ProbeResult>? pending;
    final monitor = ReachabilityMonitor(
      clock: () => now,
      localAddresses: () async => sortLocalIpAddresses(['2001:da8::1']),
      routeProbe: (route, pin, stop) =>
          pending?.future ?? Future.value(success),
      relayProbe: (_, _, _) async => success,
    );
    addTearDown(monitor.dispose);
    Map<String, dynamic> device(String pin, DateTime expiry) => {
      'deviceId': 'phone',
      'online': true,
      'peer': {
        'candidates': [public],
        'certificateSha256': pin,
        'expiresAt': expiry.toIso8601String(),
      },
    };
    void update(String pin) => monitor.update(
      onlineDevices: [device(pin, now.add(const Duration(minutes: 30)))],
      centerUrl: 'https://center.invalid',
      online: true,
      cellular: false,
    );
    update('pin');
    await monitor.refresh();
    expect(monitor.verifiedRoutes('phone', [public], 'pin'), isNotEmpty);
    pending = Completer<ProbeResult>();
    final refresh = monitor.refreshDevice('phone');
    await Future<void>.delayed(Duration.zero);
    expect(monitor.checkingDevice('phone'), true);
    expect(monitor.verifiedRoutes('phone', [public], 'pin'), isNotEmpty);
    now = now.add(const Duration(seconds: 20));
    update('pin'); // Same endpoints, only an extended announcement expiry.
    expect(monitor.verifiedRoutes('phone', [public], 'pin'), isNotEmpty);
    now = now.add(const Duration(minutes: 2));
    expect(monitor.verifiedRoutes('phone', [public], 'pin'), isEmpty);
    update('new-pin');
    expect(monitor.verifiedRoutes('phone', [public], 'pin'), isEmpty);
    pending.complete(success);
    await refresh;
  });

  test(
    'failing one source does not suppress another in-flight successful pair',
    () async {
      final monitor = ReachabilityMonitor()
        ..devices = [
          {
            'deviceId': 'phone',
            'peer': {
              'candidates': [public],
              'certificateSha256': 'pin',
            },
          },
        ];
      addTearDown(monitor.dispose);
      final reporter = monitor.captureReporter('phone');
      monitor.markFailed('phone', public, sourceAddress: wifi.sourceAddress);
      reporter(wifi, success);
      reporter(automatic, success);
      final routes = monitor.verifiedRoutes('phone', [public], 'pin');
      expect(routes.map((r) => r.key), [automatic.key]);
    },
  );

  test('a verified scope gets a useful connection budget, not one tiny slice per transport', () {
    final deadline = RouteDeadline();
    final lan = deadline.scopeBudget(last: false, verified: true);
    final coldLan = deadline.scopeBudget(last: false, nextVerified: true);
    expect(lan.inMilliseconds, inInclusiveRange(550, 600));
    expect(coldLan.inMilliseconds, inInclusiveRange(300, 350));
    expect(deadline.scopeBudget(last: true).inMilliseconds, greaterThan(900));
  });

  test('verified pairs retain LAN priority, then use measured RTT rather than a hidden non-cellular preference', () {
    const local = CandidateRoute(address: 'https://10.0.0.2:9443', lan: true);
    final monitor = ReachabilityMonitor()
      ..devices = [
        {
          'deviceId': 'phone',
          'peer': {
            'candidates': [local.address, public],
            'certificateSha256': 'pin',
          },
        },
      ];
    addTearDown(monitor.dispose);
    final report = monitor.captureReporter('phone');
    report(local, (reachable: true, elapsedMs: 300, error: ''));
    report(wifi, (reachable: true, elapsedMs: 90, error: ''));
    report(cellular, (reachable: true, elapsedMs: 5, error: ''));
    expect(
      monitor
          .verifiedRoutes(
            'phone',
            [local.address, public],
            'pin',
            cellular: true,
          )
          .map((r) => r.key),
      [local.key, cellular.key, wifi.key],
    );
    expect(
      monitor
          .verifiedRoutes(
            'phone',
            [local.address, public],
            'pin',
            cellular: false,
          )
          .map((r) => r.key),
      [local.key, wifi.key],
    );
  });

  test(
    'original advertisement order cannot override the ranked verified pairs',
    () async {
      const slow = CandidateRoute(
        address: 'https://[240e::10]:9443',
        lan: false,
      );
      const fast = CandidateRoute(
        address: 'https://[240e::20]:9443',
        lan: false,
      );
      final checks = RouteProbes(
        [slow.address, fast.address],
        [],
        'pin',
        const Duration(seconds: 1),
        routes: [slow, fast],
        verified: [fast, slow],
        probe: (_, _, _) =>
            throw StateError('Verified pairs must not be re-probed'),
      );
      addTearDown(checks.close);
      expect(
        (await checks.firstRoute([slow.address, fast.address]))!.key,
        fast.key,
      );
      checks.discard(fast);
      expect(
        (await checks.firstRoute([slow.address, fast.address]))!.key,
        slow.key,
      );
    },
  );
}
