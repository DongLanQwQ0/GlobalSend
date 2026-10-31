import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/recent_photos.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/system_bridge.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' show PreviewController;

class MediaController extends PreviewController {
  MediaController(this.folder);
  final Directory folder;
  @override
  Future<Directory> Function() get stateDirectory =>
      () async => folder;
  @override
  Future<void> stageInputs(List<String> paths, List<String> texts) async {
    stagedFiles.addAll(paths);
    stagedTexts.addAll(texts);
    changed();
  }
}

Future<void> settleModelIO(WidgetTester tester, Future<void> operation) async {
  var done = false;
  Object? failure;
  operation.then(
    (_) {
      done = true;
    },
    onError: (Object error) {
      failure = error;
      done = true;
    },
  );
  for (var attempt = 0; attempt < 200 && !done; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    done,
    isTrue,
    reason:
        'Flush model file IO through both the test clock and the real IO loop',
  );
  if (failure != null) throw failure!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'media recommendations remain in the queue alongside clipboard and staged content',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardSuggestion')
          return {'available': true, 'revision': 'fixture', 'kind': 'text'};
        if (call.method == 'windowVisible') return true;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final folder = Directory('../artifacts/tmp/suggestions83/widget-state')
          .absolute;
      await tester.runAsync(() => folder.create(recursive: true));
      final c = MediaController(folder)
        ..api = CenterApi('https://example.invalid', token: 'fixture')
        ..profile = ServerProfile(
          baseUrl: 'https://example.invalid',
          instanceId: 'fixture',
          deviceId: 'self',
        )
        ..devices = [
          {'deviceId': 'phone', 'name': '我的手机', 'online': true},
        ]
        ..connected = true;
      c.stagedTexts.add('已确认的文字');
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
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 180, 180),
        Paint()..color = const Color(0xff849cb0),
      );
      canvas.drawCircle(
        const Offset(120, 50),
        28,
        Paint()..color = const Color(0xfff5d293),
      );
      final bytes = await tester.runAsync(() async {
        final image = await recorder.endRecording().toImage(180, 180);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      });
      photos.items = [
        SuggestedPhoto(
          'photo-fixture',
          bytes!,
          path: '/fixture/photo.jpg',
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
      expect(
        find.byKey(const ValueKey('clipboard-suggestion')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('send-queue-list')),
          matching: find.byKey(const ValueKey('suggested-photo-photo-fixture')),
        ),
        findsOneWidget,
      );
      expect(c.stagedFiles, isEmpty);
      expect(find.text('待发送 · 1'), findsOneWidget);
      for (final size in [const Size(390, 844), const Size(950, 650)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final queue = find.byKey(const ValueKey('send-queue-list'));
        await tester.drag(queue, const Offset(-220, 0));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '../artifacts/tmp/suggestions83/queue-${size.width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      final tile = find.byKey(const ValueKey('suggested-photo-photo-fixture'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pump();
      await settleModelIO(tester, photos.pendingWrites);
      await tester.pumpAndSettle();
      expect(c.stagedFiles, ['/fixture/photo.jpg']);
      expect(c.stagedSends, isEmpty);
      expect(photos.items, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await settleModelIO(tester, photos.pendingWrites);
      await tester.runAsync(() => folder.delete(recursive: true));
    },
  );
}
