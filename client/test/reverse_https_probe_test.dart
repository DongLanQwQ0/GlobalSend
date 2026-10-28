import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/candidate_routes.dart';
import 'package:globalsend/local_ip_addresses.dart';
import 'package:globalsend/reachability.dart';
import 'package:globalsend/reverse_https_probe.dart';

class ProbeApi extends CenterApi {
  ProbeApi(this.respond) : super('http://127.0.0.1');
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  respond;
  final paths = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) {
    paths.add(path);
    return respond(path, Map<String, dynamic>.from(body as Map));
  }
}

const remote = 'https://[240e::2]:9443';
const publicSource = LocalIpAddress('2001:da8::1', LocalIpGroup.ipv6Public);
const success = {
  'reachable': true,
  'tested': true,
  'elapsedMs': 8,
  'address': remote,
  'cellular': true,
};
Map<String, dynamic> device({bool capable = true, String pin = 'pin'}) => {
  'deviceId': 'sender',
  'peer': {
    'httpsProbe': capable,
    'certificateSha256': pin,
    'candidates': [remote],
  },
};
Map<String, dynamic> incoming(String id, {String scope = 'public'}) => {
  'type': 'https.probe',
  'probeId': id,
  'scope': scope,
  'timeoutMs': 250,
  'requesterDeviceId': 'receiver',
  'peer': {
    'candidates': [remote],
    'certificateSha256': 'pin',
  },
};

void main() {
  test('refresh starts LAN and public requests together, shares in-flight work and reuses only fresh results', () async {
    final pending = <String, Completer<Map<String, dynamic>>>{};
    final api = ProbeApi(
      (path, body) => (pending[body['scope']] = Completer()).future,
    );
    var now = DateTime(2026, 10, 28);
    final monitor = ReverseHttpsProbes(
      api,
      localAddresses: () async => [publicSource],
      cellularAllowed: () => true,
      periodic: false,
      clock: () => now,
    );
    addTearDown(() async {
      await monitor.close();
      api.close();
    });
    monitor.update([device()], online: true, localSignature: 'wifi-a');
    final result = monitor.check('sender', 'public');
    expect(pending.keys.toSet(), {'lan', 'public'});
    expect(api.paths.length, 2);
    pending['public']!.complete({'result': success});
    pending['lan']!.complete({
      'result': {'reachable': false, 'tested': true, 'elapsedMs': 10},
    });
    expect((await result)!['cellular'], true);
    expect((await monitor.check('sender', 'public'))!['reachable'], true);
    expect(
      api.paths.length,
      2,
      reason: 'file selection can use a warm reverse path immediately',
    );
    now = now.add(const Duration(seconds: 31));
    final next = monitor.check('sender', 'public');
    expect(api.paths.length, 3);
    pending['public']!.complete({'result': success});
    await next;
    expect(api.paths.every((path) => path.endsWith('/https-probes')), true);
  });

  test('unknown timeouts are not cached as failed paths; old peers need no new endpoint', () async {
    final api = ProbeApi(
      (path, body) async => {
        'result': {'reachable': false, 'tested': false, 'elapsedMs': 1000},
      },
    );
    final monitor = ReverseHttpsProbes(
      api,
      localAddresses: () async => [],
      cellularAllowed: () => false,
      periodic: false,
    );
    addTearDown(() async {
      await monitor.close();
      api.close();
    });
    monitor.update(
      [device(capable: false)],
      online: true,
      localSignature: 'wifi',
    );
    expect(await monitor.check('sender', 'public'), null);
    expect(api.paths, isEmpty);
    monitor.update([device()], online: true, localSignature: 'wifi');
    await monitor.refresh();
    expect(monitor.cached('sender', 'public'), null);
    final before = api.paths.length;
    await monitor.check('sender', 'public');
    expect(api.paths.length, before + 1);
  });

  test('interface or peer changes fence a late success instead of polluting the new cache', () async {
    final pending = <Completer<Map<String, dynamic>>>[];
    final api = ProbeApi((path, body) {
      final p = Completer<Map<String, dynamic>>();
      pending.add(p);
      return p.future;
    });
    final monitor = ReverseHttpsProbes(
      api,
      localAddresses: () async => [],
      cellularAllowed: () => true,
      periodic: false,
    );
    addTearDown(() async {
      await monitor.close();
      api.close();
    });
    monitor.update([device()], online: true, localSignature: 'wifi-a');
    final old = monitor.check('sender', 'public');
    monitor.update(
      [device(pin: 'new pin')],
      online: true,
      localSignature: 'cellular-b',
    );
    for (final p in pending.take(2)) {
      p.complete({'result': success});
    }
    expect(await old, null);
    expect(monitor.cached('sender', 'public'), null);
    for (final p in pending.skip(2)) {
      p.complete({'result': success});
    }
    await monitor.refresh();
    expect(monitor.cached('sender', 'public')!['reachable'], true);
    monitor.update(
      [device(pin: 'new pin')],
      online: false,
      localSignature: 'cellular-b',
    );
    expect(monitor.cached('sender', 'public'), null);
  });

  test('responder starts every matching NIC and cellular handshake together; cellular success is not blocked by Wi-Fi', () async {
    final responses = <Map<String, dynamic>>[],
        started = <CandidateRoute>[],
        stopped = <String>[];
    final api = ProbeApi((path, body) async {
      responses.add(body);
      return {'ok': true};
    });
    final monitor = ReverseHttpsProbes(
      api,
      localAddresses: () async => [publicSource],
      cellularAllowed: () => true,
      androidCellular: true,
      periodic: false,
      probe: (route, pin, stop) {
        expect(pin, 'pin');
        started.add(route);
        stop.onCancel(() => stopped.add(route.key));
        return route.cellular
            ? Future.value((reachable: true, elapsedMs: 8, error: ''))
            : Completer<ProbeResult>().future;
      },
    );
    addTearDown(() async {
      await monitor.close();
      api.close();
    });
    await monitor.handle(incoming('reverse-1'));
    expect(started.length, 3);
    expect(started.where((r) => r.cellular).length, 1);
    expect(responses.single['reachable'], true);
    expect(responses.single['cellular'], true);
    expect(
      stopped.length,
      2,
      reason: 'losing sockets are canceled after choosing the successful pair',
    );
    expect(api.paths, ['/https-probes/reverse-1/result']);
  });

  test('peer cancellation stops native probe work and produces no late result or file operation', () async {
    final api = ProbeApi((path, body) async => {'ok': true});
    final started = Completer<void>(), canceled = <String>[];
    final monitor = ReverseHttpsProbes(
      api,
      localAddresses: () async => [publicSource],
      cellularAllowed: () => false,
      periodic: false,
      probe: (route, pin, stop) {
        stop.onCancel(() => canceled.add(route.key));
        if (!started.isCompleted) started.complete();
        return Completer<ProbeResult>().future;
      },
    );
    addTearDown(() async {
      await monitor.close();
      api.close();
    });
    final task = monitor.handle(incoming('reverse-cancel'));
    await started.future;
    await monitor.handle({
      'type': 'https.probe.cancel',
      'probeId': 'reverse-cancel',
    });
    await task;
    expect(canceled.length, 2);
    expect(api.paths, isEmpty);
  });

  test(
    'LAN checks exclude public-only pairs and never request a cellular network',
    () async {
      final responses = <Map<String, dynamic>>[], starts = <String>[];
      final api = ProbeApi((path, body) async {
        responses.add(body);
        return {'ok': true};
      });
      final monitor = ReverseHttpsProbes(
        api,
        localAddresses: () async => [publicSource],
        cellularAllowed: () => true,
        androidCellular: true,
        periodic: false,
        probe: (route, pin, stop) async {
          starts.add(route.key);
          return (reachable: true, elapsedMs: 3, error: '');
        },
      );
      addTearDown(() async {
        await monitor.close();
        api.close();
      });
      await monitor.handle(incoming('lan-only', scope: 'lan'));
      expect(starts, isEmpty);
      expect(responses.single['reachable'], false);
      expect(responses.single['tested'], true);
    },
  );
}
