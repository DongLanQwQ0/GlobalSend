import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api.dart';
import 'rtc_candidates.dart';
import 'rtc_connection.dart';
import 'rtc_transport.dart';

const rtcProbeChannel = 'globalsend-probe-v1';

String _nonce() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// A short-lived nonce/echo, entirely separate from file authorization/storage.
/// Probe connections never request a cellular Network or configure STUN/TURN.
class RtcProbeSession {
  RtcProbeSession(
    this.api,
    this.deviceId,
    this.view, {
    RtcConnectionFactory? connectionFactory,
    Future<void> Function()? initialize,
    Future<List<InternetAddress>> Function()? addresses,
    this.timeout = const Duration(seconds: 11),
  }) : connectionFactory = connectionFactory ?? createRtcProbeConnection,
       initialize = initialize ?? RtcFileTransport.initialize,
       addresses = addresses ?? _addresses;

  final CenterApi api;
  final String deviceId;
  final Map<String, dynamic> view;
  final RtcConnectionFactory connectionFactory;
  final Future<void> Function() initialize;
  final Future<List<InternetAddress>> Function() addresses;
  final Duration timeout;
  Timer? _deadline;
  static Future<List<InternetAddress>> _addresses() async =>
      (await NetworkInterface.list(includeLinkLocal: true))
          .expand((value) => value.addresses)
          .toList();
  String get route => '/rtc-probes/${view['attemptId']}';
  bool get initiator => deviceId == view['initiatorDeviceId'];
  bool stopped = false, _remote = false, _echoed = false;
  RtcDataConnection? _pc;
  RtcDataChannel? _channel;
  Future<RtcDataConnection>? _creating;
  Future<void>? _closing;
  late RtcCandidatePolicy _policy;
  final _wake = Completer<void>();
  final _opened = Completer<void>();
  final _echo = Completer<void>();
  final _candidates = <Map<String, dynamic>>[];
  final _seen = <String>{};
  final String nonce = _nonce();
  Object? _failure;
  bool _ended = false;

  void _check() {
    if (stopped) throw StateError('检测已取消');
    if (_failure != null) throw _failure!;
  }

  void _fail(Object error) {
    _failure ??= error;
    if (!_wake.isCompleted) _wake.complete();
  }

  Future<void> _pause() => Future.any([
    Future<void>.delayed(const Duration(milliseconds: 180)),
    _wake.future,
  ]);

  void _attach(RtcDataChannel channel) {
    if (stopped || _channel != null || channel.label != rtcProbeChannel) {
      unawaited(channel.close());
      return;
    }
    _channel = channel;
    void state(RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (!_opened.isCompleted) _opened.complete();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed &&
          !stopped &&
          !_echoed) {
        _fail(StateError('检测通道已关闭'));
      }
    }

    channel.onDataChannelState = state;
    channel.onMessage = (message) {
      if (stopped || message.isBinary) return;
      try {
        final value = jsonDecode(message.text) as Map;
        if (initiator) {
          if (value['type'] == 'echo' && value['nonce'] == nonce) {
            _echoed = true;
            if (!_echo.isCompleted) _echo.complete();
          }
        } else if (value['type'] == 'ping' &&
            value['nonce'] is String &&
            RegExp(r'^[a-f0-9]{32}$').hasMatch(value['nonce'])) {
          unawaited(
            () async {
              await _pc!.authorizeData();
              _check();
              await channel.send(
                RTCDataChannelMessage(
                  jsonEncode({'type': 'echo', 'nonce': value['nonce']}),
                ),
              );
              _echoed = true;
            }().catchError(_fail),
          );
        }
      } catch (error) {
        _fail(error);
      }
    };
    if (channel.state != null) state(channel.state!);
  }

  Future<void> _describe(String type) async {
    const constraints = {
      'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
      'optional': <Object>[],
    };
    final value = type == 'offer'
        ? await _pc!.createOffer(constraints)
        : await _pc!.createAnswer(constraints);
    _check();
    await _pc!.setLocalDescription(value);
    _check();
    await api.call('POST', '$route/description', {
      'type': type,
      'sdp': RtcCandidatePolicy.withoutCandidates(value.sdp!),
    });
  }

  Future<void> _sync() async {
    Map<String, dynamic> next;
    try {
      next = Map<String, dynamic>.from((await api.call('GET', route))['probe']);
    } on ApiException catch (error) {
      if (error.status == 410 && !initiator && _echoed) {
        _ended = true;
        return;
      }
      rethrow;
    }
    _check();
    final description = next[initiator ? 'answer' : 'offer'];
    if (!_remote && description is Map) {
      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          RtcCandidatePolicy.withoutCandidates(description['sdp']),
          description['type'],
        ),
      );
      _check();
      _remote = true;
      if (!initiator) await _describe('answer');
    }
    if (_remote) {
      for (final value
          in (next['candidates'] as Map)[initiator
              ? 'responder'
              : 'initiator']) {
        final candidate = Map<String, dynamic>.from(value);
        if (_seen.add(jsonEncode(candidate)) &&
            _policy.allows(candidate['candidate'])) {
          await _pc!.addCandidate(
            RTCIceCandidate(
              candidate['candidate'],
              candidate['sdpMid'],
              candidate['sdpMLineIndex'],
            ),
          );
          _check();
        }
      }
    }
    while (_candidates.isNotEmpty) {
      await api.call('POST', '$route/candidate', _candidates.removeAt(0));
      _check();
    }
  }

  /// Completes only after the real echo; always closes channel and PC.
  Future<void> run() async {
    final watch = Stopwatch()..start();
    _deadline = Timer(timeout, () {
      _fail(TimeoutException('直连检测超时'));
      unawaited(close());
    });
    try {
      await initialize();
      _check();
      _policy = RtcCandidatePolicy(view['scope'], await addresses());
      _check();
      _creating = connectionFactory(
        scope: view['scope'],
        allowCellular: false,
        iceServers: const [],
      );
      _pc = await _creating;
      _check();
      _pc!.onIceCandidate = (candidate) {
        if (!stopped && _policy.allows(candidate.candidate ?? '')) {
          _candidates.add(candidate.toMap());
        }
      };
      _pc!.onConnectionState = (state) {
        if (!stopped &&
            !_echoed &&
            [
              RTCPeerConnectionState.RTCPeerConnectionStateFailed,
              RTCPeerConnectionState.RTCPeerConnectionStateClosed,
            ].contains(state)) {
          _fail(StateError('直连不可达'));
        }
      };
      _pc!.onDataChannel = _attach;
      if (initiator) {
        _attach(await _pc!.createDataChannel(rtcProbeChannel));
        await _describe('offer');
      }
      var sent = false;
      Stopwatch? ping;
      while (true) {
        _check();
        if (watch.elapsed > timeout) {
          throw TimeoutException('直连检测超时');
        }
        await _sync();
        if (_ended) return;
        if (initiator && _opened.isCompleted && !sent) {
          await _pc!.authorizeData();
          _check();
          ping = Stopwatch()..start();
          await _channel!.send(
            RTCDataChannelMessage(jsonEncode({'type': 'ping', 'nonce': nonce})),
          );
          sent = true;
        }
        if (initiator && _echo.isCompleted) {
          await api.call('POST', '$route/complete', {
            'elapsedMs': ping!.elapsedMilliseconds,
          });
          return;
        }
        await _pause();
      }
    } catch (error) {
      if (!stopped) {
        try {
          await api.call('POST', '$route/fail', {'error': 'UNREACHABLE'});
        } catch (_) {}
      }
      rethrow;
    } finally {
      await close();
    }
  }

  Future<void> close() => _closing ??= () async {
    stopped = true;
    _deadline?.cancel();
    if (!_wake.isCompleted) _wake.complete();
    try {
      final creating = _creating;
      if (creating != null) _pc ??= await creating;
    } finally {
      try {
        await _channel?.close();
      } finally {
        await _pc?.close();
      }
    }
  }();
}

/// Foreground-only, one connection at a time; WS wakes it for incoming offers.
class RtcProbeMonitor {
  RtcProbeMonitor(
    this.api,
    this.deviceId, {
    this.onResults,
    this.connectionFactory,
    this.initialize,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final CenterApi api;
  final String deviceId;
  final void Function(List<Map<String, dynamic>>)? onResults;
  final RtcConnectionFactory? connectionFactory;
  final Future<void> Function()? initialize;
  final DateTime Function() clock;
  final _attempted = <String, DateTime>{};
  List<Map<String, dynamic>> results = [];
  Timer? _timer;
  bool _online = false,
      _foreground = true,
      _closed = false,
      _busy = false,
      _again = false;
  int _epoch = 0;
  DateTime? _published;
  Future<void> _presence = Future.value();
  RtcProbeSession? _session;
  bool _checkingSignal = false;
  String _peers = '';
  Set<String> _eligiblePeers = {};
  Set<String> _onlineIds = {};
  bool get active => !_closed && _online && _foreground;
  bool get hasActiveSession => _session != null;

  Future<void> signalChanged() async {
    if (!active) return;
    final session = _session;
    if (session != null && !_checkingSignal) {
      _checkingSignal = true;
      try {
        await api.call('GET', session.route);
      } on ApiException catch (error) {
        if (error.status == 410) await session.close();
      } catch (_) {
        // The short session deadline remains the fallback on transport loss.
      } finally {
        _checkingSignal = false;
      }
    }
    await refresh();
  }

  Future<void> _publish(bool foreground) {
    _presence = _presence.catchError((Object _) {}).then((_) async {
      await api.call('POST', '/devices/me/rtc-probes/presence', {
        'foreground': foreground,
      });
    });
    return _presence;
  }

  void update({
    required bool online,
    required bool foreground,
    required List<Map<String, dynamic>> devices,
  }) {
    final ids = devices
        .where((d) => d['online'] == true && d['rtc'] is Map)
        .map((d) => d['deviceId'] as String)
        .toSet();
    final peers = (ids.toList()..sort()).join(',');
    final changed =
        online != _online || foreground != _foreground || peers != _peers;
    _online = online;
    _foreground = foreground;
    _onlineIds = ids;
    _peers = peers;
    if (changed) {
      _epoch++;
      final session = _session;
      if (!active ||
          session != null &&
              !ids.contains(
                session.view[session.initiator
                    ? 'responderDeviceId'
                    : 'initiatorDeviceId'],
              )) {
        unawaited(_cancelSession());
      }
      results = results
          .where(
            (r) =>
                active &&
                ids.contains(
                  r['initiatorDeviceId'] == deviceId
                      ? r['responderDeviceId']
                      : r['initiatorDeviceId'],
                ),
          )
          .toList();
      onResults?.call(results);
      if (!active) {
        _attempted.clear();
        _published = null;
        if (online) unawaited(_publish(false).catchError((Object _) {}));
      }
    }
    if (active) {
      _timer ??= Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(refresh()),
      );
      if (changed) unawaited(refresh());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _cancelSession() async {
    final session = _session;
    if (session == null) return;
    await session.close();
    try {
      await api.call('DELETE', session.route);
    } catch (_) {}
  }

  Future<void> invalidate() async {
    _epoch++;
    _attempted.clear();
    results = [];
    _published = null;
    onResults?.call(results);
    await _cancelSession();
    if (_online) await _publish(false);
    if (active) await refresh();
  }

  Future<void> refresh() async {
    if (!active) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final epoch = _epoch;
    try {
      if (_published == null ||
          clock().difference(_published!) >= const Duration(seconds: 20)) {
        await _publish(true);
        if (!active || epoch != _epoch) return;
        _published = clock();
      }
      final snapshot = await api.call('GET', '/devices/me/rtc-probes');
      if (!active || epoch != _epoch) return;
      results = List<Map<String, dynamic>>.from(snapshot['results']);
      onResults?.call(results);
      final probes = List<Map<String, dynamic>>.from(snapshot['probes']);
      final eligible = (snapshot['peers'] as List)
          .map((p) => p['deviceId'] as String)
          .toSet();
      for (final id in {..._eligiblePeers, ...eligible}) {
        if (_eligiblePeers.contains(id) != eligible.contains(id)) {
          _attempted.removeWhere((key, _) => key.startsWith('$id/'));
        }
      }
      _eligiblePeers = eligible;
      Map<String, dynamic>? view = probes
          .where((p) => p['responderDeviceId'] == deviceId)
          .firstOrNull;
      if (view == null && probes.isEmpty) {
        final peers = List<Map<String, dynamic>>.from(snapshot['peers'])
          ..sort((a, b) => (a['deviceId'] as String).compareTo(b['deviceId']));
        for (final peer in peers) {
          final id = peer['deviceId'] as String;
          if (deviceId.compareTo(id) >= 0 || !_onlineIds.contains(id)) continue;
          for (final scope in ['lan', 'public']) {
            if (!(peer['scopes'] as List).contains(scope)) continue;
            final key = '$id/$scope', previous = _attempted['$id/$scope'];
            final recent = results.any(
              (r) =>
                  r['scope'] == scope &&
                  (r['initiatorDeviceId'] == id ||
                      r['responderDeviceId'] == id) &&
                  DateTime.parse(r['expiresAt']).isAfter(clock()),
            );
            if (recent ||
                previous != null &&
                    clock().difference(previous) < const Duration(minutes: 2)) {
              continue;
            }
            _attempted[key] = clock();
            view = Map<String, dynamic>.from(
              (await api.call('POST', '/devices/$id/rtc-probes', {
                'attemptId': _nonce(),
                'scope': scope,
              }))['probe'],
            );
            break;
          }
          if (view != null) break;
        }
      }
      if (view != null) {
        if (!active || epoch != _epoch) {
          await api.call('DELETE', '/rtc-probes/${view['attemptId']}');
          return;
        }
        final session = RtcProbeSession(
          api,
          deviceId,
          view,
          connectionFactory: connectionFactory,
          initialize: initialize,
        );
        _session = session;
        try {
          await session.run();
        } catch (_) {
        } finally {
          await session.close();
          if (identical(_session, session)) _session = null;
        }
        _again = true;
      }
    } catch (_) {
      // Discovery probes never interrupt actual file transfers or force relay.
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        if (active) unawaited(refresh());
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    results = [];
    onResults?.call(results);
    await _cancelSession();
    if (_online) {
      try {
        await _publish(false);
      } catch (_) {}
    }
  }
}
