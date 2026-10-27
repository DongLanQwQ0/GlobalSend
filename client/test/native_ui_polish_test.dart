import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_icon.dart';
import 'package:globalsend/app_icon_paths.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files_screen.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_session.dart';
import 'package:globalsend/ui_tokens.dart';

import 'native_header_menu_layout_test.dart' show LibraryFixture;
import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

class PolishController extends fixture.PreviewController {
  final canceled = <String>[];
  int retryAll = 0, clearAll = 0;
  @override
  Future<void> cancel(DockEntry item) async {
    canceled.add(item.id);
  }

  @override
  Future<void> retryFailedOutgoingFiles() async {
    retryAll++;
  }

  @override
  Future<void> clearFailedOutgoingFiles() async {
    clearAll++;
    for (final item in failedOutgoingFiles) {
      await deleteDockEntry(item);
    }
  }
}

DockEntry file(String id, {bool outgoing = false, String status = 'failed'}) =>
    DockEntry(
      id: id,
      kind: 'file',
      title: '$id.png',
      source: 'phone',
      outgoing: outgoing,
      status: status,
      transferId: 'transfer-$id',
      fileId: 'file-$id',
      size: 74891,
    );
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
  Future<GlobalKey> mount(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(950, 650),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    final base = Ui.theme();
    // The tester cannot use the operating system's fallback for a component's
    // standalone TextStyle. Specify that same OS font only in this fixture.
    final theme = base.copyWith(
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
          fontFamily: 'Microsoft YaHei',
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(
          fontFamily: 'Microsoft YaHei',
        ),
        contentTextStyle: base.dialogTheme.contentTextStyle?.copyWith(
          fontFamily: 'Microsoft YaHei',
        ),
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        textStyle: base.popupMenuTheme.textStyle?.copyWith(
          fontFamily: 'Microsoft YaHei',
        ),
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  PolishController signedIn() {
    final original = fixture.signedIn();
    return PolishController()
      ..api = original.api
      ..profile = original.profile
      ..devices = original.devices
      ..connected = true;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../artifacts/screenshots/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  void allVectorIcons(WidgetTester tester) {
    for (final icon in tester.widgetList<Icon>(
      find.byWidgetPredicate((w) => w is Icon),
    )) {
      expect(
        icon,
        isA<AppIcon>(),
        reason: 'No Material font is bundled; ${icon.icon} must be a vector',
      );
    }
  }

  void check(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(
        name,
        body,
        variant: TargetPlatformVariant.only(TargetPlatform.windows),
      );

  check(
    'official Rounded icons and standard controls render without font fallback',
    (tester) async {
      final key = await mount(
        tester,
        Scaffold(
          appBar: AppBar(
            leading: const BackButton(),
            title: const Text('统一矢量图标'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final size in [20.0, 24.0, 40.0])
                  Row(
                    children: [
                      AppIcon(Icons.link_rounded, size: size, color: Ui.green),
                      const SizedBox(width: 24),
                      AppIcon(
                        Icons.settings_outlined,
                        size: size,
                        color: Ui.green,
                      ),
                      const SizedBox(width: 24),
                      AppIcon(Icons.more_horiz, size: size, color: Ui.green),
                    ],
                  ),
                const SizedBox(height: 24),
                const SizedBox(
                  width: 180,
                  height: 60,
                  child: AppIcon(
                    Icons.settings_outlined,
                    size: 60,
                    color: Ui.green,
                  ),
                ),
                Checkbox(value: true, onChanged: (_) {}),
                Switch(value: true, onChanged: (_) {}),
                DropdownButton<String>(
                  value: 'one',
                  icon: const AppIcon(Icons.arrow_drop_down),
                  items: const [
                    DropdownMenuItem(value: 'one', child: Text('接收目录')),
                  ],
                  onChanged: (_) {},
                ),
                const AppExpansionTile(
                  title: Text('更多'),
                  children: [Text('连接设置')],
                ),
              ],
            ),
          ),
        ),
      );
      expect(appIconPaths.length, 82);
      allVectorIcons(tester);
      expect(AppIcon.supports(Icons.link_rounded), isTrue);
      expect(AppIcon.supports(Icons.settings_outlined), isTrue);
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'native-official-icons-controls');
    },
  );
  check(
    'saved card menu uses an explicit vector rather than default missing glyph',
    (tester) async {
      final key = await mount(
        tester,
        SavedFilesScreen(controller: LibraryFixture()),
      );
      final menus = tester.widgetList<PopupMenuButton<String>>(
        find.byType(PopupMenuButton<String>),
      );
      expect(menus.where((menu) => menu.icon is AppIcon), isNotEmpty);
      allVectorIcons(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, key, 'native-saved-card-vector-menu');
    },
  );
  check(
    'server modal keeps content clicks but dismisses outside and hides automatic scrollbar',
    (tester) async {
      await mount(tester, SendScreen(controller: fixture.PreviewController()));
      await tester.tap(find.byKey(const ValueKey('setup-server-settings')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('服务器设置'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('允许 HTTP'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      allVectorIcons(tester);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(RawScrollbar),
        ),
        findsNothing,
      );
      await tester.tapAt(const Offset(8, 100));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
  check(
    'failed details separates retry from cancel and dismiss never cancels transfer',
    (tester) async {
      final c = signedIn()..destinationLabel = 'Download/GlobalSend';
      final item = file('接收失败')
        ..receiveFailure = true
        ..error = '保存失败，请更改接收位置后重试。';
      c.dock.add(item);
      final key = await mount(tester, SendScreen(controller: c));
      final dynamic state = tester.state(find.byType(SendScreen));
      unawaited(state.fileAction('details', item) as Future<void>);
      await tester.pumpAndSettle();
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.actions!.whereType<FilledButton>().length, 1);
      expect(find.text('取消传输'), findsOneWidget);
      expect(find.text('使用默认目录'), findsOneWidget);
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('transfer-details-cancel')))
            .dx,
        lessThan(
          tester
              .getCenter(find.byKey(const ValueKey('transfer-details-primary')))
              .dx,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('transfer-details-primary')));
      await tester.pump();
      expect(c.retried, [item.id]);
      await capture(tester, key, 'native-transfer-failure-actions');
      await tester.tap(find.byKey(const ValueKey('transfer-details-close')));
      await tester.pumpAndSettle();
      expect(c.canceled, isEmpty);
      unawaited(state.fileAction('details', item) as Future<void>);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(8, 100));
      await tester.pumpAndSettle();
      expect(c.canceled, isEmpty);
      unawaited(state.fileAction('details', item) as Future<void>);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('transfer-details-cancel')));
      await tester.pump();
      expect(c.canceled, [item.id]);
      await tester.tap(find.byKey(const ValueKey('transfer-details-close')));
      await tester.pumpAndSettle();
    },
  );
  check('long transfer details still scroll without a visual thumb', (
    tester,
  ) async {
    final c = signedIn();
    final item = file('long')..error = List.filled(45, '等待恢复接收目录').join('\n');
    c.dock.add(item);
    await mount(tester, SendScreen(controller: c));
    final dynamic state = tester.state(find.byType(SendScreen));
    unawaited(state.fileAction('details', item) as Future<void>);
    await tester.pumpAndSettle();
    final scroll = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scroll).position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(RawScrollbar),
      ),
      findsNothing,
    );
    await tester.drag(scroll, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('transfer-details-close')));
    await tester.pumpAndSettle();
  });
  check(
    'failed send queue exposes bulk controls and individual retry only for failed outgoing files',
    (tester) async {
      final c = signedIn();
      final bad = file('bad', outgoing: true),
          good = file('active', outgoing: true, status: 'uploading');
      final paused = file('paused', outgoing: true)..locallyPaused = true;
      c.dock.addAll([bad, good, paused, file('incoming')]);
      final key = await mount(tester, SendScreen(controller: c));
      expect(find.byKey(const ValueKey('retry-outgoing-bad')), findsOneWidget);
      expect(find.byKey(const ValueKey('retry-outgoing-paused')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('retry-outgoing-bad')));
      await tester.pump();
      expect(c.retried, ['bad']);
      await tester.tap(find.byKey(const ValueKey('retry-failed-outgoing')));
      await tester.pump();
      expect(c.retryAll, 1);
      await capture(tester, key, 'native-failed-queue-controls');
      await tester.tap(find.byKey(const ValueKey('clear-failed-outgoing')));
      await tester.pumpAndSettle();
      expect(c.deleted, ['bad']);
      expect(
        c.dock.map((e) => e.id),
        containsAll(['active', 'paused', 'incoming']),
      );
      expect(find.byKey(const ValueKey('clear-failed-outgoing')), findsNothing);
    },
  );
  check('system back first exits receive selection and retains the page', (
    tester,
  ) async {
    final c = signedIn()
      ..dock.add(
        DockEntry(
          id: 'text',
          kind: 'text',
          title: '文本',
          text: '内容',
          source: 'phone',
        ),
      );
    final session = SendUiSession()..page = 0;
    await mount(
      tester,
      SendScreen(controller: c, session: session),
      size: const Size(390, 844),
    );
    await tester.tap(find.byKey(const ValueKey('receive-multi-select')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receive-select-all')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receive-select-all')), findsNothing);
    expect(find.byKey(const ValueKey('receive-toolbar')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-text')), findsOneWidget);
  });
  check(
    'history back retains history on first press and embedded file selection delegates once',
    (tester) async {
      final c = signedIn()
        ..dock.add(file('sent', outgoing: true, status: 'sent'));
      await mount(
        tester,
        SendScreen(
          controller: c,
          session: SendUiSession()
            ..page = 0
            ..contentTab = 1,
        ),
        size: const Size(390, 844),
      );
      await tester.tap(find.byKey(const ValueKey('sent-multi-select')));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sent-select-all')), findsNothing);
      expect(find.byKey(const ValueKey('sent-grid')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final library = LibraryFixture()
        ..api = c.api
        ..profile = c.profile
        ..devices = c.devices
        ..connected = true;
      await mount(
        tester,
        SendScreen(
          controller: library,
          session: SendUiSession()
            ..page = 0
            ..contentTab = 2,
        ),
        size: const Size(390, 844),
      );
      final state = tester.state<SavedFilesScreenState>(
        find.byType(SavedFilesScreen),
      );
      state.startSelection();
      await tester.pumpAndSettle();
      expect(state.selectionActive, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(state.selectionActive, isFalse);
      expect(find.byKey(const ValueKey('saved-files-grid')), findsOneWidget);
    },
  );
  check('escape dismisses modal before exiting selected cards', (tester) async {
    final c = signedIn()
      ..dock.add(
        DockEntry(
          id: 'text',
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '内容',
        ),
      );
    await mount(tester, SendScreen(controller: c));
    await tester.tap(find.byKey(const ValueKey('receive-multi-select')));
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(SendScreen));
    unawaited(state.showServerSettings() as Future<void>);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('receive-select-all')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receive-select-all')), findsNothing);
  });
  check('system back exits device multiselect before normal navigation', (
    tester,
  ) async {
    final session = SendUiSession()
      ..multiSend = true
      ..sendTargets.add('phone');
    await mount(
      tester,
      SendScreen(controller: signedIn(), session: session),
      size: const Size(390, 844),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(session.multiSend, isFalse);
    expect(session.sendTargets, isEmpty);
    expect(find.byKey(const ValueKey('add-text')), findsOneWidget);
  });
}
