import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/saved_image_preview.dart';
import 'package:globalsend/content_preview.dart';

void main() {
  test('diagnose supplied PNG with real Flutter codec', () async {
    final original = await File(
      Platform.environment['GLOBALSEND_IMAGE_SAMPLE']!,
    ).readAsBytes();
    final chunks = <Uint8List>[];
    var offset = 8;
    while (offset + 12 <= original.length) {
      final length = ByteData.sublistView(
        original,
        offset,
        offset + 4,
      ).getUint32(0);
      if (length > original.length - offset - 12) break;
      final type = String.fromCharCodes(
        original.sublist(offset + 4, offset + 8),
      );
      if (!['acTL', 'fcTL', 'fdAT'].contains(type))
        chunks.add(
          Uint8List.sublistView(original, offset, offset + length + 12),
        );
      offset += length + 12;
      if (type == 'IEND') break;
    }
    final staticPng =
        (BytesBuilder()
              ..add(original.sublist(0, 8))
              ..add(chunks.expand((x) => x).toList()))
            .takeBytes();
    for (final entry in {
      'original': original,
      'trimmed': Uint8List.sublistView(original, 0, offset),
      'static': staticPng,
    }.entries) {
      try {
        final codec = await ui.instantiateImageCodec(entry.value);
        final frame = await codec.getNextFrame();
        print(
          '${entry.key}: ${frame.image.width}x${frame.image.height}, frames=${codec.frameCount}',
        );
        frame.image.dispose();
        codec.dispose();
      } catch (error) {
        print('${entry.key}: $error');
      }
    }
    final buffer = await ui.ImmutableBuffer.fromFilePath(
      Platform.environment['GLOBALSEND_IMAGE_SAMPLE']!,
    );
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final mappedCodec = await descriptor.instantiateCodec();
    final mappedFrame = await mappedCodec.getNextFrame();
    print(
      'mapped original: ${mappedFrame.image.width}x${mappedFrame.image.height}',
    );
    mappedFrame.image.dispose();
    mappedCodec.dispose();
    descriptor.dispose();
    buffer.dispose();
  });

  testWidgets('supplied file through real card and expanded image widgets', (
    tester,
  ) async {
    final path = Platform.environment['GLOBALSEND_IMAGE_SAMPLE']!;
    for (final width in [160, 560, 1200]) {
      await tester.runAsync(() async {
        final ready = Completer<void>();
        final provider = ResizeImage(FileImage(File(path)), width: width);
        final stream = provider.resolve(ImageConfiguration.empty);
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, synchronous) {
            print(
              'ResizeImage $width: ${info.image.width}x${info.image.height}',
            );
            if (!ready.isCompleted) ready.complete();
          },
          onError: (Object error, StackTrace? trace) {
            if (!ready.isCompleted) ready.completeError(error, trace);
          },
        );
        stream.addListener(listener);
        try {
          await ready.future.timeout(const Duration(seconds: 8));
        } finally {
          stream.removeListener(listener);
        }
      });
    }
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: boundary,
          child: SavedImagePreview(
            path: path,
            title: 'mmexport1793118235786.jpg',
          ),
        ),
      ),
    );
    for (
      var attempt = 0;
      attempt < 40 &&
          tester.widget<RawImage>(find.byType(RawImage)).image == null;
      attempt++
    ) {
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('无法预览这张图片'), findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = File('../artifacts/tmp/supplied-expanded-preview.png');
      await out.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 160,
          height: 160,
          child: ContentPreview(
            location: path,
            name: 'mmexport1793118235786.jpg',
            compact: true,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
