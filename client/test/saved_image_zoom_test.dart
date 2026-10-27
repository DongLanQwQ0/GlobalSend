import 'system_font_fixture.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/saved_image_preview.dart';
import 'package:globalsend/ui_tokens.dart';

void main() {
  setUpAll(loadSystemTestFonts);
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixtures;
  final files = <String, File>{};
  const viewportKey = ValueKey('saved-image-viewer');
  const colors = [
    Color(0xffd82828),
    Color(0xff249332),
    Color(0xff2548d6),
    Color(0xffffcf24),
  ];
  setUpAll(() async {
    fixtures = await Directory('build/test-fixtures/image-zoom')
        .create(recursive: true);
    for (final (name, size) in [
      ('landscape', const Size(1200, 600)),
      ('portrait', const Size(600, 1200)),
    ]) {
      final recorder = ui.PictureRecorder();
      // Generate task-owned calibration pixels; no user image is opened.
      final paint = Canvas(recorder);
      paint.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xffc8dbd1),
      );
      for (var x = 100.0; x < size.width; x += 100) {
        paint.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = const Color(0xff759485)
            ..strokeWidth = 2,
        );
      }
      for (var y = 100.0; y < size.height; y += 100) {
        paint.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = const Color(0xff759485)
            ..strokeWidth = 2,
        );
      }
      final anchors = [
        Offset.zero,
        Offset(size.width - 100, 0),
        Offset(0, size.height - 100),
        Offset(size.width - 100, size.height - 100),
      ];
      for (var i = 0; i < anchors.length; i++) {
        paint.drawRect(
          anchors[i] & const Size(100, 100),
          Paint()..color = colors[i],
        );
      }
      final image = await recorder.endRecording().toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      files[name] = await File('${fixtures.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }
  });

  Future<GlobalKey> open(
    WidgetTester tester,
    String name,
    TargetPlatform platform,
  ) async {
    tester.view.physicalSize = platform == TargetPlatform.windows
        ? const Size(950, 650)
        : const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: Ui.theme().copyWith(platform: platform),
          home: SavedImagePreview(
            path: files[name]!.absolute.path,
            title: '$name.png',
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 40; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
      if (tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null)) {
        break;
      }
    }
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((image) => image.image != null),
      isTrue,
    );
    return key;
  }

  RenderBox picture(WidgetTester tester) =>
      tester.renderObject<RenderBox>(find.byType(SavedFilePicture));
  TransformationController controller(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byKey(viewportKey))
      .transformationController!;
  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('../artifacts/screenshots/image-zoom-$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> reset(WidgetTester tester) async {
    await tester.tap(find.text('适应窗口'));
    await tester.pumpAndSettle();
  }

  void remainsAt(RenderBox child, Offset scene, Offset focal) {
    expect((child.localToGlobal(scene) - focal).distance, lessThan(1.2));
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final name in ['landscape', 'portrait']) {
      testWidgets(
        '$platform $name wheel and buttons retain rendered focal point',
        (tester) async {
          await open(tester, name, platform);
          final rect = tester.getRect(find.byKey(viewportKey));
          final focal =
              rect.topLeft + Offset(rect.width * .41, rect.height * .62);
          final child = picture(tester),
              scene = picture(tester).globalToLocal(focal);
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: focal,
              scrollDelta: const Offset(0, -110),
            ),
          );
          await tester.pumpAndSettle();
          expect(controller(tester).value.getMaxScaleOnAxis(), greaterThan(1));
          remainsAt(child, scene, focal);
          // A button must keep the current center after an already off-center zoom.
          final center = rect.center,
              centerScene = child.globalToLocal(rect.center);
          await tester.tap(find.byTooltip('放大'));
          await tester.pumpAndSettle();
          remainsAt(child, centerScene, center);
          await reset(tester);
          for (var i = 0; i < 4; i++) {
            await tester.tap(find.byTooltip('缩小'));
          }
          await tester.pumpAndSettle();
          expect(
            controller(tester).value.getMaxScaleOnAxis(),
            closeTo(.5, .001),
          );
          remainsAt(child, child.size.center(Offset.zero), rect.center);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '$platform $name off-center two-finger pinch retains rendered focal point',
        (tester) async {
          await open(tester, name, platform);
          final rect = tester.getRect(find.byKey(viewportKey));
          final focal =
              rect.topLeft + Offset(rect.width * .43, rect.height * .61);
          final left = await tester.startGesture(
            focal - const Offset(30, 0),
            pointer: 1,
          );
          final right = await tester.startGesture(
            focal + const Offset(30, 0),
            pointer: 2,
          );
          // Cross the gesture recognizer's initial slop before sampling its
          // stable scale reference. Pointer events are delivered separately.
          await left.moveTo(focal - const Offset(70, 0));
          await right.moveTo(focal + const Offset(70, 0));
          await tester.pump();
          final child = picture(tester),
              scene = picture(tester).globalToLocal(focal);
          for (final spread in [80.0, 95.0, 115.0]) {
            await left.moveTo(focal - Offset(spread, 0));
            await right.moveTo(focal + Offset(spread, 0));
            await tester.pump();
            remainsAt(child, scene, focal);
          }
          expect(
            controller(tester).value.getMaxScaleOnAxis(),
            greaterThan(1.5),
          );
          await left.up();
          await right.up();
          await tester.pumpAndSettle();
          remainsAt(child, scene, focal);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '$platform $name four colored image corners remain reachable after zoom and resize',
        (tester) async {
          final boundary = await open(tester, name, platform);
          for (var index = 0; index < 4; index++) {
            await reset(tester);
            await tester.tap(find.byTooltip('放大'));
            await tester.tap(find.byTooltip('放大'));
            await tester.pumpAndSettle();
            final child = picture(tester),
                raw = tester.widget<RawImage>(find.byType(RawImage));
            final size = Size(
              raw.image!.width.toDouble(),
              raw.image!.height.toDouble(),
            );
            final fitted = Alignment.center.inscribe(
              applyBoxFit(BoxFit.contain, size, child.size).destination,
              Offset.zero & child.size,
            );
            final normalized = Offset(
              index.isOdd ? .95 : .05,
              index >= 2 ? .95 : .05,
            );
            final point =
                fitted.topLeft +
                Offset(
                  fitted.width * normalized.dx,
                  fitted.height * normalized.dy,
                );
            final rect = tester.getRect(find.byKey(viewportKey));
            final delta = rect.center - child.localToGlobal(point);
            await tester.dragFrom(rect.center, delta);
            await tester.pumpAndSettle();
            final actual = child.localToGlobal(point);
            expect(
              rect.deflate(15).contains(actual),
              isTrue,
              reason: 'corner $index inaccessible at $actual in $rect',
            );
            final frame = await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              );
              final offset =
                  (actual.dy.round() * image.width + actual.dx.round()) * 4;
              final color = Color.fromARGB(
                255,
                bytes!.getUint8(offset),
                bytes.getUint8(offset + 1),
                bytes.getUint8(offset + 2),
              );
              image.dispose();
              return color;
            });
            expect(
              frame,
              colors[index],
              reason: 'rendered corner $index was cropped or replaced',
            );
            if (index == 3) {
              await capture(tester, boundary, '$name-${platform.name}-corner');
            }
          }
          await reset(tester);
          tester.view.physicalSize = platform == TargetPlatform.windows
              ? const Size(700, 850)
              : const Size(700, 500);
          await tester.pumpAndSettle();
          expect(controller(tester).value.getMaxScaleOnAxis(), 1);
          final child = picture(tester),
              rect = tester.getRect(find.byKey(viewportKey));
          remainsAt(child, child.size.center(Offset.zero), rect.center);
          await capture(tester, boundary, '$name-${platform.name}-fit-resized');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
