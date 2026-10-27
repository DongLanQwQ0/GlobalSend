import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';

void main() {
  test(
    'normalization preserves prefix case and rejects credential-bearing URLs',
    () {
      expect(
        normalizeServer('https://EXAMPLE.com:8443/Base///'),
        'https://example.com:8443/Base',
      );
      expect(
        () => normalizeServer('http://localhost:8787'),
        throwsFormatException,
      );
      expect(
        normalizeServer('http://localhost:8787', allowHttp: true),
        'http://localhost:8787',
      );
      for (final bad in [
        'https://user:secret@example.com',
        'https://example.com?x=1',
        'https://example.com#x',
        'file:///tmp',
      ]) {
        expect(() => normalizeServer(bad), throwsFormatException);
      }
    },
  );
  test('server identities include base URL and instance', () {
    expect(
      profileKey('https://a/Base', 'one'),
      isNot(profileKey('https://b/Base', 'one')),
    );
    expect(
      profileKey('https://a/Base', 'one'),
      isNot(profileKey('https://a/Base', 'two')),
    );
  });
  test('safe names do not escape the receiving directory', () {
    expect(safeName('../../secret.txt'), 'secret.txt');
    expect(safeName(r'C:\folder\CON.txt'), 'file_CON.txt');
    expect(safeName('a<>b?.txt'), 'a__b_.txt');
  });
  test('candidate publication keeps public addresses alongside many LAN interfaces', () async {
    final local = List.generate(9, (index) => 'https://10.0.0.${index + 1}:8000');
    final candidates = PeerTransport.publicationCandidates([...local, 'https://203.0.113.20:8000', 'https://[2001:4860::1]:8000']);
    expect(candidates.length, 8);
    expect(candidates, contains('https://203.0.113.20:8000'));
    expect(candidates, contains('https://[2001:4860::1]:8000'));
    final stages = await PeerTransport.candidateStages(candidates);
    expect(stages.lan, contains(local.first));
    expect(stages.public, contains('https://203.0.113.20:8000'));
    expect(stages.public, isNot(contains(local.first)));
  });
}
