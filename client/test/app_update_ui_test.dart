import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_update_ui.dart';
import 'package:globalsend/app_updates.dart';
import 'package:globalsend/github_updates.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/system_bridge.dart';

import 'app_updates_test.dart' show Feed, service;
import 'github_updates_test.dart' show asset, release;
import 'system_font_fixture.dart';
import 'auto_update_engine_test.dart' as engine;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'waiting native helper disables install and keeps cancel in the same action row',
    (tester) async {
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      late AppUpdates updates;
      await tester.runAsync(() async {
        updates = AppUpdates(
          build: engine.build(UpdatePlatform.windows),
          feed: engine.feed(UpdatePlatform.windows),
          automaticDownload: false,
          downloader: engine.DownloadFixture(),
          cancelInstall: ({required automaticOnly}) async {},
          install: (_, __, {required explicit}) async => {'state': 'started'},
        );
        await updates.initialize(await engine.stateFile());
        await updates.check();
        await updates.downloadAndInstall(explicit: true);
      });
      expect(updates.installing, isFalse);
      expect(updates.installPending, isTrue);
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: AppUpdatesScope(
            updates: updates,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: Ui.theme(),
              home: Scaffold(
                appBar: AppBar(title: const Text('更新')),
                body: const Center(
                  child: SizedBox(
                    width: 600,
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: UpdateCheckControl(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final install = find.byKey(const ValueKey('install-update'));
      final cancel = find.byKey(const ValueKey('cancel-update'));
      expect(tester.widget<TextButton>(install).onPressed, isNull);
      expect(find.text('更新中…'), findsOneWidget);
      expect(tester.getCenter(install).dy, tester.getCenter(cancel).dy);
      await tester.runAsync(() async {
        final picture =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
        picture.dispose();
        final file = File('../artifacts/tmp/completion105/update-waiting.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.runAsync(updates.cancelUpdate);
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(install).onPressed, isNotNull);
      expect(cancel, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      updates.dispose();
    },
  );
  testWidgets(
    'manual iPad update preserves editing focus and opens only its IPA',
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
          release('v1.0.30', [asset('GlobalSend-1.0.30.ipa')]),
        ];
      final updates = service(feed, platform: UpdatePlatform.ios),
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
      await tester.tap(find.text('下载 IPA').first);
      await tester.pumpAndSettle();
      expect(urls.single, endsWith('GlobalSend-1.0.30.ipa'));
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
