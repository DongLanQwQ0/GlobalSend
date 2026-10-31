import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/dock_platform.dart';

import 'widget_test.dart' show signedIn;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'Android clipboard suggestion long press drags without confirming or sending',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardSuggestion')
          return {'available': true, 'revision': 'held-copy', 'kind': 'image'};
        if (call.method == 'windowVisible') return true;
        return null;
      });
      final drags = <MethodCall>[];
      messenger.setMockMethodCallHandler(DockPlatform.channel, (call) async {
        if (call.method == 'dragClipboardSuggestion') {
          drags.add(call);
          return false;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemBridge.channel, null);
        messenger.setMockMethodCallHandler(DockPlatform.channel, null);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final controller = signedIn()..clipboardTexts = ['clipboard'];
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('clipboard-suggestion'));
      await tester.longPress(card);
      await tester.pumpAndSettle();
      expect(drags, hasLength(1));
      expect(drags.single.arguments, {'revision': 'held-copy'});
      expect(controller.clipboardReads, 0);
      expect(controller.stagedTexts, isEmpty);
      expect(controller.stagedFiles, isEmpty);
      expect(controller.stagedSends, isEmpty);
      expect(card, findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('add-clipboard')));
      await tester.pumpAndSettle();
      expect(drags, hasLength(2));
      expect(controller.clipboardReads, 0);
      expect(controller.stagedTexts, isEmpty);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(controller.clipboardReads, 1);
      expect(controller.stagedTexts, ['clipboard']);
      expect(controller.stagedSends, isEmpty);
      expect(card, findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
