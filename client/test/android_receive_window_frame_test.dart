import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/android_receive_window_frame.dart';
import 'package:globalsend/receipt_preview.dart';
import 'package:globalsend/compact_content_card.dart';
import 'package:globalsend/models.dart';

void main() {
  testWidgets(
    'default compact window keeps both batch copy actions reachable without scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(320, 380);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entries = List.generate(
        2,
        (index) => DockEntry(
          id: '$index',
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '可以直接操作的接收内容',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AndroidReceiveWindowFrame(
            onWindowGesture: (_, _) async => true,
            child: ReceivedBatchPreview(
              embedded: true,
              entries: entries,
              onClose: () {},
              onCopy: (_) {},
              onView: (_) {},
              onExpand: () {},
              itemBuilder: (entry, _) => CompactContentCard(
                entry: entry,
                sender: '手机',
                timestamp: '12:34',
                onOpen: () {},
                onCopy: () {},
                copyKey: ValueKey('compact-copy-${entry.id}'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final entry in entries) {
        final rect = tester.getRect(
          find.byKey(ValueKey('compact-copy-${entry.id}')),
        );
        expect(rect.top, greaterThan(28));
        expect(rect.bottom, lessThanOrEqualTo(380 - 28));
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'bounded receipt has separate move and resize handles and antialiased clipping',
    (tester) async {
      final calls = <MethodCall>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 320,
            height: 380,
            child: AndroidReceiveWindowFrame(
              onWindowGesture: (method, value) async {
                calls.add(MethodCall(method, value));
                return true;
              },
              child: const Center(child: Text('收到内容')),
            ),
          ),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('receive-window-move')),
        const Offset(45, 25),
      );
      await tester.pumpAndSettle();
      expect(calls.map((call) => call.method), [
        'beginReceivedWindowGesture',
        'endReceivedWindowGesture',
      ]);
      expect(calls.first.arguments['resize'], false);
      expect(
        calls.last.arguments['downTimeMillis'],
        calls.first.arguments['downTimeMillis'],
      );
      calls.clear();
      await tester.drag(
        find.byKey(const ValueKey('receive-window-resize')),
        const Offset(45, 35),
      );
      await tester.pumpAndSettle();
      expect(calls.map((call) => call.method), [
        'beginReceivedWindowGesture',
        'endReceivedWindowGesture',
      ]);
      expect(calls.first.arguments['resize'], true);
      expect(
        calls.first.arguments.keys,
        unorderedEquals(['downTimeMillis', 'resize']),
      );
      final clip = tester.widget<ClipRRect>(
        find
            .descendant(
              of: find.byType(AndroidReceiveWindowFrame),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(clip.clipBehavior, Clip.antiAlias);
      expect(find.text('收到内容'), findsOneWidget);
    },
  );
  testWidgets(
    'native adjustment failure is actionable and does not crash the receiver',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AndroidReceiveWindowFrame(
            onWindowGesture: (_, _) async =>
                throw PlatformException(code: 'WINDOW_FAILURE'),
            child: const Text('保留内容'),
          ),
        ),
      );
      await tester.drag(
        find.byKey(const ValueKey('receive-window-move')),
        const Offset(40, 20),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法调整窗口'), findsOneWidget);
      expect(find.text('保留内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
