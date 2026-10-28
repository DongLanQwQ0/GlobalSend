import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files_screen.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_session.dart';
import 'package:globalsend/ui_tokens.dart';

import 'native_header_menu_layout_test.dart' show LibraryFixture;
import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemBridge.channel,
          (call) async => call.method == 'windowVisible' ? true : null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemBridge.channel, null);
  });
  LibraryFixture controller() {
    final original = fixture.signedIn();
    return LibraryFixture()
      ..api = original.api
      ..profile = original.profile
      ..devices = original.devices
      ..connected = true
      ..dock.addAll([
        DockEntry(
          id: 'received',
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '接收内容',
        ),
        DockEntry(
          id: 'sent',
          kind: 'file',
          title: 'sent.bin',
          source: 'self',
          outgoing: true,
          status: 'sent',
          localPath: 'F:/example/sent.bin',
        ),
      ]);
  }

  Future<GlobalKey> mount(WidgetTester tester, Widget child, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    final base = Ui.theme();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: base.copyWith(
            appBarTheme: base.appBarTheme.copyWith(
              titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
          ),
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('../artifacts/screenshots').create(recursive: true);
      await File('../artifacts/screenshots/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'content toolbars match accepted receipt spacing and do not grow in selection on ${platform.name}',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final mobile = platform == TargetPlatform.android,
            size = mobile ? const Size(390, 844) : const Size(950, 650);
        for (var tab = 0; tab < 3; tab++) {
          final key = await mount(
            tester,
            SendScreen(
              controller: controller(),
              session: SendUiSession()
                ..page = 0
                ..contentTab = tab,
            ),
            size,
          );
          final toolbar = find.byKey(
            ValueKey(
              ['receive-toolbar', 'sent-toolbar', 'library-toolbar'][tab],
            ),
          );
          final before = tester.getRect(toolbar);
          expect(
            before.height,
            48,
            reason: '44px existing drag hit area +2px accepted receipt padding each side',
          );
          final multi = find.descendant(
            of: toolbar,
            matching: find.widgetWithText(TextButton, '多选'),
          );
          expect(multi, findsOneWidget);
          expect(tester.getSize(multi).height, 36);
          await capture(
            tester,
            key,
            'content-toolbar-${platform.name}-$tab-normal',
          );
          await tester.tap(multi);
          await tester.pumpAndSettle();
          expect(
            tester.getRect(toolbar),
            before,
            reason: 'Selection actions must not move or grow the toolbar',
          );
          final buttons = find.descendant(
            of: toolbar,
            matching: find.byType(TextButton),
          );
          for (final button in buttons.evaluate()) {
            expect(tester.getSize(find.byWidget(button.widget)).height, 36);
          }
          final all = find.descendant(
            of: toolbar,
            matching: find.widgetWithText(TextButton, '全选'),
          );
          expect(all, findsOneWidget);
          await tester.tap(all);
          await tester.pumpAndSettle();
          expect(tester.getRect(toolbar), before);
          expect(
            find.descendant(of: toolbar, matching: find.text('取消全选')),
            findsOneWidget,
          );
          await capture(
            tester,
            key,
            'content-toolbar-${platform.name}-$tab-selected',
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
      variant: TargetPlatformVariant.only(platform),
    );
    testWidgets(
      'standalone file toolbar stays compact while editing on ${platform.name}',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final key = await mount(
          tester,
          SavedFilesScreen(controller: controller()),
          platform == TargetPlatform.android
              ? const Size(390, 844)
              : const Size(950, 650),
        );
        final toolbar = find.byKey(const ValueKey('library-toolbar'));
        final before = tester.getRect(toolbar);
        expect(before.height, 48);
        await tester.tap(find.widgetWithText(TextButton, '编辑'));
        await tester.pumpAndSettle();
        expect(tester.getRect(toolbar), before);
        expect(find.text('重命名'), findsOneWidget);
        expect(find.text('删除'), findsOneWidget);
        expect(find.text('转发'), findsOneWidget);
        await capture(
          tester,
          key,
          'content-toolbar-${platform.name}-standalone-selected',
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('编辑'), findsOneWidget);
        expect(tester.getRect(toolbar), before);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}
