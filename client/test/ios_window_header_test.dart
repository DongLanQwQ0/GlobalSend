import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/ios_window_header.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/saved_image_preview.dart';
import 'package:globalsend/shared_import_notice.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/text_viewer.dart';
import 'package:globalsend/ui_tokens.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await loadSystemTestFonts();
    // The Windows test renderer has no Apple system font. Alias its installed
    // system face only for this iPad layout render; no font enters app assets.
    final file = File(
      '${Platform.environment['WINDIR'] ?? r'C:\Windows'}/Fonts/segoeui.ttf',
    );
    if (await file.exists()) {
      final loader = FontLoader('.AppleSystemUIFont')
        ..addFont(Future.value(ByteData.sublistView(await file.readAsBytes())));
      await loader.load();
    }
  });
  setUp(() {
    FileShareBridge.windowLayout.value = {
      'leading': 72.0,
      'trailing': 0.0,
      'controlsBottom': 48.0,
      'width': 390.0,
      'height': 720.0,
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      SystemBridge.channel,
      (call) async => call.method == 'windowVisible' ? true : null,
    );
    messenger.setMockMethodCallHandler(
      FileShareBridge.channel,
      (_) async => null,
    );
  });
  tearDown(() {
    FileShareBridge.windowLayout.value = const {};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemBridge.channel, null);
    messenger.setMockMethodCallHandler(FileShareBridge.channel, null);
  });
  Future<void> viewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final directory = Directory('../artifacts/tmp/ios-native-20261102');
      await directory.create(recursive: true);
      await File('${directory.path}/$name.rgba')
          .writeAsBytes(data!.buffer.asUint8List());
      await File('${directory.path}/$name.json').writeAsString(
        jsonEncode({'width': image.width, 'height': image.height}),
      );
      image.dispose();
    });
  }

  testWidgets(
    'native window metrics inset the header but leave content full width and update on resize',
    (tester) async {
      await viewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: Scaffold(
            appBar: AppBar(
              leading: const BackButton(),
              title: const Text('图片详情'),
            ).windowSafe(),
            body: const SizedBox.expand(key: ValueKey('full-width-content')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(BackButton)).left,
        greaterThanOrEqualTo(72),
      );
      final leadingWithControls = tester.getRect(find.byType(BackButton)).left;
      expect(
        tester.getRect(find.byKey(const ValueKey('full-width-content'))).width,
        390,
      );
      FileShareBridge.windowLayout.value = const {};
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(BackButton)).left,
        leadingWithControls - 72,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('workspace and settings use one compact safe header', (
    tester,
  ) async {
    await viewport(tester);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GlobalSendApp(controller: fixture.signedIn()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(const ValueKey('local-ip-menu'))).left,
      greaterThanOrEqualTo(72),
    );
    expect(tester.getSize(find.byType(AppBar)).height, lessThanOrEqualTo(56));
    await capture(tester, key, 'ipad-workspace-header');
    await tester.tap(find.byTooltip('设置').first);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(BackButton)).left,
      greaterThanOrEqualTo(72),
    );
    await capture(tester, key, 'ipad-settings-header');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'connection, image and text detail titles respect window controls without moving low dialogs',
    (tester) async {
      await viewport(tester);
      await tester.pumpWidget(
        GlobalSendApp(controller: fixture.PreviewController()),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('local-ip-menu'))).left,
        greaterThanOrEqualTo(72),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: const SavedImagePreview(
            path: 'missing-test-image.png',
            title: '图片详情',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('图片详情')).left, greaterThanOrEqualTo(72));
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showTextViewer(
                    context,
                    title: '文本详情',
                    text: '保留正文的完整宽度。',
                  ),
                  child: const Text('打开文本'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开文本'));
      await tester.pumpAndSettle();
      final header = find.ancestor(
        of: find.text('文本详情'),
        matching: find.byType(IosWindowHeader),
      );
      expect(header, findsOneWidget);
      final padding = tester.widget<Padding>(
        find.descendant(
          of: header,
          matching: find.byKey(const ValueKey('ios-window-header-inset')),
        ),
      );
      final top = tester.getTopLeft(header).dy;
      expect(
        padding.padding.resolve(TextDirection.ltr).left,
        top >= 48 ? 0 : greaterThan(0),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'shared import notice reports actual committed count then queue preparation',
    (tester) async {
      await viewport(tester);
      final batches = ValueNotifier([
        SharedBatch(
          batchId: 'live',
          paths: [],
          texts: [],
          temporaryPaths: [],
          importing: true,
          completedItems: 1,
          totalItems: 3,
        ),
      ]);
      addTearDown(batches.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: SharedImportNotice(
            batches: batches,
            child: const Scaffold(body: Text('workspace')),
          ),
        ),
      );
      expect(find.text('正在导入 1/3 项'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        1 / 3,
      );
      batches.value = [
        SharedBatch(
          batchId: 'ready',
          paths: ['image.png'],
          texts: [],
          temporaryPaths: ['image.png'],
          completedItems: 3,
          totalItems: 3,
        ),
      ];
      await tester.pump();
      expect(find.text('正在加入待发送'), findsOneWidget);
      batches.value = [];
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('workspace'), findsOneWidget);
    },
  );
}
