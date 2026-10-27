import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/text_viewer.dart';
import 'package:globalsend/system_bridge.dart';

class PickingFiles extends FilePickerPlatform {
  final types = <FileType>[];
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    types.add(type);
    return [];
  }
}

class PreviewController extends SendController {
  Completer<String>? deviceNamePending;
  String systemName = 'DESKTOP-SYSTEM';
  @override
  Future<String> systemDeviceName() =>
      deviceNamePending?.future ?? Future.value(systemName);
  List<String>? selectedFiles;
  final sent = <(String, String)>[];
  final dragged = <String>[];
  final draggedKinds = <String>[];
  final copied = <String>[];
  final received = <String>[];
  final retried = <String>[];
  final renamed = <String>[];
  final clipboardChanges = <(bool, String)>[];
  final edited = <(String, String)>[];
  final stagedSends = <String>[];
  final batchSends = <List<String>>[];
  final failSendOnce = <String>{};
  int refreshRequests = 0, initializations = 0, disposals = 0;
  Completer<void>? notificationDrain;
  @override
  Future<void> get notificationIdle =>
      notificationDrain?.future ?? super.notificationIdle;
  bool popupSupported = false;
  int popupSettingsRequests = 0;
  final popupChanges = <bool>[];
  @override
  bool get receivePopupAvailable => popupSupported;
  @override
  Future<void> refreshReceivePopup() async {}
  @override
  Future<void> setReceivePopupEnabled(bool enabled) async {
    popupChanges.add(enabled);
    receivePopupEnabled = enabled;
    changed();
  }

  @override
  Future<void> openReceivePopupSettings() async {
    popupSettingsRequests++;
  }

  @override
  Future<void> refreshGroupDevices() async {
    refreshRequests++;
  }

  @override
  Future<void> sendStagedToMany(List<String> targets) async {
    batchSends.add(targets.toList());
    var failed = false;
    for (final id in targets) {
      if (stagedTargetStates[id] == 'sent') continue;
      if (failSendOnce.remove(id)) {
        stagedTargetStates[id] = 'failed';
        failed = true;
      } else {
        stagedTargetStates[id] = 'sent';
        stagedSends.add(id);
      }
    }
    if (!failed) {
      stagedFiles.clear();
      stagedTexts.clear();
    }
    notifyListeners();
    if (failed) throw StateError('设备暂时离线');
  }

  final deleted = <String>[];
  final requeued = <String>[];
  @override
  Future<void> requeueDockEntry(DockEntry item) async {
    requeued.add(item.id);
  }

  int clipboardReads = 0;
  List<String> clipboardPaths = [];
  List<String> clipboardTexts = ['剪贴板内容'];
  String sharedDraft = '集合时间：周六上午 9:00';
  @override
  String get sharedText => sharedDraft;
  @override
  String get sharedTextStatus => '已同步';
  @override
  bool get sharedTextSupported => true;
  final sharedChanges = <String>[];
  @override
  void setSharedTextDraft(String value) {
    sharedChanges.add(value);
    sharedDraft = value;
    changed();
  }

  @override
  Future<void> stageClipboard() async {
    clipboardReads++;
    stagedFiles.addAll(clipboardPaths);
    await stageInputs([], clipboardTexts);
  }

  @override
  Future<void> sendStaged(String target) async {
    stagedSends.add(target);
    stagedFiles.clear();
    stagedTexts.clear();
    changed();
  }

  @override
  Future<void> deleteDockEntry(DockEntry item) async {
    deleted.add(item.id);
    dock.remove(item);
    changed();
  }

  Completer<void>? renamePending;
  int retentionHours = 24;
  final retentionChanges = <int>[];
  SavedFileCleanupFilter cleanupFilter = SavedFileCleanupFilter();
  final cleanupChanges = <SavedFileCleanupFilter>[];
  String destinationLabel = '';
  bool cancelDestinationChoice = false;
  int destinationChoices = 0;
  @override
  bool get hasCustomReceiveDirectory => destinationLabel.isNotEmpty;
  @override
  String get receiveDirectoryLabel => destinationLabel;
  @override
  Future<void> chooseReceiveDirectory() async {
    destinationChoices++;
    if (!cancelDestinationChoice) destinationLabel = 'F:/接收文件';
    changed();
  }

  @override
  Future<void> clearReceiveDirectory() async {
    destinationLabel = '';
    changed();
  }

  @override
  SavedFileCleanupFilter get savedFileCleanupFilter => cleanupFilter;
  @override
  Future<void> setSavedFileCleanupFilter(SavedFileCleanupFilter value) async {
    cleanupChanges.add(value);
    cleanupFilter = value;
    changed();
  }

  @override
  int get savedFileRetentionHours => retentionHours;

  @override
  Future<void> setSavedFileRetentionHours(int hours) async {
    retentionChanges.add(hours);
    retentionHours = hours;
    changed();
  }

  @override
  Future<void> sendText(String target, String text) async {
    sent.add((target, text));
  }

  @override
  Future<void> dragOut(DockEntry item, {String pointerKind = 'auto'}) async {
    dragged.add(item.id);
    draggedKinds.add(pointerKind);
  }

  @override
  Future<void> copyDockText(DockEntry item) async {
    copied.add(item.id);
  }

  @override
  Future<void> receive(
    DockEntry item, {
    bool preferDirect = false,
    String? routeOverride,
  }) async {
    received.add(item.id);
  }

  @override
  Future<void> retry(DockEntry item) async {
    retried.add(item.id);
  }

  @override
  Future<void> renameDevice(String value) async {
    renamed.add(value);
    if (renamePending != null) await renamePending!.future;
    profile!.name = value;
    changed();
  }

  @override
  Future<void> setClipboardSync(bool value, String target) async {
    clipboardChanges.add((value, target));
    clipboardEnabled = value;
    clipboardTarget = value ? target : '';
    changed();
  }

  @override
  Future<void> editSentText(DockEntry item, String value) async {
    edited.add((item.id, value));
    item.text = value;
    item.editedAt = '2026-10-25T05:00:00Z';
    changed();
  }

  @override
  Future<void> init() async {
    initializations++;
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }

  @override
  Future<void> approveReceive(DockEntry item, List<String> ids) async {
    selectedFiles = ids;
  }
}

class DelayedRestoreController extends PreviewController {
  final restored = Completer<void>();
  @override
  Future<void> init() async {
    await restored.future;
    rememberedCenter = 'https://saved.example/center';
    changed();
  }
}

class PasswordJoinController extends PreviewController {
  final joins = <(String, String)>[];
  @override
  Future<void> connect(String address, {bool development = false}) async {
    api = CenterApi(address);
    profile = ServerProfile(baseUrl: address, instanceId: 'join-fixture');
    changed();
  }

  @override
  Future<void> enrollGroup(String name, String password) async {
    joins.add((name, password));
    api!.token = 'fixture-login';
    profile!.name = name;
    profile!.deviceId = 'self';
    profile!.groupId = 'same-password-group';
    connected = true;
    changed();
  }
}

PreviewController signedIn() => PreviewController()
  ..api = CenterApi('https://example.invalid', token: 'test-only')
  ..profile = ServerProfile(
    baseUrl: 'https://example.invalid',
    instanceId: 'preview',
    deviceId: 'self',
  )
  ..devices = [
    {'deviceId': 'phone', 'name': '我的手机', 'online': true},
  ]
  ..connected = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method == 'windowVisible') return true;
          if (call.method == 'presentReceiveDock')
            return {'presentation': 'main', 'shown': true};
          return null;
        });
  });
  setUpAll(() async {
    final uiFonts = FontLoader('GlobalSendSans');
    for (final name in ['Regular', 'Semibold']) {
      uiFonts.addFont(
        Future.value(
          ByteData.sublistView(
            await File('assets/fonts/GlobalSendSans-$name.ttf').readAsBytes(),
          ),
        ),
      );
    }
    await uiFonts.load();
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                'E:/Programs/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
              ).readAsBytes(),
            ),
          ),
        ))
        .load();
  });
  Future<void> show(
    WidgetTester tester,
    PreviewController c, {
    bool mobile = true,
    bool receive = true,
    GlobalKey? key,
  }) async {
    tester.view.physicalSize = Size(mobile ? 390 : 1280, mobile ? 844 : 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GlobalSendApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    // Most fixtures below exercise received content; choose it explicitly.
    if (mobile && receive && c.api?.token.isNotEmpty == true) {
      await tester.tap(find.widgetWithText(NavigationDestination, '接收'));
      await tester.pumpAndSettle();
    }
  }

  final serverField = find.byKey(const ValueKey('server-address'));
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    if (!const bool.fromEnvironment('SCREENSHOT')) return;
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      const prefix = String.fromEnvironment('SCREENSHOT_PREFIX');
      await File('../artifacts/screenshots/workspace-native-$prefix$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Future<void> windowVisibility(WidgetTester tester, bool visible) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemBridge.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('windowVisibilityChanged', {'visible': visible}),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'phone file and media buttons open their own multiple-file filters',
    (tester) async {
      final original = FilePickerPlatform.instance;
      final picker = PickingFiles();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      await show(tester, signedIn());
      await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-file')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-media')));
      await tester.pumpAndSettle();
      expect(picker.types, [FileType.any, FileType.media]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Android media button opens the native gallery without staging a second time',
    (tester) async {
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(DockPlatform.channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(DockPlatform.channel, null),
      );
      final c = signedIn();
      await show(tester, c);
      await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-media')));
      await tester.pumpAndSettle();
      expect(calls, ['pickMedia']);
      expect(find.text('媒体'), findsOneWidget);
      expect(c.stagedFiles, isEmpty);
      expect(c.stagedSends, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'receive multi-select absorbs every card region, copies text only and deletes only selected items',
    (tester) async {
      final clipboard = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        if (call.method == 'writeClipboard')
          clipboard.add((call.arguments as Map)['text'] as String);
        return null;
      });
      final c = signedIn()
        ..dock = [
          DockEntry(
            id: 'select-text-a',
            kind: 'text',
            title: '文本',
            text: '第一段可选择的正文',
            source: 'phone',
          ),
          DockEntry(
            id: 'select-file-a',
            kind: 'file',
            title: '图片.png',
            localPath: 'F:/synthetic/图片.png',
            source: 'phone',
            status: 'received',
          ),
          DockEntry(
            id: 'select-text-b',
            kind: 'text',
            title: '文本',
            text: '第二段可选择的正文',
            source: 'phone',
          ),
          DockEntry(
            id: 'select-file-b',
            kind: 'file',
            title: '其他文件.bin',
            localPath: 'F:/synthetic/其他文件.bin',
            source: 'phone',
            status: 'received',
          ),
        ];
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('receive-multi-select')));
      await tester.pumpAndSettle();
      Finder card(String id) => find.byKey(ValueKey('select-$id'));
      bool checked(String id) => tester
          .widget<Checkbox>(
            find.descendant(of: card(id), matching: find.byType(Checkbox)),
          )
          .value!;
      await tester.tapAt(tester.getCenter(find.text('第一段可选择的正文')));
      await tester.pumpAndSettle();
      expect(checked('select-text-a'), isTrue);
      final image = card('select-file-a');
      await tester.tapAt(tester.getTopLeft(image) + const Offset(30, 40));
      await tester.pumpAndSettle();
      expect(checked('select-file-a'), isTrue);
      await tester.longPressAt(tester.getTopLeft(image) + const Offset(40, 60));
      await tester.pumpAndSettle();
      expect(c.dragged, isEmpty);
      expect(find.byKey(const ValueKey('text-viewer-input')), findsNothing);
      final beforeMenu = checked('select-file-a');
      expect(
        find.descendant(
          of: image,
          matching: find.byType(PopupMenuButton<String>),
        ),
        findsNothing,
      );
      await tester.tapAt(tester.getTopRight(image) + const Offset(-22, 22));
      await tester.pumpAndSettle();
      expect(checked('select-file-a'), !beforeMenu);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      await tester.tap(find.byKey(const ValueKey('receive-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('复制 2 项'), findsOneWidget);
      for (final item in c.dock) {
        expect(checked(item.id), isTrue);
      }
      await tester.tap(find.byKey(const ValueKey('receive-copy-selected')));
      await tester.pumpAndSettle();
      expect(clipboard, ['第二段可选择的正文\n\n第一段可选择的正文']);
      expect(find.byKey(const ValueKey('drag-select-file-a')), findsOneWidget);
      final export = await tester.startGesture(
        tester.getTopLeft(find.byKey(const ValueKey('drag-select-file-a'))) +
            const Offset(10, 10),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
      await export.moveTo(const Offset(1400, 450));
      await export.up();
      await tester.pumpAndSettle();
      expect(c.dragged, ['select-file-a']);
      await tester.tap(find.byKey(const ValueKey('receive-multi-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receive-select-all')));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.text('第一段可选择的正文')));
      await tester.ensureVisible(card('select-file-b'));
      await tester.tapAt(tester.getCenter(find.text('其他文件.bin')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receive-delete-selected')));
      await tester.pumpAndSettle();
      expect(c.deleted, ['select-file-a', 'select-text-b']);
      expect(c.dock.map((item) => item.id), ['select-text-a', 'select-file-b']);
      expect(find.byKey(const ValueKey('drag-select-file-b')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone receive selection toolbar fits and files alone cannot be copied',
    (tester) async {
      final c = signedIn()
        ..dock = [
          DockEntry(
            id: 'phone-file',
            kind: 'file',
            title: '图片.png',
            source: 'phone',
            status: 'received',
            localPath: 'F:/synthetic/图片.png',
          ),
          DockEntry(
            id: 'phone-file-2',
            kind: 'file',
            title: '视频.mp4',
            source: 'phone',
            status: 'received',
            localPath: 'F:/synthetic/视频.mp4',
          ),
        ];
      final key = GlobalKey();
      await show(tester, c, key: key);
      await tester.tap(find.byKey(const ValueKey('receive-multi-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('receive-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('2/2 项'), findsOneWidget);
      expect(find.text('复制 0 项'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('receive-copy-selected')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .getBottomRight(find.byKey(const ValueKey('receive-multi-select')))
            .dx,
        lessThanOrEqualTo(390),
      );
      await capture(tester, key, '1.0.10-phone-receive-selection');
      await tester.tap(find.byKey(const ValueKey('receive-select-all')));
      await tester.pumpAndSettle();
      expect(find.text('0/2 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [false, true]) {
    testWidgets(
      'multi-send is consumed once and failed content can be retried by device click ${mobile ? 'phone' : 'desktop'}',
      (tester) async {
        final c = signedIn()..stagedTexts.add('确认后发给两台');
        c.devices.add({'deviceId': 'tablet', 'name': '平板', 'online': true});
        c.failSendOnce.add('tablet');
        await show(tester, c, mobile: mobile, receive: false);
        expect(find.byKey(const ValueKey('send-selected')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('multi-send-toggle')));
        await tester.tap(find.byKey(const ValueKey('target-phone')));
        await tester.tap(find.byKey(const ValueKey('target-tablet')));
        await tester.pumpAndSettle();
        expect(c.stagedSends, isEmpty);
        expect(find.text('发送 2 台'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('send-selected')));
        await tester.pumpAndSettle();
        expect(c.stagedSends, ['phone']);
        expect(c.stagedTexts, ['确认后发给两台']);
        expect(find.text('多选'), findsOneWidget);
        expect(find.byKey(const ValueKey('send-selected')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('target-tablet')));
        await tester.pumpAndSettle();
        expect(c.stagedSends, ['phone', 'tablet']);
        expect(c.stagedTexts, isEmpty);
        expect(find.text('多选'), findsOneWidget);
        expect(find.byKey(const ValueKey('send-selected')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'default 950x650 outer window keeps the whole left pane visible and lists scroll inside',
    (tester) async {
      final c = signedIn()
        ..stagedTexts.addAll(List.generate(16, (i) => '待发送文本 $i'));
      c.devices.addAll(
        List.generate(
          7,
          (i) => {'deviceId': 'peer$i', 'name': '设备$i', 'online': true},
        ),
      );
      final key = GlobalKey();
      await show(tester, c, mobile: false, key: key);
      tester.view.physicalSize = const Size(934, 611);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('send-workspace-scroll')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('send-queue'))).height,
        greaterThan(120),
      );
      expect(
        tester
            .getBottomRight(find.byKey(const ValueKey('shared-text-panel')))
            .dy,
        lessThan(611),
      );
      expect(find.text('已连接'), findsOneWidget);
      final targets = find.byKey(const ValueKey('target-devices'));
      final targetController = tester.widget<ListView>(targets).controller!;
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(targets),
          scrollDelta: const Offset(0, 160),
        ),
      );
      await tester.pumpAndSettle();
      expect(targetController.offset, greaterThan(0));
      targetController.jumpTo(0);
      await tester.pumpAndSettle();
      await capture(tester, key, '1.0.4-950-outer-workspace');
      await tester.drag(
        find.byKey(const ValueKey('send-queue-list')),
        const Offset(-450, 0),
      );
      await tester.drag(
        find.byKey(const ValueKey('target-devices')),
        const Offset(-450, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .getBottomRight(find.byKey(const ValueKey('shared-text-panel')))
            .dy,
        lessThan(611),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new receipt is prominent, updates one dialog, drags and closes with Escape',
    (tester) async {
      final c = signedIn();
      final key = GlobalKey();
      await show(tester, c, mobile: false, key: key);
      final entry = DockEntry(
        id: 'new',
        kind: 'text',
        title: '文字',
        source: 'phone',
        text: '新收到的完整文本\n可复制，也可拖出。',
      );
      c.dock.add(entry);
      c.latestReceipt = entry;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(find.text(entry.text), findsWidgets);
      await capture(tester, key, '1.0.4-receipt');
      await tester.longPressAt(
        tester.getTopLeft(find.byKey(const ValueKey('receipt-drag-surface'))) +
            const Offset(10, 10),
      );
      await tester.pumpAndSettle();
      expect(c.dragged, ['new']);
      await tester.tap(find.byKey(const ValueKey('copy-receipt')));
      await tester.pumpAndSettle();
      expect(c.copied, ['new']);
      entry.text = '另一台更新后的正文';
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(find.text(entry.text), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      expect(c.dock.single.id, 'new');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native receipt dismissal clears cached batch and its barrier without reopening after UI unload',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      final baselineBarriers = find.byType(ModalBarrier).evaluate().length;
      final a = DockEntry(
        id: 'native-close-a',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: '原生关闭甲',
      );
      final b = DockEntry(
        id: 'native-close-b',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: '原生关闭乙',
      );
      c.dock.addAll([a, b]);
      c.pendingReceipts.addAll({a.id: a, b.id: b});
      c.latestReceipt = b;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-batch-grid')), findsOneWidget);
      c.pendingReceipts.remove(a.id);
      c.nativeDismissedReceiptIds.add(a.id);
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-batch-grid')), findsNothing);
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      c.pendingReceipts.remove(b.id);
      c.nativeDismissedReceiptIds.add(b.id);
      c.latestReceipt = null;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(ModalBarrier), findsNWidgets(baselineBarriers));
      expect(
        Navigator.of(tester.element(find.byType(SendScreen))).canPop(),
        false,
      );
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-input')), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await windowVisibility(tester, false);
      await windowVisibility(tester, true);
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      expect(find.byType(ModalBarrier), findsNWidgets(baselineBarriers));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native dismissed old version cannot clear pending newer receipt',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      final newer = DockEntry(
        id: 'native-newer',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: '更新版本',
      );
      c.dock.add(newer);
      c.pendingReceipts[newer.id] = newer;
      c.latestReceipt = newer;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      // Even an old cache marker must defer to the controller's current pending version.
      c.nativeDismissedReceiptIds.add(newer.id);
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(find.text('更新版本'), findsWidgets);
      expect(c.pendingReceipts[newer.id], same(newer));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a new receipt during close animation stays visible and is not retired by the old batch',
    (tester) async {
      final c = signedIn()..receiptWindowFloating = true;
      final closes = <Map>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        if (call.method == 'dismissReceivedWindow')
          closes.add(Map.from(call.arguments as Map));
        return null;
      });
      Future<void> arrive(String id, int generation) async {
        final entry = DockEntry(
          id: id,
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '收到$id',
        );
        c.dock.add(entry);
        c.pendingReceipts[id] = entry;
        c.latestReceipt = entry;
        c.receiptSerial++;
        c.changed();
        await messenger.handlePlatformMessage(
          SystemBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('receiptArrival', {'arrivalGeneration': generation}),
          ),
          (_) {},
        );
      }

      await show(tester, c);
      await arrive('first', 100);
      await tester.pumpAndSettle();
      final close = tester
          .widget<IconButton>(find.byKey(const ValueKey('close-receipt')))
          .onPressed!;
      close();
      close();
      await tester.pump(const Duration(milliseconds: 30));
      await arrive('second', 101);
      await tester.pumpAndSettle();
      expect(closes, isEmpty);
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(find.text('收到second'), findsWidgets);
      expect(c.pendingReceipts.keys, ['second']);
      await tester.tap(find.byKey(const ValueKey('close-receipt')));
      await tester.pumpAndSettle();
      expect(closes, hasLength(1));
      expect(closes.single['arrivalGeneration'], 101);
      expect(c.dock, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an arrival while the old batch drains native notices cannot be hidden by its queued close',
    (tester) async {
      final c = signedIn()..receiptWindowFloating = true;
      final closes = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        if (call.method == 'dismissReceivedWindow') closes.add(call.method);
        return null;
      });
      void arrive(String id) {
        final entry = DockEntry(
          id: id,
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: id,
        );
        c.dock.add(entry);
        c.pendingReceipts[id] = entry;
        c.latestReceipt = entry;
        c.receiptSerial++;
        c.changed();
      }

      await show(tester, c);
      arrive('old-drain');
      await tester.pumpAndSettle();
      c.notificationDrain = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('close-receipt')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(closes, isEmpty);
      expect(c.pendingReceipts, isEmpty);
      arrive('new-during-drain');
      await tester.pumpAndSettle();
      c.notificationDrain!.complete();
      await tester.pumpAndSettle();
      expect(closes, isEmpty);
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(c.pendingReceipts.keys, ['new-during-drain']);
      await tester.tap(find.byKey(const ValueKey('close-receipt')));
      await tester.pumpAndSettle();
      expect(closes, hasLength(1));
      expect(c.dock, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bounded native receipt fills its window, expands and restores after Escape without deleting history',
    (tester) async {
      final c = signedIn();
      final key = GlobalKey();
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Future<void> presentation(bool floating) async {
        await messenger.handlePlatformMessage(
          SystemBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('receiptPresentationChanged', {'floating': floating}),
          ),
          (_) {},
        );
      }

      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'windowVisible') return true;
        if (call.method == 'expandReceivedWindow' ||
            call.method == 'dismissReceivedWindow')
          await presentation(false);
        return null;
      });
      await show(tester, c, key: key);
      tester.view.physicalSize = const Size(358, 600);
      await presentation(true);
      for (var i = 0; i < 5; i++) {
        final entry = DockEntry(
          id: 'small-$i',
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '窗口内的可复制文本 $i',
        );
        c.dock.add(entry);
        c.pendingReceipts[entry.id] = entry;
        c.latestReceipt = entry;
        c.receiptSerial++;
      }
      c.changed();
      await tester.pumpAndSettle();
      expect(c.receiptWindowFloating, isTrue);
      final preview = find.byKey(const ValueKey('receipt-preview'));
      expect(tester.getSize(preview), const Size(358, 600));
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('receipt-batch-grid')), findsOneWidget);
      await capture(tester, key, '1.0.11-bounded-receipt-grid');
      await tester.drag(
        find.byKey(const ValueKey('receipt-batch-grid')),
        const Offset(0, -420),
      );
      await tester.pumpAndSettle();
      final copy = find.byKey(const ValueKey('receipt-copy-small-4'));
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(c.copied, ['small-4']);
      await tester.tap(find.byKey(const ValueKey('expand-receipt')));
      await tester.pumpAndSettle();
      expect(calls, contains('expandReceivedWindow'));
      expect(c.receiptWindowFloating, isFalse);
      expect(find.byType(Dialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(calls, contains('dismissReceivedWindow'));
      expect(c.pendingReceipts, isEmpty);
      expect(c.dock, hasLength(5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bounded single receipt keeps text selectable and has an explicit fullscreen control',
    (tester) async {
      final c = signedIn()..receiptWindowFloating = true;
      final key = GlobalKey();
      await show(tester, c, key: key);
      tester.view.physicalSize = const Size(358, 600);
      final entry = DockEntry(
        id: 'small-single',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: '这里可以选择文字、复制，也可以打开网址。',
      );
      c.dock.add(entry);
      c.pendingReceipts[entry.id] = entry;
      c.latestReceipt = entry;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('receipt-preview'))),
        const Size(358, 600),
      );
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('expand-receipt')), findsOneWidget);
      await capture(tester, key, '1.0.11-bounded-receipt-text');
      await tester.longPress(find.byKey(const ValueKey('receipt-text')));
      await tester.pumpAndSettle();
      expect(c.dragged, isEmpty);
      await tester.tap(find.byKey(const ValueKey('copy-receipt')));
      await tester.pumpAndSettle();
      expect(c.copied, ['small-single']);
      await tester.tap(find.byKey(const ValueKey('close-receipt')));
      await tester.pumpAndSettle();
      expect(c.pendingReceipts, isEmpty);
      expect(c.dock, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit background receipt overlays a composer without discarding its draft',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('draft-input')),
        '未确认且不可丢的草稿',
      );
      final entry = DockEntry(
        id: 'draft-receipt',
        kind: 'text',
        title: '文本',
        text: '后台到达',
        source: 'phone',
      );
      c.dock.add(entry);
      c.pendingReceipts[entry.id] = entry;
      c.latestReceipt = entry;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      c.receiptWindowFloating = true;
      c.changed();
      tester.view.physicalSize = const Size(358, 600);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('close-receipt')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('draft-input')))
            .controller!
            .text,
        '未确认且不可丢的草稿',
      );
      expect(c.stagedTexts, isEmpty);
      expect(c.dock, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'receipt batch keeps delayed arrivals, updates files in place and survives tray unload',
    (tester) async {
      final c = signedIn();
      final key = GlobalKey();
      await show(tester, c, mobile: false, key: key);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      final entries = List.generate(
        3,
        (i) => DockEntry(
          id: 'batch-$i',
          kind: i == 1 ? 'file' : 'text',
          title: i == 1 ? '文件.bin' : '文本',
          source: 'phone',
          text: '批量正文$i',
          status: i == 1 ? 'offered' : 'ready',
        ),
      );
      for (final entry in entries) {
        c.dock.add(entry);
        c.pendingReceipts[entry.id] = entry;
        c.latestReceipt = entry;
        c.receiptSerial++;
        c.changed();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final grid = find.byKey(const ValueKey('receipt-batch-grid'));
      expect(grid, findsOneWidget);
      expect(find.text('收到 3 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('receipt-copy-batch-0')));
      await tester.pumpAndSettle();
      expect(c.copied, ['batch-0']);
      entries[1].status = 'received';
      entries[1].localPath = 'F:/synthetic/文件.bin';
      c.latestReceipt = entries[1];
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.text('收到 3 项'), findsOneWidget);
      final fileCard = find.descendant(
        of: grid,
        matching: find.byKey(const ValueKey('drag-batch-1')),
      );
      await tester.longPressAt(
        tester.getTopLeft(fileCard) + const Offset(10, 10),
      );
      await tester.pumpAndSettle();
      expect(c.dragged, ['batch-1']);
      final fourth = DockEntry(
        id: 'batch-3',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: '后来收到',
      );
      c.dock.add(fourth);
      c.pendingReceipts[fourth.id] = fourth;
      c.latestReceipt = fourth;
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.text('收到 4 项'), findsOneWidget);
      await capture(tester, key, '1.0.10-receipt-batch');
      await windowVisibility(tester, false);
      await windowVisibility(tester, true);
      expect(find.text('收到 4 项'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      expect(c.pendingReceipts, isEmpty);
      expect(c.dock, hasLength(4));
      await windowVisibility(tester, false);
      await windowVisibility(tester, true);
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tray unload keeps the receiver alive and restores an unconfirmed composer',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('draft-input')),
        '不能丢失的未确认草稿',
      );
      final editor = tester
          .widget<TextField>(find.byKey(const ValueKey('draft-input')))
          .controller!;
      editor.selection = const TextSelection(baseOffset: 2, extentOffset: 6);
      await windowVisibility(tester, false);
      expect(find.byKey(const ValueKey('window-ui-unloaded')), findsOneWidget);
      expect(find.byType(MaterialApp), findsNothing);
      expect(c.initializations, 1);
      expect(c.disposals, 0);
      await windowVisibility(tester, true);
      final restored = tester
          .widget<TextField>(find.byKey(const ValueKey('draft-input')))
          .controller!;
      expect(restored.text, '不能丢失的未确认草稿');
      expect(
        restored.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6),
      );
      expect(c.initializations, 1);
      expect(c.disposals, 0);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(c.stagedTexts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new receipt delegates native presentation even while UI is unloaded',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemBridge.channel, (call) async {
            calls.add(call.method);
            if (call.method == 'windowVisible') return true;
            if (call.method == 'presentReceiveDock')
              return {'presentation': 'main', 'shown': true};
            return null;
          });
      final c = signedIn();
      await show(tester, c, mobile: false);
      await windowVisibility(tester, false);
      expect(find.byKey(const ValueKey('window-ui-unloaded')), findsOneWidget);
      c.latestReceipt = DockEntry(
        id: 'tray-receipt',
        kind: 'text',
        title: '文字',
        source: 'phone',
        text: '后台收到的正文',
      );
      c.receiptSerial++;
      c.pendingReceipts['tray-receipt'] = c.latestReceipt!;
      c.changed();
      await tester.pump();
      expect(
        calls.where((method) => method == 'presentReceiveDock'),
        hasLength(1),
      );
      await windowVisibility(tester, true);
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(find.text('后台收到的正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('text selection never exports the received card', (tester) async {
    final c = signedIn()
      ..dock = [
        DockEntry(
          id: 'selection-card',
          kind: 'text',
          title: '文字',
          source: 'phone',
          text: '可以选择这一段完整文本，再复制需要的内容。',
        ),
      ];
    await show(tester, c, mobile: false);
    final body = find.text(c.dock.single.text);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.down(tester.getTopLeft(body) + const Offset(4, 8));
    await mouse.moveBy(const Offset(90, 0));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(c.dragged, isEmpty);
    await tester.longPressAt(tester.getTopLeft(body) + const Offset(12, 8));
    await tester.pumpAndSettle();
    expect(c.dragged, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Windows notification click reopens a dismissed receipt from tray',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      c.latestReceipt = DockEntry(
        id: 'notice-reopen',
        kind: 'text',
        title: '文字',
        source: 'phone',
        text: '点通知重新查看',
      );
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('close-receipt')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      await windowVisibility(tester, false);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            SystemBridge.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('receivedNotificationOpened'),
            ),
            (_) {},
          );
      await windowVisibility(tester, true);
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(find.text('点通知重新查看'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'notification open keeps the received draggable preview instead of popping it',
    (tester) async {
      final c = signedIn();
      await show(tester, c);
      c.latestReceipt = DockEntry(
        id: 'notification-preview',
        kind: 'text',
        title: '文字',
        source: 'phone',
        text: '通知对应的正文',
      );
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      c.notificationOpenTarget = 'receive';
      c.notificationOpenSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('receipt-drag-surface')),
        findsOneWidget,
      );
      expect(find.text('通知对应的正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('refresh is immediate at startup, manual press and resume', (
    tester,
  ) async {
    final c = signedIn();
    await show(tester, c, mobile: false);
    expect(c.refreshRequests, greaterThan(0));
    final before = c.refreshRequests;
    await tester.tap(find.byKey(const ValueKey('refresh-devices')));
    await tester.pumpAndSettle();
    expect(c.refreshRequests, before + 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(c.refreshRequests, before + 2);
    tester.binding.handleViewFocusChanged(
      ui.ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ui.ViewFocusState.focused,
        direction: ui.ViewFocusDirection.undefined,
      ),
    );
    await tester.pumpAndSettle();
    expect(c.refreshRequests, before + 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'receipt waits for an unconfirmed composer instead of interrupting it',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('draft-input')), '还在编辑');
      c.latestReceipt = DockEntry(
        id: 'waiting',
        kind: 'text',
        title: '文字',
        source: 'phone',
        text: '稍后显示',
      );
      c.receiptSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('draft-input')))
            .controller!
            .text,
        '还在编辑',
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receipt-preview')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'whole-card right click opens the same actions as its more button',
    (tester) async {
      final c = signedIn()
        ..dock = [
          DockEntry(
            id: 'context',
            kind: 'file',
            title: '文档.pdf',
            source: 'phone',
            status: 'received',
            localPath: 'F:/fixture/document.pdf',
          ),
        ];
      await show(tester, c, mobile: false);
      final card = find.byKey(const ValueKey('drag-context'));
      final secondary = await tester.startGesture(
        tester.getTopLeft(card) + const Offset(25, 45),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondary.up();
      await tester.pumpAndSettle();
      for (final label in ['详情', '系统打开', '定位文件', '加入待发送', '删除']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.tap(find.text('加入待发送'));
      await tester.pumpAndSettle();
      expect(c.requeued, ['context']);
      await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('更多')),
      );
      await tester.pumpAndSettle();
      for (final label in ['详情', '系统打开', '定位文件', '加入待发送', '删除']) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings fades between pages and tray restoration keeps all form choices',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-page')), findsOneWidget);
      expect(find.byType(FadeTransition), findsWidgets);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace-page')), findsNothing);
      final nameInput = find.byKey(const ValueKey('device-name-input'));
      await tester.enterText(nameInput, '未保存的设备名称');
      final retention = find.byKey(const ValueKey('file-retention-input'));
      await tester.scrollUntilVisible(
        retention,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(retention, '13');
      final unit = find.byKey(const ValueKey('retention-unit-true'));
      tester.widget<DropdownButtonFormField<bool>>(unit).onChanged!(false);
      final imageChip = find.widgetWithText(FilterChip, '图片');
      tester.widget<FilterChip>(imageChip).onSelected!(false);
      await tester.pumpAndSettle();
      await windowVisibility(tester, false);
      await windowVisibility(tester, true);
      expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
      expect(tester.widget<TextField>(nameInput).controller!.text, '未保存的设备名称');
      await tester.scrollUntilVisible(
        retention,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<TextField>(retention).controller!.text, '13');
      expect(
        find.byKey(const ValueKey('retention-unit-false')),
        findsOneWidget,
      );
      expect(tester.widget<FilterChip>(imageChip).selected, isFalse);
      expect(c.retentionChanges, isEmpty);
      expect(c.cleanupChanges, isEmpty);
      expect(c.renamed, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tray restoration keeps a sent-message edit without saving it', (
    tester,
  ) async {
    final c = signedIn()
      ..dock = [
        DockEntry(
          id: 'sent-draft',
          kind: 'text',
          title: '文字',
          source: 'self',
          outgoing: true,
          text: '已经发送的文字',
        ),
      ];
    await show(tester, c, mobile: false);
    await tester.tap(find.byKey(const ValueKey('sent-history')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('drag-sent-draft')),
        matching: find.text('本机'),
      ),
    );
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('text-viewer-input'));
    await tester.enterText(input, '尚未确认的修改');
    await windowVisibility(tester, false);
    await windowVisibility(tester, true);
    expect(tester.widget<TextField>(input).controller!.text, '尚未确认的修改');
    expect(c.edited, isEmpty);
    expect(c.dock.single.text, '已经发送的文字');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'background popup settings exposes permission and explicit toggle without a floating dock',
    (tester) async {
      final c = signedIn()
        ..popupSupported = true
        ..receiveNotificationsEnabled = true;
      await show(tester, c);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('receive-popup'));
      await tester.scrollUntilVisible(
        toggle,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(find.text('需要授权'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('receive-popup-permission')));
      await tester.pumpAndSettle();
      expect(c.popupSettingsRequests, 1);
      expect(c.popupChanges, isEmpty);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(c.popupChanges, [false]);
      expect(
        find.byKey(const ValueKey('receive-popup-permission')),
        findsNothing,
      );
      expect(find.text('悬浮通知'), findsOneWidget);
      expect(find.textContaining('悬浮窗'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'text confirms into the queue and device click sends and clears it',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('draft-input'));
      await tester.enterText(input, '第一行\n第二行，保留空格。');
      c.changed();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        '第一行\n第二行，保留空格。',
      );
      expect(c.sent, isEmpty);
      expect(c.stagedTexts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('stage-text')));
      await tester.pumpAndSettle();
      expect(c.stagedTexts, ['第一行\n第二行，保留空格。']);
      expect(c.stagedSends, isEmpty);
      expect(find.byKey(const ValueKey('send-staged')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('target-phone')));
      await tester.pumpAndSettle();
      expect(c.stagedSends, ['phone']);
      expect(c.stagedTexts, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'composer preserves unconfirmed drafts and waits for IME commit',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('draft-input'));
      await tester.enterText(input, '待提交候选');
      const composing = TextEditingValue(
        text: '待提交候选',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 3, end: 5),
      );
      tester.testTextInput.updateEditingValue(composing);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(c.stagedTexts, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('stage-text')))
            .onPressed,
        isNull,
      );
      tester.testTextInput.updateEditingValue(
        composing.copyWith(composing: TextRange.empty),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '待提交候选');
      await tester.tap(find.byKey(const ValueKey('stage-text')));
      await tester.pumpAndSettle();
      expect(c.stagedTexts, ['待提交候选']);
      expect(c.sent, isEmpty);
    },
  );

  testWidgets(
    'clipboard stages once and queued text can be edited before sending',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-clipboard')));
      await tester.pumpAndSettle();
      expect(c.clipboardReads, 1);
      expect(c.stagedTexts, ['剪贴板内容']);
      expect(c.stagedSends, isEmpty);
      await tester.tap(find.text('剪贴板内容').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('draft-input')),
        '调整后的剪贴板',
      );
      await tester.tap(find.byKey(const ValueKey('stage-text')));
      await tester.pumpAndSettle();
      expect(c.stagedTexts, ['调整后的剪贴板']);
      expect(c.sent, isEmpty);
    },
  );

  testWidgets(
    'Windows Ctrl+V keeps text editing and stages images or files without losing the draft',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var kind = 'text', kindsRead = 0;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardKind') {
          kindsRead++;
          return kind;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': '第一行\n第二行'};
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemBridge.channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      Future<void> paste() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
      }

      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('draft-input'));
      await tester.enterText(input, '左右');
      final draft = tester.widget<TextField>(input).controller!;
      draft.selection = const TextSelection.collapsed(offset: 1);
      await paste();
      expect(draft.text, '左第一行\n第二行右');
      expect(c.clipboardReads, 0);
      expect(c.stagedTexts, isEmpty);

      kind = 'image';
      c.clipboardPaths = [
        '${Directory.current.path}/build/workspace-ui-fixtures/mountains.png',
      ];
      c.clipboardTexts = [];
      await paste();
      expect(c.clipboardReads, 1);
      expect(c.stagedFiles, hasLength(1));
      expect(draft.text, '左第一行\n第二行右');
      expect(find.byKey(const ValueKey('draft-input')), findsOneWidget);
      expect(c.stagedSends, isEmpty);

      kind = 'files';
      c.clipboardPaths = ['F:/synthetic/report.pdf', 'F:/synthetic/folder'];
      await paste();
      expect(c.clipboardReads, 2);
      expect(c.stagedFiles, hasLength(3));
      expect(draft.text, '左第一行\n第二行右');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      kind = 'text';
      c.clipboardPaths = [];
      c.clipboardTexts = ['空白位置粘贴'];
      await paste();
      expect(c.stagedTexts, ['空白位置粘贴']);
      expect(c.clipboardReads, 3);
      expect(c.sent, isEmpty);
      expect(kindsRead, 4);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows paste and clipboard button share import while Ctrl+Shift+V is not intercepted',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var kindsRead = 0;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardKind') {
          kindsRead++;
          return 'files';
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final c = signedIn()
        ..clipboardPaths = ['F:/synthetic/archive.zip']
        ..clipboardTexts = [];
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('add-clipboard')));
      await tester.pumpAndSettle();
      expect(c.stagedFiles, ['F:/synthetic/archive.zip']);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(c.clipboardReads, 2);
      expect(c.stagedFiles, [
        'F:/synthetic/archive.zip',
        'F:/synthetic/archive.zip',
      ]);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(kindsRead, 1);
      expect(c.stagedSends, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'shared editor survives refresh and syncs only committed IME text',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      final input = find.byKey(const ValueKey('shared-text-input'));
      await tester.enterText(input, '组内共享的新内容');
      final editing = tester.widget<TextField>(input).controller!;
      editing.selection = const TextSelection(baseOffset: 2, extentOffset: 4);
      c.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller, same(editing));
      expect(
        editing.selection,
        const TextSelection(baseOffset: 2, extentOffset: 4),
      );
      expect(c.sharedChanges.last, '组内共享的新内容');
      final count = c.sharedChanges.length;
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '正在组字',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      expect(c.sharedChanges.length, count);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '正在组字',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pumpAndSettle();
      expect(c.sharedChanges.last, '正在组字');
      c.sharedDraft = '另一台设备更新';
      c.changed();
      await tester.pumpAndSettle();
      expect(editing.text, '另一台设备更新');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared undo and redo preserve local and synchronized edit history',
    (tester) async {
      final c = signedIn();
      final initial = c.sharedDraft;
      await show(tester, c, mobile: false);
      final input = find.byKey(const ValueKey('shared-text-input'));
      await tester.enterText(input, '本地编辑');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shared-undo')));
      await tester.pumpAndSettle();
      expect(c.sharedDraft, initial);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(c.sharedDraft, '本地编辑');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(c.sharedDraft, initial);
      await tester.tap(find.byKey(const ValueKey('shared-redo')));
      await tester.pumpAndSettle();
      expect(c.sharedDraft, '本地编辑');
      c.changed(); // Own acknowledgement does not destroy history.
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('shared-undo')))
            .onPressed,
        isNotNull,
      );
      c.sharedDraft = '另一台设备的修改';
      c.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, c.sharedDraft);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('shared-undo')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('shared-undo')));
      await tester.pumpAndSettle();
      expect(c.sharedDraft, '本地编辑');
      c.changed(); // The acknowledgement of this undo must preserve redo.
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('shared-undo')));
      await tester.pumpAndSettle();
      expect(c.sharedDraft, initial);
      await tester.tap(find.byKey(const ValueKey('shared-redo')));
      await tester.pumpAndSettle();
      expect(c.sharedDraft, '本地编辑');
      await tester.tap(find.byKey(const ValueKey('shared-redo')));
      await tester.pumpAndSettle();
      expect(c.sharedDraft, '另一台设备的修改');
    },
  );

  testWidgets(
    'sent history selects whole cards, deletes selected only and clears selection on tab switch',
    (tester) async {
      final c = signedIn();
      c.dock.addAll([
        DockEntry(
          id: 'sent-a',
          kind: 'text',
          title: '文本',
          source: 'self',
          text: '发送正文甲',
          outgoing: true,
        ),
        DockEntry(
          id: 'sent-b',
          kind: 'text',
          title: '文本',
          source: 'self',
          text: '发送正文乙',
          outgoing: true,
        ),
        DockEntry(
          id: 'received-a',
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '收到正文',
        ),
      ]);
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('content-tab-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sent-multi-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sent-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送正文乙'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sent-delete-selected')));
      await tester.pumpAndSettle();
      expect(c.deleted, ['sent-a']);
      expect(c.dock.map((e) => e.id), containsAll(['sent-b', 'received-a']));
      await tester.tap(find.byKey(const ValueKey('sent-multi-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sent-select-all')));
      await tester.tap(find.byKey(const ValueKey('content-tab-0')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('receive-delete-selected')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('content-tab-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sent-delete-selected')), findsNothing);
      expect(find.text('多选'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone shared editor keeps focus and IME client while keyboard opens',
    (tester) async {
      final c = signedIn();
      await show(tester, c);
      await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('shared-text-input'));
      await tester.ensureVisible(input);
      await tester.tap(input);
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(input);
      final element = tester.element(input);
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.element(input), same(element));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      tester.testTextInput.enterText('手机键盘编辑');
      await tester.pumpAndSettle();
      expect(c.sharedDraft, '手机键盘编辑');
      c.sharedDraft = '远端静默协作';
      c.changed();
      await tester.pumpAndSettle();
      expect(field.controller!.text, '远端静默协作');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(tester.element(input), same(element));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'queue and square targets scroll independently without pushing shared editor out',
    (tester) async {
      final c = signedIn();
      c.stagedTexts.addAll(List.generate(20, (index) => '待发送内容 $index'));
      c.devices.addAll(
        List.generate(
          8,
          (index) => {
            'deviceId': 'peer$index',
            'name': '设备 $index',
            'online': true,
            'platform': 'windows',
          },
        ),
      );
      await show(tester, c, mobile: false);
      final panel = find.byKey(const ValueKey('shared-text-panel'));
      expect(tester.getBottomRight(panel).dy, lessThan(900));
      final first = find.byKey(const ValueKey('target-phone'));
      expect(tester.getSize(first).width, tester.getSize(first).height);
      await tester.drag(
        find.byKey(const ValueKey('send-queue-list')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getBottomRight(panel).dy, lessThan(900));
      await tester.drag(
        find.byKey(const ValueKey('target-devices')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('target-peer7')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('target-peer7')));
      await tester.pumpAndSettle();
      expect(c.stagedSends, ['peer7']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short phone window and keyboard keep composer confirmation reachable',
    (tester) async {
      await show(tester, signedIn());
      await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.byKey(const ValueKey('draft-input')),
        List.filled(40, '可滚动的多行文本').join('\n'),
      );
      await tester.pumpAndSettle();
      final confirm = find.byKey(const ValueKey('stage-text'));
      expect(tester.getBottomRight(confirm).dy, lessThan(544));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('native import opens staged queue without sending', (
    tester,
  ) async {
    final c = signedIn();
    await show(tester, c);
    await c.handleNativeDockEvent({
      'type': 'nativeDrop',
      'dropId': 'queue-drop',
      'paths': <String>[],
      'texts': ['拖入的文字'],
    });
    await tester.pumpAndSettle();
    expect(find.text('拖入的文字'), findsWidgets);
    expect(find.byKey(const ValueKey('send-queue')), findsOneWidget);
    expect(c.sent, isEmpty);
    expect(c.stagedSends, isEmpty);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'whole cards keep native drag, open and menu actions on ${platform.name}',
      (tester) async {
        final c = signedIn()
          ..dock = [
            DockEntry(
              id: 'text',
              kind: 'text',
              title: '文字',
              source: 'phone',
              text: '从正文直接拖出',
            ),
            DockEntry(
              id: 'saved',
              kind: 'file',
              title: '资料.pdf',
              source: 'phone',
              status: 'received',
              localPath: 'F:/fixture/saved.pdf',
            ),
          ];
        await show(tester, c, mobile: false);
        if (platform == TargetPlatform.windows) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.down(
            tester.getBottomLeft(find.byKey(const ValueKey('drag-text'))) +
                const Offset(25, -24),
          );
          await mouse.moveBy(const Offset(60, 0));
          await mouse.up();
          await tester.pumpAndSettle();
        } else {
          await tester.longPressAt(
            tester.getTopLeft(find.byKey(const ValueKey('drag-text'))) +
                const Offset(25, 40),
          );
          await tester.pumpAndSettle();
        }
        expect(c.dragged, ['text']);
        await tester.longPressAt(
          tester.getTopLeft(find.byKey(const ValueKey('drag-saved'))) +
              const Offset(25, 40),
        );
        await tester.pumpAndSettle();
        expect(c.dragged, ['text', 'saved']);
        final menu = find.descendant(
          of: find.byKey(const ValueKey('drag-text')),
          matching: find.byTooltip('更多'),
        );
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('复制'));
        await tester.pumpAndSettle();
        expect(c.copied, ['text']);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        expect(c.deleted, ['text']);
        expect(find.byKey(const ValueKey('drag-text')), findsNothing);
        expect(c.dragged, ['text', 'saved']);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'Windows touch scrolls normally and touch or pen hold exports the whole card',
    (tester) async {
      final c = signedIn()
        ..dock = List.generate(
          16,
          (index) => DockEntry(
            id: 'touch-$index',
            kind: 'text',
            title: '文本',
            source: 'phone',
            text: '内容 $index',
          ),
        );
      await show(tester, c, mobile: false);
      final card = find.byKey(const ValueKey('drag-touch-0'));
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const ValueKey('receive-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.drag(card, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(
        c.dragged,
        isEmpty,
        reason: 'a quick touch swipe remains a scroll',
      );
      expect(scroll.position.pixels, greaterThan(0));
      scroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.stylus]) {
        final finger = await tester.createGesture(kind: kind);
        await finger.down(tester.getBottomLeft(card) + const Offset(28, -24));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
        await finger.moveBy(const Offset(60, 0));
        await finger.up();
        await tester.pumpAndSettle();
      }
      expect(c.dragged, ['touch-0', 'touch-0']);
      expect(c.draggedKinds, ['touch', 'stylus']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'notification opens the receive page instead of leaving the old reader on top',
    (tester) async {
      final c = signedIn()
        ..dock = [
          DockEntry(
            id: 'notification-route',
            kind: 'text',
            title: '文字',
            source: 'phone',
            text: '旧的阅读器',
          ),
        ];
      await show(tester, c);
      await tester.tapAt(
        tester.getBottomLeft(
              find.byKey(const ValueKey('drag-notification-route')),
            ) +
            const Offset(25, -24),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('text-viewer-input')), findsOneWidget);
      c.notificationOpenTarget = 'receive';
      c.notificationOpenSerial++;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('text-viewer-input')), findsNothing);
      expect(find.byKey(const ValueKey('receive-scroll')), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop and mobile workspace render real thumbnails and bounded 2-column grids',
    (tester) async {
      final fixture = Directory('build/workspace-ui-fixtures');
      await tester.runAsync(() async {
        await fixture.create(recursive: true);
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 480, 300),
          Paint()..color = const Color(0xffd7e7df),
        );
        canvas.drawCircle(
          const Offset(355, 70),
          38,
          Paint()..color = const Color(0xfff4dca8),
        );
        canvas.drawPath(
          Path()
            ..moveTo(0, 280)
            ..lineTo(150, 60)
            ..lineTo(310, 300)
            ..close(),
          Paint()..color = const Color(0xff7b9a85),
        );
        canvas.drawPath(
          Path()
            ..moveTo(180, 300)
            ..lineTo(340, 110)
            ..lineTo(480, 280)
            ..lineTo(480, 300)
            ..close(),
          Paint()..color = const Color(0xff427161),
        );
        final image = await recorder.endRecording().toImage(480, 300);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${fixture.path}/mountains.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        await File('${fixture.path}/index.html').writeAsString(
          '<!doctype html>\n<html lang="zh-CN">\n  <h1>GlobalSend</h1>\n  <p>从一台设备，到另一台设备。</p>\n</html>',
        );
      });
      final c = signedIn()
        ..dock = [
          DockEntry(
            id: 'photo',
            kind: 'file',
            title: '山间日落.png',
            source: 'phone',
            status: 'received',
            localPath: '${fixture.absolute.path}/mountains.png',
            size: 87322,
            createdAtMillis: 1792918800000,
          ),
          DockEntry(
            id: 'note',
            kind: 'text',
            title: '文字',
            source: 'phone',
            text: '周末照片整理好了。\n原图发给你，挑几张喜欢的。',
            createdAtMillis: 1792918801000,
          ),
          DockEntry(
            id: 'html',
            kind: 'file',
            title: 'index.html',
            source: 'phone',
            status: 'received',
            localPath: '${fixture.absolute.path}/index.html',
            size: 322,
            createdAtMillis: 1792918802000,
          ),
          DockEntry(
            id: 'archive',
            kind: 'file',
            title: '旅行照片.zip',
            source: 'phone',
            status: 'received',
            localPath: 'F:/fixture/photos.zip',
            size: 18700000,
            createdAtMillis: 1792918803000,
          ),
        ];
      c.stagedFiles.add('${fixture.absolute.path}/mountains.png');
      c.stagedTexts.add('今晚 7 点见，资料也一起带上。');
      c.devices.addAll([
        {
          'deviceId': 'ipad',
          'name': 'iPad',
          'online': true,
          'platform': 'ipad',
        },
        {
          'deviceId': 'laptop',
          'name': '工作电脑',
          'online': true,
          'platform': 'windows',
        },
      ]);
      final key = GlobalKey();
      await show(tester, c, mobile: false, key: key);
      final context = tester.element(find.byKey(const ValueKey('send-queue')));
      final loading = <Future<void>>[];
      for (final width in [160, 560]) {
        loading.add(
          precacheImage(
            ResizeImage(
              FileImage(File('${fixture.absolute.path}/mountains.png')),
              width: width,
            ),
            context,
          ),
        );
      }
      for (final widget in tester.widgetList<FutureBuilder<TextFilePreview?>>(
        find.byType(FutureBuilder<TextFilePreview?>),
      )) {
        if (widget.future != null) loading.add(widget.future!.then((_) {}));
      }
      var loaded = false;
      unawaited(
        Future.wait(loading).then((_) {
          loaded = true;
        }),
      );
      for (var attempt = 0; attempt < 40 && !loaded; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      await tester.pumpAndSettle();
      expect(
        loaded,
        isTrue,
        reason: 'image decoder and bounded HTML file read finish before screenshots',
      );
      expect(find.textContaining('<!doctype html>'), findsOneWidget);
      final grid = tester.widget<SliverGrid>(
        find.byKey(const ValueKey('receive-grid')),
      );
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      await capture(tester, key, 'desktop');
      tester.view.physicalSize = const Size(1000, 720);
      await tester.pumpAndSettle();
      expect(
        tester.getBottomRight(find.byKey(const ValueKey('drag-archive'))).dy,
        lessThan(720),
      );
      await capture(tester, key, 'desktop-compact');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      var phonePreviewReady = false;
      final phoneReads = tester
          .widgetList<FutureBuilder<TextFilePreview?>>(
            find.byType(FutureBuilder<TextFilePreview?>),
          )
          .map((widget) => widget.future)
          .whereType<Future<TextFilePreview?>>()
          .toList();
      unawaited(
        Future.wait(phoneReads).then((_) {
          phonePreviewReady = true;
        }),
      );
      for (var attempt = 0; attempt < 40 && !phonePreviewReady; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(phonePreviewReady, isTrue);
      expect(find.textContaining('<!doctype html>'), findsOneWidget);
      await capture(tester, key, 'phone-receive');
      await tester.tap(find.widgetWithText(NavigationDestination, '发送'));
      await tester.pumpAndSettle();
      await capture(tester, key, 'phone-send');
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('draft-input')),
        '写下要发送的文字，确认后一起发送。\n保留换行，也支持长文。',
      );
      await capture(tester, key, 'phone-compose');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      c.nativeDragActive = true;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.text('松手'), findsOneWidget);
      await capture(tester, key, 'drop');
      c.nativeDragActive = false;
      c.changed();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'directory history uses original reference and explicit requeue on ${platform.name}',
      (tester) async {
        final c = signedIn()
          ..dock = [
            DockEntry(
              id: 'folder',
              kind: 'file',
              title: '项目资料.zip',
              source: 'self',
              outgoing: true,
              sourceReference: 'F:/fixture/项目资料',
              localPath: 'F:/fixture/项目资料',
              status: 'received',
              size: 2048,
            ),
          ];
        await show(tester, c, mobile: false);
        await tester.tap(find.byKey(const ValueKey('sent-history')));
        await tester.pumpAndSettle();
        final card = find.byKey(
          ValueKey(
            '${platform == TargetPlatform.windows ? 'drag' : 'entry'}-folder',
          ),
        );
        expect(card, findsOneWidget);
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(find.textContaining('文件夹 · ZIP 传输'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        final menu = find.descendant(of: card, matching: find.byTooltip('更多'));
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text('加入待发送'));
        await tester.pumpAndSettle();
        expect(c.requeued, ['folder']);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'settings device name keeps its draft and saves with visible status',
    (tester) async {
      final c = signedIn();
      c.profile!.name = '原设备';
      c.renamePending = Completer<void>();
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('device-name-input'));
      final editing = tester.widget<TextField>(input).controller!;
      await tester.enterText(input, '正在修改的名称');
      c.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller, same(editing));
      expect(editing.text, '正在修改的名称');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '正在组字',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('save-device-name')))
            .onPressed,
        isNull,
      );
      expect(c.renamed, isEmpty);
      await tester.enterText(input, '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(c.renamed, isEmpty);
      await tester.enterText(input, '  书房电脑  ');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('save-device-name')));
      await tester.pump();
      expect(c.renamed, ['书房电脑']);
      expect(find.text('保存中…'), findsOneWidget);
      expect(tester.widget<TextField>(input).enabled, isFalse);
      c.renamePending!.complete();
      await tester.pumpAndSettle();
      expect(c.profile!.name, '书房电脑');
      expect(find.byKey(const ValueKey('save-device-name')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'new setup uses the system name and a late lookup never overwrites typing',
    (tester) async {
      final c = PreviewController()..systemName = 'DESKTOP-ACTUAL';
      await show(tester, c);
      final input = find.byKey(const ValueKey('setup-device-name'));
      expect(
        tester.widget<TextField>(input).controller!.text,
        'DESKTOP-ACTUAL',
      );
      await tester.pumpWidget(const SizedBox());
      final next = PreviewController()..deviceNamePending = Completer<String>();
      await show(tester, next);
      await tester.enterText(input, '手动输入中');
      next.deviceNamePending!.complete('稍后读到的系统名称');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '手动输入中');
    },
  );
  testWidgets(
    'settings preserves the registered name until system-name reset is pressed',
    (tester) async {
      final c = signedIn()..systemName = 'DESKTOP-ACTUAL';
      c.profile!.name = '书房电脑';
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('device-name-input'));
      expect(tester.widget<TextField>(input).controller!.text, '书房电脑');
      expect(c.renamed, isEmpty);
      await tester.tap(find.byKey(const ValueKey('system-device-name')));
      await tester.pumpAndSettle();
      expect(c.renamed, ['DESKTOP-ACTUAL']);
      expect(
        tester.widget<TextField>(input).controller!.text,
        'DESKTOP-ACTUAL',
      );
    },
  );
  testWidgets(
    'clipboard copy is concise and destination stays independent of sending',
    (tester) async {
      final c = signedIn()
        ..clipboardEnabled = true
        ..clipboardTarget = 'phone';
      c.devices.add({'deviceId': 'browser', 'name': '平板', 'online': true});
      await show(tester, c, mobile: false);
      await tester.tap(find.byKey(const ValueKey('target-phone')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('平板').last);
      await tester.pumpAndSettle();
      expect(c.clipboardTarget, 'phone');
      expect(c.clipboardChanges, isEmpty);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('clipboard-sync'));
      await tester.ensureVisible(tile);
      expect(tester.widget<SwitchListTile>(tile).subtitle, isNull);
      expect(find.textContaining('仅同步到'), findsNothing);
      expect(
        find.byKey(const ValueKey('clipboard-target-phone')),
        findsOneWidget,
      );
      final limit = tester.widget<TextField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.suffixText == 'MiB' &&
              widget.key != const ValueKey('cleanup-size-input'),
        ),
      );
      expect(limit.decoration!.helperText, isNull);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(tile).subtitle, isNull);
      expect(c.clipboardChanges, [(false, '')]);
    },
  );

  testWidgets(
    'recent offline target stays clickable for 30 seconds then expires automatically',
    (tester) async {
      var now = 1000;
      final c = signedIn()..discoveryNow = () => now;
      c.stagedTexts.add('宽限发送');
      await show(tester, c, mobile: false);
      await c.handleServerMessage({
        'type': 'presence',
        'deviceId': 'phone',
        'online': false,
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('target-phone')), findsOneWidget);
      expect(find.text('暂离线'), findsOneWidget);
      expect(c.onlinePeers, isEmpty);
      expect(c.sendablePeers.single['online'], false);
      await tester.tap(find.byKey(const ValueKey('target-phone')));
      await tester.pump();
      expect(c.stagedSends, ['phone']);
      now = 30999;
      await tester.pump(const Duration(milliseconds: 29999));
      expect(find.byKey(const ValueKey('target-phone')), findsOneWidget);
      now = 31000;
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(const ValueKey('target-phone')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'online target tiles update automatically and never list offline devices',
    (tester) async {
      final c = signedIn()
        ..devices.addAll([
          {
            'deviceId': 'browser',
            'name': '浏览器设备',
            'online': false,
            'platform': 'web',
          },
          {
            'deviceId': 'offline',
            'name': '离线笔记本',
            'online': false,
            'platform': 'windows',
          },
        ]);
      await show(tester, c, mobile: false);
      expect(find.byKey(const ValueKey('target-phone')), findsOneWidget);
      expect(find.byKey(const ValueKey('target-browser')), findsNothing);
      expect(find.text('离线笔记本'), findsNothing);
      c.devices.first['online'] = false;
      c.devices[1]['online'] = true;
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('target-phone')), findsNothing);
      expect(find.byKey(const ValueKey('target-browser')), findsOneWidget);
      expect(find.text('离线笔记本'), findsNothing);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('管理离线设备'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'clipboard settings show the actual destination and can turn off offline sync',
    (tester) async {
      final c = signedIn()
        ..clipboardEnabled = true
        ..clipboardTarget = 'phone';
      c.devices.first['online'] = false;
      c.devices.add({
        'deviceId': 'browser',
        'name': '新在线设备',
        'online': true,
        'platform': 'web',
      });
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final tile = find.widgetWithText(SwitchListTile, '同步剪贴板');
      await tester.ensureVisible(tile);
      expect(find.text('我的手机 · 离线'), findsOneWidget);
      expect(find.text('仅同步到 新在线设备'), findsNothing);
      c.devices[1]['online'] = false;
      c.changed();
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(c.clipboardChanges, [(false, '')]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'file retention defaults to one day and preserves draft across refresh',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('file-retention-input'));
      await tester.scrollUntilVisible(
        input,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final editing = tester.widget<TextField>(input).controller!;
      expect(editing.text, '1');
      expect(
        tester
            .widget<DropdownButtonFormField<bool>>(
              find.byType(DropdownButtonFormField<bool>),
            )
            .initialValue,
        isTrue,
      );
      await tester.enterText(input, '2');
      c.changed();
      await tester.pumpAndSettle();
      expect(editing.text, '2');
      await tester.tap(find.byKey(const ValueKey('save-file-retention')));
      await tester.pumpAndSettle();
      expect(c.retentionChanges, [48]);
      final unit = tester.widget<DropdownButtonFormField<bool>>(
        find.byType(DropdownButtonFormField<bool>),
      );
      unit.onChanged!(false);
      await tester.pumpAndSettle();
      await tester.enterText(input, '3');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('save-file-retention')));
      await tester.pumpAndSettle();
      expect(c.retentionChanges, [48, 3]);
      await tester.enterText(input, '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(c.retentionChanges, [48, 3]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'native drop feedback covers the window from settings and only stages',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await c.handleNativeDockEvent({
        'type': 'nativeDrag',
        'active': true,
        'importing': false,
      });
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('native-drop-feedback'))),
        const Size(1280, 900),
      );
      await c.handleNativeDockEvent({
        'type': 'nativeDrag',
        'active': false,
        'importing': false,
      });
      await c.handleNativeDockEvent({
        'type': 'nativeDrop',
        'dropId': 'settings-window',
        'paths': <String>[],
        'texts': ['全窗口拖入的独立文字'],
      });
      await tester.pumpAndSettle();
      expect(find.text('全窗口拖入的独立文字'), findsOneWidget);
      expect(find.text('待发送 · 1'), findsOneWidget);
      expect(c.sent, isEmpty);
      expect(find.byKey(const ValueKey('native-drop-feedback')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cleanup filters preserve drafts and save explicit categories and MiB rules',
    (tester) async {
      final c = signedIn();
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('清理类别'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widgetList<FilterChip>(find.byType(FilterChip))
            .every((chip) => chip.selected),
        isTrue,
      );
      await tester.ensureVisible(find.widgetWithText(FilterChip, '文本'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '文本'));
      await tester.pumpAndSettle();
      final rule = tester.widget<DropdownButtonFormField<SavedFileSizeRule>>(
        find.byType(DropdownButtonFormField<SavedFileSizeRule>),
      );
      rule.onChanged!(SavedFileSizeRule.greater);
      await tester.pumpAndSettle();
      final size = find.byKey(const ValueKey('cleanup-size-input'));
      await tester.enterText(size, '12.5');
      c.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(size).controller!.text, '12.5');
      expect(c.cleanupChanges, isEmpty);
      final save = find.byKey(const ValueKey('save-cleanup-filter'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        c.cleanupChanges.single.categories.contains(SavedFileCategory.text),
        isFalse,
      );
      expect(c.cleanupChanges.single.sizeRule, SavedFileSizeRule.greater);
      expect(c.cleanupChanges.single.sizeMiB, 12.5);
      final currentRule = tester
          .widget<DropdownButtonFormField<SavedFileSizeRule>>(
            find.byType(DropdownButtonFormField<SavedFileSizeRule>),
          );
      currentRule.onChanged!(SavedFileSizeRule.any);
      await tester.pumpAndSettle();
      for (final chip in tester.widgetList<FilterChip>(
        find.byType(FilterChip),
      )) {
        chip.onSelected!(false);
      }
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(c.cleanupChanges.last.categories, isEmpty);
      expect(c.cleanupChanges.last.sizeRule, SavedFileSizeRule.any);
      expect(c.cleanupChanges.last.sizeMiB, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'receive location changes and cancellation keep the form consistent',
    (tester) async {
      final c = signedIn()..cancelDestinationChoice = true;
      await show(tester, c, mobile: false);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final change = find.byKey(const ValueKey('change-receive-directory'));
      await tester.scrollUntilVisible(
        change,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(change);
      await tester.pumpAndSettle();
      expect(c.destinationChoices, 1);
      expect(find.text('应用目录'), findsOneWidget);
      expect(find.text('恢复默认'), findsNothing);
      c.cancelDestinationChoice = false;
      await tester.tap(change);
      await tester.pumpAndSettle();
      expect(find.text('F:/接收文件'), findsOneWidget);
      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();
      expect(find.text('应用目录'), findsOneWidget);
      expect(c.destinationLabel, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline saved identity can open file library with global drop feedback',
    (tester) async {
      final c = signedIn()
        ..api = null
        ..connected = false;
      await show(tester, c);
      expect(find.byTooltip('文件库'), findsOneWidget);
      await tester.tap(find.byTooltip('文件库'));
      await tester.pumpAndSettle();
      expect(find.text('文件库'), findsOneWidget);
      c.nativeDragActive = true;
      c.changed();
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('native-drop-feedback'))),
        const Size(390, 844),
      );
      c.nativeDragActive = false;
      c.changed();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('连接设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings render long device names and large text without overflow',
    (tester) async {
      final c = signedIn();
      c.profile!.name = '工作室里的这台 Windows 电脑';
      c.destinationLabel = '下载 / GlobalSend 接收';
      c.devices.add({
        'deviceId': 'browser',
        'name': '用于文件传输和文字接收的浏览器设备',
        'online': true,
        'platform': 'web',
      });
      final key = GlobalKey();
      await show(tester, c, mobile: false, key: key);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await capture(tester, key, 'settings-desktop');
      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await capture(tester, key, 'settings-mobile');
      await tester.scrollUntilVisible(
        find.text('存储'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('存储'));
      await tester.pumpAndSettle();
      await capture(tester, key, 'settings-mobile-storage');
      await tester.scrollUntilVisible(
        find.text('分组'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await capture(tester, key, 'settings-mobile-devices');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'sent message viewer edits through the controller and displays edited state',
    (tester) async {
      final c = signedIn()
        ..dock = [
          DockEntry(
            id: 'sent-message',
            kind: 'text',
            title: '文字',
            source: 'self',
            outgoing: true,
            targetDeviceId: 'phone',
            text: '原发件文字',
            status: 'received',
          ),
        ];
      await show(tester, c, mobile: false);
      final history = find.text('已发送');
      await tester.ensureVisible(history);
      await tester.tap(history);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑文本'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('text-viewer-input'));
      expect(tester.widget<TextField>(input).readOnly, isFalse);
      await tester.enterText(input, '修改后的发件\n同步给对方');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(c.edited, [('sent-message', '修改后的发件\n同步给对方')]);
      expect(find.text('已同步'), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('修改后的发件\n同步给对方'), findsOneWidget);
      expect(c.dock.single.editedAt, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'first-run connection fits a phone with basic fields directly visible',
    (tester) async {
      await show(tester, PreviewController());
      expect(
        tester.widget<TextField>(serverField).controller!.text,
        defaultCenterAddress,
      );
      expect(find.text('组密码'), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-device-name')), findsOneWidget);
      expect(find.text('生成密钥'), findsNothing);
      expect(find.text('使用配对码'), findsNothing);
      expect(find.text('连接'), findsOneWidget);
      expect(tester.getBottomRight(find.text('连接')).dy, lessThan(844));
      expect(find.text('自动接收'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a typed group password connects directly without creation or pairing steps',
    (tester) async {
      final c = PasswordJoinController()..systemName = 'vivo-X';
      await show(tester, c);
      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.text('创建组'), findsNothing);
      expect(find.text('生成密钥'), findsNothing);
      expect(find.text('使用配对码'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('group-password')),
        '1234567890',
      );
      await tester.tap(find.text('连接'));
      await tester.pumpAndSettle();
      expect(c.joins, [('vivo-X', '1234567890')]);
      expect(find.byKey(const ValueKey('send-queue')), findsOneWidget);
      expect(find.text('组密码'), findsNothing);
      expect(c.profile!.name, 'vivo-X');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('saved custom center takes precedence over default', (
    tester,
  ) async {
    await show(
      tester,
      PreviewController()
        ..profile = ServerProfile(
          baseUrl: 'https://custom.example/KeepCase',
          instanceId: 'saved',
        ),
    );
    expect(
      tester.widget<TextField>(serverField).controller!.text,
      'https://custom.example/KeepCase',
    );
  });
  testWidgets('async restore does not replace an address being edited', (
    tester,
  ) async {
    final c = DelayedRestoreController();
    await show(tester, c);
    await tester.enterText(serverField, 'https://new.example/typed');
    c.restored.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(serverField).controller!.text,
      'https://new.example/typed',
    );
  });
  testWidgets(
    'signed-in phone defaults to send on the left with receive on the right',
    (tester) async {
      await show(tester, signedIn(), receive: false);
      final send = find.widgetWithText(NavigationDestination, '发送');
      final receive = find.widgetWithText(NavigationDestination, '接收');
      expect(tester.getCenter(send).dx, lessThan(tester.getCenter(receive).dx));
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(find.byKey(const ValueKey('send-queue')), findsOneWidget);
      expect(serverField, findsNothing);
      expect(find.text('发送路径'), findsNothing);
      await tester.tap(receive);
      await tester.pumpAndSettle();
      expect(find.text('暂无接收'), findsOneWidget);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(find.text('我的手机'), findsOneWidget);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.text('自动接收'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('发送方式'),
        200,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .first,
      );
      expect(find.text('发送方式'), findsOneWidget);
      expect(find.textContaining('MiB'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('pending relay batch retains individual file selection', (
    tester,
  ) async {
    final c = signedIn()
      ..dock = [
        for (final name in ['a.txt', 'b.txt'])
          DockEntry(
            id: name,
            kind: 'file',
            title: name,
            source: 'phone',
            fileId: name,
            transferId: 'batch',
            status: 'relayConsent',
            size: 34000000,
            relayConfirmationPending: true,
            relayPendingBeforeAccept: true,
          ),
      ];
    await show(tester, c);
    expect(find.textContaining('需中继'), findsWidgets);
    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, 'b.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接收 1 项'));
    await tester.pumpAndSettle();
    expect(c.selectedFiles, ['a.txt']);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'received text opens intact and route details stay off the card',
    (tester) async {
      final original = '第一段\n${List.filled(8, '完整内容不丢失。').join('\n')}';
      final c = signedIn()
        ..dock = [
          DockEntry(
            id: 'text',
            kind: 'text',
            title: '文字',
            source: 'phone',
            text: original,
          ),
          DockEntry(
            id: 'file',
            kind: 'file',
            title: '设计稿.pdf',
            source: 'phone',
            status: 'received',
            size: 1200000,
            route: 'lan',
            routeDetail: '局域网连接详情',
          ),
        ];
      await show(tester, c);
      expect(find.text('已保存 · 局域网'), findsNothing);
      expect(find.text('局域网连接详情'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('drag-text')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('text-viewer-input'));
      expect(
        find.descendant(of: input, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(find.text(original), findsWidgets);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final menu = find.descendant(
        of: find.byKey(const ValueKey('entry-file')),
        matching: find.byTooltip('更多'),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(find.textContaining('局域网连接详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
