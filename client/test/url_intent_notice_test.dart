import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Center;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/url_intent_notice.dart';
import 'package:globalsend/url_intents.dart';
import 'package:globalsend/ui_tokens.dart';

import 'system_font_fixture.dart';
import 'url_intents_test.dart' show Center, intent, id, clock;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'interrupted webpage recovery stays compact and does not steal input focus',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        debugDisableShadows = oldShadows;
      });
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = Center(),
          rebuild = ValueNotifier(0),
          focus = FocusNode(),
          capture = GlobalKey();
      late UrlIntentIntegration integration;
      await tester.runAsync(() async {
        final base = Directory('build/test-tmp/url-intent-notice');
        await base.create(recursive: true);
        final folder = await base.createTemp('case-'),
            file = File('${folder.path}/intents.json');
        await file.writeAsString(
          jsonEncode({
            'records': {
              'scope\nsource\n$id': {
                ...intent(),
                'scope': 'scope',
                'stage': 'launching',
              },
            },
          }),
        );
        integration = UrlIntentIntegration(
          session: () => UrlIntentSession(
            api: api,
            scope: 'scope',
            deviceId: 'target',
            supported: true,
          ),
          devices: () => [],
          refreshDevices: () async {},
          changed: () => rebuild.value++,
          platform: 'windows',
          now: () => clock,
          openWebUrl: (_) async {},
        );
        await integration.initialize(file);
        await integration.synchronize();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: Ui.theme(),
            builder: (context, child) => ValueListenableBuilder(
              valueListenable: rebuild,
              builder: (_, _, _) =>
                  UrlIntentNotice(integration: integration, child: child!),
            ),
            home: Scaffold(
              appBar: AppBar(
                title: const Text(
                  'GlobalSend',
                  style: TextStyle(fontFamily: 'Segoe UI'),
                ),
              ),
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: TextField(focusNode: focus),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '保留编辑中的内容');
      await tester.pumpAndSettle();
      expect(focus.hasFocus, true);
      expect(find.text('网页请求等待打开'), findsOneWidget);
      await tester.runAsync(() async {
        final picture =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        await File('../artifacts/screenshots/url-intent-notice.png')
            .writeAsBytes(
              (await picture.toByteData(format: ui.ImageByteFormat.png))!.buffer
                  .asUint8List(),
            );
        picture.dispose();
      });
      tester.view.physicalSize = const Size(320, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await integration.dismiss(integration.needsAttention.single);
      });
      await tester.pumpAndSettle();
      expect(find.text('网页请求等待打开'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      integration.dispose();
      api.close();
      focus.dispose();
      rebuild.dispose();
      debugDefaultTargetPlatformOverride = null;
      debugDisableShadows = oldShadows;
    },
  );
}
