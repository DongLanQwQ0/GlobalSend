import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/models.dart';

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
}
