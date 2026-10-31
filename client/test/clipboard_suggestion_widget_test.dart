import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';

import 'widget_test.dart' show signedIn;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'unconfirmed clipboard card lives in the queue but is excluded from direct send until tapped',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var revision = 'copy-1';
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardSuggestion')
          return {'available': true, 'revision': revision, 'kind': 'text'};
        if (call.method == 'windowVisible') return true;
        if (call.method == 'presentReceiveDock')
          return {'presentation': 'main', 'shown': true};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final controller = signedIn()..clipboardTexts = ['synthetic clipboard'];
      controller.stagedTexts.add('confirmed draft');
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: GlobalSendApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('clipboard-suggestion')),
        findsOneWidget,
      );
      expect(controller.clipboardReads, 0);
      expect(find.text('待发送 · 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('send-queue-list')),
          matching: find.byKey(const ValueKey('clipboard-suggestion')),
        ),
        findsOneWidget,
      );
      for (final size in [const Size(390, 844), const Size(950, 650)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final card = tester.getSize(
          find.byKey(const ValueKey('clipboard-suggestion')),
        );
        expect(card.width, closeTo(card.height, .1));
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ImageByteFormat.png);
          final file = File(
            '../artifacts/screenshots/clipboard79-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const ValueKey('target-phone')));
      await tester.pumpAndSettle();
      expect(controller.stagedSends, ['phone']);
      expect(controller.clipboardReads, 0);
      expect(controller.stagedTexts, isEmpty);
      expect(
        find.byKey(const ValueKey('clipboard-suggestion')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('clipboard-suggestion')));
      await tester.pumpAndSettle();
      expect(controller.clipboardReads, 1);
      expect(controller.stagedTexts, ['synthetic clipboard']);
      expect(controller.stagedSends, ['phone']);
      expect(find.byKey(const ValueKey('clipboard-suggestion')), findsNothing);
      revision = 'copy-2';
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('clipboard-suggestion')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('忽略剪贴板建议'));
      await tester.pumpAndSettle();
      expect(controller.clipboardReads, 1);
      expect(find.byKey(const ValueKey('clipboard-suggestion')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
