import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';

import 'widget_test.dart' show signedIn;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final kind in ['text', 'image', 'files', 'empty']) {
    testWidgets(
      'Windows native paste request stages $kind without a second Ctrl+V',
      (tester) async {
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method == 'clipboardKind') return kind;
          if (call.method == 'windowVisible') return true;
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
        );
        final c = signedIn();
        if (kind != 'text') {
          c.clipboardTexts = [];
          if (kind != 'empty')
            c.clipboardPaths = [
              'C:/fixture/test.${kind == 'image' ? 'png' : 'pdf'}',
            ];
        }
        await tester.pumpWidget(GlobalSendApp(controller: c));
        await tester.pumpAndSettle();
        await messenger.handlePlatformMessage(
          SystemBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('pasteRequested'),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
        expect(c.clipboardReads, kind == 'empty' ? 0 : 1);
        if (kind == 'text') expect(c.stagedTexts, ['剪贴板内容']);
        if (kind == 'image' || kind == 'files')
          expect(c.stagedFiles, c.clipboardPaths);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'native paste inserts text at the editor selection rather than staging it',
    (tester) async {
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'clipboardKind') return 'text';
        if (call.method == 'windowVisible') return true;
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': '粘贴\n内容'};
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemBridge.channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final c = signedIn();
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-text')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('draft-input')), '左右');
      final input = tester.widget<TextField>(
        find.byKey(const ValueKey('draft-input')),
      );
      input.controller!.selection = const TextSelection.collapsed(offset: 1);
      await messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('pasteRequested'),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(input.controller!.text, '左粘贴\n内容右');
      expect(c.stagedTexts, isEmpty);
      expect(c.clipboardReads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'coincident native paste dispatch is coalesced but a later paste is kept',
    (tester) async {
      final ready = Completer<String>();
      var kindReads = 0;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'windowVisible') return true;
        if (call.method == 'clipboardKind') {
          kindReads++;
          return kindReads == 1 ? ready.future : 'text';
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      final c = signedIn();
      await tester.pumpWidget(GlobalSendApp(controller: c));
      await tester.pumpAndSettle();
      Future<void> paste() => messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('pasteRequested'),
        ),
        (_) {},
      );
      await paste();
      await paste();
      await tester.pump();
      expect(kindReads, 1);
      ready.complete('text');
      await tester.pumpAndSettle();
      expect(c.clipboardReads, 1);
      await paste();
      await tester.pumpAndSettle();
      expect(kindReads, 2);
      expect(c.clipboardReads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
