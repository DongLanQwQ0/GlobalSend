import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

class QueueApi extends CenterApi {
  QueueApi() : super('https://fixture', token: 'test');
  final calls = <String>[], offsets = <int>[];
  final releases = <Completer<void>>[];
  bool hold = false;
  int active = 0, peak = 0;
  final serverFailed = <String>{}, receiveFailed = <String>{};
  Map<String, dynamic> transfer(String id) => {
    'transferId': id,
    'sourceDeviceId': 'self',
    'targetDeviceId': 'peer',
    'files': [
      {
        'fileId': id,
        'name': '$id.bin',
        'size': 8,
        'status': serverFailed.contains(id) ? 'failed' : 'accepted',
        'transport': 'relay',
        'offset': 4,
        'receiveFailure': receiveFailed.contains(id),
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add('$method $path');
    final parts = path.split('/');
    if (method == 'GET') return {'transfer': transfer(parts.last)};
    if (path.endsWith('/receive-retry') || path.endsWith('/retry')) {
      serverFailed.remove(parts[2]);
      receiveFailed.remove(parts[2]);
    }
    return {};
  }

  @override
  Future<void> upload(String path, List<int> bytes) async {
    offsets.add(int.parse(Uri.parse(path).queryParameters['offset']!));
    active++;
    if (active > peak) peak = active;
    try {
      if (hold) {
        final release = Completer<void>();
        releases.add(release);
        await release.future;
      }
    } finally {
      active--;
    }
  }
}

DockEntry item(
  String id,
  String status, {
  bool outgoing = true,
  String kind = 'file',
}) => DockEntry(
  id: id,
  fileId: id,
  transferId: id,
  kind: kind,
  title: '$id.bin',
  source: 'self',
  targetDeviceId: 'peer',
  size: 8,
  status: status,
  outgoing: outgoing,
);
SendController controller(QueueApi api) => SendController()
  ..api = api
  ..profile = ServerProfile(
    baseUrl: api.baseUrl,
    instanceId: 'one',
    deviceId: 'self',
  )
  ..info = {
    'limits': {'chunkSize': 4},
  };
Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 15));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  setUp(() async {
    final root = await Directory('build/test-tmp').create(recursive: true);
    folder = await root.createTemp('failed-outgoing-');
  });
  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });
  test('clear failed outgoing queue is exact by ID and leaves shared external original and mixed states intact', () async {
    final api = QueueApi(), c = controller(QueueApi());
    c.api = api;
    addTearDown(c.dispose);
    c.root = await Directory('${folder.path}/state').create();
    final original = await File('${folder.path}/original.bin')
        .writeAsBytes(List.filled(8, 7));
    final failed = item('failed', 'failed'),
        failedSibling = item('failed-sibling', 'failed');
    final keep = [
      item('success', 'received'),
      item('normal', 'offered'),
      item('active', 'uploading'),
      item('paused', 'paused')..locallyPaused = true,
      item('incoming', 'failed', outgoing: false),
      item('text', 'failed', kind: 'text'),
    ];
    c.dock = [failed, failedSibling, ...keep];
    for (final entry in c.dock) c.sources[entry.fileId] = original.path;
    expect(c.failedOutgoingFiles.map((entry) => entry.id), [
      'failed',
      'failed-sibling',
    ]);
    await c.clearFailedOutgoingFiles();
    await c.persistenceIdle;
    expect(c.dock, keep);
    expect(c.sources.keys.toSet(), keep.map((entry) => entry.id).toSet());
    expect(await original.readAsBytes(), List.filled(8, 7));
    c.updateTransfer(api.transfer('failed'));
    expect(c.dock, keep);
    final state = jsonDecode(
      await File('${c.root!.path}/${c.profile!.storageKey}.json')
          .readAsString(),
    );
    expect(
      (state['dock'] as List).map((entry) => entry['id']),
      keep.map((entry) => entry.id),
    );
    expect(state['hiddenDockIds'], containsAll(['failed', 'failed-sibling']));
  });
  test('retry all coalesces duplicate clicks and runs four transfers from committed offsets without a new offer', () async {
    final api = QueueApi()..hold = true, c = controller(api);
    addTearDown(c.dispose);
    final entries = List.generate(
      6,
      (i) => item('f$i', 'failed')..error = 'network failed',
    );
    c.dock = [
      ...entries,
      item('paused', 'paused')..locallyPaused = true,
      item('incoming', 'failed', outgoing: false),
      item('normal', 'accepted'),
    ];
    for (final entry in entries)
      c.sources[entry.id] = (await File(
        '${folder.path}/${entry.id}',
      ).writeAsBytes(List.filled(8, 1))).path;
    final first = c.retryFailedOutgoingFiles(),
        second = c.retryFailedOutgoingFiles();
    for (var i = 0; i < 100 && api.active < 4; i++) await tick();
    expect(api.active, 4);
    expect(api.peak, 4);
    api.hold = false;
    for (final release in api.releases) release.complete();
    await Future.wait([first, second]);
    expect(api.offsets, List.filled(6, 4));
    expect(entries.map((entry) => entry.status), everyElement('ready'));
    expect(
      api.calls.any(
        (call) => call == 'POST /transfers' || call.endsWith('/retry'),
      ),
      isFalse,
    );
    expect(c.dock.firstWhere((entry) => entry.id == 'paused').status, 'paused');
    expect(
      c.dock.firstWhere((entry) => entry.id == 'incoming').status,
      'failed',
    );
  });
  test('receive-failure retry uses preserving endpoint while generic corrupt relay explicitly resets', () async {
    final api = QueueApi()
      ..serverFailed.addAll(['destination', 'corrupt'])
      ..receiveFailed.add('destination');
    final c = controller(api);
    addTearDown(c.dispose);
    final destination = item('destination', 'failed')
      ..receiveFailure = true
      ..error = 'folder unavailable';
    final corrupt = item('corrupt', 'failed')..error = 'HASH_MISMATCH';
    c.dock = [destination, corrupt];
    for (final entry in c.dock)
      c.sources[entry.id] = (await File(
        '${folder.path}/${entry.id}',
      ).writeAsBytes(List.filled(8, 1))).path;
    await c.retryFailedOutgoingFiles();
    expect(
      api.calls,
      contains('POST /transfers/destination/files/destination/receive-retry'),
    );
    expect(
      api.calls,
      isNot(contains('POST /transfers/destination/files/destination/retry')),
    );
    expect(api.calls, contains('POST /transfers/corrupt/files/corrupt/retry'));
    expect(c.dock.map((entry) => entry.status), everyElement('ready'));
  });
}
