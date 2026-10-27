import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

class ParallelApi extends CenterApi {
  ParallelApi() : super('https://fixture', token: 'fixture');
  final releases = <Completer<void>>[];
  final starts = <String>[];
  int active = 0, peak = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (method == 'GET') {
      final id = path.split('/').last;
      starts.add(id);
      return {
        'transfer': {
          'files': [
            {'fileId': id, 'status': 'accepted', 'offset': 0},
          ],
        },
      };
    }
    return {};
  }

  @override
  Future<void> upload(String path, List<int> bytes) async {
    final pending = Completer<void>();
    releases.add(pending);
    active++;
    if (active > peak) peak = active;
    try {
      await pending.future;
    } finally {
      active--;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> turn() => Future<void>.delayed(const Duration(milliseconds: 30));
  test(
    'profile concurrency defaults to four and preserves a saved explicit value',
    () {
      final profile = ServerProfile(
        baseUrl: 'https://fixture',
        instanceId: 'one',
      );
      expect(profile.transferConcurrency, 4);
      expect(ServerProfile.fromJson(profile.toJson()).transferConcurrency, 4);
      expect(
        ServerProfile.fromJson({...profile.toJson(), 'transferConcurrency': 7})
            .transferConcurrency,
        7,
      );
      final old = profile.toJson()..remove('transferConcurrency');
      expect(ServerProfile.fromJson(old).transferConcurrency, 4);
    },
  );
  test('one FIFO gate shares four slots and resizes without interrupting active transfers', () async {
    final gate = TransferGate(), done = <int>[];
    for (var i = 0; i < 4; i++) await gate.enter();
    final fifth = gate.enter().then((_) => done.add(5));
    final sixth = gate.enter().then((_) => done.add(6));
    await turn();
    expect(done, isEmpty);
    expect(gate.active, 4);
    gate.limit = 5;
    await turn();
    expect(done, [5]);
    expect(gate.active, 5);
    gate.limit = 1;
    for (var i = 0; i < 4; i++) gate.leave();
    await turn();
    expect(done, [5]);
    expect(gate.active, 1);
    gate.leave();
    await Future.wait([fifth, sixth]);
    expect(done, [5, 6]);
    expect(gate.active, 1);
    gate.leave();
    expect(gate.active, 0);
  });
  test('real controller relay uploads run four different files concurrently and honor live resizing and queued cancellation', () async {
    final folder = await Directory('build/test-tmp').create(recursive: true);
    final own = await folder.createTemp('parallel-files-');
    final api = ParallelApi(),
        controller = SendController()
          ..api = api
          ..profile = ServerProfile(
            baseUrl: 'https://fixture',
            instanceId: 'one',
          )
          ..info = {
            'limits': {'chunkSize': 4},
          };
    addTearDown(controller.dispose);
    final entries = <DockEntry>[];
    for (var i = 0; i < 6; i++) {
      final file = await File('${own.path}/$i.bin').writeAsBytes([1, 2, 3, 4]);
      final entry = DockEntry(
        id: '$i',
        kind: 'file',
        title: '$i.bin',
        source: 'self',
        fileId: '$i',
        transferId: '$i',
        size: 4,
        outgoing: true,
        status: 'accepted',
      );
      entries.add(entry);
      controller.sources[entry.fileId] = file.path;
    }
    final jobs = entries.map(controller.upload).toList();
    for (var i = 0; i < 100 && api.active < 4; i++) await turn();
    expect(api.active, 4);
    expect(api.starts.length, 4);
    await controller.setTransferConcurrency(5);
    for (var i = 0; i < 100 && api.active < 5; i++) await turn();
    expect(api.active, 5);
    expect(api.starts.length, 5);
    entries.last.status = 'canceled';
    entries.last.locallyCanceled = true;
    await controller.setTransferConcurrency(1);
    for (final pending in api.releases) pending.complete();
    await Future.wait(jobs);
    expect(api.peak, 5);
    expect(api.starts, hasLength(5));
    expect(controller.busyFiles, isEmpty);
  });
}
