import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/text_selection_surface.dart';

import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method == 'windowVisible') return true;
          return null;
        });
  });

  testWidgets(
    'saved file and image preview and metadata hand off outside the window with actual pointer kind',
    (tester) async {
      final directory = Directory('../artifacts/tmp/windows-export-surface');
      final document = File('${directory.path}/已保存.pdf');
      final image = File('${directory.path}/已保存.png');
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.runAsync(() async {
        await directory.create(recursive: true);
        await document.writeAsString('test fixture, not a PDF parser test');
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const Color(0xff176b50), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final pixels = await picture.toImage(32, 32);
        final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
        await image.writeAsBytes(png!.buffer.asUint8List());
        pixels.dispose();
        picture.dispose();
        await precacheImage(
          ResizeImage(FileImage(File(image.absolute.path)), width: 560),
          tester.element(find.byType(SizedBox).first),
        );
      });
      final controller = fixture.signedIn()
        ..dock = [
          for (final (id, file) in [('document', document), ('image', image)])
            DockEntry(
              id: id,
              kind: 'file',
              title: file.uri.pathSegments.last,
              source: 'phone',
              status: 'received',
              localPath: file.absolute.path,
            ),
        ];
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      final imagePreview = find.byKey(const ValueKey('preview-image'));
      expect(
        tester
            .widget<RawImage>(
              find.descendant(
                of: imagePreview,
                matching: find.byType(RawImage),
              ),
            )
            .image,
        isNotNull,
      );

      for (final id in ['document', 'image']) {
        final card = find.byKey(ValueKey('drag-$id'));
        final preview = find.byKey(ValueKey('preview-$id'));
        final points = [
          tester.getCenter(preview),
          tester.getBottomLeft(card) + const Offset(18, -14),
          tester.getBottomRight(card) + const Offset(-12, -12),
        ];
        for (final kind in [
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
        ]) {
          for (final point in points) {
            final input = await tester.createGesture(kind: kind);
            await input.down(point);
            await tester.pump(
              kLongPressTimeout + const Duration(milliseconds: 30),
            );
            await input.moveTo(const Offset(1300, 450));
            await input.up();
            await tester.pumpAndSettle();
            expect(controller.dragged.last, id);
            expect(controller.draggedKinds.last, kind.name);
          }
        }
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.down(tester.getCenter(preview));
        await mouse.moveTo(const Offset(1300, 450));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(controller.dragged.last, id);
        expect(controller.draggedKinds.last, 'mouse');
      }
      expect(controller.dragged, [
        ...List.filled(7, 'document'),
        ...List.filled(7, 'image'),
      ]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('secondary contact cannot change the long-press source kind', (
    tester,
  ) async {
    ExportLongPressGestureRecognizer? recognizer;
    String? exportedKind;
    await tester.pumpWidget(
      MaterialApp(
        home: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            ExportLongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  ExportLongPressGestureRecognizer
                >(
                  () => recognizer = ExportLongPressGestureRecognizer(),
                  (value) =>
                      value.onLongPress = () =>
                          exportedKind = value.pointerKind?.name,
                ),
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    final touch = await tester.createGesture(
      pointer: 51,
      kind: PointerDeviceKind.touch,
    );
    final pen = await tester.createGesture(
      pointer: 52,
      kind: PointerDeviceKind.stylus,
    );
    await touch.down(const Offset(100, 100));
    await pen.down(const Offset(150, 150));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 30));
    expect(recognizer?.pointerKind, PointerDeviceKind.touch);
    expect(exportedKind, 'touch');
    await pen.up();
    await touch.up();
    await tester.pumpAndSettle();
  });
}
