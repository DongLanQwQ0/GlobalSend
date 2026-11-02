import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';

import 'native_drag_render_fixture.dart';
import 'widget_test.dart' show signedIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      'confirmed staged file, folder and text expose real drag content on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = const Size(950, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <MethodCall>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          SystemBridge.channel,
          (call) async => call.method == 'windowVisible' ? true : null,
        );
        messenger.setMockMethodCallHandler(FileShareBridge.channel, (
          call,
        ) async {
          calls.add(call);
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(SystemBridge.channel, null);
          messenger.setMockMethodCallHandler(FileShareBridge.channel, null);
        });
        final c = signedIn()
          ..stagedFiles.addAll(['F:/fixture/picture.png', 'F:/fixture/folder'])
          ..stagedDirectoryNames['F:/fixture/folder'] = 'folder'
          ..stagedTexts.add('confirmed clipboard text');
        await tester.pumpWidget(GlobalSendApp(controller: c));
        await tester.pumpAndSettle();
        final cards = find.byWidgetPredicate(
          (widget) =>
              widget is ContentDragSurface &&
              widget.entry.id.startsWith('staged-'),
        );
        expect(cards, findsNWidgets(3));
        final values = tester
            .widgetList<ContentDragSurface>(cards)
            .map((card) => card.entry)
            .toList();
        expect(values[0].dragPaths, ['F:/fixture/picture.png']);
        expect(values[1].dragPaths, ['F:/fixture/folder']);
        expect(values[1].isDirectory, isTrue);
        expect(values[2].text, 'confirmed clipboard text');
        if (platform == TargetPlatform.iOS) {
          final sources =
              (calls
                          .lastWhere((call) => call.method == 'setDragSources')
                          .arguments
                      as Map)['sources']
                  as List;
          expect(
            sources.cast<Map>().any(
              (value) =>
                  (value['paths'] as List).contains('F:/fixture/picture.png'),
            ),
            isTrue,
          );
          expect(
            sources.cast<Map>().any(
              (value) =>
                  (value['texts'] as List).contains('confirmed clipboard text'),
            ),
            isTrue,
          );
        } else {
          final input = await tester.startGesture(
            tester.getCenter(cards.first),
            kind: PointerDeviceKind.touch,
          );
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 1),
          );
          await pumpNativeDrag(tester);
          expect(c.dragged, ['staged-file-F:/fixture/picture.png']);
          expect(c.draggedKinds, ['touch']);
          await input.up();
          await tester.pumpAndSettle();
        }
        expect(c.stagedFiles, hasLength(2));
        expect(c.stagedTexts, ['confirmed clipboard text']);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
