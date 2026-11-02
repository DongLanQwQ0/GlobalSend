import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'native_drag_render_fixture.dart';
import 'widget_test.dart' show PreviewController;

class ToolbarController extends PreviewController {
  final exports = <String>[];
  final previews = <Map<String, Object>>[];
  @override
  Future<bool> dragClipboard({String pointerKind = 'auto'}) async {
    exports.add(pointerKind);
    previews.add(SystemBridge.dragPreviewArguments);
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets(
      'Windows toolbar clipboard exports on $kind without confirming a suggestion',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(950, 650);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method == 'windowVisible') return true;
          if (call.method == 'clipboardSuggestion')
            return {
              'available': true,
              'revision': 'toolbar-copy',
              'kind': 'image',
            };
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
        );
        final c = ToolbarController()
          ..api = CenterApi('https://fixture.invalid', token: 'fixture')
          ..profile = ServerProfile(
            baseUrl: 'https://fixture.invalid',
            instanceId: 'fixture',
            deviceId: 'self',
          )
          ..connected = true
          ..stagedTexts.add('keep draft');
        await tester.pumpWidget(GlobalSendApp(controller: c));
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('add-clipboard'));
        final input = await tester.startGesture(
          tester.getCenter(button),
          kind: kind,
        );
        if (kind == PointerDeviceKind.touch) {
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 1),
          );
        } else {
          await input.moveBy(const Offset(28, 0));
        }
        await pumpNativeDrag(tester);
        expect(c.exports, [kind.name]);
        expect(c.previews.single['dragSessionId'], isA<int>());
        expect(
          c.previews.single.containsKey('previewRgba'),
          isFalse,
          reason: 'export actual clipboard content, not a toolbar screenshot',
        );
        expect(c.clipboardReads, 0);
        expect(c.stagedTexts, ['keep draft']);
        expect(c.stagedFiles, isEmpty);
        await input.up();
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(c.clipboardReads, 1, reason: 'click-to-add remains available');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets(
    'Apple clipboard toolbar registers its actual pasteboard provider region',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(950, 650);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        SystemBridge.channel,
        (call) async => call.method == 'windowVisible' ? true : null,
      );
      messenger.setMockMethodCallHandler(FileShareBridge.channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemBridge.channel, null);
        messenger.setMockMethodCallHandler(FileShareBridge.channel, null);
      });
      final c = ToolbarController()
        ..api = CenterApi('https://fixture.invalid', token: 'fixture')
        ..profile = ServerProfile(
          baseUrl: 'https://fixture.invalid',
          instanceId: 'fixture',
          deviceId: 'self',
        )
        ..connected = true;
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const ValueKey('add-clipboard')));
      final sources =
          (calls.lastWhere((call) => call.method == 'setDragSources').arguments
                  as Map)['sources']
              as List;
      expect(
        sources.cast<Map>().any(
          (source) =>
              source.containsKey('clipboardRevision') &&
              source['left'] == rect.left &&
              source['right'] == rect.right,
        ),
        isTrue,
      );
      expect(c.clipboardReads, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
