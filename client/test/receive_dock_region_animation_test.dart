import 'system_font_fixture.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_dock_window.dart';
import 'package:globalsend/receipt_preview.dart';
import 'package:globalsend/received_order.dart';

Map<String, dynamic> dockPayload(int generation, List<String> ids) => {
  'serial': generation,
  'arrivalGeneration': generation,
  'items': [
    for (var i = 0; i < ids.length; i++)
      {
        ...DockEntry(
          id: ids[i],
          kind: 'text',
          title: '收到文本',
          source: 'fixture',
          text: '第 ${i + 1} 项正文：卡片完整显示，不应被竖条截断。',
          createdAtMillis: 1000 + i,
          receivedAtMillis: 2000 - i,
        ).toJson(),
        'sender': '测试设备',
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final boundaryKey = GlobalKey();
  final frames = <Map<String, dynamic>>[];
  tearDown(
    () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
  );
  tearDownAll(() async {
    final report = File(
      '../artifacts/reports/receive-dock-pane-frames-final.json',
    );
    await report.parent.create(recursive: true);
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(frames),
    );
  });

  test('receipt ordering uses actual completion time with a stable in-progress placeholder', () {
    final earlyOffer = DockEntry(
      id: 'actual-newest',
      kind: 'file',
      title: 'z',
      source: '',
      createdAtMillis: 100,
      receivedAtMillis: 5000,
    );
    final lateOffer = DockEntry(
      id: 'actual-oldest',
      kind: 'file',
      title: 'a',
      source: '',
      createdAtMillis: 9000,
      receivedAtMillis: 2000,
    );
    final pending = DockEntry(
      id: 'pending',
      kind: 'file',
      title: 'b',
      source: '',
      createdAtMillis: 4000,
    );
    final source = [lateOffer, earlyOffer, pending];
    List<String> sortedIds() => ([
      ...source,
    ]..sort(compareReceivedNewestFirst)).map((entry) => entry.id).toList();
    expect(sortedIds(), ['actual-newest', 'pending', 'actual-oldest']);
    pending.progress = .8;
    expect(sortedIds(), ['actual-newest', 'pending', 'actual-oldest']);
    pending.receivedAtMillis = 6000;
    expect(sortedIds(), ['pending', 'actual-newest', 'actual-oldest']);
    expect(
      source.first.id,
      'actual-oldest',
    ); // no mutation of the source inventory
  });

  testWidgets(
    'batch receipt grid shows actual newest receipt first independently of inventory order',
    (tester) async {
      final newest = DockEntry(
        id: 'newest',
        kind: 'text',
        title: '文本',
        source: '',
        text: 'n',
        createdAtMillis: 1,
        receivedAtMillis: 50,
      );
      final older = DockEntry(
        id: 'older',
        kind: 'text',
        title: '文本',
        source: '',
        text: 'o',
        createdAtMillis: 100,
        receivedAtMillis: 20,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceivedBatchPreview(
              entries: [older, newest],
              onClose: () {},
              onCopy: (_) {},
              onView: (_) {},
              itemBuilder: (entry, actions) => Text(entry.id),
            ),
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.text('newest')).dx,
        lessThan(tester.getTopLeft(find.text('older')).dx),
      );
    },
  );

  Future<void> deliver(WidgetTester tester, Map<String, dynamic> data) async {
    await messenger.handlePlatformMessage(
      ReceiveDockApp.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('content', data)),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> mount(
    WidgetTester tester,
    Map<String, dynamic> initial,
    List<Map<String, dynamic>> regions,
    List<String> methods,
  ) async {
    tester.view.physicalSize = const Size(480, 184);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
      methods.add(call.method);
      if (call.method == 'ready') return initial;
      if (call.method == 'hitRegions')
        regions.add(Map<String, dynamic>.from(call.arguments));
      return null;
    });
    await tester.pumpWidget(
      RepaintBoundary(key: boundaryKey, child: const ReceiveDockApp()),
    );
    await tester.pumpAndSettle();
  }

  Future<int> inspectFrame(
    WidgetTester tester,
    String name,
    List<Map<String, dynamic>> regions, {
    bool screenshot = false,
  }) async {
    expect(
      regions,
      isEmpty,
      reason: 'no per-card native cut-out geometry is sent',
    );
    final backgroundAlpha = <int>[];
    await tester.runAsync(() async {
      final image =
          await (boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      for (final point in [
        const Offset(2, 2),
        const Offset(310, 15),
        const Offset(475, 90),
        const Offset(310, 182),
      ]) {
        backgroundAlpha.add(
          data.getUint8(
            (point.dy.toInt() * image.width + point.dx.toInt()) * 4 + 3,
          ),
        );
      }
      if (screenshot) {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final file = File(
          '../artifacts/screenshots/receive-dock-pane-$name-final.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png.buffer.asUint8List());
      }
      image.dispose();
    });
    frames.add({
      'frame': name,
      'legacyGeometryMessages': regions.length,
      'backgroundAlpha': backgroundAlpha,
    });
    return backgroundAlpha.where((alpha) => alpha != 179).length;
  }

  testWidgets(
    'six dock cards scroll over one unchanged translucent pane without native cut-outs',
    (tester) async {
      final regions = <Map<String, dynamic>>[], methods = <String>[];
      await mount(
        tester,
        dockPayload(1, ['a', 'b', 'c', 'd', 'e', 'f']),
        regions,
        methods,
      );
      expect(await inspectFrame(tester, 'initial-six', regions), 0);
      final misses = <int>[];
      for (var i = 0; i < 6; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: const Offset(200, 100),
            scrollDelta: const Offset(0, 37),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        misses.add(
          await inspectFrame(tester, 'scroll-$i', regions, screenshot: i == 3),
        );
      }
      expect(
        misses,
        everyElement(0),
        reason: 'scrolling must not replace the pane with clear holes or opaque fill',
      );
    },
  );

  testWidgets(
    'new dock card drops and old cards shift over the same pane without repeated presentation',
    (tester) async {
      final regions = <Map<String, dynamic>>[], methods = <String>[];
      await mount(
        tester,
        dockPayload(1, ['old-a', 'old-b', 'old-c']),
        regions,
        methods,
      );
      final next = dockPayload(2, ['new', 'old-a', 'old-b', 'old-c']);
      await deliver(tester, next);
      final misses = <int>[];
      for (var i = 0; i < 18; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        misses.add(
          await inspectFrame(
            tester,
            'arrival-$i',
            regions,
            screenshot: i == 5 || i == 17,
          ),
        );
      }
      expect(misses, everyElement(0));
      expect(methods.where((m) => m == 'presented'), hasLength(1));
    },
  );

  testWidgets(
    'hovering dock content does not overlay its generic received-text title',
    (tester) async {
      final regions = <Map<String, dynamic>>[], methods = <String>[];
      await mount(tester, dockPayload(1, ['a']), regions, methods);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(60, 85));
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(find.text('收到文本'), findsNothing);
      await mouse.removePointer();
    },
  );

  testWidgets(
    'dock sorts by receipt time and reveals a newly completed front item after scrolling',
    (tester) async {
      final regions = <Map<String, dynamic>>[], methods = <String>[];
      final data = dockPayload(1, ['a', 'b', 'c', 'd', 'e', 'pending']);
      final items = data['items'] as List<Map<String, dynamic>>;
      items.last['receivedAtMillis'] = 0;
      items.last['createdAtMillis'] = 1500;
      await mount(tester, data, regions, methods);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('dock-tile-a'))).dx,
        10,
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: const Offset(200, 100),
          scrollDelta: const Offset(0, 220),
        ),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('dock-horizontal-scroll')),
          )
          .controller!;
      expect(scroll.offset, greaterThan(0));
      items.last['receivedAtMillis'] = 5000;
      items.last['progress'] = 1.0;
      await deliver(tester, {...data, 'arrivalGeneration': 2});
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('dock-tile-pending'))).dx,
        10,
      );
      final before = tester.getTopLeft(
        find.byKey(const ValueKey('dock-tile-pending')),
      );
      items.last['progress'] = .8;
      await deliver(tester, {...data, 'arrivalGeneration': 2});
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('dock-tile-pending'))),
        before,
      );
      expect(items.last['receivedAtMillis'], 5000);
      expect(methods.where((m) => m == 'presented'), hasLength(1));
    },
  );
}
