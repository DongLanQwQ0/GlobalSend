import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/reachability.dart';
import 'package:globalsend/rtc_connection.dart';
import 'package:globalsend/rtc_probe.dart';

const dataSdp = 'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n';

class ProbeApi extends CenterApi {
  ProbeApi() : super('https://fixture.invalid');
  final calls = <String>[];
  final results = <Map<String, dynamic>>[];
  final probes = <Map<String, dynamic>>[];
  String peer = 'b';
  Map<String, dynamic> view(String id, String scope) => {
    'attemptId': id,
    'initiatorDeviceId': 'a',
    'responderDeviceId': 'b',
    'scope': scope,
    'offer': null,
    'answer': {'type': 'answer', 'sdp': dataSdp},
    'candidates': {'initiator': [], 'responder': []},
  };
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    expect(path.contains('transfer'), false);
    final value = body is Map ? body : const {};
    if (path == '/devices/me/rtc-probes/presence') return {};
    if (path == '/devices/me/rtc-probes') {
      return {
        'peers': [
          {
            'deviceId': peer,
            'scopes': ['lan', 'public'],
          },
        ],
        'probes': List.of(probes),
        'results': List.of(results),
      };
    }
    if (path.startsWith('/devices/') && path.endsWith('/rtc-probes')) {
      final probe = view(value['attemptId'], value['scope']);
      probes.add(probe);
      return {'probe': probe};
    }
    final id = path.split('/')[2];
    final probe = probes.where((p) => p['attemptId'] == id).firstOrNull;
    if (method == 'GET') {
      if (probe == null) throw ApiException(410, 'Ended');
      return {'probe': probe};
    }
    if (path.endsWith('/complete') || path.endsWith('/fail')) {
      final result = {
        ...probe!,
        'success': path.endsWith('/complete'),
        'elapsedMs': value['elapsedMs'],
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'expiresAt': DateTime.now()
            .add(const Duration(minutes: 2))
            .toUtc()
            .toIso8601String(),
      };
      results.add(result);
      probes.remove(probe);
      return {'result': result};
    }
    if (method == 'DELETE') probes.remove(probe);
    return {};
  }
}

class EchoChannel implements RtcDataChannel {
  EchoChannel(this.owner);
  final ProbeConnection owner;
  int closes = 0;
  void Function(RTCDataChannelMessage)? message;
  @override
  String get label => rtcProbeChannel;
  @override
  RTCDataChannelState get state => RTCDataChannelState.RTCDataChannelOpen;
  @override
  set onDataChannelState(void Function(RTCDataChannelState)? value) {}
  @override
  set onMessage(void Function(RTCDataChannelMessage)? value) => message = value;
  @override
  Future<int> getBufferedAmount() async => 0;
  @override
  Future<void> send(RTCDataChannelMessage value) async {
    expect(owner.authorizations, greaterThan(0));
    final sent = jsonDecode(value.text) as Map;
    expect(sent['type'], 'ping');
    message?.call(
      RTCDataChannelMessage(
        jsonEncode({'type': 'echo', 'nonce': sent['nonce']}),
      ),
    );
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

class ProbeConnection implements RtcDataConnection {
  ProbeConnection({this.failOffer = false}) {
    channel = EchoChannel(this);
  }
  final bool failOffer;
  late EchoChannel channel;
  int closes = 0, authorizations = 0;
  @override
  set onIceCandidate(void Function(RTCIceCandidate)? value) {}
  @override
  set onConnectionState(void Function(RTCPeerConnectionState)? value) {}
  @override
  set onDataChannel(void Function(RtcDataChannel)? value) {}
  @override
  set onNetwork(void Function(String, String)? value) {}
  @override
  Future<RTCSessionDescription> createOffer(
    Map<String, dynamic> constraints,
  ) async {
    expect(constraints['mandatory']['OfferToReceiveAudio'], false);
    if (failOffer) throw StateError('LAN unreachable');
    return RTCSessionDescription(dataSdp, 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer(
    Map<String, dynamic> constraints,
  ) async => RTCSessionDescription(dataSdp, 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}
  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {}
  @override
  Future<RtcDataChannel> createDataChannel(String label) async {
    expect(label, rtcProbeChannel);
    return channel;
  }

  @override
  Future<void> authorizeData() async {
    authorizations++;
  }

  @override
  Future<void> close() async {
    closes++;
  }
}

Future<void> eventually(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) throw StateError('Condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
    'nonce/echo authorizes before payload and closes without any file request',
    () async {
      final api = ProbeApi(), pc = ProbeConnection();
      final view = api.view('nonce-probe', 'lan');
      api.probes.add(view);
      final session = RtcProbeSession(
        api,
        'a',
        view,
        initialize: () async {},
        addresses: () async => [InternetAddress('192.168.1.2')],
        connectionFactory:
            ({
              required scope,
              required allowCellular,
              required iceServers,
            }) async {
              expect(allowCellular, false);
              expect(iceServers, isEmpty);
              return pc;
            },
      );
      await session.run();
      await session.close();
      expect(api.results.single['success'], true);
      expect(api.probes, isEmpty);
      expect(pc.closes, 1);
      expect(pc.channel.closes, 1);
    },
  );

  test('cancel during native creation awaits and closes the eventual owner exactly once', () async {
    final api = ProbeApi(), pc = ProbeConnection();
    final pending = Completer<RtcDataConnection>(), started = Completer<void>();
    final view = api.view('late-create', 'public');
    api.probes.add(view);
    final session = RtcProbeSession(
      api,
      'a',
      view,
      initialize: () async {},
      addresses: () async => [],
      connectionFactory:
          ({required scope, required allowCellular, required iceServers}) {
            expect(allowCellular, false);
            started.complete();
            return pending.future;
          },
    );
    final run = session.run();
    final failed = expectLater(run, throwsStateError);
    await started.future;
    var closed = false;
    final close = session.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, false);
    pending.complete(pc);
    await close;
    await failed;
    expect(pc.closes, 1);
    expect(pc.authorizations, 0);
    expect(api.calls.any((c) => c.endsWith('/fail')), false);
  });

  test('foreground monitor runs LAN before public, one owner, two-minute cadence, hide clears results', () async {
    final api = ProbeApi(), scopes = <String>[];
    var now = DateTime.now(), owners = 0, maxOwners = 0;
    final pcs = <ProbeConnection>[];
    final monitor = RtcProbeMonitor(
      api,
      'a',
      clock: () => now,
      initialize: () async {},
      connectionFactory:
          ({
            required scope,
            required allowCellular,
            required iceServers,
          }) async {
            scopes.add(scope);
            expect(allowCellular, false);
            expect(iceServers, isEmpty);
            owners++;
            if (owners > maxOwners) maxOwners = owners;
            final pc = _CountedConnection(scope == 'lan', () => owners--);
            pcs.add(pc);
            return pc;
          },
    );
    addTearDown(monitor.close);
    final devices = [
      {
        'deviceId': 'b',
        'online': true,
        'rtc': {
          'scopes': ['lan', 'public'],
        },
      },
    ];
    monitor.update(online: true, foreground: true, devices: devices);
    await eventually(
      () => api.results.length == 2 && !monitor.hasActiveSession,
    );
    await monitor.refresh();
    expect(scopes, ['lan', 'public']);
    expect(maxOwners, 1);
    expect(api.results.map((r) => r['success']), [false, true]);
    await monitor.refresh();
    expect(scopes.length, 2);
    now = now.add(const Duration(minutes: 3));
    api.results.clear();
    await monitor.refresh();
    await eventually(() => scopes.length == 4 && !monitor.hasActiveSession);
    monitor.update(online: true, foreground: false, devices: devices);
    expect(monitor.results, isEmpty);
    expect(monitor.active, false);
    await monitor.close();
    expect(pcs.every((pc) => pc.closes == 1), true);
  });

  test('larger device ID does not create duplicate probes', () async {
    final api = ProbeApi()..peer = 'a';
    final monitor = RtcProbeMonitor(api, 'z', initialize: () async {});
    monitor.update(
      online: true,
      foreground: true,
      devices: [
        {'deviceId': 'a', 'online': true, 'rtc': {}},
      ],
    );
    await monitor.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.probes, isEmpty);
    await monitor.close();
  });

  test('hiding the monitor closes an in-flight creation and never records a failure or continues public', () async {
    final api = ProbeApi(),
        pending = Completer<RtcDataConnection>(),
        started = Completer<void>();
    final pc = ProbeConnection();
    var created = 0;
    final monitor = RtcProbeMonitor(
      api,
      'a',
      initialize: () async {},
      connectionFactory:
          ({required scope, required allowCellular, required iceServers}) {
            created++;
            started.complete();
            return pending.future;
          },
    );
    final devices = [
      {'deviceId': 'b', 'online': true, 'rtc': {}},
    ];
    monitor.update(online: true, foreground: true, devices: devices);
    await started.future;
    monitor.update(online: true, foreground: false, devices: devices);
    expect(monitor.results, isEmpty);
    var closed = false;
    final close = monitor.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, false);
    pending.complete(pc);
    await close;
    await eventually(() => !monitor.hasActiveSession);
    expect(pc.closes, 1);
    expect(created, 1);
    expect(api.results, isEmpty);
    expect(api.calls.any((c) => c.endsWith('/fail')), false);
  });

  test('RTC results rank only within the requested scope and expire without blocking HTTPS', () {
    var now = DateTime.now();
    final monitor = ReachabilityMonitor(clock: () => now)
      ..devices = [
        {'deviceId': 'b', 'online': true},
      ];
    addTearDown(monitor.dispose);
    monitor.setRtcResults('a', [
      {
        'initiatorDeviceId': 'a',
        'responderDeviceId': 'b',
        'scope': 'public',
        'success': true,
        'checkedAt': now.toIso8601String(),
        'expiresAt': now.add(const Duration(minutes: 2)).toIso8601String(),
        'elapsedMs': 21,
      },
    ]);
    expect(monitor.preferRtc('b', ReachabilityScope.lan), false);
    expect(monitor.preferRtc('b', ReachabilityScope.public), true);
    expect(
      monitor.prioritize('b', ['unknown-https'], ReachabilityScope.public),
      ['unknown-https'],
    );
    now = now.add(const Duration(minutes: 2));
    expect(monitor.preferRtc('b', ReachabilityScope.public), false);
  });
}

class _CountedConnection extends ProbeConnection {
  _CountedConnection(bool failOffer, this.done) : super(failOffer: failOffer);
  final void Function() done;
  @override
  Future<void> close() async {
    await super.close();
    done();
  }
}
