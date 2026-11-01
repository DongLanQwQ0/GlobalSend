import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/copied_files.dart';
import 'package:globalsend/copied_files_view.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_tokens.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    debugPrintSynchronously('copied-file fonts begin');
    await loadSystemTestFonts();
    debugPrintSynchronously('copied-file fonts ready');
  });
  testWidgets(
    'remote roots are separate click-to-pull tiles, become busy, and dismiss without changing files',
    (tester) async {
      final capture = GlobalKey();
      debugPrintSynchronously('copied-file view body');
      final requested = <String>[];
      final copied = CopiedFilesClient(
        newId: () => 'unused',
        sendFiles: (_, _) async {},
        changed: () {},
      );
      copied.offers = [
        {
          'offerId': 'batch',
          'sourceDeviceId': 'source',
          'sourceName': 'DongLan',
          'items': [
            {'id': 'image', 'name': 'picture.jpg', 'kind': 'file'},
            {'id': 'folder', 'name': 'Course files', 'kind': 'directory'},
          ],
        },
      ];
      final appearance = Ui.theme(
        const Appearance(mode: AppearanceMode.dark, accent: AccentColor.rose),
      );
      Widget page() => MaterialApp(
        // The test host installs Ahem on button labels. Render with the actual
        // loaded system face instead, without adding a product font asset.
        theme: appearance.copyWith(
          textTheme: appearance.textTheme.apply(fontFamily: 'Segoe UI'),
          textButtonTheme: TextButtonThemeData(
            style: appearance.textButtonTheme.style!.copyWith(
              textStyle: WidgetStatePropertyAll(
                Ui.label.copyWith(fontFamily: 'Segoe UI'),
              ),
            ),
          ),
        ),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 420,
                child: CopiedFileOffers(
                  client: copied,
                  onPull: (offer, id) async {
                    requested.add(id);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('picture.jpg'), findsOneWidget);
      expect(find.text('Course files'), findsOneWidget);
      expect(requested, isEmpty);
      await tester.tap(find.text('Course files'));
      await tester.pump();
      expect(requested, ['folder']);
      copied.pulls['request'] = {
        'offerId': 'batch',
        'itemIds': ['folder'],
        'state': 'pending',
      };
      await tester.pumpWidget(page());
      await tester.pump();
      expect(find.text('正在准备'), findsOneWidget);
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('copied-file-batch-folder')),
      );
      expect(button.onPressed, isNull);
      copied.pulls.clear();
      copied.dismiss('copied:source:batch:image');
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('picture.jpg'), findsNothing);
      expect(find.text('Course files'), findsOneWidget);
      await tester.runAsync(() async {
        debugPrintSynchronously('copied-file view readback');
        final image =
            await (capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final directory = await Directory(
          '../artifacts/tmp/copied-files-client/render',
        ).create(recursive: true);
        await File('${directory.path}/offers.rgba')
            .writeAsBytes(bytes!.buffer.asUint8List());
        await File('${directory.path}/offers.json').writeAsString(
          jsonEncode({'width': image.width, 'height': image.height}),
        );
        image.dispose();
        debugPrintSynchronously('copied-file view readback complete');
      });
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
  testWidgets(
    'file push requires an explicit target and preserves that choice when switched off',
    (tester) async {
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemBridge.channel,
        (call) async => call.method == 'windowVisible'
            ? true
            : call.method == 'clipboardFilePaths'
            ? <String>[]
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final c = fixture.signedIn()
        ..info = {
          'features': {'copiedFiles': true},
        };
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final scroll = find
          .descendant(
            of: find.byKey(const ValueKey('settings-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      final toggle = find.byKey(const ValueKey('copied-files-enabled'));
      await tester.scrollUntilVisible(toggle, 350, scrollable: scroll);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNull);
      expect(c.copiedFiles.enabled, isFalse);
      final dropdown = find.byKey(const ValueKey('copied-files-target-null'));
      await Scrollable.ensureVisible(tester.element(dropdown));
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的手机').last);
      await tester.pumpAndSettle();
      expect(c.copiedFiles.targets, ['phone']);
      expect(c.copiedFiles.enabled, isFalse);
      await Scrollable.ensureVisible(tester.element(toggle), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.copiedFiles.enabled, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.copiedFiles.enabled, isFalse);
      expect(c.copiedFiles.targets, ['phone']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
