import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/text_viewer.dart';
import 'package:globalsend/web_links.dart';

void main() {
  testWidgets(
    'Android long press delegates immediately to native without a Flutter card shadow',
    (tester) async {
      final exports = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: Center(
              child: ContentDragSurface(
                entry: DockEntry(
                  id: 'phone',
                  kind: 'text',
                  title: '文本',
                  source: '',
                  text: 'native',
                ),
                onExport: (kind) async => exports.add(kind),
                child: const SizedBox(
                  key: ValueKey('source'),
                  width: 160,
                  height: 160,
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('source'))),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 650));
      expect(exports, ['touch']);
      expect(find.byKey(const ValueKey('drag-feedback-phone')), findsNothing);
      expect(find.byType(Draggable<DockEntry>), findsNothing);
      await gesture.moveBy(const Offset(30, 30));
      await tester.pump();
      expect(exports, ['touch']);
      await gesture.up();
    },
  );

  testWidgets(
    'desktop uses internal feedback then exports once with the original pointer kind',
    (tester) async {
      final exports = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: ContentDragSurface(
                entry: DockEntry(
                  id: 'desktop',
                  kind: 'text',
                  title: '文本',
                  source: '',
                  text: 'native',
                ),
                onExport: (kind) async => exports.add(kind),
                child: const SizedBox(
                  key: ValueKey('source'),
                  width: 160,
                  height: 160,
                ),
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('source'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(35, 10));
      await tester.pump();
      expect(exports, isEmpty);
      expect(
        find.byKey(const ValueKey('drag-feedback-desktop')),
        findsOneWidget,
      );
      await gesture.moveTo(const Offset(820, 250));
      await tester.pump();
      expect(exports, ['mouse']);
      expect(find.byKey(const ValueKey('drag-feedback-desktop')), findsNothing);
      await gesture.moveTo(const Offset(850, 260));
      await tester.pump();
      expect(exports, ['mouse']);
      await gesture.up();
    },
  );

  testWidgets(
    'native completion retires the old Flutter drag even when OLE consumed its pointer up',
    (tester) async {
      final native = Completer<void>();
      final exports = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: ContentDragSurface(
                entry: DockEntry(
                  id: 'returning',
                  kind: 'text',
                  title: '文本',
                  source: '',
                  text: 'native',
                ),
                onExport: (kind) {
                  exports.add(kind);
                  return native.future;
                },
                child: const SizedBox(
                  key: ValueKey('return-source'),
                  width: 160,
                  height: 160,
                ),
              ),
            ),
          ),
        ),
      );
      final center = tester.getCenter(
        find.byKey(const ValueKey('return-source')),
      );
      final old = await tester.startGesture(
        center,
        pointer: 11,
        kind: PointerDeviceKind.mouse,
      );
      await old.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('drag-feedback-returning')),
        findsOneWidget,
      );
      await old.moveTo(const Offset(830, 250));
      await tester.pump();
      expect(exports, ['mouse']);
      expect(
        find.byKey(const ValueKey('drag-feedback-returning')),
        findsNothing,
      );
      // The pointer returns while the OS, not Flutter, owns this drag. No stale
      // Flutter avatar should reappear or duplicate an internal drop.
      await old.moveTo(center);
      await tester.pump();
      expect(exports, ['mouse']);
      expect(
        find.byKey(const ValueKey('drag-feedback-returning')),
        findsNothing,
      );
      native.complete();
      await tester.pump();
      // Deliberately no old.up(): this is the actual OLE-consumed-up failure.
      final next = await tester.startGesture(
        center,
        pointer: 12,
        kind: PointerDeviceKind.mouse,
      );
      await next.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('drag-feedback-returning')),
        findsOneWidget,
      );
      await next.up();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('drag-feedback-returning')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows long-press export retains touch kind across native handoff',
    (tester) async {
      final exports = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: ContentDragSurface(
                entry: DockEntry(
                  id: 'touch',
                  kind: 'text',
                  title: '文本',
                  source: '',
                  text: 'touch native',
                ),
                onExport: (kind) async => exports.add(kind),
                child: const SizedBox(
                  key: ValueKey('touch-source'),
                  width: 160,
                  height: 160,
                ),
              ),
            ),
          ),
        ),
      );
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('touch-source'))),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 650));
      await drag.moveTo(const Offset(830, 250));
      await tester.pump();
      expect(exports, ['touch']);
      await drag.up();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expanded reader exports from header, footer and text while buttons click',
    (tester) async {
      final exports = <String>[];
      var copied = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTextViewer(
                  context,
                  title: '阅读器',
                  text: 'Drag select these words',
                  onDrag: (text, kind) async => exports.add('$kind:$text'),
                  onCopy: (text) async => copied = text,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(find.byType(ContentDragSurface));
      for (final start in [
        Offset(bounds.center.dx, bounds.top + 25),
        Offset(bounds.left + 35, bounds.bottom - 25),
      ]) {
        final drag = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(35, 0));
        await tester.pump();
        await drag.moveTo(const Offset(820, 200));
        await tester.pump();
        await drag.up();
        await tester.pump();
      }
      expect(exports, [
        'mouse:Drag select these words',
        'mouse:Drag select these words',
      ]);
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byType(WebLinkText),
              matching: find.byType(RichText),
            )
            .first,
      );
      final glyph = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .first
          .toRect();
      final start = paragraph.localToGlobal(glyph.center);
      final select = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await select.moveBy(const Offset(110, 0));
      await tester.pump();
      await select.moveTo(const Offset(820, 200));
      await tester.pump();
      await select.up();
      expect(exports.length, 3);
      expect(exports.last, 'mouse:Drag select these words');
      expect(find.byType(SelectionArea), findsNothing);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, 'Drag select these words');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
