import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/clipboard_suggestions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
}
