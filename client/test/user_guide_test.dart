import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/user_guide_screen.dart';

import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);

  testWidgets(
    'Android guide changes task and Escape returns without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: Ui.theme(const Appearance()),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const UserGuideScreen(platform: 'android'),
                  ),
                ),
                child: const Text('指南'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('指南'));
      await tester.pumpAndSettle();
      expect(find.text('Android'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guide-topic-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-section-2')), findsOneWidget);
      expect(find.textContaining('3 秒'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('指南'), findsOneWidget);
      expect(find.text('使用指南'), findsNothing);
    },
  );

  for (final (platform, size, appearance) in [
    ('android', const Size(390, 844), const Appearance()),
    (
      'windows',
      const Size(950, 650),
      const Appearance(mode: AppearanceMode.dark, accent: AccentColor.rose),
    ),
    ('ipad', const Size(768, 1024), const Appearance()),
  ]) {
    testWidgets('render guide $platform', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: Ui.theme(appearance),
            home: UserGuideScreen(platform: platform),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (platform == 'android') {
        await tester.tap(find.byKey(const ValueKey('guide-topic-1')));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final file = File('../artifacts/tmp/platform-guides102/$platform.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
}
