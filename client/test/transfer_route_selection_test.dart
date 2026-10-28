import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/transfer_route_selection.dart';

TransferRouteChoice choice(
  String name, {
  String phase = 'lan',
  bool? ready,
  Future<bool?>? pending,
}) => TransferRouteChoice(
  phase: phase,
  label: name,
  run: () async => true,
  ready: ready,
  readiness: pending,
);

void main() {
  test(
    'measured RTT ranks proven transports and reserves a proven fallback',
    () async {
      final forward = TransferRouteChoice(
        phase: 'lan',
        label: 'forward',
        run: () async => true,
        ready: true,
        latency: () => 90,
      );
      final reverse = TransferRouteChoice(
        phase: 'lan',
        label: 'reverse',
        run: () async => true,
        ready: true,
        latency: () => 8,
      );
      final selection = TransferRouteSelection([forward, reverse]);
      addTearDown(selection.close);
      expect(await selection.next('lan', Duration.zero), same(reverse));
      expect(
        selection.attemptBudget(reverse, const Duration(milliseconds: 600)),
        const Duration(milliseconds: 390),
      );
      reverse.attempted = true;
      expect(await selection.next('lan', Duration.zero), same(forward));
      expect(
        selection.attemptBudget(forward, const Duration(milliseconds: 210)),
        const Duration(milliseconds: 210),
      );
    },
  );

  test(
    'warm reverse transport wins immediately over a hanging forward probe',
    () async {
      final forward = choice('forward', pending: Completer<bool?>().future);
      final reverse = choice('reverse', ready: true);
      final selection = TransferRouteSelection([forward, reverse]);
      addTearDown(selection.close);
      expect(
        await selection
            .next('lan', const Duration(seconds: 1))
            .timeout(const Duration(milliseconds: 100)),
        same(reverse),
      );
      expect(
        selection.attemptBudget(reverse, const Duration(milliseconds: 600)),
        const Duration(milliseconds: 600),
      );
    },
  );

  test(
    'cold probes can finish out of order without waiting for forward',
    () async {
      final forward = choice('forward', pending: Completer<bool?>().future);
      final result = Completer<bool?>();
      final reverse = choice('reverse', pending: result.future);
      final selection = TransferRouteSelection([forward, reverse]);
      addTearDown(selection.close);
      final next = selection.next('lan', const Duration(seconds: 1));
      result.complete(true);
      expect(
        await next.timeout(const Duration(milliseconds: 100)),
        same(reverse),
      );
      reverse.attempted = true;
      expect(await selection.next('lan', Duration.zero), same(forward));
    },
  );

  test(
    'LAN stays ahead of warm public and relay is never a direct choice',
    () async {
      final result = Completer<bool?>();
      final lan = choice('lan', pending: result.future);
      final public = choice('public', phase: 'public', ready: true);
      final selection = TransferRouteSelection([lan, public]);
      addTearDown(selection.close);
      final next = selection.next('lan', const Duration(seconds: 1));
      result.complete(true);
      expect(await next, same(lan));
      lan.attempted = true;
      expect(await selection.next('lan', Duration.zero), isNull);
      expect(await selection.next('public', Duration.zero), same(public));
    },
  );

  test('unmeasured transport cannot consume the entire scope budget', () {
    final forward = choice('forward');
    final reverse = choice('reverse', pending: Completer<bool?>().future);
    final selection = TransferRouteSelection([forward, reverse]);
    addTearDown(selection.close);
    expect(
      selection.attemptBudget(forward, const Duration(milliseconds: 600)),
      const Duration(milliseconds: 300),
    );
    forward.attempted = true;
    expect(
      selection.attemptBudget(reverse, const Duration(milliseconds: 300)),
      const Duration(milliseconds: 300),
    );
  });

  test('confirmed unreachable is skipped; legacy and signaling failure remain usable', () async {
    final failed = choice('failed', pending: Future.value(false));
    final unknown = choice('legacy');
    final signaling = choice(
      'signaling',
      pending: Future.error(StateError('offline')),
    );
    final selection = TransferRouteSelection([failed, unknown, signaling]);
    addTearDown(selection.close);
    await Future<void>.delayed(Duration.zero);
    expect(await selection.next('lan', Duration.zero), same(unknown));
    unknown.attempted = true;
    expect(await selection.next('lan', Duration.zero), same(signaling));
    signaling.attempted = true;
    expect(await selection.next('lan', Duration.zero), isNull);
  });
}
