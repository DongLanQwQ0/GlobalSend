import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/copied_files.dart';
import 'package:globalsend/copied_files_view.dart';
import 'package:globalsend/copied_file_reference_card.dart';
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
    'reference card uses the same theme and corner actions in workspace and dock',
    (tester) async {
      final capture = GlobalKey();
      tester.view.physicalSize = const Size(430, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                for (final mode in [
                  AppearanceMode.light,
                  AppearanceMode.dark,
                  AppearanceMode.neutral,
                ])
                  Expanded(
                    child: MaterialApp(
                debugShowCheckedModeBanner: false,
                      theme: Ui.theme(
                        Appearance(mode: mode, accent: AccentColor.purple),
                      ),
                      home: Scaffold(
                        body: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 202,
                                height: 64,
                                child: CopiedFileReferenceCard(
                                  compact: true,
                                  reference: const {
                                    'name': '课堂资料.pdf',
                                    'kind': 'file',
                                    'sourceName': 'DongLan',
                                    'state': '',
                                  },
                                  onPull: () {},
                                  onDismiss: () {},
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 136,
                                height: 136,
                                child: CopiedFileReferenceCard(
                                  reference: const {
                                    'name': 'Course files',
                                    'kind': 'directory',
                                    'sourceName': 'DongLan',
                                    'state': 'failed',
                                  },
                                  onPull: () {},
                                  onDismiss: () {},
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('忽略此条目'), findsNWidgets(6));
    expect(find.text('拉取失败'), findsNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
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
        await File('${directory.path}/reference-themes100.rgba')
            .writeAsBytes(bytes!.buffer.asUint8List());
        await File('${directory.path}/reference-themes100.json').writeAsString(
          jsonEncode({'width': image.width, 'height': image.height}),
        );
        image.dispose();
      });
    },
  );
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
      final folder = find.byKey(const ValueKey('copied-file-batch-folder'));
      expect(tester.widget<CopiedFileReferenceCard>(folder).compact, isTrue);
      final button = tester.widget<InkWell>(
        find.descendant(of: folder, matching: find.byType(InkWell)).first,
      );
      expect(button.onTap, isNull);
      await tester.tap(find.text('Course files'));
      await tester.pump();
      expect(requested, ['folder']);
      copied.pulls.clear();
      await tester.tap(find.byTooltip('忽略此条目').first);
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
    'device pickers are disabled while their switches are off and first activation does not choose a file target',
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
      c.appearance.value = const Appearance(
        mode: AppearanceMode.dark,
        accent: AccentColor.rose,
      );
      c.devices.add({
        'deviceId': 'browser',
        'name': '第二台设备',
        'online': true,
        'platform': 'web',
      });
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: GlobalSendApp(controller: c),
        ),
      );
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
      final textToggle = find.byKey(const ValueKey('clipboard-sync'));
      final textDropdown = find.byKey(const ValueKey('clipboard-target-phone'));
      await tester.scrollUntilVisible(textToggle, 350, scrollable: scroll);
      await tester.pumpAndSettle();
      expect(
        tester.widget<DropdownButtonFormField<String>>(textDropdown).onChanged,
        isNull,
      );
      await tester.tap(textToggle);
      await tester.pumpAndSettle();
      expect(c.clipboardEnabled, isTrue);
      expect(
        tester.widget<DropdownButtonFormField<String>>(textDropdown).onChanged,
        isNotNull,
      );
      await tester.ensureVisible(textDropdown);
      await tester.tap(textDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('第二台设备').last);
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(textToggle), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(textToggle);
      await tester.pumpAndSettle();
      expect(c.clipboardEnabled, isFalse);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const ValueKey('clipboard-target-browser')),
            )
            .onChanged,
        isNull,
      );
      await tester.scrollUntilVisible(toggle, 350, scrollable: scroll);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).onChanged, isNotNull);
      expect(c.copiedFiles.enabled, isFalse);
      final dropdown = find.byKey(const ValueKey('copied-files-target-null'));
      expect(
        tester.widget<DropdownButtonFormField<String>>(dropdown).onChanged,
        isNull,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.copiedFiles.enabled, isTrue);
      expect(c.copiedFiles.targets, isEmpty);
      expect(
        tester.widget<DropdownButtonFormField<String>>(dropdown).onChanged,
        isNotNull,
      );
      await Scrollable.ensureVisible(tester.element(dropdown));
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的手机').last);
      await tester.pumpAndSettle();
      expect(c.copiedFiles.targets, ['phone']);
      expect(c.copiedFiles.enabled, isTrue);
      await Scrollable.ensureVisible(tester.element(toggle), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.copiedFiles.enabled, isFalse);
      expect(c.copiedFiles.targets, ['phone']);
      final selected = find.byKey(const ValueKey('copied-files-target-phone'));
      expect(
        tester.widget<DropdownButtonFormField<String>>(selected).onChanged,
        isNull,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.copiedFiles.enabled, isTrue);
      expect(c.copiedFiles.targets, ['phone']);
      expect(
        tester.widget<DropdownButtonFormField<String>>(selected).onChanged,
        isNotNull,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(textToggle));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final directory = await Directory(
          '../artifacts/tmp/copied-files-client/render',
        ).create(recursive: true);
        await File('${directory.path}/switch-targets99.rgba')
            .writeAsBytes(data!.buffer.asUint8List());
        await File('${directory.path}/switch-targets99.json').writeAsString(
          jsonEncode({'width': image.width, 'height': image.height}),
        );
        image.dispose();
      });
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
