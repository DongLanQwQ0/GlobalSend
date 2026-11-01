import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/clipboard_suggestions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('clipboard metadata without a timestamp can sort among media recommendations', () async {
    final suggestions = ClipboardSuggestions(
      read: () async => {
        'available': true,
        'revision': 'ipad-copy',
        'kind': 'text',
      },
      acknowledge: (_) async {},
    );
    addTearDown(suggestions.dispose);
    await suggestions.refresh();
    expect(suggestions.item!.suggestedAt, greaterThan(0));
  });
  test('a revision keeps its first observation time while new copies and native times can reorder', () async {
    var time = DateTime.fromMillisecondsSinceEpoch(10000);
    var status = <String, dynamic>{
      'available': true,
      'revision': 'one',
      'kind': 'text',
    };
    final suggestions = ClipboardSuggestions(
      read: () async => status,
      acknowledge: (_) async {},
      now: () => time,
    );
    addTearDown(suggestions.dispose);
    await suggestions.refresh();
    expect(suggestions.item!.suggestedAt, 10000);
    time = DateTime.fromMillisecondsSinceEpoch(30000);
    await suggestions.refresh();
    expect(suggestions.item!.suggestedAt, 10000);
    final olderClipboard = suggestions.item!;
    status = {'available': true, 'revision': 'two', 'kind': 'image'};
    await suggestions.refresh();
    final mixed = [
      ('media-between-copies', 20000),
      ('older-clipboard', olderClipboard.suggestedAt),
      ('new-clipboard', suggestions.item!.suggestedAt),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    expect(mixed.map((item) => item.$1), [
      'new-clipboard',
      'media-between-copies',
      'older-clipboard',
    ]);
    status = {...status, 'suggestedAt': 25000};
    await suggestions.refresh();
    expect(suggestions.item!.suggestedAt, 25000);
    time = DateTime.fromMillisecondsSinceEpoch(40000);
    await suggestions.refresh();
    expect(suggestions.item!.suggestedAt, 25000);
  });
  test('suggestion metadata follows revision and explicit dismissal, not content reads', () async {
    var status = <String, dynamic>{
      'available': true,
      'revision': '1',
      'kind': 'image',
    };
    final acknowledged = <String>[];
    final suggestions = ClipboardSuggestions(
      read: () async => status,
      acknowledge: (revision) async => acknowledged.add(revision),
    );
    addTearDown(suggestions.dispose);
    await suggestions.refresh();
    expect(suggestions.item!.label, '图片');
    await suggestions.dismiss();
    expect(acknowledged, ['1']);
    await suggestions.refresh();
    expect(suggestions.item, isNull);
    status = {'available': true, 'revision': '2', 'kind': 'files'};
    await suggestions.refresh();
    expect(suggestions.item!.label, '文件');
    status = {'available': false};
    await suggestions.refresh();
    expect(suggestions.item!.revision, '2');
    status = {'available': true, 'revision': '3', 'kind': 'empty'};
    await suggestions.refresh();
    expect(suggestions.item, isNull);
  });
  test(
    'confirming an earlier card does not hide a newer clipboard copy',
    () async {
      var revision = 'first';
      final acknowledged = <String>[];
      final suggestions = ClipboardSuggestions(
        read: () async => {
          'available': true,
          'revision': revision,
          'kind': 'text',
        },
        acknowledge: (value) async => acknowledged.add(value),
      );
      addTearDown(suggestions.dispose);
      await suggestions.refresh();
      final confirming = suggestions.item!.revision;
      revision = 'second';
      await suggestions.refresh();
      await suggestions.dismissRevision(confirming);
      expect(suggestions.item!.revision, 'second');
      await suggestions.refresh();
      expect(suggestions.item!.revision, 'second');
      expect(acknowledged, ['first']);
    },
  );
}
