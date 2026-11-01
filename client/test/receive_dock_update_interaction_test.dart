import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/receive_dock_window.dart';

import 'receive_dock_window_test.dart' show payload;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'dock publishes held pointers, popup lifetime and scrolling until their real end',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 184);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final states = <bool>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        if (call.method == 'ready')
          return payload(1, ['one', 'two', 'three', 'four', 'five']);
        if (call.method == 'interaction')
          states.add((call.arguments as Map)['active'] as bool);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
      );
      await tester.pumpWidget(const ReceiveDockApp());
      await tester.pumpAndSettle();
      final press = await tester.startGesture(const Offset(310, 120));
      await tester.pump();
      expect(states.last, isTrue);
      await press.up();
      await tester.pumpAndSettle();
      expect(states.last, isFalse);
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      expect(states.last, isTrue);
      await tester.tapAt(const Offset(460, 180));
      await tester.pumpAndSettle();
      expect(states.last, isFalse);
      await tester.fling(
        find.byKey(const ValueKey('dock-content-strip')),
        const Offset(-180, 0),
        700,
      );
      await tester.pump();
      expect(states.last, isTrue);
      await tester.pumpAndSettle();
      expect(states.last, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
