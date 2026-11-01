import 'system_font_fixture.dart';

import 'dart:async';
import 'dart:convert';
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
  final updates = StreamController<void>.broadcast();
  @override
  Stream<void> get changes => updates.stream;
  @override
  Future<Set<String>> availableIds(Set<String> ids) async =>
      ids.intersection(photos.map((photo) => photo.id).toSet());
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

class SharedPhotoFeed implements RecentPhotoFeed {
  final updates = StreamController<void>.broadcast();
  final candidates = <SuggestedPhoto>[
    SuggestedPhoto(
      'shared',
      Uint8List(0),
      path: 'content://media/external/images/media/42',
      name: 'photo.jpg',
    ),
  ];
  final showing = <Set<String>>[];
  final active = <bool>[];
  final dragged = <String>[];
  @override
  Stream<void> get changes => updates.stream;
  @override
  Future<List<SuggestedPhoto>> read() async => List.of(candidates);
  @override
  Future<void> setActive(bool value) async {
    active.add(value);
  }

  @override
  Future<void> setShowing(Set<String> ids, {bool interacting = false}) async {
    showing.add(Set.of(ids));
  }

  @override
  Future<void> dismiss(Iterable<String> ids) async {
    candidates.removeWhere((item) => ids.contains(item.id));
    updates.add(null);
  }

  @override
  Future<void> drag(String id) async {
    dragged.add(id);
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
    await gallery.updates.close();
    await photos.pendingWrites;
    final root = Directory('${Directory.current.path}/../artifacts/tmp')
        .absolute
        .path;
    if (!folder.absolute.path.startsWith(root)) {
      throw StateError('Unexpected fixture path');
    }
    await folder.delete(recursive: true);
  });

  test('media suggestion default is thirty seconds', () {
    expect(photos.suggestionDuration, const Duration(seconds: 30));
  });
  test(
    'main page observes native candidates without consuming them at discovery',
    () async {
      photos.dispose();
      final feed = SharedPhotoFeed();
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
        feed: feed,
      );
      photos.setVisible(true);
      await until(() => photos.items.isNotEmpty);
      expect(gallery.reads, 0);
      expect(gallery.fullFiles, 0);
      final state = jsonDecode(
        await File('${folder.path}/recent-photo-suggestions.json')
            .readAsString(),
      ) as Map;
      expect(state['handled'], isEmpty);
      photos.setShowing({'shared'});
      await photos.drag('shared');
      expect(feed.dragged, ['shared']);
      expect(photos.items.single.id, 'shared');
      final paths = <String>[];
      await photos.add('shared', (path) async => paths.add(path));
      expect(paths, ['content://media/external/images/media/42']);
      expect(feed.candidates, isEmpty);
      expect(gallery.fullFiles, 0);
      photos.setVisible(false);
      await until(() => feed.active.last == false);
      await feed.updates.close();
    },
  );

  test('suggestions discovered in one batch preserve media order on equal timestamps', () async {
    gallery.photos
      ..clear()
      ..addAll([
        SuggestedPhoto('newer-in-batch', Uint8List(0), suggestedAt: 100),
        SuggestedPhoto('older-in-batch', Uint8List(0), suggestedAt: 100),
      ]);
    photos.setVisible(true);
    await until(() => photos.items.length == 2);
    expect(photos.items.map((item) => item.id), [
      'newer-in-batch',
      'older-in-batch',
    ]);
    gallery.photos.add(
      SuggestedPhoto('later-batch', Uint8List(0), suggestedAt: 200),
    );
    await photos.refresh();
    await until(() => photos.items.length == 3);
    expect(photos.items.map((item) => item.id), [
      'later-batch',
      'newer-in-batch',
      'older-in-batch',
    ]);
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
    'Android dock mode keeps permission settings without consuming media IDs',
    () async {
      photos.dispose();
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
        suggestInApp: false,
      );
      photos.setVisible(true);
      await until(() => photos.permissionGranted);
      expect(gallery.requests, [true]);
      expect(gallery.reads, 0);
      expect(photos.items, isEmpty);
      await photos.setEnabled(false);
      final state = jsonDecode(
        await File('${folder.path}/recent-photo-suggestions.json')
            .readAsString(),
      ) as Map;
      expect(state['enabled'], false);
      expect(state['handled'], isEmpty);
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
    'old image-only setting requests image and video access once on upgrade',
    () async {
      photos.dispose();
      await File('${folder.path}/recent-photo-suggestions.json').writeAsString(
        jsonEncode({
          'enabled': true,
          'asked': true,
          'since': DateTime.now().toIso8601String(),
          'handled': <String>[],
        }),
      );
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
        suggestInApp: false,
      );
      photos.setVisible(true);
      await until(() => photos.permissionGranted);
      photos.setVisible(false);
      photos.setVisible(true);
      await photos.refresh();
      expect(gallery.requests.where((request) => request), hasLength(1));
      expect(gallery.reads, 0);
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
    'new media is discovered on library changes after the first batch',
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
      photos.setShowing({'one', 'two'});
      await until(() => photos.items.isEmpty);
      gallery.photos.add(SuggestedPhoto('later', Uint8List(0)));
      gallery.updates.add(null);
      await until(() => photos.items.any((item) => item.id == 'later'));
      expect(photos.items.map((item) => item.id), ['later']);
      expect(gallery.fullFiles, 0);
    },
  );

  test('only visible idle time expires each suggestion; hidden and interaction pause it', () async {
    photos.dispose();
    photos = RecentPhotos(
      library: gallery,
      directory: () async => folder,
      supported: true,
      suggestionDuration: const Duration(milliseconds: 100),
    );
    photos.setVisible(true);
    await until(() => photos.items.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(photos.items, hasLength(2)); // discovered but not seen
    photos.setShowing({'one'});
    await Future<void>.delayed(const Duration(milliseconds: 25));
    photos.setShowing({'one'}, interacting: true);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(photos.items, hasLength(2));
    photos.setShowing({'one'});
    await until(() => photos.items.length == 1);
    expect(photos.items.single.id, 'two'); // offscreen keeps its whole budget
    photos.setShowing({'two'});
    photos.setVisible(false);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(photos.items.single.id, 'two');
    photos.setVisible(true);
    await photos.refresh();
    photos.setShowing({'two'});
    await until(() => photos.items.isEmpty);
    await photos.refresh();
    expect(photos.items, isEmpty); // consumed suggestions never reappear
  });

  test(
    'library deletion removes a suggestion and newer items sort first',
    () async {
      photos.setVisible(true);
      await until(() => photos.items.length == 2);
      gallery.photos.removeWhere((photo) => photo.id == 'one');
      gallery.photos.add(
        SuggestedPhoto(
          'new',
          Uint8List(0),
          suggestedAt: DateTime.now().millisecondsSinceEpoch + 1000,
        ),
      );
      gallery.updates.add(null);
      await until(() => photos.items.any((photo) => photo.id == 'new'));
      expect(photos.items.map((photo) => photo.id), ['new', 'two']);
      expect(gallery.fullFiles, 0);
    },
  );

  test(
    'reopening restores unconsumed suggestions and remaining visible time',
    () async {
      photos.dispose();
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
        suggestionDuration: const Duration(milliseconds: 150),
      );
      photos.setVisible(true);
      await until(() => photos.items.length == 2);
      photos.setShowing({'one'});
      await Future<void>.delayed(const Duration(milliseconds: 40));
      photos.setVisible(false);
      await photos.pendingWrites;
      photos.dispose();
      photos = RecentPhotos(
        library: gallery,
        directory: () async => folder,
        supported: true,
        suggestionDuration: const Duration(milliseconds: 150),
      );
      photos.setVisible(true);
      await until(() => photos.items.length == 2);
      photos.setShowing({'one'});
      await until(() => photos.items.length == 1);
      expect(photos.items.single.id, 'two');
    },
  );

  test('direct disposal saves visible budget and restores it on recreation', () async {
    photos.dispose();
    photos = RecentPhotos(
      library: gallery,
      directory: () async => folder,
      supported: true,
      suggestionDuration: const Duration(seconds: 10),
    );
    photos.setVisible(true);
    await until(() => photos.items.length == 2);
    await photos.pendingWrites;
    photos.setShowing({'one'});
    await Future<void>.delayed(const Duration(milliseconds: 25));
    // This is SendScreen.dispose's actual path: no preceding visibility event.
    photos.dispose();
    final closingWrites = photos.pendingWrites;
    // The next screen is allowed to start immediately, without knowing the
    // previous model's write Future.
    photos = RecentPhotos(
      library: gallery,
      directory: () async => folder,
      supported: true,
    );
    photos.setVisible(true);
    await closingWrites;
    final file = File('${folder.path}/recent-photo-suggestions.json');
    final saved = jsonDecode(await file.readAsString()) as Map;
    final pending = (saved['pending'] as List).cast<Map>();
    final remaining =
        pending.singleWhere((item) => item['id'] == 'one')['remainingMs']
            as int;
    expect(remaining, inExclusiveRange(0, 10000));
    expect(
      pending.singleWhere((item) => item['id'] == 'two')['remainingMs'],
      10000,
    );
    await until(() => photos.items.length == 2);
    await photos.pendingWrites;
    final restored = jsonDecode(await file.readAsString()) as Map;
    expect(
      (restored['pending'] as List).cast<Map>().singleWhere(
        (item) => item['id'] == 'one',
      )['remainingMs'],
      remaining,
    );
  });

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
