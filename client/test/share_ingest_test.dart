import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/local_ip_addresses.dart';

import 'saved_files_test.dart' show fixtureDirectory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'loopback interfaces are removed without treating VPN tunnels as unusable',
    () {
      final values = addressesFromInterfaces([
        {
          'name': 'lo0',
          'addresses': ['fe80::1%lo0', '127.0.0.1'],
        },
        {
          'name': 'en0',
          'addresses': ['10.194.43.84'],
        },
        {
          'name': 'utun4',
          'addresses': ['198.18.0.1', 'fdfe:dcba:9876::1'],
        },
      ]);
      expect(values.any((value) => value.source?.name == 'lo0'), isFalse);
      expect(values.where((value) => value.source?.name == 'utun4').length, 2);
      expect(
        values.firstWhere((value) => value.address == '198.18.0.1').reserved,
        isTrue,
      );
    },
  );
  test('OS share batches persist the queued content and receipt together before acknowledgement, including more than 32 items', () async {
    final root = await fixtureDirectory();
    final paths = <String>[];
    for (var i = 0; i < 36; i++) {
      final file = File('${root.path}/share-$i.txt');
      await file.writeAsString('item $i');
      paths.add(file.path);
    }
    final c = SendController(documentsDirectory: () async => root)..root = root;
    addTearDown(c.dispose);
    expect(
      await c.stageSharedInputs('batch', paths, ['shared text'], paths),
      isTrue,
    );
    expect(c.stagedFiles.length, 36);
    await c.stageSharedInputs('batch', paths, ['shared text'], paths);
    expect(c.stagedFiles.length, 36);
    expect(c.stagedTexts, ['shared text']);
    final value = jsonDecode(
      await File('${root.path}/outbox.json').readAsString(),
    ) as Map;
    expect(value['files'], paths);
    expect(value['texts'], ['shared text']);
    expect(value['sharedBatchIds'], ['batch']);
    expect(value['temporarySources'], paths);
  });
  test('failed sharing leaves its batch unconfirmed for retry', () async {
    final root = await fixtureDirectory();
    final c = SendController(documentsDirectory: () async => root)..root = root;
    addTearDown(c.dispose);
    final path = '${root.path}/later.txt';
    await expectLater(
      c.stageSharedInputs('retry', [path], [], []),
      throwsA(isA<FileSystemException>()),
    );
    await File(path).writeAsString('ready');
    expect(await c.stageSharedInputs('retry', [path], [], []), isTrue);
    expect(c.stagedFiles, [path]);
  });
  test('directed call before connection keeps durable content and one attempt marker', () async {
    final root = await fixtureDirectory();
    final c = SendController(documentsDirectory: () async => root)..root = root;
    addTearDown(c.dispose);
    final batch = SharedBatch(
      batchId: 'directed',
      paths: [],
      texts: ['before login'],
      temporaryPaths: [],
      target: const SharedSendTarget(
        serverKey: 'center',
        deviceId: 'recipient',
      ),
    );
    await c.stageSharedInputs(batch.batchId, batch.paths, batch.texts, []);
    await expectLater(c.sendSharedBatch(batch), throwsStateError);
    final value = jsonDecode(
      await File('${root.path}/outbox.json').readAsString(),
    ) as Map;
    expect(value['texts'], ['before login']);
    expect(value['autoSharedBatchIds'], ['directed']);
    await c.sendSharedBatch(batch);
    expect(c.stagedTexts, ['before login']);
  });
}
