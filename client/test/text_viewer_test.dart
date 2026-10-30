import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/text_viewer.dart';
import 'package:globalsend/web_links.dart';

void main() {
  final folder = Directory('build/test-tmp/text-viewer');
  setUpAll(() => folder.createSync(recursive: true));

  Future<File> fixture(String name, List<int> bytes) async =>
      File('${folder.path}/$name').writeAsBytes(bytes);

  test(
    'UTF-8 text is complete and bounded previews do not replace cut characters',
    () async {
      final file = await fixture('中文.txt', utf8.encode('你好，世界🙂\n第二行'));
      final full = await readTextFilePreview(file.path);
      expect(full!.text, '你好，世界🙂\n第二行');
      expect(full.truncated, isFalse);
      final part = await readTextFilePreview(file.path, maxBytes: 5);
      expect(part!.text, '你');
      expect(part.truncated, isTrue);
      expect(part.totalBytes, await file.length());
      expect(part.text, isNot(contains('\uFFFD')));
    },
  );

  test('UTF-8 BOM and both UTF-16 BOM byte orders preserve text', () async {
    const value = '中文🙂\r\n文件内容';
    final utf8File = await fixture('bom.md', [
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(value),
    ]);
    expect((await readTextFilePreview(utf8File.path))!.text, value);
    for (final little in [true, false]) {
      final bytes = <int>[little ? 0xff : 0xfe, little ? 0xfe : 0xff];
      for (final unit in value.codeUnits) {
        bytes.addAll(
          little ? [unit & 0xff, unit >> 8] : [unit >> 8, unit & 0xff],
        );
      }
      final file = await fixture('utf16-$little.txt', bytes);
      expect((await readTextFilePreview(file.path))!.text, value);
    }
  });

  test('invalid UTF-8 and binary content remain external instead of displaying replacement text', () async {
    final invalid = await fixture('invalid.txt', [0xff, 0x61, 0x62]);
    final binary = await fixture('binary.txt', [0x61, 0, 0x62]);
    expect(await readTextFilePreview(invalid.path), isNull);
    expect(await readTextFilePreview(binary.path), isNull);
    expect(await readTextFilePreview('${folder.path}/photo.png'), isNull);
    final empty = await fixture('empty.txt', []);
    expect((await readTextFilePreview(empty.path))!.text, isEmpty);
  });

  test(
    'descriptor IO paths use the real display name to recognize text',
    () async {
      final file = await fixture('42', utf8.encode('来自目录授权的文字'));
      expect(await readTextFilePreview(file.path), isNull);
      expect(
        (await readTextFilePreview(file.path, title: '接收内容.txt'))!.text,
        '来自目录授权的文字',
      );
    },
  );

  Future<void> open(
    WidgetTester tester, {
    required String text,
    bool editable = false,
    bool closeAfterSave = false,
    Future<void> Function(String)? onSave,
    Future<void> Function(String)? onCopy,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTextViewer(
                context,
                title: '独立文字',
                text: text,
                editable: editable,
                closeAfterSave: closeAfterSave,
                onSave: onSave,
                onCopy: onCopy,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('sent text saves and closes once; a failed save stays editable', (tester) async {
    var fail = true;
    await open(tester, text: 'before', editable: true, closeAfterSave: true,
      onSave: (_) async { if (fail) throw Exception('save failed'); });
    await tester.enterText(find.byKey(const ValueKey('text-viewer-input')), 'after');
    await tester.pump(); await tester.tap(find.text('保存')); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('text-viewer-input')), findsOneWidget);
    fail = false; await tester.tap(find.text('保存')); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('text-viewer-input')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets(
    'received text viewer has one copy action that copies the whole message',
    (tester) async {
      final value = List.filled(200, '完整消息，不做预览截断。').join('\n');
      String? copied;
      await open(tester, text: value, onCopy: (text) async => copied = text);
      expect(find.byType(SelectionArea), findsNothing);
      expect(tester.widget<WebLinkText>(find.byType(WebLinkText)).text, value);
      expect(find.text('全选'), findsNothing);
      expect(find.text('复制'), findsOneWidget);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, value);
      expect(find.text('保存'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sent text viewer only saves committed edits and keeps exact multiline text',
    (tester) async {
      final saved = <String>[];
      await open(
        tester,
        text: '原消息',
        editable: true,
        onSave: (text) async => saved.add(text),
      );
      final input = find.byKey(const ValueKey('text-viewer-input'));
      await tester.enterText(input, '候选文字\n第二行');
      const composing = TextEditingValue(
        text: '候选文字\n第二行',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 4),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved, ['候选文字\n第二行']);
      expect(find.text('已同步'), findsNothing);
      expect(find.text('保存'), findsNothing);
      expect(tester.widget<TextField>(input).controller!.text, '候选文字\n第二行');
      expect(tester.takeException(), isNull);
    },
  );
}
