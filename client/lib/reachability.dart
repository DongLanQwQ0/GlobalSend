import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'network_bridge.dart';
import 'peer.dart';
import 'candidate_routes.dart';
import 'local_ip_addresses.dart';

enum ReachabilityScope { lan, public, relay }

class AddressCheck {
  const AddressCheck({
    required this.deviceId,
    required this.address,
    required this.scope,
    required this.reachable,
    required this.checkedAt,
    this.cellular = false,
    this.elapsedMs = 0,
    this.error = '',
    this.transport = 'https',
    this.tested = true,
    this.sourceAddress = '',
    this.sourceName = '',
    this.sourceEndpoint = '',
    this.targetEndpoint = '',
  });
  final String deviceId, address, error, transport, sourceAddress, sourceName;

  /// Observed socket endpoints are display data, never source-bind inputs.
  final String sourceEndpoint, targetEndpoint;
  final ReachabilityScope scope;
  final bool reachable, cellular, tested;
  final DateTime checkedAt;
  final int elapsedMs;
}

typedef AddressProbe =
    Future<({bool reachable, int elapsedMs, String error})> Function(
      String address,
      String fingerprint,
      bool cellular,
    );
typedef ProbeResult = ({bool reachable, int elapsedMs, String error});
typedef ProbeEndpoints = ({String sourceEndpoint, String targetEndpoint});
typedef CancelableAddressProbe = Future<ProbeResult> Function(
  String address,
  String fingerprint,
  bool cellular,
  ProbeCancellation cancellation,
);
typedef RouteAddressProbe = Future<ProbeResult> Function(
  CandidateRoute route,
  String fingerprint,
  ProbeCancellation cancellation,
);

class ProbeCancellation {
  bool canceled = false;
  final _done = Completer<void>();
  final List<FutureOr<void> Function()> _stops = [];
  void onCancel(FutureOr<void> Function() stop) {
    if (canceled) {
      unawaited(Future<void>.sync(stop));
    } else {
      _stops.add(stop);
    }
  }

  Future<void> cancel() async {
    if (canceled) return;
    canceled = true;
    _done.complete();
    await Future.wait(_stops.map((stop) => Future<void>.sync(stop)));
    _stops.clear();
  }

  Future<ProbeResult?> wait(Future<ProbeResult> work) => Future.any([
    work.then<ProbeResult?>((result) => result),
    _done.future.then<ProbeResult?>((_) => null),
  ]);
}

typedef CandidateStages =
    Future<({List<String> lan, List<String> public})> Function(
      List<String> values,
    );

/// Checks only the same-group addresses advertised by the center. Probes do
/// not obtain transfer tickets or carry files, text, or center credentials.
class ReachabilityMonitor extends ChangeNotifier {
  ReachabilityMonitor({
    AddressProbe? probe,
    AddressProbe? relayProbe,
    CancelableAddressProbe? cancelableProbe,
    CandidateStages? stages,
    Future<String> Function()? networkSignature,
    DateTime Function()? clock,
    this.onNetworkChanged,
    this.cellularCapable = false,
    Future<List<LocalIpAddress>> Function()? localAddresses,
    RouteAddressProbe? routeProbe,
  }) : _probe =
           cancelableProbe ??
           (probe == null
               ? ((a, b, c, stop) =>
                     probePeerAddress(a, b, c, cancellation: stop))
               : ((a, b, c, stop) => probe(a, b, c))),
       _relayProbe = relayProbe == null
           ? ((a, b, c, stop) => probeCenter(a, b, c, cancellation: stop))
           : ((a, b, c, stop) => relayProbe(a, b, c)),
       _stages = stages ?? PeerTransport.candidateStages,
       _networkSignature = networkSignature ?? interfaceSignature,
       _localAddresses = localAddresses,
       _routeProbe = routeProbe,
       _usesInjectedProbe = probe != null || cancelableProbe != null,
       _usesInjectedRelayProbe = relayProbe != null,
       _clock = clock ?? DateTime.now;

  final CancelableAddressProbe _probe, _relayProbe;
  final Set<ProbeCancellation> _probes = {};
  final CandidateStages _stages;
  final Future<String> Function() _networkSignature;
  final DateTime Function() _clock;
  final Future<List<LocalIpAddress>> Function()? _localAddresses;
  final RouteAddressProbe? _routeProbe;
  final bool _usesInjectedProbe;
  final bool _usesInjectedRelayProbe;
  List<LocalIpAddress> _localSnapshot = [];
  bool _localKnown = false;
  String _localSignature = '';
  int _localVersion = 0;
  int _localRequest = 0;
  Future<List<LocalIpAddress>?>? _pendingLocalRead;
  int _pendingLocalRevision = -1;
  final bool cellularCapable;
  final Future<void> Function()? onNetworkChanged;
  final List<AddressCheck> _results = [];
  List<Map<String, dynamic>> devices = [];
  String center = '', _inputSignature = '', _lastNetwork = '';
  String lastError = '';
  bool connected = false, allowCellular = false, running = false;
  bool _disposed = false, _tickRunning = false, _refreshAgain = false;
  int _revision = 0;
  DateTime? lastChecked;
  Timer? _timer;
  static const interval = Duration(minutes: 1);
  final List<AddressCheck> _rtcResults = [];
  final Map<String, Future<void>> _deviceRefreshes = {};
  final Map<String, int> _deviceVersions = {};
  final Map<String, String> _deviceErrors = {};
  final Map<String, ({int revision, int local, int sequence})>
  _devicePassVersions = {};
  final Map<String, void Function()> _deviceCancellations = {};
  final Map<String, int> _failureEpochs = {};
  final Map<String, int> _pairFailures = {};
  String _pairKey(String id, String address, bool cellular, String? source) =>
      jsonEncode([id, address, cellular, source]);
  static const deviceProbeBudget = Duration(seconds: 1);

  static String _peerSignature(dynamic peer) => peer is Map
      ? jsonEncode([
          peer['candidates'],
          peer['certificateSha256'],
          peer['push'],
          peer['cellularPush'],
        ])
      : '';

  bool checkingDevice(String id) => _deviceRefreshes.containsKey(id);
  String deviceError(String id) => _deviceErrors[id] ?? '';

  /// Checks only this peer. Repeated requests share the same bounded pass;
  /// unrelated peers and their cached measurements are left untouched.
  Future<void> refreshDevice(String id) => _beginDeviceCheck(id);

  Future<void> _beginDeviceCheck(
    String id, {
    List<LocalIpAddress>? locals,
    bool withRelay = true,
    Duration budget = deviceProbeBudget,
  }) {
    if (_disposed || !connected || center.isEmpty) return Future.value();
    if (budget <= Duration.zero) return Future.value();
    final active = _deviceRefreshes[id];
    if (active != null) {
      final pass = _devicePassVersions[id];
      if (pass != null &&
          (pass.revision != _revision ||
              pass.local != _localVersion ||
              pass.sequence != _deviceVersions[id])) {
        final waiting = Stopwatch()..start();
        return active.then(
          (_) => _beginDeviceCheck(
            id,
            locals: locals,
            withRelay: withRelay,
            budget: budget - waiting.elapsed,
          ),
        );
      }
      return active;
    }
    final done = Completer<void>();
    _deviceRefreshes[id] = done.future;
    final version = (_deviceVersions[id] ?? 0) + 1;
    _deviceVersions[id] = version;
    _devicePassVersions[id] = (
      revision: _revision,
      local: _localVersion,
      sequence: version,
    );
    _deviceErrors.remove(id);
    // Keep still-fresh verified paths usable while the next refresh is running.
    // Each completed check replaces its own pair; topology changes clear them.
    notifyListeners();
    unawaited(
      _checkDevice(
        id,
        version,
        locals: locals,
        withRelay: withRelay,
        budget: budget,
      ).then(
        (_) {
          _deviceRefreshes.remove(id);
          if (!_disposed) notifyListeners();
          done.complete();
        },
        onError: (Object error, StackTrace trace) {
          _deviceRefreshes.remove(id);
          if (!_disposed) notifyListeners();
          done.completeError(error, trace);
        },
      ),
    );
    return done.future;
  }

  Future<List<LocalIpAddress>?> _readLocalSnapshot({String? requestingDevice}) {
    final pending = _pendingLocalRead;
    if (pending != null && _pendingLocalRevision == _revision) return pending;
    late final Future<List<LocalIpAddress>?> future;
    future = _loadLocalSnapshot(requestingDevice: requestingDevice)
        .whenComplete(() {
          if (identical(_pendingLocalRead, future)) _pendingLocalRead = null;
        });
    _pendingLocalRead = future;
    _pendingLocalRevision = _revision;
    return future;
  }

  Future<List<LocalIpAddress>?> _loadLocalSnapshot({
    String? requestingDevice,
  }) async {
    final read = _localAddresses;
    if (read == null) return null;
    final revision = _revision, request = ++_localRequest;
    final values = await read().timeout(deviceProbeBudget);
    if (_disposed || revision != _revision || request != _localRequest)
      return null;
    final parts =
        values
            .map(
              (ip) => jsonEncode([
                ip.address,
                ip.source?.id,
                ip.source?.kind,
                ip.source?.internet,
              ]),
            )
            .toList()
          ..sort();
    final signature = parts.join('|');
    if (_localKnown && signature != _localSignature) {
      _localVersion++;
      _cancelProbes(exceptDevice: requestingDevice);
      _results.clear();
      _rtcResults.clear();
      lastChecked = null;
      if (running) _refreshAgain = connected;
    }
    _localKnown = true;
    _localSignature = signature;
    _localSnapshot = values;
    return values;
  }

  List<CandidateRoute>? plannedRoutes(
    List<String> candidates, {
    bool cellular = false,
  }) => !_localKnown
      ? null
      : planCandidateRoutes(
          candidates,
          _localSnapshot,
          androidCellular: cellularCapable,
          allowCellular: cellular,
        );

  String untestedReason(String address) {
    final ip = literalCandidateAddress(address);
    if (ip == null) return '未提供可直接检测的 IP 地址';
    if (!isDirectIp(ip)) return '本机或特殊保留地址，不用于直连';
    final routes = plannedRoutes([address], cellular: allowCellular);
    if (routes != null && routes.isEmpty) {
      return ip.type == InternetAddressType.IPv6
          ? '本机暂无可用 IPv6 路径'
          : '本机暂无可用 IPv4 路径';
    }
    return '';
  }

  String? sourceFor(
    String deviceId,
    String address, {
    bool cellular = false,
    ReachabilityScope? scope,
  }) {
    final checks = forDevice(deviceId).where(
      (check) =>
          check.reachable &&
          check.address == address &&
          check.cellular == cellular &&
          check.transport == 'https' &&
          (scope == null ||
              check.scope == scope ||
              scope == ReachabilityScope.public &&
                  check.scope == ReachabilityScope.lan) &&
          _clock().difference(check.checkedAt) < const Duration(minutes: 2),
    );
    return checks.firstOrNull?.sourceAddress;
  }

  /// A fresh success is tied to the currently advertised endpoint and pin.
  /// Returned pairs are ready for file TLS, not a reason to repeat /probe.
  List<CandidateRoute> verifiedRoutes(
    String deviceId,
    List<String> addresses,
    String fingerprint, {
    bool cellular = false,
  }) {
    final peer = devices
        .where((d) => d['deviceId'] == deviceId)
        .firstOrNull?['peer'];
    if (peer is! Map || peer['certificateSha256'] != fingerprint) return [];
    final advertised = List<String>.from(peer['candidates'] ?? []);
    return [
      for (final check in forDevice(deviceId))
        if (check.reachable &&
            check.tested &&
            check.transport == 'https' &&
            (!check.cellular || cellular) &&
            addresses.contains(check.address) &&
            advertised.contains(check.address) &&
            _clock().difference(check.checkedAt) < const Duration(minutes: 2))
          CandidateRoute(
            address: check.address,
            lan: check.scope == ReachabilityScope.lan,
            sourceAddress: check.sourceAddress,
            sourceName: check.sourceName,
            cellular: check.cellular,
          ),
    ];
  }

  /// Feed on-demand file-route handshakes back into the same measured cache.
  /// Capturing generations here prevents late replies from an old network or
  /// a route which subsequently failed from becoming current again.
  void Function(CandidateRoute, ProbeResult) captureReporter(String deviceId) {
    final version = (_deviceVersions[deviceId] ?? 0) + 1;
    _deviceVersions[deviceId] = version;
    _deviceCancellations[deviceId]?.call();
    final revision = _revision,
        local = _localVersion,
        failures = Map<String, int>.from(_pairFailures);
    return (route, result) {
      final pair = _pairKey(
        deviceId,
        route.address,
        route.cellular,
        route.sourceAddress,
      );
      final endpoint = _pairKey(deviceId, route.address, route.cellular, null);
      if (_disposed ||
          revision != _revision ||
          local != _localVersion ||
          failures[pair] != _pairFailures[pair] ||
          failures[endpoint] != _pairFailures[endpoint] ||
          version != _deviceVersions[deviceId])
        return;
      _mergeCheck(
        AddressCheck(
          deviceId: deviceId,
          address: route.address,
          scope: route.lan ? ReachabilityScope.lan : ReachabilityScope.public,
          reachable: result.reachable,
          cellular: route.cellular,
          elapsedMs: result.elapsedMs,
          error: result.error,
          checkedAt: _clock(),
          sourceAddress: route.sourceAddress,
          sourceName: route.sourceName,
        ),
      );
      notifyListeners();
    };
  }

  void _mergeCheck(AddressCheck check) {
    bool same(AddressCheck value) =>
        value.deviceId == check.deviceId &&
        value.address == check.address &&
        value.cellular == check.cellular &&
        value.transport == check.transport &&
        value.sourceAddress == check.sourceAddress;
    if (_results.any(
      (value) => same(value) && value.checkedAt.isAfter(check.checkedAt),
    ))
      return;
    _results.removeWhere(same);
    _results.add(check);
  }

  void markFailed(
    String deviceId,
    String address, {
    bool cellular = false,
    String? sourceAddress,
  }) {
    _failureEpochs[deviceId] = (_failureEpochs[deviceId] ?? 0) + 1;
    final key = _pairKey(deviceId, address, cellular, sourceAddress);
    _pairFailures[key] = (_pairFailures[key] ?? 0) + 1;
    final affected = _results
        .where(
          (check) =>
              check.deviceId == deviceId &&
              check.address == address &&
              check.cellular == cellular &&
              (sourceAddress == null || check.sourceAddress == sourceAddress),
        )
        .toList();
    for (final check in affected) {
      _mergeCheck(
        AddressCheck(
          deviceId: deviceId,
          address: address,
          scope: check.scope,
          cellular: cellular,
          reachable: false,
          checkedAt: _clock(),
          error: '连接已失效',
          sourceAddress: check.sourceAddress,
          sourceName: check.sourceName,
        ),
      );
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _checkDevice(
    String id,
    int version, {
    List<LocalIpAddress>? locals,
    bool withRelay = true,
    Duration budget = deviceProbeBudget,
  }) async {
    final revision = _revision;
    final failureEpoch = _failureEpochs[id] ?? 0;
    final device = devices
        .where((device) => device['deviceId'] == id)
        .firstOrNull;
    if (device == null) {
      _deviceErrors[id] = '设备已离线或不在当前组';
      return;
    }
    final collected = <AddressCheck>[];
    final active = <ProbeCancellation>{};
    final expired = Completer<void>();
    var timedOut = false;
    var localVersion = _localVersion;
    bool current() =>
        !_disposed &&
        revision == _revision &&
        _deviceVersions[id] == version &&
        (_failureEpochs[id] ?? 0) == failureEpoch &&
        localVersion == _localVersion;
    void cancelPass() {
      if (!expired.isCompleted) expired.complete();
      for (final stop in active.toList()) {
        unawaited(stop.cancel().catchError((Object _) {}));
      }
    }

    _deviceCancellations[id] = cancelPass;
    final deadline = Timer(budget > Duration.zero ? budget : Duration.zero, () {
      timedOut = true;
      cancelPass();
    });
    Future<void> check(
      String address,
      ReachabilityScope scope,
      bool cellular,
      String fingerprint, {
      bool relay = false,
      CandidateRoute? route,
    }) async {
      if (!current() || timedOut) return;
      final watch = Stopwatch()..start();
      ProbeEndpoints? endpoints;
      void connected(ProbeEndpoints value) => endpoints = value;
      try {
        final result = await _runProbe(
          relay
              ? _usesInjectedRelayProbe
                    ? _relayProbe
                    : (a, b, c, stop) => probeCenter(
                        a,
                        b,
                        c,
                        cancellation: stop,
                        onConnected: connected,
                      )
              : route == null
              ? _usesInjectedProbe
                    ? _probe
                    : (a, b, c, stop) => probePeerAddress(
                        a,
                        b,
                        c,
                        cancellation: stop,
                        onConnected: connected,
                      )
              : (a, b, c, stop) => _routeProbe != null
                    ? _routeProbe(route, b, stop)
                    : _usesInjectedProbe
                    ? _probe(a, b, c, stop)
                    : probePeerAddress(
                        a,
                        b,
                        c,
                        cancellation: stop,
                        sourceAddress: route.sourceAddress,
                        onConnected: connected,
                      ),
          relay ? '$address/health/ready' : address,
          fingerprint,
          cellular,
          group: active,
        );
        if (!current() || result == null && !timedOut) return;
        collected.add(
          AddressCheck(
            deviceId: id,
            address: address,
            scope: scope,
            cellular: cellular,
            reachable: result?.reachable ?? false,
            elapsedMs: result?.elapsedMs ?? watch.elapsedMilliseconds,
            error: result?.error ?? '检测超时（1 秒）',
            checkedAt: _clock(),
            sourceAddress: route?.sourceAddress ?? '',
            sourceName: route?.sourceName ?? '',
            sourceEndpoint: result?.reachable == true
                ? endpoints?.sourceEndpoint ?? ''
                : '',
            targetEndpoint: result?.reachable == true
                ? endpoints?.targetEndpoint ?? ''
                : '',
          ),
        );
      } catch (error) {
        if (!current()) return;
        collected.add(
          AddressCheck(
            deviceId: id,
            address: address,
            scope: scope,
            cellular: cellular,
            reachable: false,
            elapsedMs: watch.elapsedMilliseconds,
            error: '$error',
            checkedAt: _clock(),
            sourceAddress: route?.sourceAddress ?? '',
            sourceName: route?.sourceName ?? '',
          ),
        );
      }
    }

    // Center readiness is measured separately, not treated as proof that the
    // remote peer can receive a file through the relay.
    var relay = Future<void>.value();
    try {
      if (locals == null && _localAddresses != null) {
        locals = await Future.any<List<LocalIpAddress>?>([
          _readLocalSnapshot(requestingDevice: id),
          expired.future.then((_) => null),
        ]);
        localVersion = _localVersion;
        _devicePassVersions[id] = (
          revision: revision,
          local: localVersion,
          sequence: version,
        );
        if (locals == null || !current() || timedOut) {
          if (current() && timedOut) _deviceErrors[id] = '本机地址读取超时';
          await relay;
          return;
        }
      }
      if (withRelay)
        relay = check(center, ReachabilityScope.relay, false, '', relay: true);
      final peer = device['peer'];
      final expiry = peer is Map
          ? DateTime.tryParse(peer['expiresAt'] as String? ?? '')
          : null;
      if (peer is Map && (expiry == null || expiry.isAfter(_clock()))) {
        final values = List<String>.from(peer['candidates'] as List? ?? []);
        final fingerprint = peer['certificateSha256'] as String? ?? '';
        if (fingerprint.isNotEmpty && locals != null) {
          final routes = planCandidateRoutes(
            values,
            locals,
            androidCellular: cellularCapable,
            allowCellular: allowCellular,
          );
          await Future.wait([
            for (final route in routes)
              check(
                route.address,
                route.lan ? ReachabilityScope.lan : ReachabilityScope.public,
                route.cellular,
                fingerprint,
                route: route,
              ),
          ]);
        } else if (fingerprint.isNotEmpty) {
          final stages =
              await Future.any<({List<String> lan, List<String> public})?>([
                _stages(values),
                expired.future.then((_) => null),
              ]);
          if (stages == null) {
            if (current()) _deviceErrors[id] = '地址分类超时，未完成的地址仍为未测';
          } else if (current() && !timedOut) {
            await Future.wait([
              for (final address in stages.lan.toSet())
                check(address, ReachabilityScope.lan, false, fingerprint),
              for (final address in stages.public.toSet().difference(
                stages.lan.toSet(),
              ))
                check(address, ReachabilityScope.public, false, fingerprint),
              if (cellularCapable && allowCellular)
                for (final address in stages.public.toSet())
                  check(address, ReachabilityScope.public, true, fingerprint),
            ]);
          }
        }
      }
      await relay;
      if (!current()) return;
      for (final result in collected) {
        _mergeCheck(result);
      }
    } catch (error) {
      if (current()) _deviceErrors[id] = '$error';
      await relay;
    } finally {
      deadline.cancel();
      if (identical(_deviceCancellations[id], cancelPass))
        _deviceCancellations.remove(id);
      for (final stop in active.toList()) {
        unawaited(stop.cancel().catchError((Object _) {}));
      }
    }
  }

  void setRtcResults(String self, List<Map<String, dynamic>> values) {
    _rtcResults
      ..clear()
      ..addAll(
        values
            .where(
              (r) =>
                  (r['initiatorDeviceId'] == self ||
                      r['responderDeviceId'] == self) &&
                  DateTime.parse(r['expiresAt']).isAfter(_clock()),
            )
            .map(
              (r) => AddressCheck(
                deviceId: r['initiatorDeviceId'] == self
                    ? r['responderDeviceId']
                    : r['initiatorDeviceId'],
                address:
                    (r['initiatorDeviceId'] == self
                            ? r['responderAddress']
                            : r['initiatorAddress'])
                        as String? ??
                    'WebRTC',
                sourceAddress:
                    (r['initiatorDeviceId'] == self
                            ? r['initiatorAddress']
                            : r['responderAddress'])
                        as String? ??
                    '',
                sourceName: 'WebRTC',
                sourceEndpoint:
                    (r['initiatorDeviceId'] == self
                            ? r['initiatorAddress']
                            : r['responderAddress'])
                        as String? ??
                    '',
                targetEndpoint:
                    (r['initiatorDeviceId'] == self
                            ? r['responderAddress']
                            : r['initiatorAddress'])
                        as String? ??
                    '',
                scope: r['scope'] == 'lan'
                    ? ReachabilityScope.lan
                    : ReachabilityScope.public,
                reachable: r['success'] == true,
                checkedAt: DateTime.parse(r['checkedAt']),
                elapsedMs: r['elapsedMs'] as int? ?? 0,
                error: r['error'] as String? ?? '',
                transport: 'rtc',
              ),
            ),
      );
    if (!_disposed) notifyListeners();
  }

  bool preferRtc(String deviceId, ReachabilityScope scope) {
    final checks = forDevice(deviceId).where((r) => r.scope == scope);
    return checks.any((r) => r.transport == 'rtc' && r.reachable) &&
        !checks.any((r) => r.transport == 'https' && r.reachable);
  }

  void _pruneExpired() {
    final now = _clock();
    final ids = devices.map((d) => d['deviceId']).toSet();
    _rtcResults.removeWhere(
      (r) =>
          !ids.contains(r.deviceId) ||
          now.difference(r.checkedAt) >= const Duration(minutes: 2),
    );
    _results.removeWhere((result) {
      final device = devices
          .where((device) => device['deviceId'] == result.deviceId)
          .firstOrNull;
      if (device == null) return true;
      if (result.scope == ReachabilityScope.relay) return false;
      final peer = device['peer'];
      if (peer is! Map) return true;
      final expiry = DateTime.tryParse(peer['expiresAt'] ?? '');
      return expiry != null && !expiry.isAfter(now);
    });
  }

  List<AddressCheck> get results {
    _pruneExpired();
    return List.unmodifiable([..._results, ..._rtcResults]);
  }

  List<AddressCheck> forDevice(String id) {
    _pruneExpired();
    final values = results.where((value) => value.deviceId == id).toList();
    values.sort((a, b) {
      if (a.reachable != b.reachable) return a.reachable ? -1 : 1;
      final scope = a.scope.index.compareTo(b.scope.index);
      if (scope != 0) return scope;
      if (a.cellular != b.cellular) return a.cellular ? 1 : -1;
      return a.elapsedMs.compareTo(b.elapsedMs);
    });
    return values;
  }

  void update({
    required List<Map<String, dynamic>> onlineDevices,
    required String centerUrl,
    required bool online,
    required bool cellular,
  }) {
    final oldPeers = {
      for (final device in devices)
        device['deviceId']: _peerSignature(device['peer']),
    };
    final policyChanged =
        center != centerUrl || connected != online || allowCellular != cellular;
    final visible = onlineDevices
        .where(
          (device) => device['online'] != false && device['revoked'] != true,
        )
        .toList();
    final next = jsonEncode([
      centerUrl,
      online,
      cellular,
      visible.map((d) => [d['deviceId'], _peerSignature(d['peer'])]).toList(),
    ]);
    devices = visible.map((d) => Map<String, dynamic>.from(d)).toList();
    center = centerUrl;
    connected = online;
    allowCellular = cellular;
    if (next == _inputSignature) return;
    _inputSignature = next;
    _revision++;
    _cancelProbes();
    if (running) _refreshAgain = online;
    lastChecked = null;
    final ids = devices.map((d) => d['deviceId']).toSet();
    final changedIds = devices
        .where(
          (device) =>
              oldPeers[device['deviceId']] != _peerSignature(device['peer']),
        )
        .map((device) => device['deviceId'])
        .toSet();
    _results.removeWhere(
      (r) =>
          policyChanged ||
          !ids.contains(r.deviceId) ||
          changedIds.contains(r.deviceId),
    );
    if (policyChanged) _rtcResults.clear();
    if (!online) {
      _results.clear();
      lastChecked = null;
    }
    if (!_disposed) notifyListeners();
    if (online && !_tickRunning) unawaited(refresh());
  }

  void start() {
    _timer ??= Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(tick()),
    );
  }

  Future<void> tick() async {
    if (_disposed || _tickRunning) return;
    _tickRunning = true;
    try {
      final signature = await _networkSignature();
      if (_disposed) return;
      final changed = signature != _lastNetwork;
      _lastNetwork = signature;
      if (changed) {
        _revision++;
        _cancelProbes();
        _results.clear();
        _rtcResults.clear();
        lastChecked = null;
        notifyListeners();
        await onNetworkChanged?.call();
      }
      if (_disposed || !connected) return;
      if (changed ||
          lastChecked == null ||
          _clock().difference(lastChecked!) >= interval) {
        await refresh();
      }
    } catch (error) {
      lastError = '$error';
      if (!_disposed) notifyListeners();
    } finally {
      _tickRunning = false;
    }
  }

  Future<void>? _allRefresh;

  Future<void> refresh() {
    if (_disposed || !connected || center.isEmpty) return Future.value();
    final active = _allRefresh;
    if (active != null) return active;
    final done = Completer<void>();
    _allRefresh = done.future;
    running = true;
    notifyListeners();
    unawaited(() async {
      try {
        do {
          _refreshAgain = false;
          await _refreshAllPass();
        } while (_refreshAgain && connected && !_disposed);
        done.complete();
      } catch (error, trace) {
        done.completeError(error, trace);
      } finally {
        _allRefresh = null;
        running = false;
        if (!_disposed) notifyListeners();
      }
    }());
    return done.future;
  }

  Future<void> _refreshAllPass() async {
    final revision = _revision;
    final watch = Stopwatch()..start();
    final snapshot = List<Map<String, dynamic>>.from(devices);
    final relayStops = <ProbeCancellation>{};
    Timer? deadline;
    try {
      final locals = await _readLocalSnapshot().timeout(deviceProbeBudget);
      if (_disposed || revision != _revision) return;
      final remaining = deviceProbeBudget - watch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('本机地址读取超时');
      deadline = Timer(remaining, () {
        for (final stop in relayStops.toList()) {
          unawaited(stop.cancel().catchError((Object _) {}));
        }
      });
      final checks = [
        for (final device in snapshot)
          _beginDeviceCheck(
            device['deviceId'] as String,
            locals: locals,
            withRelay: false,
            budget: remaining,
          ),
      ];
      final versions = {
        for (final device in snapshot)
          device['deviceId'] as String:
              _deviceVersions[device['deviceId']] ?? 0,
      };
      ProbeResult? relay;
      ProbeEndpoints? relayEndpoints;
      Future<void> checkRelay() async {
        if (snapshot.isEmpty) return;
        final clock = Stopwatch()..start();
        try {
          relay = await _runProbe(
            _usesInjectedRelayProbe
                ? _relayProbe
                : (a, b, c, stop) => probeCenter(
                    a,
                    b,
                    c,
                    cancellation: stop,
                    onConnected: (value) => relayEndpoints = value,
                  ),
            '$center/health/ready',
            '',
            false,
            group: relayStops,
          );
          relay ??= (
            reachable: false,
            elapsedMs: clock.elapsedMilliseconds,
            error: '检测超时（1 秒）',
          );
        } catch (error) {
          relay = (
            reachable: false,
            elapsedMs: clock.elapsedMilliseconds,
            error: '$error',
          );
        }
      }

      await Future.wait([...checks, checkRelay()]);
      if (_disposed || revision != _revision) return;
      if (relay != null) {
        for (final device in snapshot) {
          final id = device['deviceId'] as String;
          if (versions[id] != _deviceVersions[id]) continue;
          _results.removeWhere(
            (r) => r.deviceId == id && r.scope == ReachabilityScope.relay,
          );
          _results.add(
            AddressCheck(
              deviceId: id,
              address: center,
              scope: ReachabilityScope.relay,
              reachable: relay!.reachable,
              elapsedMs: relay!.elapsedMs,
              error: relay!.error,
              checkedAt: _clock(),
              sourceEndpoint: relay!.reachable
                  ? relayEndpoints?.sourceEndpoint ?? ''
                  : '',
              targetEndpoint: relay!.reachable
                  ? relayEndpoints?.targetEndpoint ?? ''
                  : '',
            ),
          );
        }
      }
      lastError = '';
      lastChecked = _clock();
    } catch (error) {
      if (!_disposed && revision == _revision) lastError = '$error';
    } finally {
      deadline?.cancel();
      for (final stop in relayStops.toList()) {
        unawaited(stop.cancel().catchError((Object _) {}));
      }
    }
  }

  Future<ProbeResult?> _runProbe(
    CancelableAddressProbe probe,
    String address,
    String fingerprint,
    bool cellular, {
    Set<ProbeCancellation>? group,
  }) async {
    final stop = ProbeCancellation();
    _probes.add(stop);
    group?.add(stop);
    try {
      return await stop.wait(probe(address, fingerprint, cellular, stop));
    } finally {
      _probes.remove(stop);
      group?.remove(stop);
    }
  }

  void _cancelProbes({String? exceptDevice}) {
    for (final entry in _deviceCancellations.entries.toList()) {
      if (entry.key != exceptDevice) entry.value();
    }
    for (final probe in _probes.toList()) {
      unawaited(probe.cancel().catchError((Object _) {}));
    }
  }

  List<String> prioritize(
    String deviceId,
    List<String> addresses,
    ReachabilityScope scope, {
    bool cellular = false,
  }) {
    final checks = forDevice(deviceId)
        .where(
          (check) =>
              (check.scope == scope ||
                  (scope == ReachabilityScope.public &&
                      check.scope == ReachabilityScope.lan)) &&
              check.cellular == cellular &&
              _clock().difference(check.checkedAt) < const Duration(minutes: 2),
        )
        .toList();
    int rank(String address) {
      final check = checks
          .where((check) => check.address == address)
          .firstOrNull;
      return check == null
          ? 1
          : check.reachable
          ? 0
          : 2;
    }

    final result = addresses.toList();
    result.sort((a, b) {
      final order = rank(a).compareTo(rank(b));
      if (order != 0) return order;
      if (rank(a) == 0) {
        final latency = checks
            .firstWhere((check) => check.address == a)
            .elapsedMs
            .compareTo(
              checks.firstWhere((check) => check.address == b).elapsedMs,
            );
        if (latency != 0) return latency;
      }
      return addresses.indexOf(a).compareTo(addresses.indexOf(b));
    });
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelProbes();
    _timer?.cancel();
    super.dispose();
  }
}

Future<String> interfaceSignature() async {
  final interfaces = await NetworkInterface.list(includeLoopback: false);
  final values = [
    for (final interface in interfaces)
      for (final address in interface.addresses)
        '${interface.index}:${address.address}',
  ]..sort();
  return values.join('|');
}

Future<({bool reachable, int elapsedMs, String error})> probePeerAddress(
  String address,
  String fingerprint,
  bool cellular, {
  ProbeCancellation? cancellation,
  String? sourceAddress,
  void Function(ProbeEndpoints)? onConnected,
}) async {
  final nonce = List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  if (cellular) {
    cancellation?.onCancel(() => NetworkBridge.cancel(nonce));
    final result = await NetworkBridge.probePeer(
      candidate: address,
      fingerprint: fingerprint,
      nonce: nonce,
      cellular: true,
      operationId: nonce,
    );
    if (result['reachable'] == true) {
      onConnected?.call((
        sourceEndpoint: result['sourceEndpoint'] as String? ?? '',
        targetEndpoint: result['targetEndpoint'] as String? ?? '',
      ));
    }
    return (
      reachable: result['reachable'] == true,
      elapsedMs: result['elapsedMs'] as int? ?? 0,
      error: result['error'] as String? ?? '',
    );
  }
  ProbeEndpoints? endpoints;
  final watch = Stopwatch()..start(),
      client = PeerTransport.pinnedClient(
        fingerprint,
        sourceAddress: sourceAddress,
        onConnected: (socket) => endpoints = probeSocketEndpoints(socket),
      );
  cancellation?.onCancel(() => client.close(force: true));
  try {
    final request = await client.getUrl(
      Uri.parse(address)
          .replace(path: '/probe', queryParameters: {'nonce': nonce}),
    );
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 4));
    final bytes = await response
        .fold<List<int>>([], (buffer, chunk) {
          if (buffer.length + chunk.length > 4096) {
            throw const FormatException('设备响应过大');
          }
          return buffer..addAll(chunk);
        })
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final reply = jsonDecode(utf8.decode(bytes));
    if (reply['nonce'] != nonce || reply['certificateSha256'] != fingerprint) {
      throw const FormatException('设备身份不匹配');
    }
    if (endpoints != null) onConnected?.call(endpoints!);
    return (reachable: true, elapsedMs: watch.elapsedMilliseconds, error: '');
  } catch (error) {
    return (
      reachable: false,
      elapsedMs: watch.elapsedMilliseconds,
      error: '$error',
    );
  } finally {
    client.close(force: true);
  }
}

Future<({bool reachable, int elapsedMs, String error})> probeCenter(
  String address,
  String fingerprint,
  bool cellular, {
  ProbeCancellation? cancellation,
  void Function(ProbeEndpoints)? onConnected,
}) async {
  final watch = Stopwatch()..start();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  ProbeEndpoints? endpoints;
  client.connectionFactory = (url, proxyHost, proxyPort) async {
    final tcp = await Socket.startConnect(
      proxyHost ?? url.host.replaceAll(RegExp(r'^\[|\]$'), ''),
      proxyPort ?? url.port,
    );
    Socket? raw, secure;
    var canceled = false;
    final socket = tcp.socket.then<Socket>((connected) async {
      raw = connected;
      if (canceled) {
        connected.destroy();
        throw const SocketException('连接已取消');
      }
      final result = proxyHost == null && url.scheme == 'https'
          ? await SecureSocket.secure(
              connected,
              host: url.host.replaceAll(RegExp(r'^\[|\]$'), ''),
            )
          : connected;
      secure = result;
      if (canceled) {
        result.destroy();
        throw const SocketException('连接已取消');
      }
      endpoints = probeSocketEndpoints(result);
      return result;
    });
    return ConnectionTask.fromSocket(socket, () {
      canceled = true;
      tcp.cancel();
      raw?.destroy();
      secure?.destroy();
    });
  };
  cancellation?.onCancel(() => client.close(force: true));
  try {
    final request = await client.getUrl(Uri.parse(address));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 4));
    await response.drain<void>().timeout(const Duration(seconds: 4));
    if (response.statusCode == 200 && endpoints != null)
      onConnected?.call(endpoints!);
    return (
      reachable: response.statusCode == 200,
      elapsedMs: watch.elapsedMilliseconds,
      error: response.statusCode == 200 ? '' : 'HTTP ${response.statusCode}',
    );
  } catch (error) {
    return (
      reachable: false,
      elapsedMs: watch.elapsedMilliseconds,
      error: '$error',
    );
  } finally {
    client.close(force: true);
  }
}

String probeEndpoint(InternetAddress address, int port) =>
    '${address.type == InternetAddressType.IPv6 ? '[${address.address}]' : address.address}:$port';

ProbeEndpoints probeSocketEndpoints(Socket connection) => (
  sourceEndpoint: probeEndpoint(connection.address, connection.port),
  targetEndpoint: probeEndpoint(
    connection.remoteAddress,
    connection.remotePort,
  ),
);
