import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/saved_files.dart';
import 'package:globalsend/saved_files_screen.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/bulk_file_drag.dart';

import 'system_font_fixture.dart';

class CategoryLibrary extends SendController {
  final files = <SavedFile>[];
  @override
  List<SavedFile> get savedFiles => files.toList();
  @override
  Future<void> refreshLocalLibrary({bool migrate = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.windows,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform categories scope visible count, select-all and bulk drag without growing the toolbar',
      (tester) async {
        tester.view.physicalSize = platform == TargetPlatform.windows
            ? const Size(950, 650)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = CategoryLibrary();
        addTearDown(c.dispose);
        for (final name in [
          'photo.jpg',
          'notes.txt',
          'clip.mp4',
          'paper.pdf',
        ]) {
          c.files.add(
            SavedFile(
              id: name,
              profileKey: '',
              deviceId: '',
              groupId: '',
              transferId: '',
              fileId: name,
              path: 'F:/fixture/$name',
              name: name,
              size: 100,
              receivedAtMillis: 0,
            ),
          );
        }
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: Ui.theme(
                const Appearance(
                  mode: AppearanceMode.dark,
                  accent: AccentColor.purple,
                ),
              ).copyWith(platform: platform),
              home: SavedFilesScreen(controller: c),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final toolbar = find.byKey(const ValueKey('library-toolbar'));
        final height = tester.getSize(toolbar).height;
        await tester.tap(find.byKey(const ValueKey('library-category-filter')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('图片').last);
        await tester.pumpAndSettle();
        expect(tester.getSize(toolbar).height, height);
        expect(find.text('1 个文件'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('saved-file-photo.jpg')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('saved-file-notes.txt')),
          findsNothing,
        );
        final drag = tester.widget<BulkFileDrag>(
          find.byKey(const ValueKey('library-drag-all')),
        );
        expect(drag.paths, ['F:/fixture/photo.jpg']);
        if (platform == TargetPlatform.android) {
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final folder = await Directory(
              '../artifacts/tmp/cleanup-library112',
            ).create(recursive: true);
            await File('${folder.path}/native-category.rgba')
                .writeAsBytes(data!.buffer.asUint8List());
            await File('${folder.path}/native-category.size')
                .writeAsString('${image.width},${image.height}');
            image.dispose();
          });
        }
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全选'));
        await tester.pumpAndSettle();
        final state = tester.state<SavedFilesScreenState>(
          find.byType(SavedFilesScreen),
        );
        expect(state.selected, {'photo.jpg'});
        state.finishSelection();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('library-category-filter')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('音频').last);
        await tester.pumpAndSettle();
        expect(find.text('此分类暂无文件'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('library-category-filter')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部').last);
        await tester.pumpAndSettle();
        expect(find.text('4 个文件'), findsOneWidget);
        expect(c.files, hasLength(4));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
