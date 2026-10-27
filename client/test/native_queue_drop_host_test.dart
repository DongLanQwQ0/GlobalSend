import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/android_queue_drop_host.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'widget_test.dart' show signedIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final geometry = <Map<String, dynamic>>[];
  setUp(() {
    geometry.clear();
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'queueDropBounds')
        geometry.add(Map<String, dynamic>.from(call.arguments));
      if (call.method == 'windowVisible') return true;
      if (call.method == 'presentReceiveDock')
        return {'presentation': 'main', 'shown': true};
      return null;
    });
    messenger.setMockMethodCallHandler(
      DockPlatform.channel,
      (call) async => null,
    );
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SystemBridge.channel, null);
    messenger.setMockMethodCallHandler(DockPlatform.channel, null);
  });

  testWidgets(
    'publishes only the visible queue in physical view pixels and updates its layout',
    (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final queue = GlobalKey();
      var top = 100.0, enabled = true;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, update) {
              change = update;
              return NativeQueueDropHost(
                target: queue,
                enabled: enabled,
                child: Scaffold(
                  body: Stack(
                    children: [
                      Positioned(
                        left: 20,
                        top: top,
                        width: 200,
                        height: 180,
                        child: ColoredBox(key: queue, color: Colors.green),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(geometry.last, {
        'enabled': true,
        'left': 40.0,
        'top': 200.0,
        'right': 440.0,
        'bottom': 560.0,
        'surfaceWidth': 800.0,
        'surfaceHeight': 1600.0,
      });
      final count = geometry.length;
      await tester.pump();
      expect(geometry.length, count);
      change(() => top = 220);
      await tester.pumpAndSettle();
      expect(geometry.last['top'], 440.0);
      change(() => enabled = false);
      await tester.pumpAndSettle();
      expect(geometry.last, {'enabled': false});
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(geometry.last, {'enabled': false});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clips the queue rectangle to the visible painted area', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final queue = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: NativeQueueDropHost(
          target: queue,
          enabled: true,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 120,
                height: 80,
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    maxWidth: 200,
                    maxHeight: 180,
                    child: SizedBox(key: queue, width: 200, height: 180),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(geometry.last['right'], 120.0);
    expect(geometry.last['bottom'], 80.0);
    expect(tester.takeException(), isNull);
  });

  test('Android geometry keeps the deliberate send-tab hover target separate from an inactive queue', () async {
    Map<String, dynamic>? arguments;
    messenger.setMockMethodCallHandler(DockPlatform.channel, (call) async {
      arguments = Map<String, dynamic>.from(call.arguments);
      return null;
    });
    await DockPlatform.setQueueDropBounds(
      null,
      surface: const Size(1080, 2400),
      sendNavigation: const Rect.fromLTRB(540, 2210, 1080, 2400),
    );
    expect(arguments, {
      'enabled': false,
      'sendNavigation': {
        'left': 540.0,
        'top': 2210.0,
        'right': 1080.0,
        'bottom': 2400.0,
        'surfaceWidth': 1080.0,
        'surfaceHeight': 2400.0,
      },
    });
  });

  testWidgets(
    'queue geometry is disabled behind a reader or editor route then restored on return',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(950, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = signedIn();
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      expect(geometry.last['enabled'], true);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      expect(geometry.last, {'enabled': false});
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(geometry.last['enabled'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a deliberate native send-tab navigation request changes page without staging anything',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = signedIn();
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NavigationDestination, '接收'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      await controller.handleNativeDockEvent({
        'type': 'nativeDrag',
        'local': true,
        'navigate': 'send',
        'active': false,
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(controller.stagedTexts, isEmpty);
      expect(controller.stagedFiles, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'new receipt dialogs wait for the local system drag to end without losing the receipt',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = signedIn();
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      await controller.handleNativeDockEvent({
        'type': 'nativeDrag',
        'local': true,
        'sessionActive': true,
        'active': false,
      });
      final receipt = DockEntry(
        id: 'drag-source-receipt',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: '拖放期间保留',
      );
      controller.dock.add(receipt);
      controller.pendingReceipts[receipt.id] = receipt;
      controller.latestReceipt = receipt;
      controller.receiptSerial++;
      controller.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(controller.pendingReceipts.containsKey(receipt.id), true);
      await controller.handleNativeDockEvent({
        'type': 'nativeDrag',
        'local': true,
        'sessionActive': false,
        'active': false,
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(find.text(receipt.text), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
