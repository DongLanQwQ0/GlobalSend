import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/content_groups.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DockEntry text(
    String id,
    String value, {
    bool outgoing = false,
    int time = 1,
  }) => DockEntry(
    id: id,
    kind: 'text',
    title: '文本',
    source: 'sender',
    text: value,
    outgoing: outgoing,
    createdAtMillis: time,
  );
  test('identical cards group newest-first without deleting delivery records or external references', () {
    final entries = [
      text('a', 'same'),
      text('b', 'same', time: 2),
      text('c', 'different'),
      text('d', 'same', outgoing: true),
    ];
    final display = mergeContentCards(entries);
    expect(display.map((entry) => entry.id), ['b', 'c', 'd']);
    expect(entries.length, 4);
    final files = [
      for (final id in ['a', 'b'])
        DockEntry(
          id: id,
          kind: 'file',
          title: '$id.png',
          source: 'sender',
          localPath: 'external/$id',
          size: 5,
          contentDigest: 'digest',
          createdAtMillis: id == 'b' ? 2 : 1,
        ),
    ];
    expect(mergeContentCards(files).single.id, 'b');
    expect(files.first.localPath, 'external/a');
  });
  test('canonical updates change every delivery, ignore stale versions, and persist identity', () {
    final c = SendController();
    addTearDown(c.dispose);
    c.dock.addAll([text('a', 'old', outgoing: true), text('b', 'old')]);
    c.applyTextDocument({
      'sourceEventIds': ['a', 'b'],
      'contentId': 'shared',
      'revision': 3,
      'text': 'latest',
      'editedAt': 'now',
    });
    expect(c.dock.every((entry) => entry.text == 'latest'), isTrue);
    c.applyTextDocument({
      'sourceEventIds': ['a'],
      'contentId': 'shared',
      'revision': 2,
      'text': 'stale',
      'editedAt': 'then',
    });
    expect(c.dock.every((entry) => entry.text == 'latest'), isTrue);
    final restored = DockEntry.fromJson(c.dock.first.toJson());
    expect(restored.contentId, 'shared');
    expect(restored.contentRevision, 3);
  });
}
