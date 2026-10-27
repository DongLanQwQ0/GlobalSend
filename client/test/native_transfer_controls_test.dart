import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/transfer_operation.dart';
import 'package:globalsend/receive_destination.dart';

import 'saved_files_test.dart' show LibraryApi;

class RealHttpOverrides extends HttpOverrides {}

class PausedReceiveApi extends LibraryApi {
  bool resumed = false;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    final result = await super.call(method, path, body, authenticated);
    if (method == 'GET' && result['transfer'] is Map) {
      final t = Map<String, dynamic>.from(result['transfer']);
      t.addAll({
        'transferId': 'incoming',
        'sourceDeviceId': 'sender',
        'targetDeviceId': 'peer',
      });
      final file = Map<String, dynamic>.from((t['files'] as List).single);
      file.addAll({'name': 'partial.bin', 'size': 4, 'offset': 0});
      t['files'] = [file];
      return {'transfer': t};
    }
    return result;
  }

  @override
  Future<void> download(
    String path,
    File destination,
    void Function(int) progress, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    if (resumed) {
      expect(await destination.readAsBytes(), [1, 2]);
      return super.download(
        path,
        destination,
        progress,
        expectedSha256: expectedSha256,
        expectedSize: expectedSize,
      );
    }
    await destination.writeAsBytes([1, 2]);
    progress(2);
    await TransferOperation.current!.stopped.future;
    throw const TransferStopped();
  }
}

class ControlApi extends CenterApi {
  ControlApi() : super('http://fixture', token: 'fixture');
  Completer<Map<String, dynamic>>? metadata, cancelRequest;
  Completer<void>? blockedUpload;
  final calls = <String>[], offsets = <int>[];
  int offset = 0;
  Map<String, dynamic> get transfer => {
    'transferId': 't',
    'sourceDeviceId': 'self',
    'targetDeviceId': 'peer',
    'createdAt': '2026-10-27T00:00:00Z',
    'files': [
      {
        'fileId': 'f',
        'name': 'sample.bin',
        'size': 8,
        'status': 'accepted',
        'transport': 'relay',
        'offset': offset,
        'sha256': 'fixture',
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
    if (method == 'GET') return metadata?.future ?? {'transfer': transfer};
    if (path.endsWith('/cancel') && cancelRequest != null)
      return cancelRequest!.future;
    return {};
  }

  @override
  Future<void> upload(String path, List<int> bytes) async {
    final at = int.parse(Uri.parse(path).queryParameters['offset']!);
    offsets.add(at);
    if (at == 4 && blockedUpload != null) await blockedUpload!.future;
    offset = at + bytes.length;
  }
}

DockEntry entry({bool outgoing = true}) => DockEntry(
  id: 'f',
  kind: 'file',
  title: 'sample.bin',
  source: 'self',
  fileId: 'f',
  transferId: 't',
  size: 8,
  outgoing: outgoing,
  status: 'accepted',
  targetDeviceId: 'peer',
);
SendController controller(ControlApi api) => SendController()
  ..api = api
  ..profile = ServerProfile(
    baseUrl: 'http://fixture',
    instanceId: 'one',
    deviceId: 'self',
  )
  ..info = {
    'limits': {'chunkSize': 4},
    'features': {'receiveErrorReporting': true},
  };
Future<void> settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  setUp(() async {
    folder = await Directory('build/test-tmp').create(recursive: true);
    folder = await folder.createTemp('file-controls-');
  });
  tearDown(() async {
    if (await folder.exists()) await folder.delete(recursive: true);
  });
  test('pause preserves receiver partial and resume reuses it rather than deleting it', () async {
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${folder.path}/registry');
    addTearDown(() => ReceiveDestination.registryDirectoryForTesting = null);
    final api = PausedReceiveApi();
    final c = SendController(documentsDirectory: () async => folder)
      ..root = await Directory('${folder.path}/state').create()
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'one',
        deviceId: 'peer',
      )
      ..api = api
      ..info = {
        'features': {'direct': false},
      };
    addTearDown(c.dispose);
    final item = DockEntry(
      id: 'received',
      kind: 'file',
      title: 'partial.bin',
      source: 'sender',
      fileId: 'received',
      transferId: 'incoming',
      size: 4,
      status: 'ready',
    );
    c.dock.add(item);
    final receive = c.receive(item);
    for (var i = 0; i < 50 && item.receivedBytes < 2; i++) await settle();
    expect(item.receivedBytes, 2, reason: item.error);
    await c.pause(item);
    await receive;
    expect(item.status, 'paused');
    expect(await File(item.partialPath).readAsBytes(), [1, 2]);
    api.resumed = true;
    await c.resume(item);
    expect(item.status, 'received', reason: item.error);
    expect(await File(item.localPath).readAsBytes(), [1, 2, 3, 4]);
  });
  test('incoming offer notifies before metadata and keeps one receipt identity across completion and dismissal', () async {
    if (!Platform.isWindows) return;
    final api = ControlApi()..metadata = Completer();
    final c = controller(api);
    c.profile!.deviceId = 'peer';
    c.profile!.autoReceive = false;
    addTearDown(c.dispose);
    final snapshots = <String>[];
    c.addListener(() {
      if (c.pendingReceipts.isNotEmpty)
        snapshots.add(c.pendingReceipts.values.first.status);
    });
    final transfer = api.transfer;
    final remote = (transfer['files'] as List).single as Map;
    remote['status'] = 'offered';
    c.updateTransfer(transfer);
    expect(snapshots, ['offered']);
    expect(api.calls, isEmpty);
    final item = c.dock.single, serial = c.receiptSerial;
    c.dismissReceipts([item.id]);
    remote['status'] = 'received';
    c.updateTransfer(transfer);
    expect(c.receiptSerial, serial);
    expect(c.pendingReceipts, isEmpty);
  });
  test('queued gate cancellation never consumes a permit', () async {
    final gate = TransferGate(limit: 1);
    await gate.enter();
    final stop = Completer<void>();
    final wait = expectLater(
      gate.enter(stopped: stop.future),
      throwsA(isA<TransferStopped>()),
    );
    stop.complete();
    await wait;
    expect(gate.active, 1);
    gate.leave();
    expect(gate.active, 0);
  });
  test('pause during metadata is immediate and late metadata cannot restart the file', () async {
    final api = ControlApi()..metadata = Completer();
    final c = controller(api);
    addTearDown(c.dispose);
    final file = await File('${folder.path}/sample.bin')
        .writeAsBytes(List.generate(8, (i) => i));
    final item = entry();
    c.sources['f'] = file.path;
    c.dock.add(item);
    final work = c.upload(item);
    await settle();
    await c.pause(item).timeout(const Duration(milliseconds: 200));
    expect(item.status, 'paused');
    await work.timeout(const Duration(milliseconds: 500));
    expect(c.busyFiles, isEmpty);
    api.metadata!.complete({'transfer': api.transfer});
    await settle();
    expect(item.status, 'paused');
    expect(api.offsets, isEmpty);
    final restored = DockEntry.fromJson(item.toJson());
    expect(restored.locallyPaused, isTrue);
    c.updateTransfer(api.transfer);
    await settle();
    expect(item.status, 'paused');
    expect(api.offsets, isEmpty);
  });
  test('resume reads committed offset without destructive retry and keeps source reference', () async {
    final api = ControlApi()..blockedUpload = Completer();
    final c = controller(api);
    addTearDown(c.dispose);
    final file = await File('${folder.path}/sample.bin')
        .writeAsBytes(List.generate(8, (i) => i));
    final item = entry();
    c.sources['f'] = file.path;
    c.dock.add(item);
    final work = c.upload(item);
    for (var i = 0; i < 50 && api.offsets.length < 2; i++) await settle();
    expect(api.offsets, [0, 4]);
    await c.pause(item);
    await work;
    expect(item.status, 'paused');
    expect(item.progress, .5);
    expect(c.sources['f'], file.path);
    api.blockedUpload = null;
    await c.resume(item);
    expect(api.offsets, [0, 4, 4]);
    expect(item.status, 'ready');
    expect(api.calls.where((s) => s.endsWith('/retry')), isEmpty);
  });
  test('cancel is immediate even when center cancel never responds and ignores late work', () async {
    final api = ControlApi()
      ..metadata = Completer()
      ..cancelRequest = Completer();
    final c = controller(api);
    addTearDown(c.dispose);
    final item = entry();
    c.sources['f'] = 'unread';
    c.dock.add(item);
    final work = c.upload(item);
    await settle();
    await c.cancel(item).timeout(const Duration(milliseconds: 200));
    expect(item.status, 'canceled');
    await work.timeout(const Duration(milliseconds: 500));
    api.metadata!.complete({'transfer': api.transfer});
    api.cancelRequest!.complete({});
    await settle();
    c.updateTransfer(api.transfer);
    expect(item.status, 'canceled');
    expect(api.offsets, isEmpty);
    expect(c.busyFiles, isEmpty);
  });
  test('remote receive storage error reaches sender and does not automatically upload', () async {
    final api = ControlApi();
    final c = controller(api);
    addTearDown(c.dispose);
    final item = entry();
    c.sources['f'] = 'source';
    c.dock.add(item);
    final transfer = api.transfer;
    final f = (transfer['files'] as List).single as Map;
    f['status'] = 'failed';
    f['receiveFailure'] = true;
    f['errorCode'] = '该目录不支持直接读写';
    c.updateTransfer(transfer);
    await settle();
    expect(item.status, 'failed');
    expect(item.receiveFailure, isTrue);
    expect(item.error, '该目录不支持直接读写');
    expect(api.calls, isEmpty);
  });
  test('receive failure retry preserves relay committed bytes instead of resetting the attempt', () async {
    final api = ControlApi()..offset = 4;
    final c = controller(api);
    addTearDown(c.dispose);
    final item = entry()
      ..status = 'failed'
      ..receiveFailure = true
      ..error = '接收目录不可写';
    final file = await File('${folder.path}/retry.bin')
        .writeAsBytes(List.generate(8, (i) => i));
    c.sources['f'] = file.path;
    c.dock.add(item);
    await c.retry(item);
    expect(api.calls, contains('POST /transfers/t/files/f/receive-retry'));
    expect(api.calls, isNot(contains('POST /transfers/t/files/f/retry')));
    expect(api.offsets, [4]);
    expect(item.status, 'ready');
    expect(item.receiveFailure, isFalse);
  });
  test('upgrading an old failed receiver reports its saved directory error without restarting it', () async {
    final api = ControlApi();
    final c = controller(api);
    c.profile!.deviceId = 'peer';
    addTearDown(c.dispose);
    final item = entry(outgoing: false)
      ..status = 'failed'
      ..error = '该目录不支持直接读写，请选择本地文件夹';
    c.dock.add(item);
    c.updateTransfer(api.transfer);
    await settle();
    expect(item.status, 'failed');
    expect(item.receiveFailure, isTrue);
    expect(api.calls.where((s) => s.endsWith('/receive-error')), hasLength(1));
    expect(api.offsets, isEmpty);
  });
  test('receiver destination preparation failure reports once and does not fall back to relay', () async {
    final api = ControlApi();
    final notDirectory = await File('${folder.path}/not-directory')
        .writeAsString('x');
    final c =
        SendController(
            documentsDirectory: () async => Directory(notDirectory.path),
          )
          ..api = api
          ..profile = ServerProfile(
            baseUrl: 'http://fixture',
            instanceId: 'one',
            deviceId: 'peer',
          )
          ..info = {
            'features': {'receiveErrorReporting': true},
          };
    addTearDown(c.dispose);
    final item = entry(outgoing: false);
    await c.receive(item);
    await settle();
    expect(item.status, 'failed');
    expect(item.receiveFailure, isTrue);
    expect(api.calls.where((s) => s.endsWith('/receive-error')), hasLength(1));
    expect(api.calls.where((s) => s.endsWith('/relay')), isEmpty);
  });
  test(
    'per-file HTTP cancellation aborts one hanging response without closing shared center',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        if (request.uri.path.endsWith('/fast')) {
          request.response.write('{}');
          unawaited(request.response.close());
        }
      });
      final api = CenterApi('http://127.0.0.1:${server.port}');
      addTearDown(api.close);
      final op = TransferOperation();
      final pending = op.run(() => api.forOperation(op).call('GET', '/slow'));
      final stopped = expectLater(pending, throwsA(anything));
      await settle();
      await op.cancel();
      await stopped.timeout(const Duration(milliseconds: 500));
      await op.dispose();
      expect(await api.call('GET', '/fast'), isEmpty);
    }, RealHttpOverrides()),
  );
}
