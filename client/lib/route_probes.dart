import 'dart:async';

import 'reachability.dart';
import 'candidate_routes.dart';

/// All advertised IPs begin their no-file handshake together. A route attempt
/// may stop waiting without stopping other scopes' independent probes.
class RouteProbes {
  RouteProbes(
    List<String> normal,
    List<String> cellular,
    String fingerprint,
    Duration limit, {
    List<CandidateRoute>? routes,
    List<String> lanAddresses = const [],
    List<CandidateRoute> verified = const [],
    RouteAddressProbe? probe,
    this.onResult,
  }) {
    final cached = {for (final route in verified) route.key: route};
    final available =
        routes ??
        [
          for (final address in normal.toSet())
            CandidateRoute(
              address: address,
              lan: lanAddresses.contains(address),
            ),
          for (final address in cellular.toSet())
            CandidateRoute(address: address, lan: false, cellular: true),
        ];
    final planned = [
      for (final route in verified)
        if (available.any((value) => value.key == route.key)) route,
      ...available,
    ];
    // Cached source/Network pairs are ready immediately. Only unmeasured pairs
    // need another handshake; a stalled default route cannot block cellular.
    for (final route in planned) {
      if (!(route.cellular ? cellular : normal).contains(route.address))
        continue;
      if (_routes.containsKey(route.key)) continue;
      _routes[route.key] = route;
      if (cached.containsKey(route.key)) {
        _reachable.add(route.key);
        _checks[route.key] = Future.value(true);
      } else {
        _start(route, fingerprint, probe);
      }
    }
    _timer = Timer(
      limit > Duration.zero ? limit : Duration.zero,
      () => unawaited(close()),
    );
  }
  final _checks = <String, Future<bool>>{};
  final _routes = <String, CandidateRoute>{};
  final _reachable = <String>{};
  final _rejected = <String>{};
  final void Function(CandidateRoute, ProbeResult)? onResult;
  final _stops = <ProbeCancellation>[];
  Timer? _timer;
  Future<void>? _closing;
  void _start(
    CandidateRoute route,
    String fingerprint,
    RouteAddressProbe? probe,
  ) {
    final stop = ProbeCancellation();
    _stops.add(stop);
    _checks[route.key] = stop
        .wait(
          probe != null
              ? probe(route, fingerprint, stop)
              : probePeerAddress(
                  route.address,
                  fingerprint,
                  route.cellular,
                  cancellation: stop,
                  sourceAddress: route.sourceAddress,
                ),
        )
        .then((value) {
          if (value == null || stop.canceled || _rejected.contains(route.key))
            return false;
          onResult?.call(route, value);
          if (value.reachable) {
            _reachable.add(route.key);
          }
          return value.reachable;
        }, onError: (_) => false)
        .whenComplete(() => _stops.remove(stop));
  }

  CandidateRoute? readyRoute(
    List<String> addresses, {
    bool? cellular,
    bool? lan,
  }) => _matching(
    addresses,
    cellular,
    lan,
  ).where((route) => _reachable.contains(route.key)).firstOrNull;

  Iterable<CandidateRoute> _matching(
    List<String> addresses,
    bool? cellular,
    bool? lan,
  ) sync* {
    for (final address in addresses) {
      for (final route in _routes.values) {
        if (route.address == address &&
            (cellular == null || route.cellular == cellular) &&
            (lan == null || route.lan == lan) &&
            !_rejected.contains(route.key))
          yield route;
      }
    }
  }

  void discard(CandidateRoute route) {
    _rejected.add(route.key);
    _reachable.remove(route.key);
  }

  String? ready(List<String> addresses, {bool cellular = false}) =>
      readyRoute(addresses, cellular: cellular)?.address;

  String? sourceFor(String address, {bool cellular = false}) =>
      readyRoute([address], cellular: cellular)?.sourceAddress;

  Future<String?> first(List<String> addresses, {bool cellular = false}) async {
    return (await firstRoute(addresses, cellular: cellular))?.address;
  }

  Future<CandidateRoute?> firstRoute(
    List<String> addresses, {
    bool? cellular,
    bool? lan,
  }) async {
    final ready = readyRoute(addresses, cellular: cellular, lan: lan);
    if (ready != null) return ready;
    final results = _matching(addresses, cellular, lan).toList();
    if (results.isEmpty) return null;
    final done = Completer<CandidateRoute?>();
    var remaining = results.length;
    for (final route in results) {
      unawaited(
        _checks[route.key]!.then((reachable) {
          if (done.isCompleted) return;
          if (reachable && !_rejected.contains(route.key)) {
            done.complete(route);
          } else if (--remaining == 0) {
            done.complete(null);
          }
        }),
      );
    }
    return done.future;
  }

  Future<void> close() => _closing ??= () async {
    _timer?.cancel();
    await Future.wait(_stops.toList().map((stop) => stop.cancel()));
  }();
}
