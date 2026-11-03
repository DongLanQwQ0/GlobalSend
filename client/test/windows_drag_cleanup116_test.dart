import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'native_drag_render_fixture.dart';

class DragCleanupBinding extends AutomatedTestWidgetsFlutterBinding {
  Future<void> holdDispatch(Future<void> release) => lockEvents(() => release);
}

void main() {
  final binding = DragCleanupBinding();
  for (final acknowledge in [false, true]) {
    testWidgets(
      'Windows ends avatar synchronously with pointer dispatch locked, ack=$acknowledge',
      (tester) async {
        final reply = Completer<bool>();
        final locked = Completer<void>();
        final calls = <Map<String, Object>>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method != 'dragOut') return null;
          calls.add(Map<String, Object>.from(call.arguments as Map));
          return reply.future;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: Center(
                child: ContentDragSurface(
                  entry: DockEntry(
                    id: 'cleanup',
                    kind: 'text',
                    title: '文本',
                    source: '',
                    text: '合成内容',
                  ),
                  onExport: (kind) =>
                      SystemBridge.dragOut(text: '合成内容', pointerKind: kind),
                  child: const SizedBox(
                    key: ValueKey('cleanup-source'),
                    width: 160,
                    height: 160,
                  ),
                ),
              ),
            ),
          ),
        );
        final input = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('cleanup-source'))),
          kind: PointerDeviceKind.mouse,
        );
        await input.moveBy(const Offset(30, 0));
        await pumpNativeDrag(tester);
        expect(calls, hasLength(1));
        unawaited(binding.holdDispatch(locked.future));
        try {
          if (acknowledge) await signalNativeDragStarted(calls.single);
          reply.complete(false);
          await pumpNativeDrag(tester);
          expect(
            find.byKey(const ValueKey('drag-feedback-cleanup')),
            findsNothing,
            reason: 'completion must destroy the avatar without waiting for queued PointerCancel',
          );
        } finally {
          locked.complete();
          await tester.pump();
          await input.up();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
