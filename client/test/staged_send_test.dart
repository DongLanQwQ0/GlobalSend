import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/file_share.dart';

class BatchController extends SendController {
  BatchController() {
    api = CenterApi('http://fixture', token: 'fixture');
    profile = ServerProfile(baseUrl: 'http://fixture', instanceId: 'fixture');
  }
  final calls = <String>[];
  String? failOnce;
  Completer<void>? gate;

  @override
  Future<void> sendText(String target, String text) async {
    final call = '$target:$text';
    calls.add(call);
    await gate?.future;
    if (failOnce == call) {
      failOnce = null;
      throw StateError('目标暂时离线');
    }
  }

  @override
  Future<void> offer(
    String target,
    List<String> paths, {
    String? routePreferenceOverride,
    Map<String, String>? displayNames,
  }) async {
    calls.add('$target:files:${paths.join(',')}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  SharedBatch directed(
    BatchController c, {
    String id = 'share-one',
    String? serverKey,
  }) => SharedBatch(
    batchId: id,
    paths: ['shared.jpg'],
    texts: ['分享正文'],
    temporaryPaths: [],
    target: SharedSendTarget(
      serverKey: serverKey ?? c.profile!.key,
      deviceId: 'second-id',
      name: '同名设备',
    ),
  );

  test('directed share uses ID, sends only that batch, and ignores repeat callbacks', () async {
    final c = BatchController();
    addTearDown(c.dispose);
    c.devices = [
      {'deviceId': 'first-id', 'name': '同名设备', 'online': true},
      {'deviceId': 'second-id', 'name': '同名设备', 'online': true},
    ];
    c.stagedFiles.addAll(['draft.pdf', 'shared.jpg']);
    c.stagedTexts.addAll(['原有草稿', '分享正文']);
    final batch = directed(c);
    await c.sendSharedBatch(batch);
    await c.sendSharedBatch(batch);
    expect(c.calls, ['second-id:files:shared.jpg', 'second-id:分享正文']);
    expect(c.stagedFiles, ['draft.pdf']);
    expect(c.stagedTexts, ['原有草稿']);
  });

  test(
    'directed share leaves an identical pre-existing text draft intact',
    () async {
      final c = BatchController();
      addTearDown(c.dispose);
      c.devices = [
        {'deviceId': 'second-id', 'online': true},
      ];
      c.stagedTexts.add('同一段正文');
      final batch = SharedBatch(
        batchId: 'identical-text',
        paths: [],
        texts: ['同一段正文'],
        temporaryPaths: [],
        target: directed(c).target,
      );
      await c.stageSharedInputs(
        batch.batchId,
        [],
        batch.texts,
        [],
        preserveTextCopies: true,
      );
      await c.sendSharedBatch(batch);
      expect(c.calls, ['second-id:同一段正文']);
      expect(c.stagedTexts, ['同一段正文']);
    },
  );

  test(
    'directed share rejects another center even when device names match',
    () async {
      final c = BatchController();
      addTearDown(c.dispose);
      c.stagedTexts.add('分享正文');
      await expectLater(
        c.sendSharedBatch(directed(c, serverKey: 'another-center')),
        throwsStateError,
      );
      expect(c.calls, isEmpty);
      expect(c.stagedTexts, ['分享正文']);
    },
  );

  test(
    'failed directed share keeps its files and text for manual retry',
    () async {
      final c = BatchController()..failOnce = 'second-id:分享正文';
      addTearDown(c.dispose);
      c.devices = [
        {'deviceId': 'second-id', 'online': true},
      ];
      c.stagedFiles.add('shared.jpg');
      c.stagedTexts.add('分享正文');
      await expectLater(c.sendSharedBatch(directed(c)), throwsStateError);
      expect(c.stagedFiles, ['shared.jpg']);
      expect(c.stagedTexts, ['分享正文']);
      await c.sendStaged('second-id');
      expect(c.calls, [
        'second-id:files:shared.jpg',
        'second-id:分享正文',
        'second-id:分享正文',
      ]);
      expect(c.stagedTexts, isEmpty);
    },
  );

  test(
    'single target consumes its batch and identical next batch sends again',
    () async {
      final c = BatchController();
      addTearDown(c.dispose);
      c.stagedTexts.add('正文');
      await c.sendStaged('phone');
      expect(c.stagedTexts, isEmpty);
      expect(c.stagedTargetStates['phone'], 'sent');
      c.stagedTexts.add('正文');
      await c.sendStaged('phone');
      expect(c.calls, ['phone:正文', 'phone:正文']);
    },
  );

  test(
    'multi target consumes once after sending all selected devices',
    () async {
      final c = BatchController();
      addTearDown(c.dispose);
      c.stagedFiles.add('original.png');
      c.stagedTexts.add('正文');
      await c.sendStagedToMany(['phone', 'tablet', 'phone']);
      expect(c.calls, [
        'phone:files:original.png',
        'phone:正文',
        'tablet:files:original.png',
        'tablet:正文',
      ]);
      expect(c.stagedFiles, isEmpty);
      expect(c.stagedTexts, isEmpty);
      expect(c.stagedTargetStates, {'phone': 'sent', 'tablet': 'sent'});
    },
  );

  test(
    'partial failure retains batch and retry skips delivered content',
    () async {
      final c = BatchController()..failOnce = 'tablet:第二段';
      addTearDown(c.dispose);
      c.stagedTexts.addAll(['第一段', '第二段']);
      await expectLater(
        c.sendStagedToMany(['phone', 'tablet']),
        throwsStateError,
      );
      expect(c.stagedTexts, ['第一段', '第二段']);
      expect(c.stagedTargetStates, {'phone': 'sent', 'tablet': 'failed'});
      await c.sendStagedToMany(['phone', 'tablet']);
      expect(c.calls, [
        'phone:第一段',
        'phone:第二段',
        'tablet:第一段',
        'tablet:第二段',
        'tablet:第二段',
      ]);
      expect(c.stagedTexts, isEmpty);
    },
  );

  test('content added while sending remains for the next click', () async {
    final c = BatchController()..gate = Completer<void>();
    addTearDown(c.dispose);
    c.stagedTexts.add('已确认');
    final sending = c.sendStaged('phone');
    c.stagedTexts.add('稍后发送');
    c.gate!.complete();
    await sending;
    expect(c.calls, ['phone:已确认']);
    expect(c.stagedTexts, ['稍后发送']);
  });
}
