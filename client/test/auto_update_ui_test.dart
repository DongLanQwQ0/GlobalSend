import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_update_ui.dart';
import 'package:globalsend/app_updates.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/github_updates.dart';
import 'package:globalsend/ui_tokens.dart';

import 'app_updates_test.dart' show Feed;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  for (final (platform, size, appearance) in [
    (UpdatePlatform.android, const Size(390, 844), const Appearance()),
    (
      UpdatePlatform.windows,
      const Size(950, 650),
      const Appearance(mode: AppearanceMode.dark, accent: AccentColor.rose),
    ),
  ]) {
    testWidgets('automatic update controls fit ${platform.name}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final updates = AppUpdates(
        build: AppBuildInfo(
          platform: platform,
          architecture: '',
          version: const AppReleaseVersion(1, 0, 78, 102),
        ),
        feed: Feed(),
      );
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: AppUpdatesScope(
            updates: updates,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: Ui.theme(appearance),
              home: Scaffold(
                appBar: AppBar(title: const Text('更新')),
                body: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: const UpdateCheckControl(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('自动检查更新'), findsOneWidget);
      expect(find.text('自动下载并更新'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('auto-install-updates')));
      await tester.pumpAndSettle();
      expect(updates.autoDownload, isFalse);
      await tester.tap(find.byKey(const ValueKey('auto-install-updates')));
      await tester.pumpAndSettle();
      expect(updates.autoDownload, isTrue);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        final file = File(
          '../artifacts/tmp/automatic-updates103/ui-${platform.name}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      updates.dispose();
    });
  }
}
