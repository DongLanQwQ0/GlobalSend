import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/text_viewer.dart';
import 'package:globalsend/web_links.dart';

void main() {
  testWidgets(
    'read-only file preview double-click opens from blank paper or text',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTextViewer(
                  context,
                  title: 'fixture.txt',
                  text: 'select these words',
                  onOpenExternal: () async {
                    opened++;
                  },
                ),
                child: const Text('预览'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      Future<void> doubleClick(Offset point) async {
        await tester.tapAt(point);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(point);
        await tester.pumpAndSettle();
      }

      final paper = tester.getRect(
        find.byKey(const ValueKey('text-viewer-input')),
      );
      await doubleClick(paper.bottomRight - const Offset(30, 30));
      expect(opened, 1);
      await doubleClick(
        tester.getTopLeft(find.byType(WebLinkText)) + const Offset(9, 10),
      );
      expect(opened, 2);
      expect(find.byType(SelectionArea), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
