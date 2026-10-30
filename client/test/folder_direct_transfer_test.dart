import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/folder_transfer.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/receive_destination.dart';

import 'center_integration_test.dart' show until;

void main() {
  test('folder enumeration references originals and includes empty directories beyond 32 files', () async {
    final work = await (await Directory(
      'build/test-tmp',
    ).create(recursive: true)).createTemp('folder-enumeration-');
    final root = await Directory('${work.path}/资料/空目录').create(recursive: true);
    final selected = root.parent;
    for (var i = 0; i < 40; i++)
      await File('${selected.path}/$i.txt').writeAsString('original $i');
    final entries = await readFolderEntries(selected.path);
    expect(entries.length, 42);
    expect(
      entries
          .where((entry) => entry.directory)
          .map((entry) => entry.relativePath),
      containsAll(['资料', '资料/空目录']),
    );
    expect(entries.every((entry) => !entry.location.endsWith('.zip')), isTrue);
    expect((await selected.list(recursive: true).toList()).length, 41);
  });

  for (final direct in [false, true]) {
    test(
      'real center native folder ${direct ? 'pinned HTTPS' : 'relay'} writes exact tree and keeps external originals',
      () async {
        final work = await (await Directory(
          'build/test-tmp',
        ).create(recursive: true)).createTemp('folder-stack-');
        final original = Directory('${work.path}/original/资料');
        await Directory('${original.path}/sub').create(recursive: true);
        await Directory('${original.path}/空目录').create();
        await File('${original.path}/sub/a.txt').writeAsString('真实目录正文');
        await File('${original.path}/zero.bin').create();
        final inbox = await Directory('${work.path}/inbox').create();
        await Directory('${inbox.path}/资料').create();
        await File('${inbox.path}/资料/user-original.txt')
            .writeAsString('do not overwrite');
        ReceiveDestination.registryDirectoryForTesting = () async =>
            Directory('${work.path}/registry');
        final center = await Process.start('node', [
          'tool/start_test_center.mjs',
          work.absolute.path,
        ]);
        final log = File('${work.path}/center-stderr.log').openWrite();
        final errors = center.stderr.listen(log.add);
        final controllers = <SendController>[];
        PeerTransport? peer;
        try {
          final line = await center.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 15));
          final base = jsonDecode(line)['url'] as String;
          for (final name in ['source', 'target']) {
            final api = CenterApi(base);
            final info = await api.call('GET', '/info', null, false);
            final session = await api.call('POST', '/devices/enroll', {
              'name': name,
              'platform': 'windows',
              'groupKey': 'folder-native-stack',
            }, false);
            api.token = session['deviceToken'];
            final controller =
                SendController(documentsDirectory: () async => inbox)
                  ..root = Directory('${work.path}/$name-state')
                  ..api = api
                  ..info = info
                  ..profile = ServerProfile(
                    baseUrl: base,
                    instanceId: info['instanceId'],
                    deviceId: session['device']['deviceId'],
                    groupId: session['groupId'],
                  );
            await controller.root!.create();
            if (name == 'target') {
              await File('${controller.root!.path}/saved-files.json')
                  .writeAsString(
                    jsonEncode({
                      'receiveDestinationLocation': inbox.path,
                      'receiveDestinationLabel': 'inbox',
                      'files': [],
                    }),
                  );
            }
            controllers.add(controller);
            await controller.openSocket(controller.generation);
            await api.call('POST', '/devices/me/capabilities', {
              'folderTransfer': true,
            });
          }
          final source = controllers[0], target = controllers[1];
          source.profile!.sendRoutePreference = direct ? 'lan' : 'relay';
          if (direct) {
            peer = PeerTransport(source.api!, (id) => source.sources[id]);
            await peer.start(
              createPeerIdentity('folder-test'),
              loopbackOnly: true,
            );
            source.peer = peer;
          }
          await source.stageDirectory(original.path);
          expect(source.stagedFiles, [original.path]);
          expect(source.stagedDirectoryNames[original.path], '资料');
          expect(
            await Directory('${source.root!.path}/outgoing-folders').exists(),
            isFalse,
          );
          await source.sendStaged(target.profile!.deviceId);
          final transfers = await source.api!.call('GET', '/transfers');
          final transfer = transfers['transfers'].first as Map;
          expect((transfer['files'] as List).length, 5);
          await until(
            () =>
                target.dock.length == 5 &&
                target.dock.every((entry) => entry.status == 'received'),
            () async {
              await source.reconcile();
              await target.reconcile();
            },
          );
          final folder = target.dock.singleWhere(
            (entry) => entry.isDirectory && entry.relativePath == '资料',
          );
          expect(folder.localPath, endsWith('资料 (1)'));
          expect(
            await File('${folder.localPath}/sub/a.txt').readAsString(),
            '真实目录正文',
          );
          expect(await File('${folder.localPath}/zero.bin').length(), 0);
          expect(await Directory('${folder.localPath}/空目录').exists(), isTrue);
          expect(
            target.dock.every((entry) => entry.receivedAtMillis > 0),
            isTrue,
          );
          expect(target.savedFiles.where((file) => file.directory).length, 3);
          expect(
            await File('${original.path}/sub/a.txt').readAsString(),
            '真实目录正文',
          );
          expect(
            await File('${inbox.path}/资料/user-original.txt').readAsString(),
            'do not overwrite',
          );
          final remote = await source.api!.call(
            'GET',
            '/transfers/${transfer['transferId']}',
          );
          expect(
            (remote['transfer']['files'] as List)
                .where((file) => file['entryKind'] != 'directory')
                .every(
                  (file) => file['transport'] == (direct ? 'direct' : 'relay'),
                ),
            isTrue,
          );
          expect(
            target.dock.every((entry) => !entry.title.endsWith('.zip')),
            isTrue,
          );
          // Root mapping is durable and used even when a file finishes before its directory entry.
          expect(
            await ReceiveDestination.folderDirectory(
              destinationLocation: inbox.path,
              transferKey: '${target.profile!.key}:${transfer['transferId']}',
              relativePath: '资料/sub',
            ),
            '${folder.localPath}${Platform.pathSeparator}sub',
          );
          final savedRoot = target.savedFiles.singleWhere(
            (file) => file.directory && file.relativePath == '资料',
          );
          // A repeated complete tree must reuse that exact allocated root,
          // including its empty directories, rather than receiving 资料 (2).
          await target.refreshSavedFiles();
          final savedIds = target.savedFiles.map((file) => file.id).toSet();
          final modified = await File('${folder.localPath}/sub/a.txt')
              .lastModified();
          await source.stageDirectory(original.path);
          await source.sendStaged(target.profile!.deviceId);
          final againList = await source.api!.call('GET', '/transfers');
          final again = (againList['transfers'] as List).singleWhere(
            (value) => value['transferId'] != transfer['transferId'],
          ) as Map;
          await until(
            () =>
                target.dock
                        .where(
                          (entry) => entry.transferId == again['transferId'],
                        )
                        .length ==
                    5 &&
                target.dock
                    .where((entry) => entry.transferId == again['transferId'])
                    .every((entry) => entry.status == 'received'),
            () async {
              await source.reconcile();
              await target.reconcile();
            },
          );
          final reused = await source.api!.call(
            'GET',
            '/transfers/${again['transferId']}',
          );
          final receipts = reused['transfer']['files'] as List;
          expect(
            receipts.every(
              (value) => value['reused'] == true && value['offset'] == 0,
            ),
            isTrue,
          );
          expect(
            receipts.map((value) => value['receivedAt']).toSet().length,
            1,
          );
          expect(target.savedFiles.map((file) => file.id).toSet(), savedIds);
          expect(
            target.dock
                .singleWhere(
                  (entry) =>
                      entry.transferId == again['transferId'] &&
                      entry.relativePath == '资料',
                )
                .localPath,
            folder.localPath,
          );
          expect(await Directory('${inbox.path}/资料 (2)').exists(), isFalse);
          expect(
            await File('${folder.localPath}/sub/a.txt').lastModified(),
            modified,
          );
          if (!direct) {
            // Later user-created files are not part of the received manifest.
            await File('${folder.localPath}/keep-user.txt')
                .writeAsString('keep');
          }
          await target.deleteSavedFiles([savedRoot.id]);
          if (direct) {
            expect(await Directory(folder.localPath).exists(), isFalse);
            expect(target.savedFiles, isEmpty);
          } else {
            expect(
              await File('${folder.localPath}/keep-user.txt').readAsString(),
              'keep',
            );
            expect(target.savedFiles.map((file) => file.id), [savedRoot.id]);
          }
          expect(
            await File('${original.path}/sub/a.txt').readAsString(),
            '真实目录正文',
          );
          // Extensionless gallery files retain their source reference but send
          // usable image metadata to every receiver, including the Web client.
          final photo = await File('test/fixtures/extensionless-photo')
              .copy('${work.path}/1000061883');
          await source.stageInputs([photo.path], []);
          await source.sendStaged(target.profile!.deviceId);
          await until(
            () => target.dock.any(
              (item) =>
                  item.title == '1000061883.jpg' && item.status == 'received',
            ),
            () async {
              await source.reconcile();
              await target.reconcile();
            },
          );
          final delivered = target.dock.singleWhere(
            (item) => item.title == '1000061883.jpg',
          );
          expect(
            await File(delivered.localPath).readAsBytes(),
            await photo.readAsBytes(),
          );
          expect(await photo.exists(), true);
          final photoTransfers =
              (await source.api!.call('GET', '/transfers'))['transfers']
                  as List;
          final metadata = photoTransfers
              .expand((value) => value['files'] as List)
              .singleWhere((value) => value['name'] == '1000061883.jpg');
          expect(metadata['mimeType'], 'image/jpeg');
        } finally {
          for (final controller in controllers) controller.dispose();
          await peer?.close();
          center.kill();
          await center.exitCode.timeout(const Duration(seconds: 5));
          await errors.cancel();
          await log.close();
          ReceiveDestination.registryDirectoryForTesting = null;
          stdout.writeln('Folder integration evidence: ${work.absolute.path}');
        }
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
