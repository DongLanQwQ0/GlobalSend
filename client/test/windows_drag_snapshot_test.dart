import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/ui_tokens.dart';

import 'native_drag_render_fixture.dart';
import 'system_font_fixture.dart';

void main() {
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'native export reuses exact full-width rounded image card pixels',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final file = File('../artifacts/tmp/dock-pane/drag-image-fixture.png')
          .absolute;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 100, 100),
          Paint()..color = const Color(0xffcd384c),
        );
        canvas.drawRect(
          const Rect.fromLTWH(100, 0, 100, 100),
          Paint()..color = const Color(0xff2973ac),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(200, 100);
        await file.writeAsBytes(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        image.dispose();
        picture.dispose();
      });
      final calls = <Map<dynamic, dynamic>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemBridge.channel, (call) async {
            calls.add(call.arguments as Map);
            return true;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Center(
              child: ContentDragSurface(
                entry: DockEntry(
                  id: 'rgba',
                  kind: 'file',
                  title: 'photo.png',
                  source: '',
                  localPath: file.path,
                ),
                onExport: (kind) async {
                  await SystemBridge.dragOut(
                    paths: [file.path],
                    pointerKind: kind,
                  );
                },
                child: const SizedBox(
                  key: ValueKey('image-source'),
                  width: 160,
                  height: 160,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() => precacheImage(
        ResizeImage(FileImage(file), width: 560),
        tester.element(find.byKey(const ValueKey('image-source'))),
      ));
      final drag = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('image-source'))),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(30, 0));
      await pumpNativeDrag(tester);
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      final feedback = find.byKey(const ValueKey('drag-feedback-rgba'));
      expect(tester.getSize(feedback), const Size(184, 140));
      late List<int> expected;
      await tester.runAsync(() async {
        final boundary = find.ancestor(of: feedback, matching: find.byType(RepaintBoundary))
            .evaluate().map((element) => element.renderObject)
            .whereType<RenderRepaintBoundary>()
            .firstWhere((boundary) => boundary.size == const Size(184, 140));
        final image = await boundary.toImage();
        expect(image.width, 184);
        expect(image.height, 140);
        expected = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
        expect(
          expected[(50 * 184 + 4) * 4],
          greaterThan(expected[(50 * 184 + 4) * 4 + 2]),
        );
        expect(
          expected[(50 * 184 + 179) * 4 + 2],
          greaterThan(expected[(50 * 184 + 179) * 4]),
        );
        await File(
          '../artifacts/screenshots/windows-drag-card-unified-final.png',
        ).writeAsBytes(
          (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
              .asUint8List(),
        );
        image.dispose();
      });
      await drag.moveTo(const Offset(830, 250));
      await pumpNativeDrag(tester);
      expect(calls, hasLength(1));
      expect(calls.single['previewWidth'], 184);
      expect(calls.single['previewHeight'], 140);
      expect(calls.single['previewRgba'], orderedEquals(expected));
      expect(find.byKey(const ValueKey('drag-feedback-rgba')), findsNothing);
      await drag.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
