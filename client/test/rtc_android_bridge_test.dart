import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/rtc_connection.dart';
import 'package:globalsend/rtc_transport.dart';

import 'saved_files_test.dart' show fixtureDirectory;

Future<void> event(String sessionId, Map<String, Object> values) async {
  final done = Completer<void>();
  ServicesBinding.instance.channelBuffers.push(
    AndroidRtcConnection.channel.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('event', {'sessionId': sessionId, ...values}),
    ),
    (_) => done.complete(),
  );
  await done.future;
}

class FixtureCenter extends CenterApi {
  FixtureCenter() : super('https://fixture.invalid', token: 'center-token');
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async => method == 'GET'
      ? {
          'rtc': {
            'state': 'negotiating',
            'offer': null,
            'candidates': {'source': [], 'target': []},
          },
        }
      : {};
}

class CellularFixtureTransport extends RtcFileTransport {
  CellularFixtureTransport(
    super.api, {
    super.cellularAllowed,
    super.connectionFactory,
  });
  @override
  bool get cellularCapable => true;
}

class PendingPeer implements RtcDataConnection {
  final release = Completer<void>();
  int closes = 0;
  Future<void>? _closing;
  @override
  Future<void> close() => _closing ??= () {
    closes++;
    return release.future;
  }();
  @override
  set onIceCandidate(void Function(RTCIceCandidate)? value) {}
  @override
  set onConnectionState(void Function(RTCPeerConnectionState)? value) {}
  @override
  set onDataChannel(void Function(RtcDataChannel)? value) {}
  @override
  set onNetwork(void Function(String, String)? value) {}
  @override
  Future<void> authorizeData() async {}
  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {}
  @override
  Future<RtcDataChannel> createDataChannel(String label) =>
      throw UnimplementedError();
  @override
  Future<RTCSessionDescription> createOffer(Map<String, dynamic> constraints) =>
      throw UnimplementedError();
  @override
  Future<RTCSessionDescription> createAnswer(
    Map<String, dynamic> constraints,
  ) => throw UnimplementedError();
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  test(
    'probe purpose clamps cellular and external ICE before reaching Android',
    () async {
      MethodCall? created;
      messenger.setMockMethodCallHandler(AndroidRtcConnection.channel, (
        call,
      ) async {
        if (call.method == 'create') created = call;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          AndroidRtcConnection.channel,
          null,
        ),
      );
      final pc = await AndroidRtcConnection.create(
        scope: 'public',
        allowCellular: true,
        iceServers: [
          {'urls': 'stun:unused.invalid'},
        ],
        probe: true,
      );
      expect(created!.arguments['probe'], true);
      expect(created!.arguments['allowCellular'], false);
      expect(created!.arguments['iceServers'], isEmpty);
      await pc.close();
    },
  );
  test(
    'cellular factory policy is public, Android and explicit-permission only',
    () {
      expect(
        rtcCellularPolicy(android: true, scope: 'lan', permission: true),
        isFalse,
      );
      expect(
        rtcCellularPolicy(android: true, scope: 'public', permission: false),
        isFalse,
      );
      expect(
        rtcCellularPolicy(android: true, scope: 'public', permission: true),
        isTrue,
      );
      expect(
        rtcCellularPolicy(android: false, scope: 'public', permission: true),
        isFalse,
      );
    },
  );

  test('Android adapter uses scoped policies, native data authorization and buffered bytes without credentials', () async {
    final calls = <MethodCall>[];
    var authorized = false;
    messenger.setMockMethodCallHandler(AndroidRtcConnection.channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'createChannel':
          return 'open';
        case 'bufferedAmount':
          return 262144;
        case 'authorize':
          if (!authorized) {
            throw PlatformException(
              code: 'RTC_FAILED',
              message: 'Selected network unknown',
            );
          }
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        AndroidRtcConnection.channel,
        null,
      ),
    );
    final lan = await AndroidRtcConnection.create(
      scope: 'lan',
      allowCellular: true,
      iceServers: [],
    );
    final public = await AndroidRtcConnection.create(
      scope: 'public',
      allowCellular: true,
      iceServers: [],
    );
    try {
      final creates = calls.where((call) => call.method == 'create').toList();
      expect(creates[0].arguments['allowCellular'], false);
      expect(creates[1].arguments['allowCellular'], true);
      final networks = <String>[];
      public.onNetwork = (network, family) => networks.add('$network/$family');
      await event(public.sessionId, {
        'type': 'network',
        'network': 'cellular',
        'family': 'ipv6',
      });
      expect(networks, ['cellular/ipv6']);
      final data = await public.createDataChannel(rtcFileChannel);
      await expectLater(
        public.authorizeData(),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.where((call) => call.method == 'send'), isEmpty);
      authorized = true;
      await public.authorizeData();
      expect(await data.getBufferedAmount(), 262144);
      await data.send(
        RTCDataChannelMessage.fromBinary(Uint8List.fromList([1, 2, 3])),
      );
      final sent = calls.last.arguments as Map;
      expect(sent['data'], [1, 2, 3]);
      expect(sent['binary'], true);
      for (final call in calls) {
        expect((call.arguments as Map).containsKey('authorization'), false);
        expect((call.arguments as Map).containsKey('token'), false);
      }
    } finally {
      await lan.close();
      await public.close();
    }
  });

  test('native close is awaited once and late events cannot reach a closed or other session', () async {
    final released = Completer<void>();
    var closes = 0, oldMessages = 0, liveMessages = 0;
    String oldId = '';
    messenger.setMockMethodCallHandler(AndroidRtcConnection.channel, (
      call,
    ) async {
      if (call.method == 'createChannel') return 'open';
      if (call.method == 'close' && call.arguments['sessionId'] == oldId) {
        closes++;
        await released.future;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        AndroidRtcConnection.channel,
        null,
      ),
    );
    final old = await AndroidRtcConnection.create(
      scope: 'public',
      allowCellular: true,
      iceServers: [],
    );
    final live = await AndroidRtcConnection.create(
      scope: 'lan',
      allowCellular: false,
      iceServers: [],
    );
    oldId = old.sessionId;
    (await old.createDataChannel(rtcFileChannel)).onMessage = (_) =>
        oldMessages++;
    (await live.createDataChannel(rtcFileChannel)).onMessage = (_) =>
        liveMessages++;
    var completed = false;
    final closing = old.close().then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, false);
    await event(oldId, {'type': 'message', 'binary': false, 'data': 'late'});
    await event(live.sessionId, {
      'type': 'message',
      'binary': false,
      'data': 'live',
    });
    expect(oldMessages, 0);
    expect(liveMessages, 1);
    released.complete();
    await closing;
    await old.close();
    expect(closes, 1);
    await live.close();
  });

  test('cancel waits for an in-flight native create and its close before returning', () async {
    final folder = await fixtureDirectory();
    messenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (_) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        null,
      ),
    );
    final started = Completer<void>(),
        creation = Completer<RtcDataConnection>();
    final peer = PendingPeer();
    final api = FixtureCenter();
    final transport = RtcFileTransport(
      api,
      connectionFactory:
          ({required scope, required allowCellular, required iceServers}) {
            started.complete();
            return creation.future;
          },
    );
    final source = await File('${folder.path}/source').writeAsBytes([1, 2, 3]);
    final sending = transport
        .send(
          fileRoute: '/transfers/t/files/f',
          attempt: {'attemptId': 'one', 'scope': 'public', 'offset': 0},
          source: source,
          size: 3,
          onProgress: (_) {},
        )
        .then<Object?>((_) => null, onError: (Object error) => error);
    await started.future;
    var done = false;
    final canceled = transport.cancelFile('f').then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, false);
    creation.complete(peer);
    await Future<void>.delayed(Duration.zero);
    expect(done, false);
    peer.release.complete();
    await canceled;
    expect(await sending, isA<StateError>());
    expect(peer.closes, 1);
    await transport.close();
    api.close();
    expect(await source.readAsBytes(), [1, 2, 3]);
  });

  test(
    'replacement retains a closing cellular owner in the revoke barrier',
    () async {
      final folder = await fixtureDirectory();
      messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (_) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Method'),
          null,
        ),
      );
      final firstCreated = Completer<void>(), nextCreated = Completer<void>();
      final first = PendingPeer(), next = PendingPeer();
      var allowed = true;
      final policies = <bool>[];
      final api = FixtureCenter();
      final transport = CellularFixtureTransport(
        api,
        cellularAllowed: () => allowed,
        connectionFactory:
            ({
              required scope,
              required allowCellular,
              required iceServers,
            }) async {
              policies.add(allowCellular);
              if (policies.length == 1) {
                firstCreated.complete();
                return first;
              }
              nextCreated.complete();
              return next;
            },
      );
      final source = await File('${folder.path}/source')
          .writeAsBytes([1, 2, 3]);
      Future<Object?> send(String attempt) => transport
          .send(
            fileRoute: '/transfers/t/files/f',
            attempt: {'attemptId': attempt, 'scope': 'public', 'offset': 0},
            source: source,
            size: 3,
            onProgress: (_) {},
          )
          .then<Object?>((_) => null, onError: (Object error) => error);
      final oldSend = send('old');
      await firstCreated.future;
      final replacement = send('replacement');
      for (var i = 0; i < 100 && first.closes == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(first.closes, 1);
      allowed = false;
      var revoked = false;
      final revocation = transport.revokeCellular().then((_) => revoked = true);
      await Future<void>.delayed(Duration.zero);
      expect(revoked, false);
      first.release.complete();
      await revocation;
      await nextCreated.future;
      expect(policies, [true, false]);
      expect(next.closes, 0);
      next.release.complete();
      await transport.close();
      expect(await oldSend, isA<StateError>());
      expect(await replacement, isA<StateError>());
      api.close();
    },
  );

  test('Windows real plugin wrapper cancels an in-flight create with one ordered native teardown', () async {
    final folder = await fixtureDirectory();
    const method = MethodChannel('FlutterWebRTC.Method');
    const events = MethodChannel('FlutterWebRTC/peerConnectionEventfixture');
    final creating = Completer<Map<String, Object>>(),
        creationStarted = Completer<void>();
    final closeNative = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(events, (call) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(method, (call) async {
      if (call.method == 'createPeerConnection') {
        creationStarted.complete();
        return creating.future;
      }
      if (call.method == 'peerConnectionClose') {
        calls.add(call.method);
        await closeNative.future;
      }
      if (call.method == 'peerConnectionDispose') calls.add(call.method);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(method, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    final api = FixtureCenter(), transport = RtcFileTransport(FixtureCenter());
    final source = await File('${folder.path}/source').writeAsBytes([1]);
    final sending = transport
        .send(
          fileRoute: '/transfers/t/files/f',
          attempt: {'attemptId': 'one', 'scope': 'lan', 'offset': 0},
          source: source,
          size: 1,
          onProgress: (_) {},
        )
        .then<Object?>((_) => null, onError: (Object error) => error);
    await creationStarted.future;
    var done = false;
    final canceled = transport.cancelFile('f').then((_) => done = true);
    creating.complete({'peerConnectionId': 'fixture'});
    for (var i = 0; i < 100 && !calls.contains('peerConnectionClose'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(done, false);
    closeNative.complete();
    await canceled;
    expect(await sending, isA<StateError>());
    expect(calls, [
      'listen',
      'cancel',
      'peerConnectionDispose',
      'peerConnectionClose',
    ]);
    await transport.close();
    api.close();
    transport.api.close();
  });
}
