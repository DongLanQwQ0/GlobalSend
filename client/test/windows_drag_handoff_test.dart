import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_drag_surface.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

import 'native_drag_render_fixture.dart';

void main() {
  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets(
      '$kind keeps one avatar until actual OLE ownership; late ack cannot revive it',
      (tester) async {
        final calls = <Map<String, Object>>[];
        final replies = <Completer<bool>>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method != 'dragOut') return null;
          calls.add(Map<String, Object>.from(call.arguments as Map));
          final reply = Completer<bool>();
          replies.add(reply);
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
                    id: 'handoff',
                    kind: 'text',
                    title: '卡片',
                    source: '',
                    text: '内容',
                  ),
                  onExport: (kind) async {
                    await SystemBridge.dragOut(text: '内容', pointerKind: kind);
                  },
                  child: const SizedBox(
                    key: ValueKey('source'),
                    width: 180,
                    height: 160,
                  ),
                ),
              ),
            ),
          ),
        );
        final origin = tester.getCenter(find.byKey(const ValueKey('source')));
        final avatar = find.byKey(const ValueKey('drag-feedback-handoff'));
        for (var repeat = 0; repeat < 3; ++repeat) {
          final input = await tester.startGesture(origin, kind: kind);
          if (kind == PointerDeviceKind.touch) {
            await tester.pump(
              kLongPressTimeout - const Duration(milliseconds: 1),
            );
            expect(calls, hasLength(repeat));
            expect(avatar, findsNothing);
            await tester.pump(const Duration(milliseconds: 1));
          } else {
            await input.moveBy(const Offset(30, 0));
          }
          await pumpNativeDrag(tester);
          expect(
            calls,
            hasLength(repeat + 1),
            reason: 'no extra movement after the hold threshold',
          );
          expect(calls.last['previewRgba'], isNotEmpty);
          expect(
            avatar,
            findsOneWidget,
            reason: 'queued native export is not ownership',
          );
          if (repeat == 2) {
            replies.last.complete(false); // Native rejected before ownership.
            await pumpNativeDrag(tester);
            expect(avatar, findsNothing);
            await signalNativeDragStarted(calls.last);
            await tester.pump();
            expect(avatar, findsNothing);
            await input.up();
            await tester.pump();
            continue;
          }
          if (repeat != 0) {
            await signalNativeDragStarted(calls.first);
            await tester.pump();
            expect(
              avatar,
              findsOneWidget,
              reason: 'old session must not hide the new avatar',
            );
          }
          await input.moveBy(const Offset(20, 0));
          await tester.pump();
          expect(calls, hasLength(repeat + 1));
          expect(avatar, findsOneWidget);
          await signalNativeDragStarted(calls.last);
          await tester.pump();
          expect(avatar, findsNothing);
          await signalNativeDragStarted(
            calls.last,
          ); // Duplicate start notification.
          for (var move = 0; move < 3; ++move) {
            await input.moveBy(const Offset(20, 0));
            await tester.pump();
            expect(
              avatar,
              findsNothing,
              reason: 'onDragEnd cannot resurrect feedback',
            );
            expect(calls, hasLength(repeat + 1));
          }
          replies.last.complete(true);
          await pumpNativeDrag(tester);
          await input.up();
          await tester.pump();
          await signalNativeDragStarted(calls.last);
          await tester.pump();
          expect(avatar, findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
