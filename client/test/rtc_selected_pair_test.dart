import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/rtc_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const rows = <Map<String, dynamic>>[
    {
      'id': 'transport',
      'type': 'transport',
      'selectedCandidatePairId': 'chosen',
    },
    {
      'id': 'old',
      'type': 'candidate-pair',
      'localCandidateId': 'wrong',
      'remoteCandidateId': 'wrong',
      'nominated': true,
      'state': 'succeeded',
    },
    {
      'id': 'chosen',
      'type': 'candidate-pair',
      'localCandidateId': 'local',
      'remoteCandidateId': 'remote',
    },
    {
      'id': 'local',
      'type': 'local-candidate',
      'address': '2001:db8::2',
      'port': 51344,
    },
    {
      'id': 'remote',
      'type': 'remote-candidate',
      'ip': '10.0.0.2',
      'port': 62000,
    },
    {
      'id': 'wrong',
      'type': 'local-candidate',
      'address': '192.0.2.7',
      'port': 1,
    },
  ];

  test('transport selected pair wins over earlier nominated candidate and formats IPv6', () {
    final pair = rtcSelectedPairFromStats(rows)!;
    expect(pair.localAddress, '[2001:db8::2]:51344');
    expect(pair.remoteAddress, '10.0.0.2:62000');
    expect(
      rtcSelectedPairFromStats(
        rows
            .map((r) => r['id'] == 'local' ? {...r, 'port': 51344.0} : r)
            .toList(),
      )!.localAddress,
      '[2001:db8::2]:51344',
    );
  });

  test('only a uniquely selected or succeeded nominated pair can be used', () {
    final withoutTransport = rows
        .where((r) => r['type'] != 'transport' && r['id'] != 'old')
        .toList();
    expect(rtcSelectedPairFromStats(withoutTransport), isNull);
    final selected = withoutTransport
        .map((r) => r['id'] == 'chosen' ? {...r, 'selected': true} : r)
        .toList();
    expect(
      rtcSelectedPairFromStats(selected)!.localAddress,
      '[2001:db8::2]:51344',
    );
    final nominated = withoutTransport
        .map(
          (r) => r['id'] == 'chosen'
              ? {...r, 'nominated': true, 'state': 'succeeded'}
              : r,
        )
        .toList();
    expect(
      rtcSelectedPairFromStats(nominated)!.remoteAddress,
      '10.0.0.2:62000',
    );
    expect(
      rtcSelectedPairFromStats([
        ...nominated,
        {
          'id': 'other',
          'type': 'candidate-pair',
          'nominated': true,
          'state': 'succeeded',
        },
      ]),
      isNull,
    );
  });

  test('missing endpoint fields remain unknown rather than borrowing another candidate', () {
    final partial = rows
        .map(
          (r) => r['id'] == 'remote'
              ? {...r, 'ip': null}
              : r['id'] == 'local'
              ? {...r, 'port': null}
              : r,
        )
        .toList();
    final pair = rtcSelectedPairFromStats(partial)!;
    expect(pair.localAddress, '2001:db8::2');
    expect(pair.remoteAddress, isEmpty);
    expect(
      rtcSelectedPairFromStats(
        rows
            .where(
              (r) =>
                  r['type'] != 'local-candidate' &&
                  r['type'] != 'remote-candidate',
            )
            .toList(),
      ),
      isNull,
    );
  });

  test('Android stats bridge returns the native selected pair without SDP guessing', () async {
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AndroidRtcConnection.channel, (
      MethodCall call,
    ) async {
      calls.add(call.method);
      return call.method == 'stats' ? rows : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        AndroidRtcConnection.channel,
        null,
      ),
    );
    final connection = await AndroidRtcConnection.create(
      scope: 'lan',
      allowCellular: false,
      iceServers: const [],
    );
    final pair = await connection.selectedCandidatePair();
    expect(pair!.localAddress, '[2001:db8::2]:51344');
    expect(pair.remoteAddress, '10.0.0.2:62000');
    await connection.close();
    expect(calls, ['create', 'stats', 'close']);
  });
}
