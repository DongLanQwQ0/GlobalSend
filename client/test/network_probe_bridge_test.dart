import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/network_bridge.dart';
import 'package:globalsend/network_proxy.dart';
import 'package:globalsend/reachability.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => NetworkProxy.bypassSystemProxy = true);
  test(
    'canceling a cellular probe releases the same native operation immediately',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final response = Completer<Map<String, dynamic>>(),
          started = Completer<void>();
      String? probing, canceled;
      messenger.setMockMethodCallHandler(NetworkBridge.channel, (call) async {
        if (call.method == 'probePeer') {
          probing = call.arguments['operationId'];
          started.complete();
          return response.future;
        }
        if (call.method == 'cancelOperation') {
          canceled = call.arguments['operationId'];
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(NetworkBridge.channel, null),
      );
      final stop = ProbeCancellation();
      final probingResult = probePeerAddress(
        'https://[2001:db8::2]:9443',
        'pin',
        true,
        cancellation: stop,
      );
      await started.future;
      await stop.cancel();
      expect(canceled, probing);
      expect(canceled, isNotEmpty);
      response.complete({'reachable': false, 'error': 'canceled'});
      expect((await probingResult).reachable, false);
    },
  );
  test(
    'peer probe passes exact candidate and network without a file ticket',
    () async {
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NetworkBridge.channel, (call) async {
            received = call;
            return {
              'reachable': false,
              'elapsedMs': 12,
              'network': 'cellular',
              'error': 'No route to host',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NetworkBridge.channel, null),
      );
      final result = await NetworkBridge.probePeer(
        candidate: 'https://[2001:db8::2]:9443',
        fingerprint: 'pin',
        nonce: 'nonce',
        cellular: true,
      );
      expect(received!.method, 'probePeer');
      expect(received!.arguments, {
        'bypassSystemProxy': true,
        'candidate': 'https://[2001:db8::2]:9443',
        'fingerprint': 'pin',
        'nonce': 'nonce',
        'cellular': true,
      });
      expect(result['reachable'], isFalse);
      expect(result['error'], 'No route to host');
    },
  );
  test(
    'native requests carry the current proxy preference, including opt-out',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NetworkBridge.channel, (call) async {
        calls.add(call);
        return <String, dynamic>{};
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(NetworkBridge.channel, null),
      );
      for (final bypass in [true, false]) {
        NetworkProxy.bypassSystemProxy = bypass;
        await NetworkBridge.putFile(
          'https://center.example/upload',
          'file',
          cellular: true,
          authorization: 'ticket',
          offset: 0,
          length: 1,
        );
        await NetworkBridge.probePeer(
          candidate: 'https://peer.example',
          fingerprint: 'pin',
          nonce: 'n',
          cellular: true,
        );
        expect(
          calls
              .skip(calls.length - 2)
              .map((call) => call.arguments['bypassSystemProxy']),
          [bypass, bypass],
        );
      }
    },
  );
  test('cellular push carries a scoped ticket and routes progress only while its operation is active', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var progress = 0;
    Future<void> report(int bytes) async {
      final delivered = Completer<void>();
      ServicesBinding.instance.channelBuffers.push(
        NetworkBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('progress', {'operationId': 'push-op', 'bytes': bytes}),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
    }

    messenger.setMockMethodCallHandler(NetworkBridge.channel, (call) async {
      expect(call.method, 'uploadPeer');
      final args = Map<String, dynamic>.from(call.arguments);
      expect(args['cellular'], true);
      expect(args['ticket'], 'scoped-peer-ticket');
      expect(args['attemptId'], 'attempt');
      expect(args['offset'], 2);
      expect(args.containsKey('authorization'), false);
      await report(4);
      return {'bytes': 4, 'network': 'cellular'};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NetworkBridge.channel, null),
    );
    await NetworkBridge.uploadPeer(
      candidates: ['https://[2001:db8::2]:9443'],
      fingerprint: 'pin',
      ticket: 'scoped-peer-ticket',
      transferId: 'transfer',
      fileId: 'file',
      attemptId: 'attempt',
      path: '/proc/self/fd/42',
      offset: 2,
      expectedSize: 4,
      operationId: 'push-op',
      nonce: 'nonce',
      onProgress: (value) => progress = value,
    );
    expect(progress, 4);
    await report(9);
    expect(progress, 4);
  });

  test('verified cellular download passes its selected endpoint without changing legacy calls', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <Map<String, dynamic>>[];
    messenger.setMockMethodCallHandler(NetworkBridge.channel, (call) async {
      expect(call.method, 'downloadPeer');
      calls.add(Map<String, dynamic>.from(call.arguments));
      return {'bytes': 4};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NetworkBridge.channel, null),
    );
    const endpoint = 'https://[240e::2]:9443';
    Future<void> download(String? verified) => NetworkBridge.downloadPeer(
      candidates: [endpoint],
      fingerprint: 'pin',
      ticket: 'ticket',
      transferId: 'transfer',
      fileId: 'file',
      path: 'file.part',
      operationId: 'download',
      expectedSize: 4,
      expectedSha256: 'hash',
      nonce: 'nonce',
      onProgress: (_) {},
      verifiedCandidate: verified,
    );
    await download(endpoint);
    await download(null);
    expect(calls[0]['verifiedCandidate'], endpoint);
    expect(calls[0]['cellular'], true);
    expect(calls[0]['ticket'], 'ticket');
    expect(calls[1].containsKey('verifiedCandidate'), false);
  });
}
