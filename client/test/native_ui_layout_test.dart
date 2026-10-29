import 'system_font_fixture.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receipt_preview.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/text_viewer.dart';

import 'widget_test.dart' as fixture;
import 'credential_recovery_screen_test.dart' as recovery;

class DensityController extends fixture.PreviewController {
  DensityController() {
    final base = fixture.signedIn();
    api = base.api;
    profile = base.profile;
    devices = base.devices;
    connected = true;
  }
  @override
  Future<void> refreshSavedFiles({bool cleanup = false}) async {}
}

void main() {
  setUpAll(loadSystemTestFonts);
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemBridge.channel,
          (call) async => call.method == 'windowVisible' ? true : null,
        );
  });
  Future<GlobalKey> show(
    WidgetTester tester,
    Widget app,
    Size size, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: key, child: app));
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../artifacts/screenshots/native-ui-1.0.12-$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final size in [const Size(934, 611), const Size(390, 844)]) {
    testWidgets(
      'multiple groups use one compact shared selector ${size.width}',
      (tester) async {
        final c = fixture.signedIn();
        c.info = {
          'features': {'multiGroup': true, 'groupSharedText': true},
        };
        c.profile!.groupId = 'first';
        c.profile!.groups = [
          {'groupId': 'first', 'name': '我的设备'},
          {'groupId': 'second', 'name': '朋友'},
        ];
        final key = await show(tester, GlobalSendApp(controller: c), size);
        expect(
          find.byKey(const ValueKey('shared-group-selector')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await capture(tester, key, 'multi-groups-${size.width.toInt()}');
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('加入分组'),400,scrollable:find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(find.text('退出此组'), findsNothing);
        expect(find.byTooltip('退出此组'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await capture(
          tester,
          key,
          'multi-group-settings-${size.width.toInt()}',
        );
        await tester.tap(find.text('加入分组'));
        await tester.pumpAndSettle();
        expect(find.text('名称（可选）'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture(tester, key, 'multi-group-join-${size.width.toInt()}');
      },
    );
  }

  for (final size in [const Size(934, 611), const Size(390, 844)]) {
    testWidgets(
      'connection external labels and recoverable identity ${size.width}',
      (tester) async {
        final key = await show(
          tester,
          GlobalSendApp(controller: fixture.PreviewController()),
          size,
        );
        expect(find.text('设备名称'), findsOneWidget);
        expect(find.text('更多'), findsNothing);
        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('server-address')),
        );
        expect(field.decoration!.labelText, isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('group-password'))).height,
          greaterThanOrEqualTo(56),
        );
        await capture(tester, key, 'connection-${size.width.toInt()}');
        await tester.pumpWidget(const SizedBox());
        final recovered = await show(
          tester,
          GlobalSendApp(controller: recovery.RecoveryUiController()),
          size,
          scale: 1.3,
        );
        final server = tester.widget<TextField>(
          find.byKey(const ValueKey('server-address')),
        );
        expect(server.readOnly, isTrue);
        expect(server.enabled, isTrue);
        await tester.ensureVisible(
          find.byKey(const ValueKey('credential-diagnostics')),
        );
        await capture(
          tester,
          recovered,
          'recovery-${size.width.toInt()}-large',
        );
        await tester.tap(find.byKey(const ValueKey('credential-diagnostics')));
        await tester.pumpAndSettle();
        expect(
          tester
                  .widget<AlertDialog>(find.byType(AlertDialog))
                  .backgroundColor ??
              Ui.theme().dialogTheme.backgroundColor,
          Colors.white,
        );
        await capture(tester, recovered, 'diagnostics-${size.width.toInt()}');
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final scale in [1.0, 1.3]) {
    testWidgets(
      'compact workspace keeps long and recently offline devices readable $scale',
      (tester) async {
        final c = fixture.signedIn()..stagedTexts.add('长文本预览 😀\n下一行内容');
        c.devices[0]['name'] = '我的手机 vivo X300 Pro Max';
        c.devices.add({
          'deviceId': 'away',
          'name': '暂时离开的平板',
          'online': false,
          'lastSeen': DateTime.now().toUtc().toIso8601String(),
        });
        c.recentDevices.deadlines['away'] = c.discoveryNow() + 30000;
        final key = await show(
          tester,
          GlobalSendApp(controller: c),
          const Size(934, 611),
          scale: scale,
        );
        expect(
          find.byKey(const ValueKey('send-workspace-scroll')),
          findsNothing,
        );
        expect(find.text('添加文件'), findsOneWidget);
        expect(
          tester
              .getBottomRight(find.byKey(const ValueKey('shared-text-panel')))
              .dy,
          lessThan(611),
        );
        expect(find.text('设备 2'), findsOneWidget);
        await capture(tester, key, 'workspace-$scale');
        await tester.tap(find.byKey(const ValueKey('add-text')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('draft-input')),
          '准备发送的内容\n包含完整正文与链接 https://example.invalid',
        );
        await tester.pumpAndSettle();
        await capture(tester, key, 'compose-$scale');
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'phone send workspace and settings dropdown retain large text hierarchy',
    (tester) async {
      final c = fixture.signedIn()..stagedTexts.add('可预览的待发送内容');
      c.profile = ServerProfile(
        baseUrl: 'https://123.207.180.163/globalsend',
        instanceId: 'preview',
        deviceId: 'self',
        name: '原设备',
      );
      debugPrint('ui-phone: before mount');
      final key = await show(
        tester,
        GlobalSendApp(controller: c),
        const Size(390, 844),
        scale: 1.3,
      );
      debugPrint('ui-phone: mounted');
      await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
      await tester.pumpAndSettle();
      debugPrint('ui-phone: send mounted');
      await capture(tester, key, 'send-phone-large');
      debugPrint('ui-phone: send captured');
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('device-name-input'));
      debugPrint('ui-phone: settings mounted');
      expect(find.byKey(const ValueKey('save-device-name')), findsNothing);
      await tester.enterText(name, '书房电脑');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('save-device-name')), findsOneWidget);
      await capture(tester, key, 'settings-focused-phone-large');
      await tester.scrollUntilVisible(
        find.text('发送方式'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final dropdown = find.byType(DropdownButtonFormField<String>).first;
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.text('局域网'), findsOneWidget);
      await capture(tester, key, 'settings-dropdown-phone-large');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'connection errors and long read-only body keep padded readable controls',
    (tester) async {
      final c = fixture.PreviewController()..message = '连接失败，请检查服务器地址';
      final key = await show(
        tester,
        GlobalSendApp(controller: c),
        const Size(390, 844),
        scale: 1.3,
      );
      await tester.tap(find.byKey(const ValueKey('server-address')));
      await tester.pumpAndSettle();
      await capture(tester, key, 'connection-error-phone-large');
      expect(find.text('连接失败，请检查服务器地址'), findsOneWidget);
      final copied = <String>[];
      final body = List.filled(
        25,
        '完整正文、选择与复制。打开链接 https://example.invalid 😀',
      ).join('\n');
      await tester.pumpWidget(const SizedBox());
      final readerKey = await show(
        tester,
        MaterialApp(
          theme: Ui.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showTextViewer(
                    context,
                    title: '收到的文本',
                    text: body,
                    onCopy: (value) async {
                      copied.add(value);
                    },
                  ),
                  child: const Text('查看'),
                ),
              ),
            ),
          ),
        ),
        const Size(934, 611),
        scale: 1.3,
      );
      await tester.tap(find.text('查看'));
      await tester.pumpAndSettle();
      await capture(tester, readerKey, 'reader-long-large');
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, [body]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'received batch footer stays inside each card at large phone scale',
    (tester) async {
      final c = fixture.signedIn();
      final key = await show(
        tester,
        GlobalSendApp(controller: c),
        const Size(390, 844),
        scale: 1.3,
      );
      c.dock.addAll(
        List.generate(
          5,
          (i) => DockEntry(
            id: 'batch$i',
            kind: 'text',
            title: '文本',
            source: 'phone',
            text: '第 $i 项\n真实正文内容 😀',
            status: 'received',
          ),
        ),
      );
      c.changed();
      c.latestReceipt = c.dock[1];
      c.pendingReceipts[c.dock[0].id] = c.dock[0];
      c.pendingReceipts[c.dock[1].id] = c.dock[1];
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byType(ReceivedBatchPreview), findsOneWidget);
      await capture(tester, key, 'batch-phone-large');
      expect(tester.takeException(), isNull);
    },
  );
  for (final scale in [1.0, 1.3]) {
    testWidgets(
      'phone compact header four destinations animate without duplicate tabs $scale',
      (tester) async {
        final c = DensityController()..stagedTexts.add('待发送草稿');
        final key = await show(
          tester,
          GlobalSendApp(controller: c),
          const Size(390, 844),
          scale: scale,
        );
        final bar = tester.getRect(find.byType(AppBar));
        expect(bar.height, 48);
        final tools = [
          'add-text',
          'add-clipboard',
          'add-file',
          'add-media',
        ].map((key) => tester.getRect(find.byKey(ValueKey(key)))).toList();
        expect(tools.every((rect) => rect.top == tools.first.top), isTrue);
        expect(tools.every((rect) => rect.height >= 44), isTrue);
        expect(tools.first.top - bar.bottom, lessThanOrEqualTo(16));
        await capture(tester, key, 'mobile-actions-one-row-$scale');
        expect(find.byType(NavigationDestination), findsNWidgets(4));
        final labels = ['发送', '接收', '历史', '文件'];
        for (var index = 1; index < 4; index++) {
          final tab = find.widgetWithText(NavigationDestination, labels[index]);
          await tester.tap(tab);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 90));
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is FadeTransition &&
                  widget.opacity.value > 0 &&
                  widget.opacity.value < 1,
            ),
            findsWidgets,
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<NavigationBar>(find.byType(NavigationBar))
                .selectedIndex,
            index,
          );
          expect(find.byKey(const ValueKey('content-tabs')), findsNothing);
        }
        await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
        await tester.pumpAndSettle();
        expect(c.stagedTexts, ['待发送草稿']);
        await tester.tap(find.widgetWithText(NavigationDestination, '历史'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../artifacts/screenshots/compact-mobile-header-$scale.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
