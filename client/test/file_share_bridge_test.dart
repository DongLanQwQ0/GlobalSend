import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/appearance.dart';
import 'package:globalsend/ui_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('share suggestions retain the unique target while old default settings disappear', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? actual;
    messenger.setMockMethodCallHandler(FileShareBridge.channel, (call) async {
      actual = call;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(FileShareBridge.channel, null),
    );
    await FileShareBridge.recordTarget(
      const SharedSendTarget(
        serverKey: 'center',
        deviceId: 'uuid',
        name: '电脑',
        platform: 'windows',
      ),
    );
    expect(actual!.method, 'recordShareTarget');
    expect(actual!.arguments, {
      'serverKey': 'center',
      'deviceId': 'uuid',
      'name': '电脑',
      'platform': 'windows',
    });
    final profile = ServerProfile.fromJson({
      'baseUrl': 'https://fixture.test',
      'instanceId': 'one',
      'shareTargetDeviceId': 'old-target',
      'shareTargetName': '旧设备',
    });
    expect(profile.toJson().containsKey('shareTargetDeviceId'), isFalse);
    expect(profile.toJson().containsKey('shareTargetName'), isFalse);
  });
  test('shared inbox schema preserves batch identity and every file/text without acknowledging it', () {
    final batch = SharedBatch.fromMap({
      'batchId': 'batch',
      'paths': ['a.pdf', 'b.mp4'],
      'texts': ['https://example.test', 'second'],
      'temporaryPaths': ['a.pdf', 'b.mp4'],
      'error': 'one source unavailable',
      'target': {
        'serverKey': 'center-instance',
        'deviceId': 'uuid-two',
        'name': '同名设备',
      },
    });
    expect(batch.batchId, 'batch');
    expect(batch.paths, ['a.pdf', 'b.mp4']);
    expect(batch.texts, ['https://example.test', 'second']);
    expect(batch.temporaryPaths, batch.paths);
    expect(batch.error, 'one source unavailable');
    expect(batch.target!.deviceId, 'uuid-two');
    expect(batch.target!.serverKey, 'center-instance');
    expect(SharedBatch.fromMap({'batchId': 'old'}).target, isNull);
  });
  test('in-progress sharing preserves real item progress and target without becoming a completed batch', () {
    final importing = SharedBatch.fromMap({
      'batchId': 'live-import',
      'importing': true,
      'completedItems': 1,
      'totalItems': 3,
      'paths': ['already-copied.png'],
      'target': {'serverKey': 'center', 'deviceId': 'unique-target'},
    });
    expect(importing.importing, isTrue);
    expect(importing.completedItems, 1);
    expect(importing.totalItems, 3);
    expect(importing.target!.deviceId, 'unique-target');
    expect(SharedBatch.fromMap({'batchId': 'legacy'}).importing, isFalse);
  });
  test('bulk drag channel keeps all file and text items while preserving old single-item calls', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DockPlatform.channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(DockPlatform.channel, null),
    );
    await DockPlatform.startDrag(
      paths: ['a.pdf', 'b.mp4'],
      texts: ['first', 'second'],
      label: '4 项',
    );
    expect(calls.single.arguments, {
      'paths': ['a.pdf', 'b.mp4'],
      'texts': ['first', 'second'],
      'label': '4 项',
    });
    await DockPlatform.startDrag(path: 'single.txt', label: 'single');
    expect(calls.last.arguments, {'path': 'single.txt', 'label': 'single'});
    await DockPlatform.startDrag(text: 'plain', label: 'text');
    expect(calls.last.arguments, {'text': 'plain', 'label': 'text'});
  });
  testWidgets(
    'native bulk handle update bridge follows theme foreground and preserves its batch',
    (tester) async {
      const channel = MethodChannel('dev.globalsend/drag-handle/71');
      final updates = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        updates.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final rose = Ui.theme(const Appearance(accent: AccentColor.rose));
      final purple = Ui.theme(
        const Appearance(mode: AppearanceMode.dark, accent: AccentColor.purple),
      );
      const home = Scaffold(
        body: BulkDragHandle(paths: ['original.png'], texts: ['original text']),
      );
      await tester.pumpWidget(MaterialApp(theme: rose, home: home));
      // Exercise the actual channel update without creating a real UIKit view on
      // the Windows test host. UIKit's onPlatformViewCreated supplies this ID.
      final dynamic state = tester.state(find.byType(BulkDragHandle));
      state.platformViewId = 71;
      state.sync();
      await tester.pumpAndSettle();
      expect(
        (updates.last.arguments as Map)['foreground'],
        rose.extension<UiPalette>()!.accent.toARGB32(),
      );
      await tester.pumpWidget(MaterialApp(theme: purple, home: home));
      await tester.pumpAndSettle();
      expect(updates.last.method, 'update');
      expect(updates.last.arguments, {
        'paths': ['original.png'],
        'texts': ['original text'],
        'foreground': purple.extension<UiPalette>()!.accent.toARGB32(),
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
