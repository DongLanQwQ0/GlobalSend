import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/peer.dart';
import 'package:globalsend/receive_destination.dart';

import 'center_integration_test.dart' show until;

class CountingPeer extends PeerTransport {
  CountingPeer(super.api, super.sourcePath) : super(pushEnabled: true);
  int pullRequests = 0;
  @override
  Future<void> handle(HttpRequest request) {
    if (request.method == 'GET' && request.uri.path.startsWith('/files/')) {
      pullRequests++;
    }
    return super.handle(request);
  }
}

void main() {
  test('direct send awaiting receipt keeps complete progress despite zero center offset', () {
    final c = SendController()
      ..profile = ServerProfile(
        baseUrl: 'https://fixture.invalid',
        instanceId: 'fixture',
        deviceId: 'self',
      );
    addTearDown(c.dispose);
    final entry = DockEntry(
      id: 'f',
      kind: 'file',
      title: 'file.bin',
      source: 'self',
      transferId: 't',
      fileId: 'f',
      size: 6,
      outgoing: true,
      status: 'awaitingReceipt',
      route: 'lan',
      progress: 1,
    );
    c.dock = [entry];
    c.updateTransfer({
      'transferId': 't',
      'sourceDeviceId': 'self',
      'targetDeviceId': 'peer',
      'files': [
        {
          'fileId': 'f',
          'name': 'file.bin',
          'size': 6,
          'status': 'accepted',
          'offset': 0,
          'transport': 'direct',
        },
      ],
    });
    expect(entry.status, 'awaitingReceipt');
    expect(entry.progress, 1);
  });
  test('LAN reverse push precedes reachable public pull and resumes the original partial without relay bytes', () async {
    final folder = await (await Directory(
      'build/test-tmp',
    ).create(recursive: true)).createTemp('reverse-direct-');
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${folder.path}/registry');
    final process = await Process.start(
      'node',
      ['tool/start_test_center.mjs', folder.absolute.path],
      environment: {'GLOBALSEND_TEST_BOOTSTRAP': newId()},
    );
    final log = File('${folder.path}/center-stderr.log').openWrite();
    final errors = process.stderr.listen(log.add);
    SendController? sender, receiver;
    CountingPeer? sourcePeer;
    PeerTransport? targetPeer;
    try {
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 15));
      final base = jsonDecode(line)['url'] as String;
      final first = CenterApi(base), second = CenterApi(base);
      final key = newGroupKey();
      Future<ServerProfile> enroll(CenterApi api, String name) async {
        final result = await api.call('POST', '/devices/enroll', {
          'name': name,
          'platform': 'windows',
          'groupKey': key,
        }, false);
        api.token = result['deviceToken'];
        return ServerProfile(
          baseUrl: base,
          instanceId: 'integration',
          deviceId: result['device']['deviceId'],
          groupId: result['groupId'],
        );
      }

      final a = await enroll(first, 'sender'),
          b = await enroll(second, 'receiver');
      final info = await first.call('GET', '/info', null, false);
      String sourcePublic = '';
      // Scope discovery is injected; all sockets and file bytes are real loopback
      // HTTPS. The second source endpoint models a reachable public candidate.
      Future<({List<String> lan, List<String> public})> stages(
        List<String> values,
      ) async => (
        lan: values.where((value) => value != sourcePublic).toList(),
        public: values.where((value) => value == sourcePublic).toList(),
      );
      sender =
          SendController(
              documentsDirectory: () async =>
                  Directory('${folder.path}/sender-files'),
              addressStages: stages,
            )
            ..api = first
            ..profile = a
            ..profiles = [a]
            ..info = info
            ..root = Directory('${folder.path}/sender-state');
      receiver =
          SendController(
              documentsDirectory: () async =>
                  Directory('${folder.path}/receiver-files'),
              addressStages: stages,
            )
            ..api = second
            ..profile = b
            ..profiles = [b]
            ..info = info
            ..root = Directory('${folder.path}/receiver-state');
      final source = sender, target = receiver;
      await source.openSocket(source.generation);
      await target.openSocket(target.generation);
      sourcePeer = CountingPeer(first, (id) => source.sources[id]);
      targetPeer = PeerTransport(second, (_) => null, pushEnabled: true);
      await sourcePeer.start(
        createPeerIdentity('reverse-source'),
        loopbackOnly: true,
      );
      await targetPeer.start(
        createPeerIdentity('reverse-target'),
        loopbackOnly: true,
      );
      targetPeer.candidates = targetPeer.candidates
          .map((value) => '$value/')
          .toList();
      await targetPeer.publish();
      sourcePublic = sourcePeer.candidates.single;
      sourcePeer.candidates = ['https://127.0.0.1:1', sourcePublic];
      await sourcePeer.publish();
      source.peer = sourcePeer;
      target.peer = targetPeer;
      target.profile!.autoReceive = false;
      final bytes = List<int>.generate(700000, (index) => index % 251);
      final file = await File('${folder.path}/from-phone.bin')
          .writeAsBytes(bytes);
      await source.offer(b.deviceId, [file.path]);
      Future<void> refresh() async {
        await source.reconcile();
        await target.reconcile();
      }

      await until(
        () => target.dock.any((item) => item.title == 'from-phone.bin'),
        refresh,
      );
      final item = target.dock.firstWhere(
        (item) => item.title == 'from-phone.bin',
      );
      final part = File(
        '${folder.path}/receiver-files/GlobalSend/${b.key}/${b.deviceId}/${item.fileId}/${item.title}.part',
      );
      await part.parent.create(recursive: true);
      await part.writeAsBytes(bytes.take(12345).toList());
      item.partialPath = part.path;
      final progress = <int>[];
      target.addListener(() {
        if (item.receivedBytes > 0) progress.add(item.receivedBytes);
      });
      await target.acceptSelected(item, [item.fileId]);
      await until(() => item.status == 'received', refresh);
      expect(item.route, 'lan');
      expect(await File(item.localPath).readAsBytes(), bytes);
      expect(await part.exists(), isFalse);
      expect(
        sourcePeer.pullRequests,
        0,
        reason: 'LAN push must win before the reachable public pull',
      );
      expect(progress, contains(12345));
      expect(target.savedFiles.single.path, File(item.localPath).absolute.path);
      final remote = await first.call('GET', '/transfers/${item.transferId}');
      expect(remote['transfer']['files'][0]['status'], 'received');
      expect(remote['transfer']['files'][0]['transport'], 'direct');
      expect(remote['transfer']['files'][0]['offset'], 0);
      await refresh();
      expect(item.progress, 1);
      expect(
        source.dock.firstWhere((entry) => entry.fileId == item.fileId).progress,
        1,
      );
      var relayBytes = 0;
      await for (final entry in Directory(
        '${folder.path}/relay',
      ).list(recursive: true)) {
        if (entry is File) relayBytes += await entry.length();
      }
      expect(relayBytes, 0);
      expect(await File(item.localPath).parent.list().length, 1);
      // Both directions now really refuse connections. The same new-capability
      // clients must fall back, while a manual LAN offer must remain failed.
      sourcePeer.candidates = ['https://127.0.0.1:1'];
      targetPeer.candidates = ['https://127.0.0.1:2'];
      await sourcePeer.publish();
      await targetPeer.publish();
      target.profile!.autoReceive = true;
      final fallback = await File(
        '${folder.path}/both-directions-unreachable.bin',
      ).writeAsBytes(bytes.take(8000).toList());
      await source.offer(b.deviceId, [fallback.path]);
      await until(
        () => target.dock.any(
          (entry) =>
              entry.title == 'both-directions-unreachable.bin' &&
              entry.status == 'received',
        ),
        refresh,
      );
      final relayed = target.dock.firstWhere(
        (entry) => entry.title == 'both-directions-unreachable.bin',
      );
      expect(relayed.route, 'relay');
      expect(relayed.routeDetail, contains('反向直传不可用'));
      expect(
        await File(relayed.localPath).readAsBytes(),
        bytes.take(8000).toList(),
      );
      final relayState = await first.call(
        'GET',
        '/transfers/${relayed.transferId}',
      );
      expect(relayState['transfer']['files'][0]['offset'], 8000);
      await source.offer(b.deviceId, [
        fallback.path,
      ], routePreferenceOverride: 'lan');
      await until(
        () => target.dock.any(
          (entry) =>
              entry.title == relayed.title &&
              entry.fileId != relayed.fileId &&
              entry.status == 'failed',
        ),
        refresh,
      );
      final manual = target.dock.firstWhere(
        (entry) =>
            entry.title == relayed.title && entry.fileId != relayed.fileId,
      );
      final manualState = await first.call(
        'GET',
        '/transfers/${manual.transferId}',
      );
      expect(manualState['transfer']['files'][0]['transport'], 'direct');
      expect(manualState['transfer']['files'][0]['offset'], 0);
      expect(manual.localPath, isEmpty);
      stdout.writeln('Reverse direct evidence: ${folder.absolute.path}');
    } finally {
      sender?.dispose();
      receiver?.dispose();
      await sourcePeer?.close();
      await targetPeer?.close();
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await errors.cancel();
      await log.close();
      ReceiveDestination.registryDirectoryForTesting = null;
    }
  }, timeout: const Timeout(Duration(seconds: 70)));
}
