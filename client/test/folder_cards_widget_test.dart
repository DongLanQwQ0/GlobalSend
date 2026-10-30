import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/compact_content_card.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  for (final mobile in [false, true]) {
    testWidgets(
      'a 2000-file folder renders one ${mobile ? 'mobile' : 'desktop'} card',
      (tester) async {
        tester.view.physicalSize = mobile
            ? const Size(400, 850)
            : const Size(950, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          SystemBridge.channel,
          (call) async => call.method == 'windowVisible' ? true : null,
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
        );
        final c = fixture.signedIn();
        c.dock.add(
          DockEntry(
            id: 'folder',
            fileId: 'folder',
            kind: 'file',
            title: '课程资料',
            source: 'phone',
            transferId: 'tree',
            relativePath: '课程资料',
            entryKind: 'directory',
            status: 'received',
            createdAtMillis: 123,
          ),
        );
        for (var i = 0; i < 2000; i++)
          c.dock.add(
            DockEntry(
              id: 'f$i',
              fileId: 'f$i',
              kind: 'file',
              title: '内部文件$i.txt',
              source: 'phone',
              transferId: 'tree',
              relativePath: '课程资料/内部文件$i.txt',
              size: 100,
              status: 'received',
              createdAtMillis: 123,
            ),
          );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: GlobalSendApp(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        if (mobile) {
          await tester.tap(find.widgetWithText(NavigationDestination, '接收'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(CompactContentCard), findsOneWidget);
        expect(find.text('课程资料'), findsOneWidget);
        expect(find.textContaining('内部文件'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final folder = await Directory('../artifacts/screenshots/folder58')
              .create(recursive: true);
          await File('${folder.path}/${mobile ? 'mobile' : 'desktop'}.png')
              .writeAsBytes(
                (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
                    .asUint8List(),
              );
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant.only(
        mobile ? TargetPlatform.android : TargetPlatform.windows,
      ),
    );
  }
}
