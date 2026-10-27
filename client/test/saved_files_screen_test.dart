import 'system_font_fixture.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/saved_files.dart';
import 'package:globalsend/saved_files_screen.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/saved_image_preview.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/app_icon.dart';

class GalleryController extends SendController {
  final library = <SavedFile>[];
  final forwarded = <(String, List<String>)>[];
  final deleted = <String>[];
  @override
  List<SavedFile> get savedFiles => List.of(library);
  @override
  Future<void> refreshSavedFiles({bool cleanup = false}) async {}
  @override
  Future<void> renameSavedFile(String id, String name) async {
    final index = library.indexWhere((file) => file.id == id);
    library[index] = library[index].renamed(name);
    changed();
  }

  @override
  Future<void> deleteSavedFiles(Iterable<String> ids) async {
    deleted.addAll(ids);
    library.removeWhere((file) => ids.contains(file.id));
    changed();
  }

  @override
  Future<void> forwardSavedFiles(String target, Iterable<String> ids) async {
    forwarded.add((target, ids.toList()));
  }
}

SavedFile entry(String id, String name, String path, int hours, int size) =>
    SavedFile(
      id: id,
      profileKey: 'test',
      deviceId: 'receiver',
      groupId: 'group',
      transferId: id,
      fileId: id,
      path: path,
      name: name,
      size: size,
      receivedAtMillis: DateTime(
        2026,
        10,
        25,
        12,
      ).subtract(Duration(hours: hours)).millisecondsSinceEpoch,
    );

void main() {
  setUpAll(loadSystemTestFonts);
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DockPlatform.channel, (call) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DockPlatform.channel, null);
  });
  late Directory fixture;
  late File photo;
  Future<void> decode(ImageProvider provider) async {
    final done = Completer<void>();
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (image, synchronousCall) {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 5));
    } finally {
      stream.removeListener(listener);
    }
  }

  setUpAll(() async {
    fixture = await Directory('build/test-fixtures/library-ui')
        .create(recursive: true);
    final recorder = ui.PictureRecorder();
    // A task-owned image fixture; no user photo is read for visual checks.
    final scene = Canvas(recorder);
    scene.drawRect(
      const Rect.fromLTWH(0, 0, 640, 420),
      Paint()..color = const Color(0xffd4e9e0),
    );
    scene.drawCircle(
      const Offset(500, 95),
      46,
      Paint()..color = const Color(0xfff3c47a),
    );
    final hills = Path()
      ..moveTo(0, 340)
      ..quadraticBezierTo(160, 120, 330, 310)
      ..quadraticBezierTo(470, 190, 640, 320)
      ..lineTo(640, 420)
      ..lineTo(0, 420)
      ..close();
    scene.drawPath(hills, Paint()..color = const Color(0xff49795f));
    final image = await recorder.endRecording().toImage(640, 420);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    photo = await File('${fixture.path}/山间图片.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });

  GalleryController controller() => GalleryController()
    ..connected = true
    ..devices = [
      {
        'deviceId': 'online',
        'name': '我的手机',
        'platform': 'android',
        'online': true,
      },
      {
        'deviceId': 'offline',
        'name': '离线电脑',
        'platform': 'windows',
        'online': false,
      },
    ]
    ..library.addAll([
      entry('image', '山间图片.png', photo.path, 0, 82340),
      entry('notes', '会议记录与待办事项.txt', '${fixture.path}/notes.txt', 1, 4096),
      entry('archive', '项目资料.zip', '${fixture.path}/archive.zip', 2, 12582912),
      entry('slides', '演示文稿.pdf', '${fixture.path}/slides.pdf', 3, 245760),
    ]);

  Future<void> show(
    WidgetTester tester,
    GalleryController c, {
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await decode(ResizeImage(FileImage(photo), width: 320));
      await decode(ResizeImage(FileImage(photo), width: 390));
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: Ui.theme().copyWith(platform: TargetPlatform.android),
          home: SavedFilesScreen(controller: c),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('build/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'library uses a two-column grid with real thumbnails and sorting; long press drags and selects the whole tile',
    (tester) async {
      final c = controller(), boundary = GlobalKey();
      addTearDown(c.dispose);
      await show(tester, c, boundary: boundary);
      final grid = tester.widget<GridView>(
        find.byKey(const ValueKey('saved-files-grid')),
      );
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        2,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('saved-file-image'))).dy,
        tester.getTopLeft(find.byKey(const ValueKey('saved-file-notes'))).dy,
      );
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('4 个文件'), findsOneWidget);
      for (
        var attempt = 0;
        attempt < 20 &&
            tester
                .widgetList<RawImage>(find.byType(RawImage))
                .every((image) => image.image == null);
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      expect(
        tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null),
        isTrue,
      );
      await capture(tester, boundary, 'library-mobile');
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(AppCheckedPopupMenuItem<SavedFilesSort>, '最大优先'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('saved-file-archive'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('saved-file-image'))).dy,
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('saved-file-archive')));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('saved-file-slides')));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重命名'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'library rename, online forwarding and confirmed deletion use selected file identities',
    (tester) async {
      final c = controller();
      addTearDown(c.dispose);
      await show(tester, c);
      await tester.longPress(find.byKey(const ValueKey('saved-file-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('library-rename-input')),
        '新版记录.txt',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(c.library[1].name, '新版记录.txt');
      await tester.tap(find.text('转发'));
      await tester.pumpAndSettle();
      expect(find.text('我的手机'), findsOneWidget);
      expect(find.text('离线电脑'), findsNothing);
      await tester.tap(find.text('我的手机'));
      await tester.pumpAndSettle();
      expect(c.forwarded.single.$1, 'online');
      expect(c.forwarded.single.$2, ['notes']);
      await tester.longPress(find.byKey(const ValueKey('saved-file-notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('仅删除本机副本。'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(c.deleted, ['notes']);
      expect(c.library, hasLength(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image preview opens from a Chinese filename and supports wheel zoom, pinch, reset and return',
    (tester) async {
      final c = controller(), boundary = GlobalKey();
      addTearDown(c.dispose);
      await show(tester, c, boundary: boundary);
      await tester.tap(find.byKey(const ValueKey('saved-file-image')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.byType(SavedImagePreview), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(
        find.byKey(const ValueKey('saved-image-viewer')),
      );
      final matrix = viewer.transformationController!;
      expect(matrix.value.getMaxScaleOnAxis(), 1);
      await tester.tap(find.byTooltip('放大'));
      await tester.pumpAndSettle();
      expect(matrix.value.getMaxScaleOnAxis(), greaterThan(1));
      await tester.tap(find.text('适应窗口'));
      await tester.pumpAndSettle();
      expect(matrix.value.getMaxScaleOnAxis(), 1);
      final center = tester.getCenter(
        find.byKey(const ValueKey('saved-image-viewer')),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          scrollDelta: const Offset(0, -100),
        ),
      );
      await tester.pumpAndSettle();
      expect(matrix.value.getMaxScaleOnAxis(), greaterThan(1));
      await tester.tap(find.text('适应窗口'));
      await tester.pumpAndSettle();
      final left = await tester.startGesture(
        center - const Offset(30, 0),
        pointer: 1,
      );
      final right = await tester.startGesture(
        center + const Offset(30, 0),
        pointer: 2,
      );
      await left.moveTo(center - const Offset(65, 0));
      await right.moveTo(center + const Offset(65, 0));
      await tester.pump();
      expect(matrix.value.getMaxScaleOnAxis(), greaterThan(1));
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('适应窗口'));
      await tester.pumpAndSettle();
      await capture(tester, boundary, 'library-image-preview');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(SavedFilesScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid image shows an explicit external-open fallback', (
    tester,
  ) async {
    final file = (await tester.runAsync(
      () => File('${fixture.path}/损坏.png').writeAsString('not an image'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: SavedImagePreview(path: file.path, title: '损坏.png'),
      ),
    );
    for (
      var frame = 0;
      frame < 20 && find.text('无法预览这张图片').evaluate().isEmpty;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    expect(find.text('无法预览这张图片'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '用其他应用打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'content URI thumbnails and image preview decode in place and release their descriptor leases',
    (tester) async {
      final c = controller();
      addTearDown(c.dispose);
      const location = 'content://fixture/document/image';
      c.library[0] = entry('image', '中文原图.png', location, 0, 82340);
      final live = <String>{};
      var serial = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(ReceiveDestination.channel, (
        call,
      ) async {
        if (call.method == 'open') {
          final handle = 'image-${++serial}';
          live.add(handle);
          return {
            'location': location,
            'ioPath': photo.path,
            'handle': handle,
            'name': '中文原图.png',
            'size': photo.lengthSync(),
          };
        }
        if (call.method == 'close') {
          live.remove(call.arguments['handle']);
          return null;
        }
        throw StateError('Unexpected ${call.method}');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          ReceiveDestination.channel,
          null,
        ),
      );
      Future<void> awaitPixels() async {
        for (var frame = 0; frame < 30; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          final pixels = tester.widgetList<RawImage>(find.byType(RawImage));
          if (pixels.isNotEmpty &&
              pixels.every((image) => image.image != null)) {
            return;
          }
        }
        fail('URI image did not decode');
      }

      await show(tester, c);
      await awaitPixels();
      expect(live, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('saved-file-image')));
      await tester.pumpAndSettle();
      await awaitPixels();
      expect(find.byType(SavedImagePreview), findsOneWidget);
      expect(live, hasLength(2));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(live, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(live, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
