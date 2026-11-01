import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/content_groups.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/incoming_receipt_state.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/receive_destination.dart';

import 'center_integration_test.dart' show until;

void main() {
  test('real native copied references pull ordinary direct files and a folder without consuming drafts', () async {
    final parent = await Directory(
      '../artifacts/tmp/copied-files-native-center',
    ).create(recursive: true);
    final work = await parent.createTemp('case-');
    final folder = await Directory('${work.path}/original/Bundle')
        .create(recursive: true);
    await Directory('${folder.path}/empty').create();
    await Directory('${folder.path}/sub').create();
    await File('${folder.path}/sub/note.txt')
        .writeAsString('copied folder body');
    await File('${folder.path}/zero.bin').create();
    final file = await File('${work.path}/original/copied.txt')
        .writeAsString('copied standalone body');
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${work.path}/registry');
    final process = await Process.start('node', [
      '--import',
      '../server/node_modules/tsx/dist/loader.mjs',
      'tool/start_test_center.mjs',
      work.absolute.path,
    ]);
    final log = File('${work.path}/center-stderr.log').openWrite();
    final errors = process.stderr.listen(log.add);
    final clients = <SendController>[];
    PeerTransport? peer;
    try {
      final firstLine = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final base = jsonDecode(firstLine)['url'] as String;
      for (var index = 0; index < 3; index++) {
        final api = CenterApi(base);
        final info = await api.call('GET', '/info', null, false);
        final session = await api.call('POST', '/devices/enroll', {
          'name': 'Same device name',
          'platform': index == 0 ? 'windows' : 'android',
          'groupKey': 'copied-native-integration',
        }, false);
        api.token = session['deviceToken'];
        final state = await Directory('${work.path}/state-$index').create();
        final c =
            SendController(
                stateDirectory: () async => state,
                documentsDirectory: () async =>
                    Directory('${work.path}/files-$index'),
              )
              ..api = api
              ..info = info
              ..root = state
              ..profile = ServerProfile(
                baseUrl: base,
                instanceId: info['instanceId'],
                deviceId: session['device']['deviceId'],
                groupId: session['groupId'],
              );
        clients.add(c);
        await c.openSocket(c.generation);
        expect(c.connected, isTrue);
        await api.call('POST', '/devices/me/capabilities', {
          'folderTransfer': true,
        });
      }
      final source = clients[0], target = clients[1], unselected = clients[2];
      final targetId = target.profile!.deviceId;
      peer = PeerTransport(source.api!, (id) => source.sources[id]);
      await peer.start(
        createPeerIdentity('copied-native-integration'),
        loopbackOnly: true,
      );
      source.peer = peer;
      source.stagedTexts.add('keep this draft');
      source.stagedFiles.add('${work.path}/unrelated-draft.bin');
      await source.copiedFiles.configure(true, [targetId]);
      await source.copiedFiles.copiedPaths([file.path, folder.path]);
      await until(
        () => target.copiedFiles.references.length == 2,
        () async => Future<void>.delayed(Duration.zero),
      );
      expect(target.copiedFiles.references.map((item) => item['name']), [
        'copied.txt',
        'Bundle',
      ]);
      expect(unselected.copiedFiles.references, isEmpty);
      expect(source.sources, isEmpty);
      expect(source.dock, isEmpty);
      expect(
        (await source.api!.call('GET', '/transfers'))['transfers'],
        isEmpty,
      );
      expect(
        await Directory('${source.root!.path}/outgoing-folders').exists(),
        isFalse,
      );

      for (final name in ['copied.txt', 'Bundle']) {
        final reference = target.copiedFiles.references.singleWhere(
          (item) => item['name'] == name,
        );
        await target.pullCopiedFileSelection({
          'id': reference['id'],
          'serverKey': target.profile!.key,
        });
      }
      Future<void> refresh() async {
        await source.reconcile();
        await target.reconcile();
      }

      await until(
        () =>
            target.dock.length == 6 &&
            target.dock.every((item) => item.status == 'received'),
        refresh,
      );
      final standalone = target.dock.singleWhere(
        (item) => item.title == 'copied.txt',
      );
      final directory = target.dock.singleWhere(
        (item) => item.isDirectory && item.relativePath == 'Bundle',
      );
      expect(standalone.route, 'lan');
      expect(
        await File(standalone.localPath).readAsString(),
        'copied standalone body',
      );
      expect(
        await File('${directory.localPath}/sub/note.txt').readAsString(),
        'copied folder body',
      );
      expect(await Directory('${directory.localPath}/empty').exists(), isTrue);
      expect(await File('${directory.localPath}/zero.bin').length(), 0);
      expect(IncomingReceiptState(standalone).canExport, isTrue);
      expect(IncomingReceiptState(directory).canExport, isTrue);
      expect(mergeContentCards(target.historyDock), hasLength(2));
      expect(target.pendingReceipts, hasLength(2));
      expect(
        target.pendingReceipts.keys,
        containsAll([standalone.id, directory.id]),
      );
      expect(source.stagedTexts, ['keep this draft']);
      expect(source.stagedFiles, ['${work.path}/unrelated-draft.bin']);
      expect(unselected.dock, isEmpty);
      expect(
        (await unselected.api!.call('GET', '/transfers'))['transfers'],
        isEmpty,
      );
      expect(await file.readAsString(), 'copied standalone body');
      expect(
        await File('${folder.path}/sub/note.txt').readAsString(),
        'copied folder body',
      );
      await until(
        () => target.copiedFiles.pulls.values.every(
          (pull) => pull['state'] == 'sent',
        ),
        refresh,
      );
      await source.copiedFiles.configure(false, [targetId]);
      await until(
        () => target.copiedFiles.references.isEmpty,
        () async => Future<void>.delayed(Duration.zero),
      );
      expect(target.pendingReceipts, hasLength(2));
      await target.requeueDockEntry(standalone);
      await target.requeueDockEntry(directory);
      expect(target.stagedFiles, [standalone.localPath, directory.localPath]);
      expect(target.stagedDirectoryNames[directory.localPath], 'Bundle');
      expect(
        await Directory('${target.root!.path}/outgoing-folders').exists(),
        isFalse,
      );
      stdout.writeln(
        'Copied file native center evidence: ${work.absolute.path}',
      );
    } finally {
      for (final c in clients) c.dispose();
      await peer?.close();
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await errors.cancel();
      await log.close();
      ReceiveDestination.registryDirectoryForTesting = null;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
