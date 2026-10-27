import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/compact_content_card.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receipt_preview.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/web_links.dart';

const shortText = '这是完整的接收内容。点击复制，或者直接拖动这一整张弹层。\n正文也能拖动，不再被文字选择阻挡。';
final longText = List.generate(
  20,
  (i) => '第 ${i + 1} 行：收到的完整文本可以从标题、正文、边缘和空白处拖动，复制仍是独立按钮。',
).join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final textFont = FontLoader('GlobalSendSans');
    for (final name in ['Regular', 'Semibold']) {
      textFont.addFont(
        Future.value(
          ByteData.sublistView(
            await File('assets/fonts/GlobalSendSans-$name.ttf').readAsBytes(),
          ),
        ),
      );
    }
    await textFont.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            await File(
              'E:/Programs/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
            ).readAsBytes(),
          ),
        ),
      );
    await icons.load();
  });

  Offset glyph(WidgetTester tester, Finder ancestor, {int index = 0}) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: ancestor, matching: find.byType(RichText)).first,
    );
    final box = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: index, extentOffset: index + 1),
        )
        .first
        .toRect();
    return paragraph.localToGlobal(box.center);
  }

  Future<void> exportFrom(
    WidgetTester tester,
    Offset start,
    List<String> exports,
    String text,
  ) async {
    final before = exports.length;
    final drag = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(Offset(start.dx > 800 ? -35 : 35, 0));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('drag-feedback-receipt-region')),
      findsOneWidget,
      reason: 'internal preview from $start',
    );
    await drag.moveTo(const Offset(980, 300));
    await tester.pump();
    expect(exports.length, before + 1, reason: 'one native export from $start');
    expect(exports.last, 'mouse:$text');
    expect(
      find.byKey(const ValueKey('drag-feedback-receipt-region')),
      findsNothing,
    );
    await drag.up();
    await tester.pump();
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../artifacts/screenshots/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final fixture in [('short', shortText), ('long', longText)]) {
    testWidgets(
      'Windows ${fixture.$1} received text: entire visible popup drags; real controls remain independent',
      (tester) async {
        tester.view.physicalSize = const Size(950, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final exports = <String>[], copied = <String>[];
        final captureKey = GlobalKey();
        final entry = DockEntry(
          id: 'receipt-region',
          kind: 'text',
          title: '文本',
          source: 'fixture',
          text: fixture.$2,
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: captureKey,
            child: MaterialApp(
              theme: Ui.theme().copyWith(platform: TargetPlatform.windows),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      child: const Text('打开'),
                      onPressed: () => Navigator.of(context).push(
                        DialogRoute<void>(
                          context: context,
                          builder: (dialog) => ReceivedContentPreview(
                            entry: entry,
                            sender: 'V2527A',
                            platformIcon: Icons.phone_android,
                            onClose: () => Navigator.pop(dialog),
                            onCopy: () => copied.add(entry.text),
                            onOpen: () {},
                            dragSurface: (child) => ContentDragSurface(
                              entry: entry,
                              onExport: (kind) async =>
                                  exports.add('$kind:${entry.text}'),
                              child: child,
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
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(find.byType(SelectionArea), findsNothing);
        await capture(tester, captureKey, 'receipt-text-${fixture.$1}-1.0.19');
        final bounds = tester.getRect(
          find.byKey(const ValueKey('receipt-content-surface')),
        );
        final body = tester.getRect(
          find.byKey(const ValueKey('receipt-content-scroll')),
        );
        final starts = <String, Offset>{
          'upper left corner': bounds.topLeft + const Offset(12, 12),
          'upper right corner': bounds.topRight + const Offset(-12, 12),
          'lower left corner': bounds.bottomLeft + const Offset(12, -12),
          'lower right corner': bounds.bottomRight - const Offset(12, 12),
          'top edge': bounds.topCenter + const Offset(0, 2),
          'bottom edge': bounds.bottomCenter - const Offset(0, 2),
          'left edge': bounds.centerLeft + const Offset(2, 0),
          'right edge': bounds.centerRight - const Offset(2, 0),
          'sender glyph': glyph(tester, find.text('V2527A')),
          'platform icon': tester.getCenter(find.byIcon(Icons.phone_android)),
          'subtitle glyph': glyph(tester, find.text('收到文本')),
          'body glyph': glyph(
            tester,
            find.byKey(const ValueKey('receipt-text')),
          ),
          'body trailing blank': Offset(body.right - 15, body.top + 10),
          'body bottom': body.bottomCenter - const Offset(0, 3),
          'metadata glyph': glyph(
            tester,
            find.text('${entry.text.runes.length} 字符'),
          ),
          'footer whitespace': bounds.bottomCenter - const Offset(0, 30),
        };
        for (final zone in starts.entries) {
          try {
            await exportFrom(tester, zone.value, exports, entry.text);
          } catch (error) {
            fail('${fixture.$1} ${zone.key}: $error');
          }
        }
        expect(exports, hasLength(starts.length));
        for (final key in ['copy-receipt', 'close-receipt']) {
          final before = exports.length;
          final start = tester.getCenter(find.byKey(ValueKey(key)));
          final drag = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveBy(const Offset(-45, 0));
          await tester.pump();
          expect(
            find.byKey(const ValueKey('drag-feedback-receipt-region')),
            findsNothing,
          );
          await drag.up();
          await tester.pump();
          expect(exports, hasLength(before));
          expect(copied, isEmpty);
          expect(
            find.byKey(const ValueKey('receipt-content-surface')),
            findsOneWidget,
          );
        }
        await tester.tap(find.byKey(const ValueKey('copy-receipt')));
        await tester.pumpAndSettle();
        expect(copied, [entry.text]);
        // A real touch long press still passes through the existing Windows
        // native handoff; the same readonly glyph is no longer a selection gate.
        final touch = await tester.startGesture(
          starts['body glyph']!,
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 650));
        await touch.moveTo(const Offset(980, 300));
        await tester.pump();
        expect(exports.last, 'touch:${entry.text}');
        await touch.up();
        await tester.tap(find.byKey(const ValueKey('close-receipt')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('receipt-content-surface')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Android readonly card glyph uses original native long press; copy/menu stay controls',
    (tester) async {
      final exports = <String>[];
      var copied = 0, menu = 0;
      final entry = DockEntry(
        id: 'phone-readonly',
        kind: 'text',
        title: '文本',
        source: '',
        text: shortText,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme().copyWith(platform: TargetPlatform.android),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 230,
                child: ContentDragSurface(
                  entry: entry,
                  onExport: (kind) async => exports.add(kind),
                  child: CompactContentCard(
                    entry: entry,
                    sender: '发送者',
                    timestamp: '12:34',
                    onOpen: () {},
                    onCopy: () => copied++,
                    menu: IconButton(
                      onPressed: () => menu++,
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final text = find.byType(WebLinkText).first;
      final drag = await tester.startGesture(
        glyph(tester, text),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 650));
      expect(exports, ['touch']);
      expect(find.byType(Draggable<DockEntry>), findsNothing);
      expect(find.byType(SelectionArea), findsNothing);
      await drag.up();
      for (final button in [find.text('复制'), find.byIcon(Icons.more_horiz)]) {
        final press = await tester.startGesture(
          tester.getCenter(button),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(const Duration(milliseconds: 650));
        await press.up();
        await tester.pump();
        expect(exports, ['touch']);
      }
      expect(copied, 1);
      expect(menu, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
