import 'dart:ui' show Rect, Size;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/system_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemBridge.channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemBridge.channel, null),
  );

  test(
    'file export carries the actual touch or pen source to Windows',
    () async {
      for (final kind in ['touch', 'stylus']) {
        expect(
          await SystemBridge.dragOut(
            paths: ['F:/received/photo.png'],
            pointerKind: kind,
          ),
          true,
        );
        expect(calls.last.method, 'dragOut');
        expect(calls.last.arguments, {
          'paths': ['F:/received/photo.png'],
          'pointerKind': kind,
        });
      }
    },
  );
  test('explicit mouse export and existing default callers keep their entry points', () async {
    await SystemBridge.dragOut(text: '鼠标内容', pointerKind: 'mouse');
    expect(calls.last.arguments, {'text': '鼠标内容', 'pointerKind': 'mouse'});
    await SystemBridge.dragOut(text: '旧调用');
    expect(calls.last.arguments, {'text': '旧调用', 'pointerKind': 'auto'});
  });
  test('queue region sends physical client geometry and disables when no target is visible', () async {
    await SystemBridge.setQueueDropBounds(
      const Rect.fromLTRB(20, 40, 220, 240),
      surface: const Size(950, 650),
    );
    expect(calls.single.method, 'queueDropBounds');
    expect(calls.single.arguments, {
      'enabled': true,
      'left': 20.0,
      'top': 40.0,
      'right': 220.0,
      'bottom': 240.0,
      'surfaceWidth': 950.0,
      'surfaceHeight': 650.0,
    });
    await SystemBridge.setQueueDropBounds(null);
    expect(calls.last.arguments, {'enabled': false});
  });
}
