import 'package:flutter/material.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/web_links.dart';

void main() {
  test(
    'shared recognition examples preserve prose and Chinese URL components',
    () async {
      final cases = jsonDecode(
        await File('../packages/protocol/fixtures/web-links.json')
            .readAsString(),
      ) as List;
      for (final item in cases) {
        final text = item['text'] as String,
            links = findWebLinks(item['text'] as String);
        expect(
          links.map((link) => link.label).toList(),
          item['labels'],
          reason: text,
        );
        for (final link in links)
          expect(text.substring(link.start, link.end), link.label);
      }
    },
  );
  test('recognizes web links with punctuation, query, balanced paths and IPv6', () {
    const text =
        '打开（https://example.com/a_(b)?q=1&x=2）。\nwww.example.com，http://[2408::1]:8787/globalsend/。';
    final links = findWebLinks(text);
    expect(links.map((link) => link.label), [
      'https://example.com/a_(b)?q=1&x=2',
      'www.example.com',
      'http://[2408::1]:8787/globalsend/',
    ]);
    expect(links[1].uri.toString(), 'https://www.example.com');
    for (final link in links) {
      expect(text.substring(link.start, link.end), link.label);
    }
    expect(
      findWebLinks('javascript:alert(1) file:///C:/test <b>文字</b> https://'),
      isEmpty,
    );
  });

  testWidgets(
    'tap opens the link; moving across it still starts whole-card drag',
    (tester) async {
      final opened = <Uri>[];
      var dragged = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GestureDetector(
                onPanStart: (_) => dragged = true,
                child: WebLinkText(
                  'https://example.com',
                  onOpen: (uri) async => opened.add(uri),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('https://example.com'));
      await tester.pump();
      expect(opened.single.toString(), 'https://example.com');
      opened.clear();
      await tester.drag(find.text('https://example.com'), const Offset(60, 0));
      expect(dragged, isTrue);
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read-only message text keeps URLs clickable without selection', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: WebLinkText(
              'https://example.com',
              onOpen: (uri) async => opened = uri,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('https://example.com'));
    await tester.pump();
    expect(opened.toString(), 'https://example.com');
    expect(find.byType(SelectionArea), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('opening a web link uses the shared platform bridge', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    MethodCall? call;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemBridge.channel, (value) async {
          call = value;
          return null;
        });
    await SystemBridge.openWebUrl(Uri.parse('https://example.com/a?q=中文'));
    expect(call!.method, 'openWebUrl');
    expect(call!.arguments, {
      'url': 'https://example.com/a?q=%E4%B8%AD%E6%96%87',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemBridge.channel, null);
  });
}
