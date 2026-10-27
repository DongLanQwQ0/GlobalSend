import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/rtc_candidates.dart';

String candidate(String host, {String type = 'host'}) =>
    'candidate:1 1 udp 2122260223 $host 54321 typ $type';

void main() {
  final interfaces = [InternetAddress('2001:db8:1:2::99')];
  final lan = RtcCandidatePolicy('lan', interfaces);
  final public = RtcCandidatePolicy('public', interfaces);

  test('LAN stage accepts private, mDNS and same /64 IPv6 host candidates', () {
    for (final address in [
      '192.168.1.2',
      '10.0.0.2',
      '172.20.0.2',
      '100.70.2.1',
      'fd12::2',
      'fe80::2',
      'fec0::2',
      'feff::2',
      'device.local',
      '2001:db8:1:2::4',
    ]) {
      expect(lan.allows(candidate(address)), isTrue, reason: address);
    }
    expect(lan.allows(candidate('8.8.8.8')), isFalse);
    expect(lan.allows(candidate('2001:db8:1:3::4')), isFalse);
    expect(lan.allows(candidate('192.168.1.2', type: 'srflx')), isFalse);
  });

  test(
    'public stage keeps public IPv4/IPv6 and reflexive candidates, never TURN',
    () {
      for (final address in ['8.8.8.8', '2001:db8:1:3::4']) {
        expect(public.allows(candidate(address)), isTrue);
        expect(public.allows(candidate(address, type: 'srflx')), isTrue);
        expect(public.allows(candidate(address, type: 'relay')), isFalse);
      }
      for (final address in [
        '10.0.0.2',
        '172.16.0.1',
        '192.168.1.1',
        'fd12::2',
        'fe80::2',
        'fec0::2',
        'feff::2',
        'device.local',
        '127.0.0.1',
        '::1',
        '224.0.0.1',
      ]) {
        expect(public.allows(candidate(address)), isFalse, reason: address);
      }
    },
  );

  test('all embedded SDP candidates are removed so scoped trickle ICE owns routing', () {
    const sdp =
        'v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n'
        'a=ice-ufrag:abc\r\na=candidate:1 1 udp 1 8.8.8.8 1234 typ host\r\n'
        'a=end-of-candidates\r\na=fingerprint:sha-256 12:34\r\n';
    final stripped = RtcCandidatePolicy.withoutCandidates(sdp);
    expect(stripped.codeUnits.take(5), [118, 61, 48, 13, 10]);
    expect(stripped, isNot(contains('a=candidate:')));
    expect(stripped, isNot(contains('a=end-of-candidates')));
    expect(stripped, contains('a=ice-ufrag:abc'));
    expect(stripped, contains('a=fingerprint:sha-256 12:34'));
  });
}
