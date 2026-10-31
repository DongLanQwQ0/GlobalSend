import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/recent_photos.dart';
import 'package:globalsend/content_drag_surface.dart';

import 'widget_test.dart' show PreviewController;
import 'media_suggestion_queue_test.dart' show settleModelIO;
import 'native_drag_render_fixture.dart';
import 'system_font_fixture.dart';

class RecommendationController extends PreviewController {
  RecommendationController(this.folder);
  final Directory folder;
  final exports = <String>[];
  final previews = <Map<String, Object>>[];
  bool accepted = false;
  @override
  Future<Directory> Function() get stateDirectory =>
      () async => folder;
  @override
  Future<bool> dragClipboard({String pointerKind = 'auto'}) async {
    exports.add(pointerKind);
    previews.add(SystemBridge.dragPreviewArguments);
    return accepted;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'Windows recommendations use native mouse and touch drag without staging placeholders',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(950, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final folder = Directory('../artifacts/tmp/windows-suggestions86/widget')
          .absolute;
      await tester.runAsync(() => folder.create(recursive: true));
      final c = RecommendationController(folder)
        ..api = CenterApi('https://example.invalid', token: 'fixture')
        ..profile = ServerProfile(
          baseUrl: 'https://example.invalid',
          instanceId: 'fixture',
          deviceId: 'self',
        )
        ..devices = [
          {'deviceId': 'phone', 'name': '手机', 'online': true},
        ]
        ..connected = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final fileExports = <Map>[];
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardSuggestion')
          return {
            'available': true,
            'revision': 'clipboard-fixture',
            'kind': 'image',
          };
        if (call.method == 'windowVisible') return true;
        if (call.method == 'dragOut') {
          fileExports.add(call.arguments as Map);
          return c.accepted;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: GlobalSendApp(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic screen = tester.state(find.byType(SendScreen));
      final RecentPhotos photos = screen.recentPhotos;
      await settleModelIO(tester, photos.setEnabled(true));
      final bytes = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 120, 120),
          Paint()..color = const Color(0xff347aad),
        );
        final image = await recorder.endRecording().toImage(120, 120);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return bytes!.buffer.asUint8List();
      });
      photos.items = [
        SuggestedPhoto(
          'photo',
          bytes!,
          path: 'F:/fixture/photo.jpg',
          name: 'photo.jpg',
        ),
      ];
      screen.refreshPhotoSuggestions();
      await tester.pumpAndSettle();
      await settleModelIO(
        tester,
        precacheImage(
          MemoryImage(bytes),
          tester.element(find.byType(SendScreen)),
        ),
      );
      await tester.runAsync(() async {
        await File('${folder.parent.path}/fixture.png').writeAsBytes(bytes);
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        await File('${folder.parent.path}/source.rgba')
            .writeAsBytes(data!.buffer.asUint8List());
        await File('${folder.parent.path}/source.json').writeAsString(
          jsonEncode({'width': image.width, 'height': image.height}),
        );
        image.dispose();
      });
      Future<void> drag(Finder source, PointerDeviceKind kind) async {
        final before = c.exports.length + fileExports.length;
        await tester.ensureVisible(source);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(source),
          kind: kind,
        );
        if (kind == PointerDeviceKind.mouse)
          await gesture.moveBy(const Offset(28, 0));
        else
          await tester.pump(const Duration(milliseconds: 600));
        for (
          var i = 0;
          i < 20 && c.exports.length + fileExports.length == before;
          i++
        ) {
          await pumpNativeDrag(tester);
        }
        await settleModelIO(tester, photos.pendingWrites);
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();
        debugPrint(
          'recommendation native drag complete: $kind, exports=${c.exports.length + fileExports.length}',
        );
      }

      final clipboard = find.byKey(const ValueKey('clipboard-suggestion'));
      expect(
        Theme.of(tester.element(clipboard)).platform,
        TargetPlatform.windows,
      );
      expect(
        tester
            .widget<ContentDragSurface>(
              find.ancestor(
                of: clipboard,
                matching: find.byType(ContentDragSurface),
              ),
            )
            .nativeOnly,
        isTrue,
      );
      await drag(clipboard, PointerDeviceKind.mouse);
      expect(c.exports, ['mouse']);
      expect(c.previews.single['previewRgba'], isNotEmpty);
      await tester.runAsync(() async {
        final prefix = '${folder.parent.path}/clipboard-preview';
        final image = c.previews.first;
        await File('$prefix.rgba')
            .writeAsBytes(image['previewRgba'] as List<int>);
        await File('$prefix.json').writeAsString(
          jsonEncode({
            'width': image['previewWidth'],
            'height': image['previewHeight'],
          }),
        );
      });
      expect(clipboard, findsOneWidget);
      expect(c.stagedTexts, isEmpty);
      expect(c.stagedFiles, isEmpty);
      expect(c.clipboardReads, 0);
      c.accepted = true;
      await drag(clipboard, PointerDeviceKind.touch);
      expect(c.exports, ['mouse', 'touch']);
      expect(clipboard, findsNothing);
      expect(c.stagedFiles, isEmpty);
      await tester.runAsync(() async {
        final image =
            await (capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        await File('${folder.parent.path}/after-clipboard.rgba')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      final photo = find.byKey(const ValueKey('suggested-photo-photo'));
      c.accepted = false;
      await drag(photo, PointerDeviceKind.mouse);
      expect(fileExports.last['paths'], ['F:/fixture/photo.jpg']);
      expect(photo, findsOneWidget);
      c.accepted = true;
      await drag(photo, PointerDeviceKind.touch);
      await settleModelIO(tester, photos.pendingWrites);
      expect(fileExports.last['pointerKind'], 'touch');
      expect(fileExports.last['previewRgba'], isNotEmpty);
      final pixels = fileExports.last['previewRgba'] as List<int>;
      final middle =
          ((fileExports.last['previewHeight'] as int) ~/
                  2 *
                  (fileExports.last['previewWidth'] as int) +
              (fileExports.last['previewWidth'] as int) ~/ 2) *
          4;
      expect(pixels[middle + 2], greaterThan(pixels[middle] + 40));
      await tester.runAsync(() async {
        final prefix = '${folder.parent.path}/photo-preview';
        final image = fileExports.last;
        await File('$prefix.rgba')
            .writeAsBytes(image['previewRgba'] as List<int>);
        await File('$prefix.json').writeAsString(
          jsonEncode({
            'width': image['previewWidth'],
            'height': image['previewHeight'],
          }),
        );
      });
      expect(photos.items, isEmpty);
      expect(c.stagedFiles, isEmpty);
      expect(c.stagedSends, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settleModelIO(tester, photos.pendingWrites);
      await tester.runAsync(() => folder.delete(recursive: true));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
