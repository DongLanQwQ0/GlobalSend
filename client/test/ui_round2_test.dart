import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/compact_time.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/text_selection_surface.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/saved_image_preview.dart';

import 'widget_test.dart' as fixture;

class RoundController extends fixture.PreviewController {
  RoundController() {
    api = CenterApi('https://example.invalid', token: 'fixture');
    profile = ServerProfile(
      baseUrl: api!.baseUrl,
      instanceId: 'preview',
      deviceId: 'self',
      name: '我的电脑',
    );
    devices = [
      {'deviceId': 'phone', 'name': '我的手机', 'online': true},
    ];
    connected = true;
  }
  String syncStatus = '已同步';
  bool dirty = false;
  @override
  String get sharedTextStatus => syncStatus;
  @override
  bool get sharedTextDirty => dirty;
  @override
  Future<void> sendStaged(String target) async {
    await super.sendStaged(target);
    stagedTargetStates[target] = 'sent';
    changed();
  }
}

class HistoryUiController extends RoundController {
  final archived = <DockEntry>[];
  @override
  List<DockEntry> get historyDock => [...dock, ...archived];
  @override
  bool isLocalHistory(DockEntry entry) => archived.contains(entry);
  @override
  Future<void> removeHistoryEntries(Iterable<DockEntry> entries) async {
    final ids = entries.map((entry) => entry.id).toSet();
    archived.removeWhere((entry) => ids.contains(entry.id));
    dock.removeWhere((entry) => ids.contains(entry.id));
    changed();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemBridge.channel,
          (call) async => call.method == 'windowVisible' ? true : null,
        );
  });
  setUpAll(() async {
    final fonts = FontLoader('GlobalSendSans');
    for (final weight in ['Regular', 'Semibold']) {
      fonts.addFont(
        Future.value(
          ByteData.sublistView(
            await File('assets/fonts/GlobalSendSans-$weight.ttf').readAsBytes(),
          ),
        ),
      );
    }
    await fonts.load();
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                'E:/Programs/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
              ).readAsBytes(),
            ),
          ),
        ))
        .load();
  });

  Future<GlobalKey> show(
    WidgetTester tester,
    fixture.PreviewController c,
    Size size, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GlobalSendApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    if (size.width < 900) {
      await tester.tap(find.widgetWithText(NavigationDestination, '接收'));
      await tester.pumpAndSettle();
    }
    return key;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../artifacts/screenshots/native-round2-$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  DockEntry text(String id, {bool outgoing = false}) => DockEntry(
    id: id,
    kind: 'text',
    title: '文本',
    source: 'phone',
    sourceLabel: '我的手机',
    text: '内容要一目了然\n共享不再反复显示已同步。',
    outgoing: outgoing,
    receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
  );

  test(
    'compact time uses calendar yesterday rather than a rolling duration',
    () {
      final now = DateTime(2026, 10, 26, 0, 5);
      expect(compactTime(DateTime(2026, 10, 26, 0, 1), now: now), '00:01');
      expect(compactTime(DateTime(2026, 10, 25, 0, 1), now: now), '00:01');
      expect(
        compactTime(DateTime(2026, 10, 24, 23, 59), now: now),
        '10/24 23:59',
      );
    },
  );

  for (final scale in [1.0, 1.3]) {
    testWidgets(
      'desktop tabs square queue and tall silent shared editor $scale',
      (tester) async {
        final c = fixture.signedIn()
          ..dock = [text('received'), text('sent', outgoing: true)];
        c.stagedTexts.addAll(['第一条待发送', '第二条待发送']);
        final key = await show(tester, c, const Size(934, 611), scale: scale);
        expect(
          find.byKey(const ValueKey('send-workspace-scroll')),
          findsNothing,
        );
        expect(find.text('已同步'), findsNothing);
        expect(find.text('查看'), findsNothing);
        final shared = tester.getRect(
          find.byKey(const ValueKey('shared-text-panel')),
        );
        expect(shared.bottom, lessThanOrEqualTo(611));
        expect(shared.height, greaterThan(115));
        final tile = tester.getSize(
          find.byKey(const ValueKey('send-queue-list')).hitTestable(),
        );
        expect(tile.width, greaterThan(100));
        await capture(tester, key, 'desktop-$scale');
        await tester.tap(find.byKey(const ValueKey('content-tab-1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('sent-grid')), findsOneWidget);
        expect(find.byKey(const ValueKey('send-queue')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('content-tab-2')));
        await tester.pumpAndSettle();
        expect(find.text('收到的文件会保存在这里'), findsOneWidget);
        await capture(tester, key, 'library-$scale');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'empty queue opens focused composer and cards keep their own actions',
    (tester) async {
      final c = fixture.signedIn();
      await show(tester, c, const Size(934, 611));
      await tester.tap(find.text('点击输入文本，或拖入文件'));
      await tester.pumpAndSettle();
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('draft-input')),
      );
      expect(input.focusNode!.hasFocus, isTrue);
      await tester.enterText(find.byKey(const ValueKey('draft-input')), '待发草稿');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-input')), findsNothing);
      await tester.tap(find.text('点击输入文本，或拖入文件'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('draft-input')))
            .controller!
            .text,
        '待发草稿',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local content drag is accepted only by the queue without native export',
    (tester) async {
      final c = fixture.signedIn()..dock = [text('drag-local')];
      await show(tester, c, const Size(934, 611));
      final card = tester.getRect(
        find.byKey(const ValueKey('drag-drag-local')),
      );
      expect(
        isTextSelectionPosition(
          card.topRight + const Offset(-15, 70),
          tester.view.viewId,
        ),
        isFalse,
      );
      final gesture = await tester.startGesture(
        card.topRight + const Offset(-15, 70),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-20, 0));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('drag-feedback-drag-local')),
        findsOneWidget,
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('send-queue'))),
      );
      await tester.pump();
      expect(find.text('松手，加入待发'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(c.requeued, ['drag-local']);
      expect(c.dragged, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read-only text has no selection drag exclusion, including actual glyphs',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 200,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    'Hello\n\nWorld',
                    textDirection: TextDirection.ltr,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.text('Hello\n\nWorld'),
          matching: find.byType(RichText),
        ),
      );
      final box = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .single
          .toRect();
      final glyph = paragraph.localToGlobal(box.center);
      expect(isTextSelectionPosition(glyph, tester.view.viewId), isFalse);
      expect(find.byType(SelectionArea), findsNothing);
      expect(
        isTextSelectionPosition(
          Offset(glyph.dx + 200, glyph.dy),
          tester.view.viewId,
        ),
        isFalse,
      );
      expect(
        isTextSelectionPosition(
          Offset(glyph.dx, glyph.dy + 100),
          tester.view.viewId,
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'archived receive selection survives refresh and deletes through history API',
    (tester) async {
      final c = HistoryUiController()..archived.add(text('archived'));
      await show(tester, c, const Size(934, 611));
      await tester.tap(find.byKey(const ValueKey('receive-multi-select')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('select-archived')));
      c.changed();
      await tester.pump();
      expect(find.text('复制 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('receive-delete-selected')));
      await tester.pumpAndSettle();
      expect(c.archived, isEmpty);
      expect(find.byKey(const ValueKey('drag-archived')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('device success expires and shared only reports failed sync', (
    tester,
  ) async {
    final c = RoundController()..stagedTexts.add('要发送的文字');
    await show(tester, c, const Size(934, 611));
    expect(find.text('已同步'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('target-phone')));
    await tester.pump();
    expect(
      find.text('已发送'),
      findsNWidgets(2),
    ); // tab + transient device feedback
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('已发送'), findsOneWidget); // only the tab remains
    c.dirty = true;
    c.syncStatus = '同步失败，稍后重试';
    c.changed();
    await tester.pump();
    expect(find.text('未同步'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'shared blank text focuses and drags into queue without external export',
    (tester) async {
      final c = RoundController();
      await show(tester, c, const Size(934, 611));
      final field = tester.getRect(
        find.byKey(const ValueKey('shared-text-input')),
      );
      final blank = field.bottomRight + const Offset(-24, -24);
      await tester.tapAt(blank);
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('shared-text-input')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      final gesture = await tester.startGesture(
        blank,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-12, 0));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('drag-feedback-group-shared-text-drag')),
        findsOneWidget,
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('send-queue'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(c.stagedTexts, [c.sharedText]);
      expect(c.dragged, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image cards extend previews and external double click delegates without launching apps',
    (tester) async {
      late File file;
      await tester.runAsync(() async {
        final parent = Directory('../artifacts/tmp/native-round2');
        await parent.create(recursive: true);
        final folder = await parent.createTemp('image-');
        file = File('${folder.path}/picture.png');
        await file.parent.create(recursive: true);
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 700, 500),
          ui.Paint()..color = const Color(0xff214e72),
        );
        canvas.drawCircle(
          const ui.Offset(500, 160),
          180,
          ui.Paint()..color = const Color(0xff55aab0),
        );
        canvas.drawCircle(
          const ui.Offset(150, 410),
          240,
          ui.Paint()..color = const Color(0xffd18b75),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(700, 500);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
        picture.dispose();
      });
      const name = '很长的文件名不再挤占图片预览区域.png';
      final c = fixture.signedIn()
        ..dock = [
          DockEntry(
            id: 'image',
            kind: 'file',
            title: name,
            source: 'phone',
            sourceLabel: '我的手机',
            localPath: file.absolute.path,
            status: 'received',
            size: 64000,
          ),
          text('text-beside-image'),
        ];
      var opens = 0;
      final key = await show(tester, c, const Size(934, 611));
      for (
        var i = 0;
        i < 30 &&
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .every((image) => image.image == null);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue,
      );
      expect(find.text(name), findsNothing);
      final card = tester.getRect(find.byKey(const ValueKey('drag-image')));
      final preview = tester.getRect(
        find.byKey(const ValueKey('preview-image')),
      );
      expect(preview.height / card.height, greaterThan(.7));
      await capture(tester, key, 'image-band-desktop');
      await tester.tapAt(preview.center);
      await tester.pumpAndSettle();
      final viewer = find.byKey(const ValueKey('saved-image-viewer'));
      expect(viewer, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(viewer, findsNothing);
      expect(find.byKey(const ValueKey('send-queue')), findsOneWidget);
      // open_filex uses Process.start on Windows. Inject the action rather
      // than launching a real desktop viewer from this component test.
      await tester.pumpWidget(
        MaterialApp(
          home: SavedImagePreview(
            path: file.absolute.path,
            title: name,
            onOpenExternal: () async {
              opens++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(viewer);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(viewer);
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone receive cards compact footer and shared keyboard keep composition',
    (tester) async {
      final c = fixture.signedIn()..dock = [text('phone-1'), text('phone-2')];
      final key = await show(tester, c, const Size(390, 844), scale: 1.3);
      expect(find.text('查看'), findsNothing);
      expect(find.textContaining('接收 10/'), findsNothing);
      await capture(tester, key, 'phone-receive-1.3');
      await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('shared-text-input')),
      );
      // The editor's center can lie below the fixed bottom navigation. Tap
      // the visible text area, as a person would, rather than that hidden center.
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const ValueKey('shared-text-input'))) +
            const Offset(24, 24),
      );
      await tester.pump();
      final editable = tester.widget<TextField>(
        find.byKey(const ValueKey('shared-text-input')),
      );
      expect(editable.focusNode!.hasFocus, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('shared-text-input')))
            .focusNode,
        same(editable.focusNode),
      );
      await capture(tester, key, 'phone-keyboard-1.3');
      expect(tester.takeException(), isNull);
    },
  );
}
