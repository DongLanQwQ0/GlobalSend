import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/receive_dock_window.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(
    () => messenger.setMockMethodCallHandler(
      SystemBridge.channel,
      (call) async => call.method == 'windowVisible' ? true : null,
    ),
  );
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
  );

  testWidgets('follow-system changes live without replacing local editors', (
    tester,
  ) async {
    final c = fixture.signedIn();
    c.stagedTexts.add('保留输入');
    await c.appearance.set(
      mode: AppearanceMode.system,
      accent: AccentColor.purple,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(GlobalSendApp(controller: c));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );
    expect(c.appearance.value.mode, AppearanceMode.system);
    expect(c.stagedTexts, ['保留输入']);
    await c.appearance.set(mode: AppearanceMode.neutral);
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.light,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('appearance persists separately from group and all palette text is readable', () async {
    final file = File('../artifacts/tmp/appearance-test/settings.json');
    await file.parent.create(recursive: true);
    if (await file.exists()) await file.delete();
    final settings = AppearanceSettings();
    await settings.load(file);
    await Future.wait([
      settings.set(mode: AppearanceMode.dark),
      settings.set(accent: AccentColor.blue),
      settings.set(mode: AppearanceMode.neutral, accent: AccentColor.purple),
    ]);
    final restored = AppearanceSettings();
    await restored.load(file);
    expect(restored.value.toJson(), {'mode': 'neutral', 'accent': 'purple'});
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
    }

    for (final mode in AppearanceMode.values) {
      for (final accent in AccentColor.values) {
        final p = UiPalette.from(Appearance(mode: mode, accent: accent));
        expect(contrast(p.ink, p.surface), greaterThan(7));
        expect(contrast(p.muted, p.input), greaterThan(4.5));
        expect(contrast(p.green, p.surface), greaterThan(4.5));
        expect(contrast(p.green, p.onAccent), greaterThan(4.5));
        final baseline = UiPalette.from(Appearance(mode: mode));
        expect(
          p.background,
          baseline.background,
          reason: 'The page canvas is neutral, not a fixed green wash.',
        );
        if (accent != AccentColor.green) {
          expect(p.softGreen, isNot(baseline.softGreen));
          if (mode != AppearanceMode.neutral)
            expect(
              p.input,
              isNot(baseline.input),
              reason: 'Input, shared text and preview surfaces derive from the chosen accent.',
            );
        }
      }
    }
    settings.dispose();
    restored.dispose();
  });

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) =>
      tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../artifacts/screenshots/themes/native-$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'live appearance keeps drafts, shared editor and navigator on ${platform.name}',
      (tester) async {
        tester.view.physicalSize = platform == TargetPlatform.windows
            ? const Size(950, 650)
            : const Size(412, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = fixture.signedIn();
        c.stagedTexts.add('保留这条待发送内容');
        c.dock = [
          DockEntry(
            id: 'receipt',
            kind: 'text',
            title: '文本',
            source: 'phone',
            text: '图片与文字预览保持原色。',
          ),
        ];
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: GlobalSendApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        for (final mode in AppearanceMode.values) {
          await c.appearance.set(mode: mode, accent: AccentColor.blue);
          await tester.pumpAndSettle();
          expect(c.stagedTexts.single, '保留这条待发送内容');
          expect(c.sharedText, '集合时间：周六上午 9:00');
          expect(c.initializations, 1);
          expect(find.byType(ColorFiltered), findsNothing);
          final scaffold = find.byType(Scaffold).first;
          expect(
            Theme.of(tester.element(scaffold)).brightness,
            mode == AppearanceMode.dark ? Brightness.dark : Brightness.light,
          );
          await capture(tester, key, '${platform.name}-${mode.name}');
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('暗色').first);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('accent-purple')));
        await tester.pumpAndSettle();
        expect(c.appearance.value.mode, AppearanceMode.dark);
        expect(c.appearance.value.accent, AccentColor.purple);
        if (platform == TargetPlatform.android) {
          final y = tester
              .getTopLeft(find.byKey(const ValueKey('accent-green')))
              .dy;
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('accent-slate'))).dy,
            y,
            reason: 'All six swatches fit on one line at ordinary phone width.',
          );
        }
        await capture(tester, key, '${platform.name}-settings');
        expect(c.stagedTexts.single, '保留这条待发送内容');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
  testWidgets('UI-only receive dock takes theme from main engine payload', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 184);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    messenger.setMockMethodCallHandler(
      ReceiveDockApp.channel,
      (call) async => call.method == 'ready'
          ? {
              'serial': 1,
              'arrivalGeneration': 1,
              'appearance': {'mode': 'dark', 'accent': 'blue'},
              'items': [
                DockEntry(
                  id: 'dock',
                  kind: 'text',
                  source: 'phone',
                  text: '暗色接收坞',
                  title: '文本',
                ).toJson(),
              ],
            }
          : null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: key, child: const ReceiveDockApp()),
    );
    await tester.pumpAndSettle();
    final scaffold = find.byKey(const ValueKey('dock-pane'));
    expect(Theme.of(tester.element(scaffold)).brightness, Brightness.dark);
    await capture(tester, key, 'dock-dark');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
