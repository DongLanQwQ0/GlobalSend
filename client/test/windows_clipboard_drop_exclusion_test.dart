import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/android_queue_drop_host.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/bulk_file_drag.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/system_bridge.dart';

import 'system_font_fixture.dart';
import 'windows_recommendation_drag_test.dart' show RecommendationController;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final geometry = <Map>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    geometry.clear();
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'queueDropBounds') geometry.add(call.arguments as Map);
      if (call.method == 'windowVisible') return true;
      if (call.method == 'clipboardSuggestion') {
        return {
          'available': true,
          'revision': 'exclusion-fixture',
          'kind': 'text',
        };
      }
      return null;
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
  );

  testWidgets(
    'visible clipboard exclusion follows clipping, movement and removal',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final queue = GlobalKey(), clipboard = GlobalKey();
      var left = 150.0, visible = true;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, update) {
              change = update;
              return NativeQueueDropHost(
                target: queue,
                enabled: true,
                excludedTargets: [clipboard],
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    key: queue,
                    width: 200,
                    height: 180,
                    child: ClipRect(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          if (visible)
                            Positioned(
                              left: left,
                              top: 20,
                              width: 100,
                              height: 100,
                              child: ColoredBox(
                                key: clipboard,
                                color: Colors.grey,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(geometry.last['exclusions'], [
        {'left': 300.0, 'top': 40.0, 'right': 400.0, 'bottom': 240.0},
      ]);
      change(() => left = 10);
      await tester.pumpAndSettle();
      expect((geometry.last['exclusions'] as List).single['left'], 20.0);
      change(() => visible = false);
      await tester.pumpAndSettle();
      expect(geometry.last.containsKey('exclusions'), false);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(geometry.last, {'enabled': false});
    },
  );

  testWidgets(
    'clipboard card blocks queue hover and drop; the rest still stages',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(950, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final folder = Directory(
        '../artifacts/tmp/windows-clipboard-exclusion88/widget',
      ).absolute;
      await tester.runAsync(() => folder.create(recursive: true));
      final c = RecommendationController(folder)
        ..api = CenterApi('https://example.invalid', token: 'fixture')
        ..profile = ServerProfile(
          baseUrl: 'https://example.invalid',
          instanceId: 'fixture',
          deviceId: 'self',
        )
        ..connected = true;
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      final clipboard = find.byKey(const ValueKey('clipboard-suggestion'));
      expect(clipboard, findsOneWidget);
      final cardBox = tester.renderObject<RenderBox>(clipboard);
      final card = MatrixUtils.transformRect(
        cardBox.getTransformTo(null),
        Offset.zero & cardBox.size,
      );
      final exclusion = (geometry.last['exclusions'] as List).single as Map;
      expect(exclusion, {
        'left': card.left,
        'top': card.top,
        'right': card.right,
        'bottom': card.bottom,
      });
      final screenContext = tester.element(find.byType(SendScreen));
      final entry = OverlayEntry(
        builder: (_) => Positioned(
          right: 20,
          bottom: 20,
          child: Draggable<DockEntry>(
            data: BulkFileEntry(['F:/fixture/drop.txt']),
            hitTestBehavior: HitTestBehavior.opaque,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: const SizedBox(width: 20, height: 20),
            child: const SizedBox(
              key: ValueKey('fixture-drag'),
              width: 40,
              height: 40,
            ),
          ),
        ),
      );
      Overlay.of(screenContext).insert(entry);
      await tester.pumpAndSettle();
      final queueBox = tester.getRect(find.byKey(const ValueKey('send-queue')));
      final valid = Offset(queueBox.right - 20, card.center.dy);
      Future<void> moveTo(TestGesture gesture, Offset point) async {
        await gesture.moveTo(point);
        await tester.pump();
      }

      // Inspect the rendered border, not a direct callback invocation.
      double queueStroke() =>
          ((tester
                              .widget<Container>(
                                find.byKey(const ValueKey('send-queue')),
                              )
                              .decoration
                          as BoxDecoration)
                      .border!
                  as Border)
              .top
              .width;
      final normalStroke = queueStroke();
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('fixture-drag'))),
      );
      await moveTo(drag, valid);
      expect(queueStroke(), greaterThan(normalStroke));
      await moveTo(drag, card.center);
      expect(queueStroke(), normalStroke);
      await moveTo(drag, valid);
      expect(queueStroke(), greaterThan(normalStroke));
      await moveTo(drag, card.center);
      await drag.up();
      await tester.pumpAndSettle();
      expect(c.stagedFiles, isEmpty);
      final second = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('fixture-drag'))),
      );
      await moveTo(second, valid);
      await second.up();
      await tester.pumpAndSettle();
      expect(c.stagedFiles, ['F:/fixture/drop.txt']);
      entry.remove();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
