import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'windows_recommendation_drag_test.dart' show RecommendationController;
import 'native_drag_render_fixture.dart';
import 'system_font_fixture.dart';

class NativeStartController extends RecommendationController {
  NativeStartController(super.folder);
  final native = Completer<void>();
  final starts = <String>[];
  @override
  Future<void> dragOut(DockEntry entry, {String pointerKind = 'auto'}) {
    starts.add('$pointerKind:${entry.text}');
    return native.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'immediate native card drag retains queue and device drop destinations',
    (tester) async {
      tester.view.physicalSize = const Size(950, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final folder = Directory('../artifacts/tmp/native-start94/controller')
          .absolute;
      await tester.runAsync(() => folder.create(recursive: true));
      debugPrintSynchronously('native-start: folder ready');
      final c = NativeStartController(folder)
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
      c.stagedTexts.add('原有草稿');
      c.dock.add(
        DockEntry(
          id: 'source',
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '跨桌面拖动',
          status: 'received',
        ),
      );
      final bounds = <Map>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        if (call.method == 'queueDropBounds') bounds.add(call.arguments as Map);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(GlobalSendApp(controller: c));
      debugPrintSynchronously('native-start: mounted');
      await tester.pumpAndSettle();
      debugPrintSynchronously('native-start: settled');
      final source = find.byKey(const ValueKey('preview-source'));
      final input = await tester.startGesture(
        tester.getCenter(source),
        kind: PointerDeviceKind.mouse,
      );
      await input.moveBy(const Offset(30, 0));
      await pumpNativeDrag(tester);
      debugPrintSynchronously('native-start: source handed off');
      expect(c.starts, ['mouse:跨桌面拖动']);
      await tester.pump(const Duration(milliseconds: 32));
      expect(bounds.last['enabled'], true);
      expect(bounds.last['serverKey'], c.profile!.key);
      expect((bounds.last['devices'] as List).single['deviceId'], 'phone');
      await c.handleNativeDockEvent({
        'type': 'nativeDrop',
        'dropId': 'queue-drop',
        'paths': <String>[],
        'texts': ['放回待发'],
      });
      debugPrintSynchronously('native-start: queue drop consumed');
      await tester.pump(const Duration(milliseconds: 32));
      expect(c.stagedTexts, ['原有草稿', '放回待发']);
      await c.handleNativeDockEvent({
        'type': 'nativeDrop',
        'dropId': 'device-drop',
        'targetDeviceId': 'phone',
        'serverKey': c.profile!.key,
        'paths': <String>[],
        'texts': ['跨桌面拖动'],
      });
      debugPrintSynchronously('native-start: device drop consumed');
      await tester.pump(const Duration(milliseconds: 32));
      expect(c.delivered.single['targets'], ['phone']);
      expect(c.delivered.single['texts'], ['跨桌面拖动']);
      expect(c.stagedTexts, ['原有草稿', '放回待发']);
      c.native.complete();
      await pumpNativeDrag(tester);
      await input.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
