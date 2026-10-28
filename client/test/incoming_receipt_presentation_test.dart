import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/incoming_receipt_state.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receipt_preview.dart';
import 'package:globalsend/receive_dock_window.dart';

import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final captureKey = GlobalKey();
  DockEntry file(String id, {String status = 'offered', int created = 100}) =>
      DockEntry(
        id: id,
        kind: 'file',
        title: '$id.bin',
        source: 'phone',
        status: status,
        createdAtMillis: created,
        size: 1024 * 1024,
        route: 'pending',
      );
  Map<String, dynamic> payload(int serial, List<DockEntry> entries) => {
    'serial': serial,
    'arrivalGeneration': serial,
    'items': [
      for (final entry in entries)
        {...entry.toJson(), 'progress': entry.progress, 'sender': '手机'},
    ],
  };
  Future<void> frame(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> update(
    WidgetTester tester,
    int serial,
    List<DockEntry> entries,
  ) async {
    await messenger.handlePlatformMessage(
      ReceiveDockApp.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('content', payload(serial, entries)),
      ),
      (_) {},
    );
    await frame(tester);
  }

  Future<void> picture(WidgetTester tester, String name) =>
      tester.runAsync(() async {
        final image =
            await (captureKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        await File('../artifacts/screenshots/$name.png').writeAsBytes(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        image.dispose();
      });

  test('incoming offered accepted upload ready download pause failure and completion have explicit states', () {
    final entry = file('state');
    for (final status in [
      'offered',
      'accepted',
      'uploading',
      'ready',
      'downloading',
    ]) {
      entry.status = status;
      final state = IncomingReceiptState(entry);
      expect(state.pending, true, reason: status);
      expect(state.showProgress, true, reason: status);
      expect(state.progressValue, null, reason: status);
      expect(state.canExport, false, reason: status);
    }
    entry.status = 'downloading';
    entry.route = 'direct';
    entry.progress = .42;
    expect(IncomingReceiptState(entry).label, '接收中 42%');
    expect(IncomingReceiptState(entry).progressValue, .42);
    entry.status = 'paused';
    expect(IncomingReceiptState(entry).primaryAction, 'resume');
    expect(IncomingReceiptState(entry).progressValue, .42);
    entry.status = 'failed';
    expect(IncomingReceiptState(entry).primaryAction, 'retry');
    entry.status = 'saved';
    entry.localPath = 'F:/received/state.bin';
    expect(IncomingReceiptState(entry).canExport, true);
    expect(IncomingReceiptState(entry).showProgress, false);
    expect(IncomingReceiptState(entry).label, '');
  });

  test('live receipt order retains completion slots while new arrivals enter first', () {
    final a = file('a', created: 100),
        b = file('b', created: 200),
        c = file('c', created: 300);
    var order = receiptDisplayOrder([], [a, b]);
    expect(order, ['b', 'a']);
    a.receivedAtMillis = 5000;
    a.status = 'saved';
    order = receiptDisplayOrder(order, [a, b]);
    expect(order, ['b', 'a']);
    expect(receiptDisplayOrder(order, [a, b, c]), ['c', 'b', 'a']);
  });

  testWidgets(
    'prewarmed empty dock presents on arrival and can clear and reuse the same UI',
    (tester) async {
      tester.view.physicalSize = const Size(480, 184);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') return payload(0, []);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
      );
      await tester.pumpWidget(const ReceiveDockApp());
      await frame(tester);
      expect(calls.where((call) => call.method == 'presented'), isEmpty);
      final state = tester.state(find.byType(ReceiveDockApp));
      await update(tester, 1, [file('first')]);
      expect(calls.where((call) => call.method == 'presented'), hasLength(1));
      await update(tester, 1, []);
      expect(find.byKey(const ValueKey('dock-tile-first')), findsNothing);
      await messenger.handlePlatformMessage(
        ReceiveDockApp.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('content', {
            ...payload(2, [file('second')]),
            'reveal': true,
          }),
        ),
        (_) {},
      );
      await frame(tester);
      expect(identical(state, tester.state(find.byType(ReceiveDockApp))), true);
      expect(find.byKey(const ValueKey('dock-tile-second')), findsOneWidget);
      expect(calls.where((call) => call.method == 'ready'), hasLength(1));
      expect(calls.where((call) => call.method == 'presented'), hasLength(2));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'dock begins before bytes then progresses and completes in its original slot without another presentation',
    (tester) async {
      tester.view.physicalSize = const Size(480, 184);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      final a = file('first'),
          b = file('second', status: 'downloading', created: 200);
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') return payload(1, [a]);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
      );
      await tester.pumpWidget(
        RepaintBoundary(key: captureKey, child: const ReceiveDockApp()),
      );
      await frame(tester);
      expect(find.text('待接收'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        null,
      );
      final surface = find.descendant(
        of: find.byKey(const ValueKey('dock-tile-first')),
        matching: find.byType(ContentDragSurface),
      );
      expect(tester.widget<ContentDragSurface>(surface).enabled, false);
      a.status = 'accepted';
      await update(tester, 1, [a]);
      expect(find.text('连接中'), findsOneWidget);
      b.route = 'direct';
      b.progress = .25;
      await update(tester, 2, [a, b]);
      expect(find.text('接收中 25%'), findsOneWidget);
      final before = tester.getTopLeft(
        find.byKey(const ValueKey('dock-tile-first')),
      );
      final sameSurface = tester.state(surface);
      await picture(tester, 'receive-dock-incoming-progress');
      final received = File('../artifacts/tmp/dock-pane/received-progress.bin')
          .absolute;
      await tester.runAsync(() async => received.writeAsBytes([1, 2, 3]));
      a.status = 'saved';
      a.localPath = received.path;
      a.receivedAtMillis = 10000;
      a.progress = 1;
      await update(tester, 2, [a, b]);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('dock-tile-first'))),
        before,
      );
      expect(identical(tester.state(surface), sameSurface), true);
      expect(tester.widget<ContentDragSurface>(surface).enabled, true);
      expect(calls.where((call) => call.method == 'presented'), hasLength(1));
      await picture(tester, 'receive-dock-incoming-complete-in-place');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'dock failure retries and paused transfer resumes without opening the main window',
    (tester) async {
      tester.view.physicalSize = const Size(480, 184);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      final failed = file('failed', status: 'failed'),
          paused = file('paused', status: 'paused', created: 200)
            ..progress = .5;
      messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') return payload(1, [failed, paused]);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
      );
      await tester.pumpWidget(
        RepaintBoundary(key: captureKey, child: const ReceiveDockApp()),
      );
      await frame(tester);
      expect(find.text('接收失败'), findsOneWidget);
      expect(find.text('已暂停'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await frame(tester);
      await tester.tap(find.text('继续'));
      await frame(tester);
      expect(
        calls
            .where((call) => call.method == 'action')
            .map((call) => (call.arguments as Map)['action']),
        ['retry', 'resume'],
      );
      expect(calls.where((call) => call.method == 'presented'), hasLength(1));
      await picture(tester, 'receive-dock-incoming-retry');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'main batch retains its item state and position when a transfer completes',
    (tester) async {
      final a = file('a'), b = file('b', created: 200);
      Widget page() => MaterialApp(
        home: ReceivedBatchPreview(
          entries: [a, b],
          onClose: () {},
          onCopy: (_) {},
          onView: (_) {},
          itemBuilder: (entry, _) => Text(entry.id),
        ),
      );
      await tester.pumpWidget(page());
      await frame(tester);
      final before = tester.getTopLeft(
        find.byKey(const ValueKey('receipt-batch-a')),
      );
      a.receivedAtMillis = 10000;
      a.status = 'saved';
      await tester.pumpWidget(page());
      await frame(tester);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('receipt-batch-a'))),
        before,
      );
    },
  );
}
