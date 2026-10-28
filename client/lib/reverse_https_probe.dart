import 'dart:async';
import 'dart:convert';

import 'api.dart';
import 'candidate_routes.dart';
import 'connection_window.dart';
import 'local_ip_addresses.dart';
import 'reachability.dart';
import 'route_probes.dart';

/// A peer-to-local nonce handshake. No file grant, file writer or receive slot
/// is opened until the receiver later chooses this transport.
class ReverseHttpsProbes {
  ReverseHttpsProbes(
    this.api, {
    required this.localAddresses,
    required this.cellularAllowed,
    this.androidCellular = false,
    this.probe,
    DateTime Function()? clock,
    bool periodic = true,
  }) : clock = clock ?? DateTime.now {
    if (periodic) {
      _timer = Timer.periodic(const Duration(seconds: 15), (_) {
        if (_online) unawaited(refresh());
      });
    }
  }
  final CenterApi api;
  final Future<List<LocalIpAddress>> Function() localAddresses;
  final bool Function() cellularAllowed;
  final bool androidCellular;
  final RouteAddressProbe? probe;
  final DateTime Function() clock;
  static const lifetime = Duration(seconds: 30);
  final _cache = <String, ({DateTime at, Map<String, dynamic> result})>{};
  final _requests = <String, Future<Map<String, dynamic>?>>{};
  final _windows = <ConnectionWindow>{};
  final _incoming = <String, ProbeCancellation>{};
  List<Map<String, dynamic>> _devices = [];
  String _signature = '';
  bool _closed = false, _online = false;
  int _epoch = 0;
  Timer? _timer;

  void update(
    List<Map<String, dynamic>> devices, {
    required bool online,
    required String localSignature,
  }) {
    if (_closed) return;
    _devices = devices;
    _online = online;
    final signature = jsonEncode([
      online,
      localSignature,
      cellularAllowed(),
      for (final device in devices)
        [
          device['deviceId'],
          device['peer']?['candidates'],
          device['peer']?['certificateSha256'],
          device['peer']?['httpsProbe'],
        ],
    ]);
    if (signature == _signature) return;
    _signature = signature;
    invalidate();
    if (online) unawaited(refresh());
  }

  void invalidate() {
    _epoch++;
    _cache.clear();
    _requests.clear();
    for (final window in _windows.toList()) {
      unawaited(window.cancel());
    }
    for (final stop in _incoming.values.toList()) {
      unawaited(stop.cancel());
    }
  }

  Map<String, dynamic>? cached(String deviceId, String scope) {
    final value = _cache['$deviceId/$scope'];
    return value != null && clock().difference(value.at) < lifetime
        ? value.result
        : null;
  }

  Future<Map<String, dynamic>?> check(
    String deviceId,
    String scope, {
    Duration limit = const Duration(seconds: 1),
  }) {
    if (_closed || !_online || limit <= Duration.zero) return Future.value();
    final value = cached(deviceId, scope);
    if (value != null) return Future.value(value);
    final key = '$deviceId/$scope', existing = _requests[key];
    if (existing != null) return existing;
    final device = _devices.where((d) => d['deviceId'] == deviceId).firstOrNull;
    if (device?['peer']?['httpsProbe'] != true) return Future.value();
    final epoch = _epoch, window = ConnectionWindow(limit);
    _windows.add(window);
    late Future<Map<String, dynamic>?> work;
    work = () async {
      try {
        final reply = await window.run(
          () => api.call('POST', '/devices/$deviceId/https-probes', {
            'scope': scope,
            'timeoutMs': limit.inMilliseconds.clamp(1, 1000),
          }),
        );
        final result = Map<String, dynamic>.from(reply['result']);
        if (_closed || epoch != _epoch) return null;
        if (result['tested'] == true) {
          _cache[key] = (at: clock(), result: result);
        }
        return result;
      } catch (_) {
        // A signaling timeout is unknown reachability, not a failed address.
        return null;
      } finally {
        _windows.remove(window);
        if (identical(_requests[key], work)) _requests.remove(key);
      }
    }();
    _requests[key] = work;
    return work;
  }

  Future<void> refresh({String? deviceId, bool force = false}) async {
    if (_closed || !_online) return;
    if (force) {
      _cache.removeWhere(
        (key, _) => deviceId == null || key.startsWith('$deviceId/'),
      );
    }
    await Future.wait([
      for (final device in _devices)
        if (deviceId == null || device['deviceId'] == deviceId)
          for (final scope in ['lan', 'public'])
            check(device['deviceId'], scope),
    ]);
  }

  Future<void> handle(Map<String, dynamic> message) async {
    final id = message['probeId'] as String;
    if (message['type'] == 'https.probe.cancel') {
      await _incoming[id]?.cancel();
      return;
    }
    if (_closed || _incoming.containsKey(id)) return;
    final stop = ProbeCancellation();
    _incoming[id] = stop;
    final watch = Stopwatch()..start();
    final limit = Duration(milliseconds: message['timeoutMs'] as int);
    final timer = Timer(limit, () => unawaited(stop.cancel()));
    RouteProbes? checks;
    try {
      final locals = await localAddresses().timeout(limit);
      if (stop.canceled) return;
      final peer = message['peer'] as Map;
      final candidates = List<String>.from(peer['candidates']);
      final routes = planCandidateRoutes(
        candidates,
        locals,
        allowCellular: cellularAllowed(),
        androidCellular: androidCellular,
      ).where((route) => route.lan == (message['scope'] == 'lan')).toList();
      final endpoints = <String, ProbeEndpoints>{};
      final results = <String, ProbeResult>{};
      checks = RouteProbes(
        routes.where((r) => !r.cellular).map((r) => r.address).toList(),
        routes.where((r) => r.cellular).map((r) => r.address).toList(),
        peer['certificateSha256'],
        limit - watch.elapsed,
        routes: routes,
        probe:
            probe ??
            (route, pin, cancel) => probePeerAddress(
              route.address,
              pin,
              route.cellular,
              sourceAddress: route.sourceAddress,
              cancellation: cancel,
              onConnected: (value) => endpoints[route.key] = value,
            ),
        onResult: (route, result) => results[route.key] = result,
      );
      stop.onCancel(checks.close);
      final selected = await checks.firstRoute(candidates);
      if (stop.canceled || _closed) return;
      final observed = selected == null ? null : endpoints[selected.key];
      final reporting = ConnectionWindow(limit - watch.elapsed);
      stop.onCancel(reporting.cancel);
      await reporting.run(
        () => api.call('POST', '/https-probes/$id/result', {
          'reachable': selected != null,
          'tested': true,
          'elapsedMs': selected == null
              ? watch.elapsedMilliseconds
              : results[selected.key]!.elapsedMs,
          if (selected != null) ...{
            'address': selected.address,
            'cellular': selected.cellular,
            'sourceName': selected.sourceName,
            if (observed != null) 'sourceEndpoint': observed.sourceEndpoint,
            if (observed != null) 'targetEndpoint': observed.targetEndpoint,
          },
        }),
      );
    } catch (_) {
      // The requester's bounded request also expires/cancels this work.
    } finally {
      timer.cancel();
      await checks?.close();
      if (identical(_incoming[id], stop)) _incoming.remove(id);
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    invalidate();
    await Future.wait(_windows.toList().map((window) => window.cancel()));
    await Future.wait(_incoming.values.toList().map((stop) => stop.cancel()));
  }
}
