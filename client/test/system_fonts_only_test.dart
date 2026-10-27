import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_icon.dart';
import 'package:globalsend/app_icon_paths.dart';
import 'package:globalsend/ui_tokens.dart';

import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  test(
    'asset manifest carries no text or icon font and no font dependency',
    () async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      expect(manifest, isEmpty);
      final pubspec = await File('pubspec.yaml').readAsString();
      expect(pubspec, contains('uses-material-design: false'));
      expect(pubspec, isNot(contains('cupertino_icons:')));
      final bundled = await Directory('assets')
          .list(recursive: true)
          .where(
            (entity) =>
                entity is File &&
                RegExp(
                  r'\.(?:ttf|otf|woff2?|ttc)$',
                  caseSensitive: false,
                ).hasMatch(entity.path),
          )
          .toList();
      expect(bundled, isEmpty);
    },
  );
  testWidgets(
    'all static icon paths render without glyph text, including framework back and expansion controls',
    (tester) async {
      tester.view.physicalSize = const Size(860, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey(), navigator = GlobalKey<NavigatorState>();
      Widget icons() => Wrap(
        children: appIconSymbols
            .map(
              (code) => Padding(
                padding: const EdgeInsets.all(7),
                child: AppIcon(code, size: 28, color: Ui.green),
              ),
            )
            .toList(),
      );
      Widget details() => Scaffold(
        appBar: AppBar(title: const Text('系统字体 · 矢量图标')),
        body: Column(
          children: [
            Expanded(child: icons()),
            const AppExpansionTile(
              title: Text('展开'),
              children: [Text('文字直接使用操作系统字体')],
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: Ui.theme(),
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => navigator.currentState!.push(
                  MaterialPageRoute<void>(builder: (_) => details()),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BackButton),
          matching: find.byIcon(Icons.arrow_back),
        ),
        findsOneWidget,
      );
      for (final icon in tester.widgetList<Icon>(
        find.byWidgetPredicate((widget) => widget is Icon),
      )) {
        expect(icon, isA<AppIcon>());
      }
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: Ui.theme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'GlobalSend · 系统字体',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      children: appIconSymbols
                          .map(
                            (code) => Padding(
                              padding: const EdgeInsets.all(7),
                              child: AppIcon(code, size: 28, color: Ui.green),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 16),
                    const Text('发送  接收  文件  历史   ABC 123'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('../artifacts/reports/system-fonts-only')
            .create(recursive: true);
        await File('../artifacts/reports/system-fonts-only/vector-grid.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
