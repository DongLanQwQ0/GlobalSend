import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/system_bridge.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'saving sent text never resurrects an already dismissed receipt',
    (tester) async {
      final mobile = defaultTargetPlatform == TargetPlatform.android;
      tester.view.physicalSize = mobile
          ? const Size(400, 850)
          : const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        if (call.method == 'presentReceiveDock')
          return {'presentation': 'main', 'shown': true};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final sent = DockEntry(
        id: 'sent',
        kind: 'text',
        title: 'text',
        source: 'self',
        outgoing: true,
        targetDeviceId: 'phone',
        text: 'original sent',
      );
      final old = DockEntry(
        id: 'old',
        kind: 'text',
        title: 'text',
        source: 'phone',
        text: 'older received',
      );
      final c = fixture.signedIn()..dock.addAll([sent, old]);
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      c.latestReceipt = old;
      c.pendingReceipts[old.id] = old;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('close-receipt')));
      await tester.pumpAndSettle();
      expect(c.pendingReceipts, isEmpty);
      final dynamic state = tester.state(find.byType(SendScreen));
      final work = state.readText(sent) as Future<void>;
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('text-viewer-input')),
        'edited sent',
      );
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await work;
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      expect(c.dock, contains(old));
      expect(sent.text, 'edited sent');
      final next = DockEntry(
        id: 'next',
        kind: 'text',
        title: 'text',
        source: 'phone',
        text: 'new received',
      );
      c.dock.add(next);
      c.latestReceipt = next;
      c.pendingReceipts[next.id] = next;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('receipt-preview')),
          matching: find.text('new received'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
