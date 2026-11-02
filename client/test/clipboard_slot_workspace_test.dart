import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'widget_test.dart' show signedIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'one workspace clipboard slot refreshes silently and only becomes a draft on request',
    (tester) async {
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger = tester.binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'windowVisible') return true;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final c = signedIn();
      DockEntry value(String text, int revision) => DockEntry(
        id: 'remote-$revision',
        kind: 'text',
        title: '剪贴板',
        source: 'source',
        text: text,
        autoClipboard: true,
        createdAtMillis: revision,
        originDeviceId: 'source',
        sourceEventId: 'copy-$revision',
      );
      await c.clipboard.receive(value('first clipboard', 1));
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clipboard-slot')), findsOneWidget);
      expect(find.textContaining('first clipboard'), findsOneWidget);
      expect(c.dock, isEmpty);
      expect(c.receiptSerial, 0);
      await c.clipboard.receive(value('latest clipboard', 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('clipboard-slot')), findsOneWidget);
      expect(find.textContaining('latest clipboard'), findsOneWidget);
      expect(find.textContaining('first clipboard'), findsNothing);
      expect(c.dock, isEmpty);
      expect(c.stagedTexts, isEmpty);
      expect(c.receiptSerial, 0);
      expect(
        calls.where(
          (call) => [
            'showReceivedWindow',
            'activateWindow',
          ].contains(call.method),
        ),
        isEmpty,
      );
      final updates = calls.where((call) => call.method == 'presentReceiveDock').toList();
      expect(updates, hasLength(2));
      for (final update in updates) {
        final payload = update.arguments as Map;
        expect(payload['quiet'], isTrue);
        expect(payload['items'], isEmpty);
        expect(payload['serial'], 0);
      }
      await tester.tap(find.text('复制').first);
      await tester.pumpAndSettle();
      expect(c.copied, ['clipboard-slot']);
      expect(c.stagedTexts, isEmpty);
      await tester.tap(find.byTooltip('加入待发送'));
      await tester.pumpAndSettle();
      expect(c.stagedTexts, ['latest clipboard']);
      expect(c.clipboardSlot?.text, 'latest clipboard');
      expect(c.dock, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
