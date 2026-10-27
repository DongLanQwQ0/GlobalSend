import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/system_bridge.dart';

import 'native_transfer_controls_test.dart' show ControlApi;
import 'widget_test.dart' as fixture;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'pending file pause and cancel stay clickable during another global working action',
    (tester) async {
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            SystemBridge.channel,
            (call) async => call.method == 'windowVisible' ? true : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final c = fixture.signedIn()..api = ControlApi();
      final item = DockEntry(
        id: 'pending',
        kind: 'file',
        title: 'waiting.bin',
        source: 'self',
        fileId: 'pending',
        transferId: 'pending',
        size: 1024,
        outgoing: true,
        status: 'accepted',
      );
      c.dock.add(item);
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('content-tab-1')));
      await tester.pumpAndSettle();
      final pending = Completer<void>();
      final dynamic state = tester.state(find.byType(SendScreen));
      final work = state.perform(() => pending.future) as Future<void>;
      await tester.pump();
      final pause = find.widgetWithText(TextButton, '暂停');
      expect(pause, findsOneWidget);
      expect(tester.widget<TextButton>(pause).onPressed, isNotNull);
      await tester.tap(pause);
      await tester.pump();
      expect(item.status, 'paused');
      final cancel = find.widgetWithText(TextButton, '取消');
      expect(tester.widget<TextButton>(cancel).onPressed, isNotNull);
      await tester.tap(cancel);
      await tester.pump();
      expect(item.status, 'canceled');
      pending.complete();
      await work;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
