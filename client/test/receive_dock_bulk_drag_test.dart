import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/receive_dock_window.dart';
import 'package:globalsend/models.dart';

import 'native_drag_render_fixture.dart';
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final fixtures = Directory('../artifacts/tmp/dock-pane/bulk-header').absolute;
  const handle = ValueKey('dock-drag-all-files');
  final calls = <MethodCall>[];
  final imageKey = GlobalKey();
  late List<String> paths;

  setUp(() async {
    calls.clear();
    await fixtures.create(recursive: true);
    paths = [for (var i = 0; i < 40; i++) '${fixtures.path}/file-$i.bin'];
    await Future.wait(paths.map((path) => File(path).writeAsBytes([1, 2])));
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(ReceiveDockApp.channel, null),
  );

  Map<String, dynamic> content({bool files = true}) => {
    'arrivalGeneration': 1,
    'serial': 1,
    'items': [
      if (files) ...[
        for (var i = 0; i < paths.length; i++)
          DockEntry(
            id: 'file-$i',
            kind: 'file',
            title: 'file-$i.bin',
            source: 'phone',
            localPath: paths[i],
            receivedAtMillis: 1000 - i,
          ).toJson(),
        DockEntry(
          id: 'duplicate',
          kind: 'file',
          title: 'duplicate.bin',
          source: 'phone',
          localPath: paths.first,
        ).toJson(),
        DockEntry(
          id: 'missing',
          kind: 'file',
          title: 'missing.bin',
          source: 'phone',
          localPath: '${fixtures.path}/absent.bin',
        ).toJson(),
        DockEntry(
          id: 'not-local',
          kind: 'file',
          title: 'remote.bin',
          source: 'phone',
        ).toJson(),
      ],
      DockEntry(
        id: 'text',
        kind: 'text',
        title: '文本',
        source: 'phone',
        text: '不能作为文件拖出',
        localPath: paths.first,
      ).toJson(),
    ],
  };

  Future<void> mount(WidgetTester tester, {bool files = true}) async {
    tester.view.physicalSize = const Size(480, 184);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    messenger.setMockMethodCallHandler(ReceiveDockApp.channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') return content(files: files);
      return null;
    });
    await tester.pumpWidget(
      RepaintBoundary(key: imageKey, child: const ReceiveDockApp()),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();
  }

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      'dock header $kind exports all 40 actual files with card pixels, not text or the button',
      (tester) async {
        await mount(tester);
        expect(find.byKey(handle), findsOneWidget);
        expect(find.byTooltip('拖出全部文件'), findsOneWidget);
        expect(tester.getSize(find.byKey(handle)), const Size(44, 30));
        if (kind == PointerDeviceKind.mouse) {
          await tester.runAsync(() async {
            final image =
                await (imageKey.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            await File(
              '../artifacts/screenshots/receive-dock-bulk-header-final.png',
            ).writeAsBytes(
              (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
                  .asUint8List(),
            );
            image.dispose();
          });
        }
        final drag = await tester.startGesture(
          tester.getCenter(find.byKey(handle)),
          kind: kind,
        );
        if (kind == PointerDeviceKind.touch)
          await tester.pump(const Duration(milliseconds: 650));
        await drag.moveBy(const Offset(25, 0));
        await pumpNativeDrag(tester);
        expect(find.text('复制 40 项'), findsOneWidget);
        expect(
          tester.getSize(
            find.byKey(const ValueKey('drag-feedback-bulk-file-drag')),
          ),
          const Size(184, 140),
        );
        if (kind == PointerDeviceKind.mouse) {
          final updated = content()..['serial'] = 2;
          await messenger.handlePlatformMessage(
            ReceiveDockApp.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('content', updated),
            ),
            (_) {},
          );
          await pumpNativeDrag(tester);
          expect(find.text('复制 40 项'), findsOneWidget);
        }
        await drag.moveTo(const Offset(510, 90));
        await pumpNativeDrag(tester);
        final exported =
            calls.singleWhere((call) => call.method == 'dragOut').arguments
                as Map;
        expect(exported['paths'], paths);
        expect(exported['pointerKind'], kind.name);
        expect(exported['previewWidth'], 184);
        expect(exported['previewHeight'], 140);
        expect((exported['previewRgba'] as List).length, 184 * 140 * 4);
        expect(calls.where((call) => call.method == 'move'), isEmpty);
        expect(
          find.byKey(const ValueKey('drag-feedback-bulk-file-drag')),
          findsNothing,
        );
        await drag.up();
        await tester.pumpAndSettle();
        // The new source must not consume the rest of the header's window move.
        final move = await tester.startGesture(
          const Offset(22, 18),
          kind: kind,
        );
        await move.moveBy(const Offset(30, 0));
        await tester.pump();
        expect(calls.where((call) => call.method == 'move'), hasLength(1));
        await move.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  testWidgets(
    'dock hides bulk drag when it contains only text or no local bytes',
    (tester) async {
      await mount(tester, files: false);
      expect(find.byKey(handle), findsNothing);
      expect(find.byTooltip('拖出全部文件'), findsNothing);
      expect(calls.where((call) => call.method == 'dragOut'), isEmpty);
    },
  );
}
