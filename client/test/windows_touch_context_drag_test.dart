import 'native_drag_render_fixture.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/text_selection_surface.dart';

void main() {
  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.stylus]) {
    for (final buttons in [kPrimaryButton, kSecondaryButton]) {
      testWidgets('Windows $kind held $buttons drags twice without a menu', (
        tester,
      ) async {
        final exports = <String>[];
        final secondaryKinds = <PointerDeviceKind?>[];
        var menus = 0, copies = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ContentDragSurface(
                    entry: DockEntry(
                      id: 'touch-context',
                      kind: 'text',
                      title: '文本',
                      source: '',
                      text: '整张卡片',
                    ),
                    onExport: (kind) async => exports.add(kind),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapDown: (details) {
                        secondaryKinds.add(details.kind);
                        if (ContentDragSurface.allowsContextMenu(
                          context,
                          details.kind,
                        ))
                          menus++;
                      },
                      child: SizedBox(
                        key: const ValueKey('surface'),
                        width: 180,
                        height: 160,
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: ContentDragControl(
                            child: TextButton(
                              onPressed: () => copies++,
                              child: const Text('复制'),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final origin =
            tester.getTopLeft(find.byKey(const ValueKey('surface'))) +
            const Offset(40, 40);
        for (var repeat = 0; repeat < 2; repeat++) {
          final drag = await tester.startGesture(
            origin,
            kind: kind,
            buttons: buttons,
          );
          await tester.pump(const Duration(milliseconds: 650));
          expect(menus, 0);
          await drag.moveBy(const Offset(35, 0));
          await pumpNativeDrag(tester);
          expect(
            find.byKey(const ValueKey('drag-feedback-touch-context')),
            findsOneWidget,
          );
          await drag.moveTo(const Offset(830, 200));
          await pumpNativeDrag(tester);
          expect(exports, List.filled(repeat + 1, kind.name));
          await drag.up();
          await pumpNativeDrag(tester);
        }
        await tester.tap(find.text('复制'));
        await pumpNativeDrag(tester);
        expect(copies, 1);
        final right = await tester.startGesture(
          origin,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await tester.pump(const Duration(milliseconds: 150));
        await right.up();
        await tester.pumpAndSettle();
        expect(menus, 1, reason: 'secondary pointer kinds: $secondaryKinds');
        expect(exports.length, 2);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'short touch movement still scrolls, editable text still focuses',
    (tester) async {
      final scroll = ScrollController();
      final exports = <String>[];
      final editor = TextEditingController(text: '可编辑');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                ContentDragSurface(
                  entry: DockEntry(
                    id: 'scroll',
                    kind: 'text',
                    title: '文本',
                    source: '',
                    text: '',
                  ),
                  onExport: (kind) async => exports.add(kind),
                  child: const SizedBox(
                    key: ValueKey('scroll-card'),
                    height: 180,
                  ),
                ),
                TextField(
                  key: const ValueKey('actual-editor'),
                  controller: editor,
                ),
                const SizedBox(height: 1000),
              ],
            ),
          ),
        ),
      );
      final finger = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('scroll-card'))),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 30));
      await finger.moveBy(const Offset(0, -70));
      await pumpNativeDrag(tester);
      await finger.moveBy(const Offset(0, -70));
      await finger.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(exports, isEmpty);
      await tester.tap(find.byKey(const ValueKey('actual-editor')));
      await tester.enterText(
        find.byKey(const ValueKey('actual-editor')),
        '正常输入',
      );
      expect(editor.text, '正常输入');
      expect(exports, isEmpty);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      editor.dispose();
    },
  );
}
