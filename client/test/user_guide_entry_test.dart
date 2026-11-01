import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/user_guide_screen.dart';

import 'widget_test.dart' show signedIn;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'settings guide opens and Escape returns without losing settings draft',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(950, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final c = signedIn();
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('device-name-input'));
      await tester.scrollUntilVisible(
        input,
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(input, 'keep this draft');
      final guide = find.byKey(const ValueKey('open-user-guide'));
      await tester.scrollUntilVisible(
        guide,
        -180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(guide);
      await tester.pumpAndSettle();
      expect(find.byType(UserGuideScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(UserGuideScreen), findsNothing);
      await tester.scrollUntilVisible(
        input,
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('settings-list')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        tester.widget<TextField>(input).controller!.text,
        'keep this draft',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
