import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/saved_files_screen.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/ui_tokens.dart';
import 'package:globalsend/models.dart';

import 'saved_files_screen_test.dart' show GalleryController, entry;
import 'system_font_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  testWidgets(
    'Android first hold starts native drag before release and subsequent holds export selection without mutating it',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final drags = <Map<String, dynamic>>[];
      var selectionChanges = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DockPlatform.channel, (call) async {
            if (call.method == 'startDrag')
              drags.add(Map<String, dynamic>.from(call.arguments as Map));
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DockPlatform.channel, null),
      );
      final c = GalleryController()
        ..library.addAll([
          entry('a', 'a.bin', 'content://original/a', 0, 16),
          entry('b', 'b.bin', 'content://original/b', 1, 24),
        ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: SavedFilesScreen(
            controller: c,
            onSelectionChanged: () => selectionChanges++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(SavedFilesScreen));
      Future<void> hold(
        String id,
        List<String> expected,
        Set<String> selection,
      ) async {
        final before = drags.length;
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('saved-file-$id'))),
          kind: PointerDeviceKind.touch,
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
        expect(
          drags.length,
          before + 1,
          reason: 'native drag must start during this held pointer, not after another long press',
        );
        expect(drags.last['paths'], expected);
        expect(Set<String>.from(state.selected), selection);
        expect(find.byType(Draggable<DockEntry>), findsNothing);
        expect(find.byKey(const ValueKey('drag-feedback-a')), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await hold('a', ['content://original/a'], {});
      expect(state.selecting, isFalse);
      await hold('b', ['content://original/b'], {});
      expect(state.selecting, isFalse);
      expect(selectionChanges, 0);
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('saved-file-a')));
      await tester.pumpAndSettle();
      expect(state.selecting, isTrue);
      await hold('b', ['content://original/a'], {'a'});
      await tester.tap(find.byKey(const ValueKey('saved-file-b')));
      await tester.pumpAndSettle();
      expect(Set<String>.from(state.selected), {'a', 'b'});
      expect(find.byType(Dialog), findsNothing);
      await hold(
        'b',
        ['content://original/a', 'content://original/b'],
        {'a', 'b'},
      );
      await tester.tap(find.byKey(const ValueKey('saved-file-a')));
      await tester.pumpAndSettle();
      await hold('a', ['content://original/b'], {'b'});
      await tester.tap(find.byKey(const ValueKey('saved-file-b')));
      await tester.pumpAndSettle();
      await hold('a', ['content://original/a'], {});
      expect(
        selectionChanges,
        5,
        reason: 'only the explicit edit button and four taps change selection',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
  testWidgets(
    'library back closes top modal then selection before leaving the route for system appbar and escape',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DockPlatform.channel, (call) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DockPlatform.channel, null),
      );
      final c = GalleryController()
        ..library.add(entry('a', 'a.bin', 'content://original/a', 0, 16));
      await tester.pumpWidget(
        MaterialApp(
          theme: Ui.theme(),
          home: Builder(
            builder: (home) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(home).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SavedFilesScreen(controller: c),
                  ),
                ),
                child: const Text('打开文件库'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final action in ['system', 'appbar', 'escape']) {
        await tester.tap(find.text('打开文件库'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('saved-file-a')));
        await tester.pumpAndSettle();
        final state = tester.state<SavedFilesScreenState>(
          find.byType(SavedFilesScreen),
        );
        expect(state.selectionActive, isTrue);
        if (action == 'system') {
          await tester.tap(find.text('重命名'));
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byType(Dialog), findsNothing);
          expect(state.selectionActive, isTrue);
        }
        Future<void> back() async {
          if (action == 'system')
            await tester.binding.handlePopRoute();
          else if (action == 'appbar')
            await tester.tap(find.byType(BackButton));
          else
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }

        await back();
        expect(find.byType(SavedFilesScreen), findsOneWidget);
        expect(state.selectionActive, isFalse);
        expect(state.selected, isEmpty);
        await back();
        expect(find.byType(SavedFilesScreen), findsNothing);
        expect(find.text('打开文件库'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
