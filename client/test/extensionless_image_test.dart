import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/compact_content_card.dart';
import 'package:globalsend/content_preview.dart';
import 'package:globalsend/image_kind.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_image_preview.dart';

import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  final source = File('test/fixtures/extensionless-photo').absolute;
  test(
    'numeric JPEG is detected from bounded signature without renaming source',
    () async {
      expect(knownImageName('1000061883'), false);
      expect(await imageAtLocation(source.path, '1000061883'), true);
      expect(await source.exists(), true);
      expect(imageHeader([0xff, 0xd8]), false);
      expect(imageHeader('plain text'.codeUnits), false);
      expect(imageHeader([137, 80, 78, 71, 13, 10, 26, 10]), true);
    },
  );
  test('user-provided received samples decode in Flutter as well as signature detection', () async {
    final samples = Platform.environment['GLOBALSEND_IMAGE_SAMPLES'];
    if (samples == null) return;
    for (final path in samples.split(';')) {
      expect(
        await imageAtLocation(path, File(path).uri.pathSegments.last),
        true,
      );
      final codec = await ui.instantiateImageCodec(
        await File(path).readAsBytes(),
        targetWidth: 128,
      );
      try {
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 128);
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    }
  });
  testWidgets(
    'receive, history/library card and compact dock preview all display extensionless image',
    (tester) async {
      final capture = GlobalKey();
      final entry = DockEntry(
        id: 'legacy-image',
        kind: 'file',
        title: '1000061883',
        source: 'phone',
        localPath: source.path,
        status: 'received',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: Row(
                children: [
                  for (final dock in [false, true])
                    SizedBox(
                      width: 190,
                      height: 240,
                      child: CompactContentCard(
                        entry: entry,
                        sender: 'phone',
                        timestamp: '15:00',
                        onOpen: () {},
                        previewOnly: dock,
                      ),
                    ),
                  SizedBox(
                    width: 190,
                    height: 240,
                    child: ContentPreview(
                      location: source.path,
                      name: entry.title,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
        await tester.pump();
        if (tester
                .widgetList<RawImage>(find.byType(RawImage))
                .where((image) => image.image != null)
                .length ==
            3) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(find.byType(SavedFilePicture), findsNWidgets(3));
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .where((image) => image.image != null)
            .length,
        3,
      );
      expect(tester.takeException(), isNull);
      final output = Platform.environment['GLOBALSEND_IMAGE_RENDER'];
      if (output != null) {
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          await File(output).writeAsBytes(
            (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
                .asUint8List(),
          );
          image.dispose();
        });
      }
    },
  );
  testWidgets('clicking a legacy numeric image opens the in-app image viewer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSavedImagePreview(
              context,
              path: source.path,
              title: '1000061889',
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 35)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(SavedImagePreview), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
