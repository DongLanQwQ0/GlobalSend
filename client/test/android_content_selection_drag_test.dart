import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/screen.dart';
import 'package:globalsend/ui_session.dart';
import 'package:globalsend/ui_tokens.dart';

import 'system_font_fixture.dart';
import 'widget_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  for (final tab in [0, 1]) {
    testWidgets(
      '${tab == 0 ? 'receive' : 'history'} Android holds drag the selection and only taps change it',
      (tester) async {
        tester.view.physicalSize = const Size(420, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final drags = <Map<String, dynamic>>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DockPlatform.channel, (call) async {
              if (call.method == 'startDrag')
                drags.add(Map<String, dynamic>.from(call.arguments as Map));
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(DockPlatform.channel, null),
        );
        final c = fixture.signedIn()
          ..dock = [
            DockEntry(
              id: 'file',
              kind: 'file',
              title: 'file.bin',
              source: 'phone',
              outgoing: tab == 1,
              status: 'received',
              localPath: 'content://original/file',
            ),
            DockEntry(
              id: 'text',
              kind: 'text',
              title: '文本',
              source: 'phone',
              outgoing: tab == 1,
              status: 'received',
              text: '待拖动的文字',
            ),
          ];
        final session = SendUiSession()
          ..page = 0
          ..contentTab = tab;
        await tester.pumpWidget(
          MaterialApp(
            theme: Ui.theme(),
            home: SendScreen(controller: c, session: session),
          ),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(SendScreen));
        Future<void> hold(
          String id,
          List<String> paths,
          List<String> texts,
          Set<String> selected,
        ) async {
          final count = drags.length;
          final pointer = await tester.startGesture(
            tester.getCenter(find.byKey(ValueKey('select-$id'))),
            kind: PointerDeviceKind.touch,
          );
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 80),
          );
          expect(
            drags.length,
            count + 1,
            reason: 'native drag starts before lifting this held pointer',
          );
          expect(drags.last['paths'], paths);
          expect(drags.last['texts'], texts);
          expect(Set<String>.from(state.selected), selected);
          expect(state.selecting, isTrue);
          expect(find.byType(Draggable<DockEntry>), findsNothing);
          await pointer.up();
          await tester.pumpAndSettle();
        }

        await hold('file', ['content://original/file'], [], {'file'});
        await hold('text', ['content://original/file'], [], {'file'});
        await tester.tap(find.byKey(const ValueKey('select-text')));
        await tester.pumpAndSettle();
        await hold('text', ['content://original/file'], ['待拖动的文字'], {
          'file',
          'text',
        });
        await tester.tap(find.byKey(const ValueKey('select-file')));
        await tester.pumpAndSettle();
        await hold('file', [], ['待拖动的文字'], {'text'});
        await tester.tap(find.byKey(const ValueKey('select-text')));
        await tester.pumpAndSettle();
        await hold('file', ['content://original/file'], [], {});
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(state.selecting, isFalse);
        expect(state.selected, isEmpty);
        expect(session.page, 0);
        expect(session.contentTab, tab);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
