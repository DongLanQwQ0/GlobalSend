import 'system_font_fixture.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/recent_photos.dart';
import 'package:globalsend/recent_photos_view.dart';
import 'package:globalsend/ui_tokens.dart';

class Gallery extends RecentPhotoLibrary {
  bool allowed = true;
  final requests = <bool>[];
  int reads = 0, fullFiles = 0;
  Completer<void>? scanGate;
  final photos = [
    SuggestedPhoto('one', Uint8List(0)),
    SuggestedPhoto('two', Uint8List(0)),
  ];

  @override
  Future<bool> permission({required bool request}) async {
    requests.add(request);
    return allowed;
  }

  @override
  Future<List<SuggestedPhoto>> readSince(
    DateTime since,
    Set<String> handled,
  ) async {
    reads++;
    await scanGate?.future;
    return photos.where((photo) => !handled.contains(photo.id)).toList();
  }

  @override
  Future<String?> filePath(String id) async {
    fullFiles++;
    return '/gallery/$id.jpg';
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Photo suggestion work did not finish');
}

void main() {
  setUpAll(loadSystemTestFonts);
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late Gallery gallery;
  late RecentPhotos photos;
  setUp(() async {
    final root = Directory('${Directory.current.path}/../artifacts/tmp')
        .absolute;
    await root.create(recursive: true);
    folder = await root.createTemp('recent-photos-test-');
    gallery = Gallery();
    photos = RecentPhotos(
      library: gallery,
      directory: () async => folder,
      supported: true,
    );
  });
  tearDown(() async {
    photos.dispose();
    final root = Directory('${Directory.current.path}/../artifacts/tmp')
        .absolute
        .path;
    if (!folder.absolute.path.startsWith(root)) {
      throw StateError('Unexpected fixture path');
    }
    await folder.delete(recursive: true);
  });

  test(
    'foreground finds photos; no full image is loaded until explicitly added',
    () async {
      await photos.refresh();
      expect(gallery.requests, isEmpty);
      photos.setVisible(true);
      await until(() => photos.items.length == 2);
      expect(gallery.requests, [true]);
      expect(gallery.fullFiles, 0);
      final staged = <String>[];
      await photos.add('one', (path) async => staged.add(path));
      expect(staged, ['/gallery/one.jpg']);
      expect(photos.items.map((item) => item.id), ['two']);
      photos.setVisible(false);
      await photos.refresh();
      expect(gallery.reads, 1);
    },
  );

  test(
    'denied access is not requested again; granting in Settings works',
    () async {
      gallery.allowed = false;
      photos.setVisible(true);
      await until(() => photos.problem != null);
      await photos.refresh();
      expect(gallery.requests, [true, false]);
      expect(gallery.reads, 0);
      gallery.allowed = true;
      await photos.refresh();
      expect(photos.items, hasLength(2));
      expect(photos.problem, isNull);
    },
  );

  test(
    'dismissals and switch persist across screen recreation and group changes',
    () async {
      photos.setVisible(true);
      await until(() => photos.items.isNotEmpty);
      await photos.dismiss(['one']);
      await photos.setEnabled(false);
      photos.dispose();
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
      );
      photos.setVisible(true);
      await photos.setEnabled(true);
      expect(
        photos.items,
        isEmpty,
      ); // Already suggested, even without manual dismissal.
      gallery.photos.add(SuggestedPhoto('three', Uint8List(0)));
      await photos.refresh();
      expect(photos.items.map((item) => item.id), ['three']);
      expect(gallery.requests.where((request) => request), hasLength(1));
    },
  );

  test(
    'suggests once per opening and clears itself without manual dismissal',
    () async {
      photos.dispose();
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
        suggestionDuration: const Duration(milliseconds: 40),
      );
      photos.setVisible(true);
      await until(() => photos.items.isNotEmpty);
      await until(() => photos.items.isEmpty);
      gallery.photos.add(SuggestedPhoto('later', Uint8List(0)));
      await photos.refresh();
      photos.setVisible(false);
      photos.setVisible(true);
      await photos.refresh();
      expect(photos.items, isEmpty);
      expect(gallery.reads, 1);
      photos.dispose();
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
      );
      photos.setVisible(true);
      await until(() => photos.items.isNotEmpty);
      expect(photos.items.map((item) => item.id), ['later']);
    },
  );

  test('failed staging keeps the suggestion for retry', () async {
    photos.setVisible(true);
    await until(() => photos.items.isNotEmpty);
    await expectLater(
      photos.add('one', (_) async => throw StateError('stage failed')),
      throwsStateError,
    );
    expect(photos.items.map((item) => item.id), contains('one'));
  });

  test('backgrounding discards a pending scan result', () async {
    gallery.scanGate = Completer<void>();
    photos.setVisible(true);
    await until(() => gallery.reads > 0);
    photos.setVisible(false);
    gallery.scanGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(photos.items, isEmpty);
  });

  testWidgets(
    'compact suggestions fit the existing queue and add via the whole thumbnail',
    (tester) async {
      tester.view.physicalSize = const Size(390, 170);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 180, 180),
        Paint()
          ..shader = const LinearGradient(
            colors: [Color(0xfff2cba7), Color(0xff72a7aa)],
          ).createShader(const Rect.fromLTWH(0, 0, 180, 180)),
      );
      canvas.drawCircle(
        const Offset(120, 55),
        25,
        Paint()..color = const Color(0xffffe3aa),
      );
      final picture = recorder.endRecording();
      final bytes = (await tester.runAsync(() async {
        final image = await picture.toImage(180, 180);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;
      picture.dispose();
      final chosen = <String>[];
      var dismissed = false;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: Ui.theme(),
            home: Scaffold(
              body: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('待发送'),
                    ),
                  ),
                  Expanded(
                    child: RecentPhotosView(
                      photos: List.generate(
                        3,
                        (i) => SuggestedPhoto('$i', bytes),
                      ),
                      onAdd: chosen.add,
                      onDismiss: () => dismissed = true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('suggested-photo-0')));
      expect(chosen, ['0']);
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final capture = await boundary.toImage();
        final png = await capture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../artifacts/screenshots/recent-photos-widget.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
        capture.dispose();
      });
      await tester.tap(find.byTooltip('忽略这些图片'));
      expect(dismissed, isTrue);
    },
  );
}
