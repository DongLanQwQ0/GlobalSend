import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/ios_drag_source.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';

import 'widget_test.dart' show signedIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'iPad sending-page clipboard recommendation is a real native drag source without confirming it',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardSuggestion') {
          return {
            'available': true,
            'revision': 'ipad-copy-401',
            'kind': 'files',
          };
        }
        if (call.method == 'windowVisible') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(FileShareBridge.channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemBridge.channel, null);
        messenger.setMockMethodCallHandler(FileShareBridge.channel, null);
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final controller = signedIn()..clipboardTexts = ['actual clipboard'];
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('clipboard-suggestion'));
      final native = find.ancestor(
        of: card,
        matching: find.byType(IOSDragSource),
      );
      expect(native, findsOneWidget);
      expect(
        tester.widget<IOSDragSource>(native).clipboardRevision,
        'ipad-copy-401',
      );
      final regions =
          calls.where((c) => c.method == 'setDragSources').last.arguments
              as Map;
      final clipboardSources = (regions['sources'] as List)
          .cast<Map>()
          .where((s) => s['clipboardRevision'] == 'ipad-copy-401')
          .toList();
      expect(
        clipboardSources,
        hasLength(2),
        reason: 'suggestion card and toolbar both expose the clipboard',
      );
      final clipboard = clipboardSources.first;
      expect(clipboard['paths'], isEmpty);
      expect(clipboard['texts'], isEmpty);
      expect(controller.clipboardReads, 0);
      expect(controller.stagedFiles, isEmpty);
      expect(controller.stagedTexts, isEmpty);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(controller.clipboardReads, 1);
      expect(controller.stagedTexts, ['actual clipboard']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
