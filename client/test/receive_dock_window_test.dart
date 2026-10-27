import 'native_drag_render_fixture.dart';
import 'system_font_fixture.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_dock_window.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/compact_content_card.dart';
import 'package:globalsend/web_links.dart';

Map<String, dynamic> payload(int generation, List<String> ids) => {
  'serial': generation * 2,
  'arrivalGeneration': generation,
  'items': [
    for (final id in ids)
      {
        ...DockEntry(
          id: id,
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '这是正文 $id，空白处可以拖动。',
          receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
        'sender': '我的手机',
      },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final captureKey = GlobalKey();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> content(WidgetTester tester, Map<String, dynamic> data) async {
    await messenger.handlePlatformMessage(
      ReceiveDockApp.channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('content', data)),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 184);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(key: captureKey, child: const ReceiveDockApp()),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null);
    messenger.setMockMethodCallHandler(SystemBridge.channel, null);
  });

  testWidgets(
    'dock URL click uses its system channel instead of a missing plugin',
    (tester) async {
      const text = 'https://example.com/中文?q=1';
      final initial = payload(1, ['url']);
      (initial['items'] as List).first['text'] = text;
      final urls = <String>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return initial;
        return null;
      });
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'openWebUrl')
          urls.add((call.arguments as Map)['url'] as String);
        return null;
      });
      await mount(tester);
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byType(WebLinkText).first,
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
      await tester.tapAt(paragraph.localToGlobal(glyph.center));
      await tester.pumpAndSettle();
      expect(urls, [Uri.parse(text).toString()]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'readonly dock text drags instead of moving the window; copy and close stay controls',
    (tester) async {
      final exports = <Map<String, dynamic>>[];
      final moves = <Object?>[];
      final actions = <Map<String, dynamic>>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return payload(1, ['readonly']);
        if (call.method == 'dragOut')
          exports.add(Map<String, dynamic>.from(call.arguments));
        if (call.method == 'move') moves.add(call.arguments);
        if (call.method == 'action')
          actions.add(Map<String, dynamic>.from(call.arguments));
        return null;
      });
      await mount(tester);
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byType(WebLinkText).first,
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
      for (var attempt = 0; attempt < 2; attempt++) {
        final drag = await tester.startGesture(
          paragraph.localToGlobal(glyph.center),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(35, 0));
        await pumpNativeDrag(tester);
        await drag.moveTo(const Offset(500, 90));
        await pumpNativeDrag(tester);
        await drag.up();
        await pumpNativeDrag(tester);
      }
      expect(exports, hasLength(2));
      expect(exports.last, {
        'pointerKind': 'mouse',
        'text': '这是正文 readonly，空白处可以拖动。',
      });
      expect(moves, isEmpty);
      expect(find.byType(SelectionArea), findsNothing);
      for (final control in [find.text('复制'), find.byIcon(Icons.close)]) {
        final drag = await tester.startGesture(
          tester.getCenter(control),
          kind: PointerDeviceKind.mouse,
        );
        await drag.moveBy(const Offset(45, 0));
        await pumpNativeDrag(tester);
        await drag.up();
        await pumpNativeDrag(tester);
      }
      expect(exports, hasLength(2));
      expect(moves, isEmpty);
      expect(actions, isEmpty);
      await tester.tap(find.text('复制'));
      await pumpNativeDrag(tester);
      expect(actions.single['action'], 'copy');
      await tester.tap(find.byIcon(Icons.close));
      await pumpNativeDrag(tester);
      expect(actions.last['action'], 'close');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dock uses compact horizontal squares and delegates copy and close without a session',
    (tester) async {
      final actions = <Map<String, dynamic>>[];
      final methods = <String>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        methods.add(call.method);
        if (call.method == 'ready') return payload(7, ['first', 'second']);
        if (call.method == 'action')
          actions.add(Map<String, dynamic>.from(call.arguments));
        return null;
      });
      await mount(tester);
      expect(find.text('收到 2 项'), findsOneWidget);
      expect(methods.where((method) => method == 'presented'), hasLength(1));
      expect(find.text('查看'), findsNothing);
      final scroller = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('dock-horizontal-scroll')),
      );
      expect(scroller.scrollDirection, Axis.horizontal);
      final size = tester.getSize(find.byType(CompactContentCard).first);
      expect(size.width, size.height);
      expect(find.byType(GridView), findsNothing);
      await tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/screenshots/receive-dock-compact-final.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('复制').first);
      await pumpNativeDrag(tester);
      expect(actions.single['action'], 'copy');
      expect(actions.single['id'], 'first');
      await tester.tap(find.byIcon(Icons.close));
      await pumpNativeDrag(tester);
      expect(actions.last, containsPair('action', 'close'));
      expect(actions.last['arrivalGeneration'], 7);
      expect(actions.last['serial'], 14);
      expect(actions.last['itemIds'], ['first', 'second']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dock has one translucent pane and no separate count or top button backgrounds',
    (tester) async {
      final regions = <Map<String, dynamic>>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return payload(1, ['one']);
        if (call.method == 'hitRegions')
          regions.add(Map<String, dynamic>.from(call.arguments));
        return null;
      });
      await mount(tester);
      expect(
        regions,
        isEmpty,
        reason: 'the native pane no longer cuts out card gaps',
      );
      for (final key in ['dock-count', 'dock-open', 'dock-close']) {
        final box = tester.widget<DecoratedBox>(find.byKey(ValueKey(key)));
        expect((box.decoration as BoxDecoration).color, Colors.transparent);
      }
      await tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int alpha(int x, int y) =>
            pixels.getUint8((y * image.width + x) * 4 + 3);
        expect(
          alpha(310, 80),
          179,
          reason: 'the whole pane shares the same 70-percent-alpha background',
        );
        expect(
          alpha(100, 110),
          179,
          reason: 'text preview has no additional independent surface',
        );
        image.dispose();
      });
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(find.text('加入待发送'), findsOneWidget);
      final menu = tester.getRect(
        find
            .ancestor(of: find.text('加入待发送'), matching: find.byType(Material))
            .first,
      );
      expect(menu.left, lessThan(148));
      expect(
        menu.right,
        greaterThan(158),
        reason: 'the menu crosses the former native card gap',
      );
      expect(menu.left, greaterThanOrEqualTo(0));
      expect(menu.right, lessThanOrEqualTo(480));
      expect(menu.top, greaterThanOrEqualTo(0));
      expect(menu.bottom, lessThanOrEqualTo(184));
      await tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final rgba = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        // These columns straddle the old SetWindowRgn cut at x=148..158.
        for (final x in [146, 150, 154, 158, 162]) {
          final y = menu.center.dy.round();
          expect(rgba.getUint8((y * image.width + x) * 4 + 3), 179);
        }
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('../artifacts/screenshots/receive-dock-pane-menu-final.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(regions, isEmpty);
    },
  );

  testWidgets(
    'dock movement sends the original client down point and retires the Flutter gesture',
    (tester) async {
      final moves = <Map<String, dynamic>>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return payload(1, ['one']);
        if (call.method == 'move')
          moves.add(Map<String, dynamic>.from(call.arguments));
        return null;
      });
      await mount(tester);
      for (var attempt = 0; attempt < 2; attempt++) {
        final gesture = await tester.startGesture(
          const Offset(24, 18),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(const Offset(84, 18));
        await pumpNativeDrag(tester);
        await gesture.up();
        await tester.pumpAndSettle();
      }
      expect(moves, hasLength(2));
      for (final move in moves) {
        expect(move['x'], 24);
        expect(move['y'], 18);
        expect(move['touch'], false);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a hidden native dock can rearm its content first-frame acknowledgement',
    (tester) async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        methods.add(call.method);
        return call.method == 'ready' ? payload(1, ['old']) : null;
      });
      await mount(tester);
      await content(tester, {
        ...payload(2, ['new']),
        'reveal': true,
      });
      expect(methods.where((method) => method == 'presented'), hasLength(2));
      await content(tester, payload(2, ['new']));
      expect(methods.where((method) => method == 'presented'), hasLength(2));
    },
  );

  testWidgets(
    'new arrivals shift existing squares without restarting native presentation',
    (tester) async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        methods.add(call.method);
        return call.method == 'ready' ? payload(1, ['old']) : null;
      });
      await mount(tester);
      final old = find.byKey(const ValueKey('dock-tile-old'));
      final start = tester.getTopLeft(old).dx;
      await messenger.handlePlatformMessage(
        ReceiveDockApp.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('content', payload(2, ['old', 'new'])),
        ),
        (_) {},
      );
      await pumpNativeDrag(tester);
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getTopLeft(old).dx, greaterThan(start));
      await tester.pumpAndSettle();
      final settled = tester.getTopLeft(old);
      expect(
        settled.dx,
        greaterThan(
          tester.getTopLeft(find.byKey(const ValueKey('dock-tile-new'))).dx,
        ),
      );
      await content(tester, payload(2, ['old', 'new']));
      expect(tester.getTopLeft(old), settled);
      expect(methods.where((method) => method == 'presented'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a queued close retains its old batch and old content cannot replace a newer arrival',
    (tester) async {
      final closing = Completer<void>();
      Map<String, dynamic>? close;
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return payload(7, ['old']);
        if (call.method == 'action') {
          close = Map<String, dynamic>.from(call.arguments);
          await closing.future;
        }
        return null;
      });
      await mount(tester);
      await tester.tap(find.byIcon(Icons.close));
      await pumpNativeDrag(tester);
      await content(tester, payload(8, ['new-a', 'new-b']));
      await content(tester, payload(6, ['stale']));
      expect(find.text('收到 2 项'), findsOneWidget);
      expect(close!['arrivalGeneration'], 7);
      expect(close!['itemIds'], ['old']);
      closing.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a delayed ready reply cannot overwrite an already delivered content update',
    (tester) async {
      final initial = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(
        ReceiveDockApp.channel,
        (call) async => call.method == 'ready' ? initial.future : null,
      );
      await mount(tester);
      await content(tester, payload(12, ['new-one', 'new-two']));
      initial.complete(payload(11, ['old']));
      await tester.pumpAndSettle();
      expect(find.text('收到 2 项'), findsOneWidget);
      expect(find.textContaining('new-one'), findsOneWidget);
    },
  );

  testWidgets('dock card right click uses the existing action menu', (
    tester,
  ) async {
    final actions = <Map<String, dynamic>>[];
    messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
      if (call.method == 'ready') return payload(3, ['right-click']);
      if (call.method == 'action')
        actions.add(Map<String, dynamic>.from(call.arguments));
      return null;
    });
    await mount(tester);
    final top = tester.getTopLeft(find.byType(CompactContentCard));
    await tester.tapAt(
      top + const Offset(8, 50),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('加入待发送'), findsOneWidget);
    await tester.tap(find.text('加入待发送'));
    await tester.pumpAndSettle();
    expect(actions.single['action'], 'stage');
    expect(actions.single['id'], 'right-click');
  });

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.stylus]) {
    testWidgets('Windows dock $kind secondary hold exports instead of a menu', (
      tester,
    ) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final exports = <Map<String, dynamic>>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return payload(3, ['held-touch']);
        if (call.method == 'dragOut')
          exports.add(Map<String, dynamic>.from(call.arguments));
        return null;
      });
      await mount(tester);
      final top = tester.getTopLeft(find.byType(CompactContentCard));
      final drag = await tester.startGesture(
        top + const Offset(15, 65),
        kind: kind,
        buttons: kSecondaryButton,
      );
      await tester.pump(const Duration(milliseconds: 650));
      expect(find.text('加入待发送'), findsNothing);
      await drag.moveTo(const Offset(510, 95));
      await pumpNativeDrag(tester);
      expect(exports.single['pointerKind'], kind.name);
      await drag.up();
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = previousPlatform;
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'dock surfaces failure and consent while normal progress stays quiet',
    (tester) async {
      final actions = <Map<String, dynamic>>[];
      final data = payload(4, ['file']);
      final item = (data['items'] as List).single as Map<String, dynamic>;
      item.addAll({
        'kind': 'file',
        'title': '报告.pdf',
        'status': 'failed',
        'error': 'fixture failure',
      });
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready') return data;
        if (call.method == 'action')
          actions.add(Map<String, dynamic>.from(call.arguments));
        return null;
      });
      await mount(tester);
      expect(find.text('接收失败'), findsOneWidget);
      await tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('../artifacts/screenshots/receive-dock-failure-final.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(find.text('加入待发送'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('接收失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(actions.single['action'], 'retry');
      item.addAll({
        'status': 'ready',
        'relayConfirmationPending': true,
        'progress': .4,
      });
      await content(tester, data);
      expect(find.text('需要确认中继'), findsOneWidget);
      item.addAll({
        'status': 'downloading',
        'relayConfirmationPending': false,
        'progress': .4,
        'transferBytesPerSecond': 2048,
      });
      await content(tester, data);
      expect(find.text('重试'), findsNothing);
      expect(find.text('接收失败'), findsNothing);
      expect(find.textContaining('2.0 KiB/s'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .4,
      );
      item['status'] = 'received';
      await content(tester, data);
      expect(find.textContaining('2.0 KiB/s'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );

  test('Windows dock bridge keeps explicit native focus result and dispatches actions separately from drops', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      methods.add(call.method);
      return call.method == 'presentReceiveDock'
          ? {'presentation': 'dock', 'shown': true, 'arrivalGeneration': 25}
          : null;
    });
    final events = <Map<String, dynamic>>[];
    final sub = SystemBridge.windowEvents.listen(events.add);
    final state = await SystemBridge.presentReceiveDock(items: [], serial: 12);
    expect(state['presentation'], 'dock');
    expect(SystemBridge.receiptArrivalGeneration, 25);
    await SystemBridge.drainLaunchFiles();
    await messenger.handlePlatformMessage(
      SystemBridge.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('receiveDockAction', {
          'action': 'stage',
          'id': 'entry',
          'arrivalGeneration': 25,
        }),
      ),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
    expect(events.single['dockAction']['action'], 'stage');
    expect(methods, ['presentReceiveDock', 'drainLaunchFiles']);
    await sub.cancel();
  }, skip: !Platform.isWindows);
}
