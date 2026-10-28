import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_update_ui.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/system_bridge.dart';

import 'app_updates_test.dart' show Feed, service;
import 'github_updates_test.dart' show asset, release;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'update offer preserves editing focus and opens only its matching package',
    (tester) async {
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = oldShadows);
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final feed = Feed()
        ..rows = [
          release('v1.0.30', [asset('GlobalSend-1.0.30-windows-x64.zip')]),
        ];
      final updates = service(feed),
          focus = FocusNode(),
          text = TextEditingController(),
          capture = GlobalKey();
      final urls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'openWebUrl')
          urls.add((call.arguments as Map)['url'] as String);
        else
          fail(
            'Update must not invoke receive/tray/activation: ${call.method}',
          );
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: AppUpdatesScope(
            updates: updates,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: Ui.theme(),
              builder: (context, child) => AppUpdateNotice(child: child!),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(80),
                  child: Column(
                    children: [
                      TextField(focusNode: focus, controller: text),
                      const UpdateCheckControl(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '保留正在编辑的内容');
      await updates.check(manual: true);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, true);
      expect(text.text, '保留正在编辑的内容');
      expect(find.byKey(const ValueKey('update-notice')), findsOneWidget);
      await tester.runAsync(() async {
        final picture =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        await File('../artifacts/screenshots/platform-update-notice.png')
            .writeAsBytes(
              (await picture.toByteData(format: ui.ImageByteFormat.png))!.buffer
                  .asUint8List(),
            );
        picture.dispose();
      });
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(urls.single, endsWith('GlobalSend-1.0.30-windows-x64.zip'));
      await tester.tap(find.byTooltip('稍后'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-notice')), findsNothing);
      updates.setForeground(false);
      await updates.check(manual: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-notice')), findsNothing);
      updates.setForeground(true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('update-notice')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      updates.dispose();
      focus.dispose();
      text.dispose();
      debugDisableShadows = oldShadows;
    },
  );
}
