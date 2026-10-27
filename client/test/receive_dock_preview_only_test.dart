import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/compact_content_card.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_dock_window.dart';

import 'native_drag_render_fixture.dart';
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final captureKey = GlobalKey();
  final imageFile = File('../artifacts/tmp/dock-pane/preview-only-image.png')
      .absolute;
  final binaryFile = File('../artifacts/tmp/dock-pane/preview-only-archive.zip')
      .absolute;
  final calls = <MethodCall>[];
  final receiptTime = DateTime(2026, 10, 27, 23, 9).millisecondsSinceEpoch;
  const text = '文字直接铺满预览区域。复制和菜单留在卡片上，不再挤占一行。';
  Map<String, dynamic> data(List<DockEntry> entries) => {
    'serial': 1,
    'arrivalGeneration': 1,
    'items': [
      for (final entry in entries)
        {...entry.toJson(), 'progress': entry.progress, 'sender': 'DongLan'},
    ],
  };
  Future<void> mount(WidgetTester tester, List<DockEntry> entries) async {
    tester.view.physicalSize = const Size(480, 184);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    calls.clear();
    messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') return data(entries);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
    );
    await tester.pumpWidget(
      RepaintBoundary(key: captureKey, child: const ReceiveDockApp()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }

  Future<void> capture(WidgetTester tester, String name) =>
      tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        await File('../artifacts/screenshots/$name.png').writeAsBytes(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        image.dispose();
      });
  void noMetadata(WidgetTester tester) {
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join('\n');
    expect(visibleText, isNot(contains('DongLan')));
    expect(visibleText, isNot(contains('23:09')));
    expect(visibleText, isNot(contains('KiB')));
    expect(visibleText, isNot(contains('字符')));
  }

  testWidgets(
    'dock image and text use the entire square while ordinary files keep a primary name',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 200, 200),
          Paint()..color = const Color(0xff82acc6),
        );
        canvas.drawOval(
          const Rect.fromLTWH(-50, 80, 300, 180),
          Paint()..color = const Color(0xff2f6f9a),
        );
        canvas.drawCircle(
          const Offset(150, 40),
          28,
          Paint()..color = const Color(0xffdeeff4),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(200, 200);
        await imageFile.writeAsBytes(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        await binaryFile.writeAsBytes([1, 2]);
        image.dispose();
        picture.dispose();
      });
      final image = DockEntry(
        id: 'image',
        kind: 'file',
        title: 'hidden-photo.png',
        source: 'phone',
        size: 74905,
        localPath: imageFile.path,
        receivedAtMillis: receiptTime + 2,
      );
      final message = DockEntry(
        id: 'text',
        kind: 'text',
        title: 'hidden-message-title',
        text: text,
        source: 'phone',
        receivedAtMillis: receiptTime + 1,
      );
      final ordinary = DockEntry(
        id: 'ordinary',
        kind: 'file',
        title: 'project.zip',
        source: 'phone',
        localPath: binaryFile.path,
        receivedAtMillis: receiptTime,
      );
      // Resolve the provider before the dock's Image first subscribes in fake
      // async; awaiting that same in-flight stream in runAsync stalls its pump.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.runAsync(
        () => precacheImage(
          ResizeImage(FileImage(imageFile), width: 560),
          tester.element(find.byType(Scaffold).first),
        ),
      );
      await mount(tester, [image, message, ordinary]);
      noMetadata(tester);
      expect(find.text('hidden-photo.png'), findsNothing);
      expect(find.text('hidden-message-title'), findsNothing);
      expect(find.text('project.zip'), findsOneWidget);
      for (final id in ['image', 'text']) {
        final card = find.descendant(
          of: find.byKey(ValueKey('dock-tile-$id')),
          matching: find.byType(CompactContentCard),
        );
        expect(tester.widget<CompactContentCard>(card).previewOnly, true);
        expect(
          tester.getRect(find.byKey(ValueKey('preview-$id'))),
          tester.getRect(card),
        );
      }
      expect(find.byKey(const ValueKey('dock-drag-all-files')), findsOneWidget);
      await capture(tester, 'receive-dock-preview-only-content');
      await tester.tap(find.text('复制'));
      await tester.pump();
      expect(
        (calls.lastWhere((call) => call.method == 'action').arguments
            as Map)['action'],
        'copy',
      );
      await tester.tap(find.byIcon(Icons.more_horiz).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入待发送'));
      await tester.pumpAndSettle();
      expect(
        (calls.lastWhere((call) => call.method == 'action').arguments
            as Map)['action'],
        'stage',
      );
      final drag = await tester.startGesture(
        tester.getTopLeft(find.byKey(const ValueKey('dock-tile-text'))) +
            const Offset(25, 70),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(25, 0));
      await pumpNativeDrag(tester);
      await drag.moveTo(const Offset(510, 90));
      await pumpNativeDrag(tester);
      final exported =
          calls.lastWhere((call) => call.method == 'dragOut').arguments as Map;
      expect(exported['text'], text);
      expect(exported['previewWidth'], 184);
      expect(exported['previewHeight'], 140);
      await drag.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'dock progress pause resume and retry remain overlays without metadata',
    (tester) async {
      final pending = DockEntry(
        id: 'pending',
        kind: 'file',
        title: 'receiving.bin',
        source: 'phone',
        status: 'downloading',
        route: 'direct',
        receivedAtMillis: receiptTime + 2,
      )..progress = .35;
      final paused = DockEntry(
        id: 'paused',
        kind: 'file',
        title: 'paused.bin',
        source: 'phone',
        status: 'paused',
        receivedAtMillis: receiptTime + 1,
      )..progress = .5;
      final failed = DockEntry(
        id: 'failed',
        kind: 'file',
        title: 'failed.bin',
        source: 'phone',
        status: 'failed',
        receivedAtMillis: receiptTime,
      );
      await mount(tester, [pending, paused, failed]);
      noMetadata(tester);
      expect(find.text('接收中 35%'), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
      expect(find.text('接收失败'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
      for (final label in ['暂停', '继续', '重试']) {
        await tester.tap(find.text(label));
        await tester.pump();
      }
      expect(
        calls
            .where((call) => call.method == 'action')
            .map((call) => (call.arguments as Map)['action']),
        ['pause', 'resume', 'retry'],
      );
      await capture(tester, 'receive-dock-preview-only-progress');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'shared cards retain metadata unless the independent dock explicitly requests previewOnly',
    (tester) async {
      final entry = DockEntry(
        id: 'normal',
        kind: 'text',
        title: '文本',
        text: '默认布局',
        source: 'phone',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              height: 220,
              child: CompactContentCard(
                entry: entry,
                sender: 'DongLan',
                timestamp: '23:09',
                onOpen: () {},
                onCopy: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CompactContentCard>(find.byType(CompactContentCard))
            .previewOnly,
        false,
      );
      expect(find.text('DongLan'), findsOneWidget);
      expect(find.textContaining('23:09'), findsOneWidget);
    },
  );
}
