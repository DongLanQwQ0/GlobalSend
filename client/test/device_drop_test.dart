import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

class DropController extends SendController {
  final offered = <(String, List<String>)>[];
  final messages = <(String, String)>[];
  bool fail = false;
  @override
  Future<void> offer(
    String target,
    List<String> paths, {
    String? routePreferenceOverride,
    Map<String, String>? displayNames,
  }) async {
    if (fail) throw StateError('offline');
    offered.add((target, paths.toList()));
  }

  @override
  Future<void> sendText(String target, String text) async {
    messages.add((target, text));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('device drops send their batch directly, keep unrelated drafts, and retain failed content', () async {
    final work = await (await Directory(
      'build/test-tmp',
    ).create(recursive: true)).createTemp('device-drop-');
    final original = await File('${work.path}/drop.txt').writeAsString('drop');
    final draft = await File('${work.path}/draft.txt').writeAsString('draft');
    final c = DropController()
      ..api = CenterApi('https://fixture.invalid', token: 'test-only')
      ..profile = ServerProfile(
        baseUrl: 'https://fixture.invalid',
        instanceId: 'fixture',
        deviceId: 'self',
      );
    addTearDown(c.dispose);
    await c.stageInputs([draft.path], ['unrelated']);
    await c.handleNativeDockEvent({
      'type': 'nativeDrop',
      'dropId': 'device-one',
      'paths': [original.path],
      'texts': ['only this'],
      'targetDeviceId': 'uuid-target',
      'serverKey': c.profile!.key,
    });
    expect(c.offered.single.$1, 'uuid-target');
    expect(c.offered.single.$2, [original.path]);
    expect(c.messages.single, ('uuid-target', 'only this'));
    expect(c.stagedFiles, [draft.path]);
    expect(c.stagedTexts, ['unrelated']);
    c.fail = true;
    await c
        .sendDroppedInputs('uuid-target', [original.path], [])
        .catchError((Object _) {});
    expect(c.stagedFiles, [draft.path, original.path]);
    expect(c.stagedTexts, ['unrelated']);
    expect(await original.readAsString(), 'drop');
  });
}
