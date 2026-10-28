import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files.dart';
import 'package:globalsend/saved_files_screen.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/bulk_file_drag.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/receipt_preview.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/ui_session.dart';

import 'system_font_fixture.dart';
import 'native_drag_render_fixture.dart';
import 'widget_test.dart' as fixture;

class LibraryFixture extends fixture.PreviewController {
  @override
  List<SavedFile> get savedFiles => [
    SavedFile(
      id: 'saved',
      profileKey: 'profile',
      deviceId: 'self',
      groupId: 'group',
      transferId: 'transfer',
      fileId: 'file',
      path: 'F:/example/saved.bin',
      name: 'saved.bin',
      size: 4,
      receivedAtMillis: DateTime(2026, 10, 27, 20).millisecondsSinceEpoch,
    ),
  ];
  @override
  Future<void> refreshSavedFiles({bool cleanup = false}) async {}
}

class BatchFixture extends fixture.PreviewController {
  final queued = <String>[];
  @override
  Future<void> stageInputs(List<String> paths, List<String> texts) async {
    queued.addAll(paths);
    stagedFiles.addAll(paths);
    changed();
  }
}

void onPlatform(
  String name,
  Future<void> Function(WidgetTester) body, {
  TargetPlatform platform = TargetPlatform.windows,
}) => testWidgets(name, body, variant: TargetPlatformVariant.only(platform));

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
    Widget child,
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
    await tester.pumpWidget(RepaintBoundary(key: key, child: child));
    await tester.pumpAndSettle();
    return key;
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async =>
      tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('../artifacts/screenshots/header-menu')
            .create(recursive: true);
        await File('../artifacts/screenshots/header-menu/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
  for (final scale in [1.0, 1.3])
    onPlatform(
      '950 by 650 header tabs align with right content and keep touch controls $scale',
      (tester) async {
        final c = fixture.signedIn()
          ..dock = [
            DockEntry(
              id: 'text',
              kind: 'text',
              title: '文本',
              source: 'phone',
              text: '收到的文本内容，清晰直接。',
            ),
          ];
        final key = await mount(
          tester,
          GlobalSendApp(controller: c),
          const Size(950, 650),
          scale: scale,
        );
        final tabs = find.byKey(const ValueKey('content-tabs'));
        expect(
          find.ancestor(of: tabs, matching: find.byType(AppBar)),
          findsOneWidget,
        );
        final right = tester.getRect(
          find.byKey(const ValueKey('receive-scroll')),
        );
        expect(tester.getTopLeft(tabs).dx, closeTo(right.left, 1));
        expect(
          tester.getBottomRight(tabs).dy,
          tester.getTopLeft(find.byKey(const ValueKey('desktop-content-pane'))).dy,
          reason: 'Desktop tabs connect directly to their content pane.',
        );
        expect(tester.getBottomRight(tabs).dy, lessThan(right.top));
        expect(
          tester.getSize(find.byKey(const ValueKey('receive-toolbar'))).height,
          48,
        );
        expect(
          tester.getSize(find.byTooltip('设置')).width,
          greaterThanOrEqualTo(44),
        );
        expect(find.byType(NavigationBar), findsNothing);
        expect(
          find.byKey(const ValueKey('send-workspace-scroll')),
          findsNothing,
        );
        await capture(tester, key, 'desktop-$scale');
        await tester.tap(find.byKey(const ValueKey('content-tab-1')));
        await tester.pumpAndSettle();
        expect(find.text('暂无发送记录'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('content-tab-0')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('receive-scroll')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  onPlatform(
    'phone keeps its four bottom destinations without desktop header tabs',
    (tester) async {
      final key = await mount(
        tester,
        GlobalSendApp(controller: fixture.signedIn()),
        const Size(390, 844),
      );
      expect(find.byKey(const ValueKey('content-tabs')), findsNothing);
      expect(find.byType(NavigationDestination), findsNWidgets(4));
      expect(find.widgetWithText(NavigationDestination, '发送'), findsOneWidget);
      await tester.tap(find.widgetWithText(NavigationDestination, '接收'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('receive-scroll')), findsOneWidget);
      await capture(tester, key, 'phone');
      expect(tester.takeException(), isNull);
    },
    platform: TargetPlatform.android,
  );
  onPlatform(
    'received file menu orders open locate queue before delete and details',
    (tester) async {
      final c = fixture.signedIn()
        ..dock = [
          DockEntry(
            id: 'menu-file',
            kind: 'file',
            title: 'file.bin',
            source: 'phone',
            localPath: 'F:/example/file.bin',
            status: 'received',
          ),
        ];
      await mount(tester, GlobalSendApp(controller: c), const Size(950, 650));
      final menu = find.descendant(
        of: find.byKey(const ValueKey('drag-menu-file')),
        matching: find.byType(PopupMenuButton<String>),
      );
      final widget = tester.widget<PopupMenuButton<String>>(menu);
      final entries = widget
          .itemBuilder(tester.element(menu))
          .cast<PopupMenuItem<String>>();
      expect(entries.map((entry) => entry.value).toList(), [
        'openExternal',
        'locate',
        'requeue',
        'delete',
        'details',
      ]);
      expect((entries.first.child! as Text).data, '打开');
    },
  );
  onPlatform(
    'library file menu uses same order and opens its details without an external action',
    (tester) async {
      final c = LibraryFixture();
      await mount(
        tester,
        MaterialApp(
          theme: Ui.theme(),
          home: SavedFilesScreen(controller: c),
        ),
        const Size(950, 650),
      );
      final menu = find.byType(PopupMenuButton<String>);
      final widget = tester.widget<PopupMenuButton<String>>(menu);
      final entries = widget
          .itemBuilder(tester.element(menu))
          .cast<PopupMenuItem<String>>();
      expect(entries.map((entry) => entry.value).toList(), [
        'open',
        'locate',
        'queue',
        'rename',
        'select',
        'delete',
        'details',
      ]);
      expect((entries.first.child! as Text).data, '打开');
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('F:/example/saved.bin'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  onPlatform(
    'bulk drag exports every path without a 32 item cap and a click does not open another action',
    (tester) async {
      final calls = <Map>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemBridge.channel, (call) async {
            if (call.method == 'dragOut') {
              calls.add(Map.from(call.arguments));
              return true;
            }
            return null;
          });
      final paths = List.generate(40, (index) => 'F:/example/$index.bin');
      await mount(
        tester,
        MaterialApp(
          theme: Ui.theme(),
          home: Scaffold(
            body: Center(child: BulkFileDrag(paths: paths)),
          ),
        ),
        const Size(950, 650),
      );
      await tester.tap(find.byType(BulkFileDrag));
      await tester.pump();
      expect(calls, isEmpty);
      final surface = tester.widget<ContentDragSurface>(
        find.byType(ContentDragSurface),
      );
      expect(surface.entry, isA<BulkFileEntry>());
      expect(surface.itemCount, 40);
      await surface.onExport('mouse');
      expect(calls.single['paths'], paths);
      expect(calls.single['pointerKind'], 'mouse');
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: Scaffold(body: BulkFileDrag(paths: const [])),
        ),
      );
      await tester.pump();
      expect(find.byType(ContentDragSurface), findsNothing);
    },
  );
  onPlatform(
    'receive and sent bulk handles contain only local files and selection narrows the current batch',
    (tester) async {
      final c = fixture.signedIn()
        ..dock = [
          DockEntry(
            id: 'one',
            kind: 'file',
            title: 'one.bin',
            source: 'phone',
            localPath: 'F:/example/one.bin',
            status: 'received',
          ),
          DockEntry(
            id: 'two',
            kind: 'file',
            title: 'two.bin',
            source: 'phone',
            localPath: 'F:/example/two.bin',
            status: 'received',
          ),
          DockEntry(
            id: 'pending',
            kind: 'file',
            title: 'pending.bin',
            source: 'phone',
            status: 'offered',
          ),
          DockEntry(
            id: 'text',
            kind: 'text',
            title: '文本',
            source: 'phone',
            text: 'not a file',
          ),
          DockEntry(
            id: 'sent',
            kind: 'file',
            title: 'sent.bin',
            source: 'self',
            outgoing: true,
            localPath: 'F:/example/sent.bin',
            status: 'received',
          ),
        ];
      await mount(tester, GlobalSendApp(controller: c), const Size(950, 650));
      BulkFileDrag receive() =>
          tester.widget(find.byKey(const ValueKey('receive-drag-all')));
      expect(receive().paths.toSet(), {
        'F:/example/one.bin',
        'F:/example/two.bin',
      });
      await tester.tap(find.byKey(const ValueKey('receive-multi-select')));
      // The still-offered fixture intentionally keeps its progress animation.
      await tester.pump(const Duration(milliseconds: 300));
      expect(receive().paths, isEmpty);
      await tester.tap(find.byKey(const ValueKey('select-one')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(receive().paths, ['F:/example/one.bin']);
      await tester.tap(find.byKey(const ValueKey('content-tab-1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BulkFileDrag>(find.byKey(const ValueKey('sent-drag-all')))
            .paths,
        ['F:/example/sent.bin'],
      );
      expect(tester.takeException(), isNull);
    },
  );
  onPlatform(
    'bulk file handle keeps Windows touch long press for dragging instead of its tooltip',
    (tester) async {
      final calls = <Map>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemBridge.channel, (call) async {
            if (call.method == 'dragOut') {
              calls.add(Map.from(call.arguments));
              return true;
            }
            return null;
          });
      final paths = ['F:/example/one.bin', 'F:/example/two.bin'];
      await mount(
        tester,
        MaterialApp(
          theme: Ui.theme(),
          home: Scaffold(
            body: Center(child: BulkFileDrag(paths: paths)),
          ),
        ),
        const Size(950, 650),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(BulkFileDrag)),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 650));
      await gesture.moveBy(const Offset(20, 20));
      await tester.pump();
      expect(find.text('复制 2 项'), findsOneWidget);
      await gesture.moveTo(const Offset(970, 330));
      await pumpNativeDrag(tester);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(calls.single['paths'], paths);
      expect(calls.single['pointerKind'], 'touch');
      expect(tester.takeException(), isNull);
    },
  );
  onPlatform(
    'dragging the bulk handle into the compose area requeues the entire batch',
    (tester) async {
      final base = fixture.signedIn(),
          c = BatchFixture()
            ..api = base.api
            ..profile = base.profile
            ..devices = base.devices
            ..connected = true;
      c.dock = [
        for (final id in ['one', 'two'])
          DockEntry(
            id: id,
            kind: 'file',
            title: '$id.bin',
            source: 'phone',
            localPath: 'F:/example/$id.bin',
            status: 'received',
          ),
      ];
      final snapshot = await mount(
        tester,
        GlobalSendApp(controller: c),
        const Size(950, 650),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('receive-drag-all'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-20, 20));
      await tester.pumpAndSettle();
      expect(find.text('复制 2 项'), findsOneWidget);
      await capture(tester, snapshot, 'bulk-drag-preview');
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('send-queue'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(c.queued.toSet(), {'F:/example/one.bin', 'F:/example/two.bin'});
      expect(tester.takeException(), isNull);
    },
  );
  onPlatform('library and receipt batch expose all their visible local files', (
    tester,
  ) async {
    await mount(
      tester,
      MaterialApp(
        theme: Ui.theme(),
        home: SavedFilesScreen(controller: LibraryFixture(), embedded: true),
      ),
      const Size(950, 650),
    );
    expect(
      tester
          .widget<BulkFileDrag>(find.byKey(const ValueKey('library-drag-all')))
          .paths,
      ['F:/example/saved.bin'],
    );
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BulkFileDrag>(find.byKey(const ValueKey('library-drag-all')))
          .paths,
      isEmpty,
    );
    final entries = [
      DockEntry(
        id: 'file',
        kind: 'file',
        title: 'file.bin',
        source: 'phone',
        localPath: 'F:/example/file.bin',
      ),
      DockEntry(
        id: 'text',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: 'text',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: Ui.theme(),
        home: Scaffold(
          body: ReceivedBatchPreview(
            entries: entries,
            onClose: () {},
            itemBuilder: (_, child) => child,
            onCopy: (_) {},
            onView: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<BulkFileDrag>(find.byKey(const ValueKey('receipt-drag-all')))
          .paths,
      ['F:/example/file.bin'],
    );
    expect(tester.takeException(), isNull);
  });
  onPlatform(
    'dock detail requests are consumed once and survive a hidden main screen rebuild',
    (tester) async {
      final c = fixture.signedIn()
        ..dock = [
          DockEntry(
            id: 'details-file',
            kind: 'file',
            title: 'details.bin',
            source: 'phone',
            localPath: 'F:/example/details.bin',
            status: 'received',
          ),
        ];
      final session = SendUiSession()
        ..detailsId = 'details-file'
        ..detailsRequest = 1;
      Widget app() => MaterialApp(
        theme: Ui.theme(),
        home: SendScreen(controller: c, session: session),
      );
      await mount(tester, app(), const Size(950, 650));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(session.detailsId, isNull);
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      c.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox());
      session.detailsId = 'details-file';
      session.detailsRequest++;
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(session.detailsId, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
