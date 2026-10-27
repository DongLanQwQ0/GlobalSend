import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/received_file_access.dart';
import 'package:globalsend/saved_files.dart';

import 'saved_files_test.dart' show LibraryApi, fixtureDirectory, profile;

DockEntry incoming() => DockEntry(
  id: 'received',
  kind: 'file',
  title: '收到的文件.txt',
  source: 'sender',
  transferId: 'incoming',
  fileId: 'received',
  size: 4,
);

Future<SendController> receiver(Directory folder, String destination) async {
  final state = await Directory('${folder.path}/state').create();
  await File('${state.path}/saved-files.json').writeAsString(
    jsonEncode({
      'receiveDestinationLocation': destination,
      'receiveDestinationLabel': '我的接收目录',
      'files': [],
    }),
  );
  final p = profile();
  return SendController(
      documentsDirectory: () async => Directory('${folder.path}/documents'),
    )
    ..root = state
    ..profile = p
    ..profiles = [p]
    ..api = LibraryApi()
    ..connected = true
    ..devices = [
      {'deviceId': 'peer', 'online': true},
    ]
    ..info = {
      'features': {'direct': false},
      'limits': {'maxFileSize': 1024},
    };
}

class UriFixture {
  UriFixture(this.folder);
  final Directory folder;
  final files = <String, File>{};
  final handles = <String, String>{};
  final calls = <String>[];
  int serial = 0;
  Map<String, dynamic> info(String uri) => {
    'location': uri,
    'name': files[uri]?.uri.pathSegments.last ?? '',
    'size': files[uri]?.existsSync() == true ? files[uri]!.lengthSync() : 0,
    'exists': files[uri]?.existsSync() ?? false,
  };
  Map<String, dynamic> lease(String uri) {
    final handle = 'lease-${++serial}';
    handles[handle] = uri;
    return {...info(uri), 'handle': handle, 'ioPath': files[uri]!.path};
  }

  Future<Object?> call(MethodCall call) async {
    calls.add(call.method);
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final uri = args['location'] as String? ?? '';
    switch (call.method) {
      case 'create':
        final location = 'content://fixture/document/${++serial}';
        files[location] = await File('${folder.path}/${args['name']}').create();
        return lease(location);
      case 'open':
        return lease(uri);
      case 'close':
        handles.remove(args['handle']);
        return null;
      case 'isOwned':
        return files.containsKey(uri);
      case 'stat':
        return info(uri);
      case 'rename':
        expect(
          handles.values,
          isNot(contains(uri)),
          reason: 'close before rename',
        );
        final next = 'content://fixture/document/${++serial}';
        files[next] = await files
            .remove(uri)!
            .rename('${folder.path}/${args['name']}');
        return info(next);
      case 'delete':
        final file = files.remove(uri);
        if (file != null && await file.exists()) await file.delete();
        return file != null;
      default:
        throw StateError('Unexpected method ${call.method}');
    }
  }
}

class InterruptedApi extends LibraryApi {
  @override
  Future<void> download(
    String path,
    File destination,
    void Function(int) progress, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    await destination.writeAsBytes([1, 2]);
    progress(2);
    throw const SocketException('fixture interrupted');
  }
}

class UploadApi extends LibraryApi {
  final uploaded = <int>[];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path == '/transfers/upload') {
      return {
        'transfer': {
          'files': [
            {'fileId': 'upload-file', 'status': 'accepted', 'offset': 0},
          ],
        },
      };
    }
    if (path.endsWith('/complete')) return {};
    return super.call(method, path, body, authenticated);
  }

  @override
  Future<void> upload(String path, List<int> bytes) async =>
      uploaded.addAll(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('relay upload reads a canonical URI through one live lease', () async {
    final folder = await fixtureDirectory();
    final uri = UriFixture(folder);
    const location = 'content://fixture/document/relay-source';
    uri.files[location] = await File('${folder.path}/relay-source.bin')
        .writeAsBytes([1, 2, 3, 4]);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReceiveDestination.channel, uri.call);
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(ReceiveDestination.channel, null),
    );
    final c = await receiver(folder, '');
    addTearDown(c.dispose);
    c.api?.close();
    final api = UploadApi();
    c.api = api;
    c.info = {
      'limits': {'chunkSize': 2},
    };
    c.sources['upload-file'] = location;
    final item = DockEntry(
      id: 'upload-file',
      kind: 'file',
      title: 'source.bin',
      source: 'receiver',
      transferId: 'upload',
      fileId: 'upload-file',
      size: 4,
      outgoing: true,
    );
    c.dock = [item];
    await c.upload(item);
    expect(item.status, 'ready', reason: item.error);
    expect(api.uploaded, [1, 2, 3, 4]);
    expect(uri.calls.where((call) => call == 'open'), hasLength(1));
    expect(uri.handles, isEmpty);
  });

  test('SAF partial resumes through its original URI after restart and failed source reads close the lease', () async {
    final folder = await fixtureDirectory();
    final selected = await Directory('${folder.path}/provider').create();
    final uri = UriFixture(selected);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReceiveDestination.channel, uri.call);
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(ReceiveDestination.channel, null),
    );
    final c = await receiver(folder, 'content://fixture/tree/selected');
    addTearDown(c.dispose);
    c.api?.close();
    c.api = InterruptedApi();
    final item = incoming();
    c.dock = [item];
    await c.receive(item);
    expect(item.status, 'failed');
    expect(item.partialPath, startsWith('content://'));
    expect(item.receivedBytes, 2);
    expect(uri.handles, isEmpty);
    final persisted = jsonDecode(
      await File('${c.root!.path}/${c.profile!.key}.json').readAsString(),
    );
    final resumed = DockEntry.fromJson(
      Map<String, dynamic>.from(persisted['dock'][0]),
    );
    c.dock = [resumed];
    c.api?.close();
    c.api = LibraryApi();
    // Even when the selected folder changes, the original partial stays bound.
    await c.clearReceiveDirectory();
    await c.receive(resumed);
    expect(resumed.status, 'received', reason: resumed.error);
    expect(uri.calls.where((call) => call == 'create'), hasLength(1));
    expect(uri.calls.where((call) => call == 'open'), hasLength(1));
    expect(uri.handles, isEmpty);
    await uri.files[resumed.localPath]!.delete();
    await expectLater(
      c.offer('peer', [resumed.localPath]),
      throwsA(isA<FileSystemException>()),
    );
    expect(uri.handles, isEmpty);
  });

  test('selected Windows folder receives directly, preserves collisions, and cleans only its registered file', () async {
    final folder = await fixtureDirectory();
    final selected = await Directory('${folder.path}/selected').create();
    final existing = await File('${selected.path}/收到的文件.txt')
        .writeAsString('user-owned');
    final c = await receiver(folder, selected.absolute.path);
    addTearDown(c.dispose);
    final item = incoming();
    c.dock = [item];
    await c.receive(item);
    expect(item.status, 'received', reason: item.error);
    addTearDown(() async {
      if (await ReceiveDestination.isOwned(item.localPath)) {
        await ReceiveDestination.delete(item.localPath);
      }
    });
    expect(
      await File(item.localPath).parent.resolveSymbolicLinks(),
      await selected.resolveSymbolicLinks(),
    );
    expect(await File(item.localPath).readAsBytes(), [1, 2, 3, 4]);
    expect(await existing.readAsString(), 'user-owned');
    expect(await Directory('${folder.path}/documents').exists(), false);
    expect(c.savedFiles.single.managedLocation, true);
    expect(c.hasCustomReceiveDirectory, true);
    expect(c.receiveDirectoryLabel, '我的接收目录');
    final store = SavedFilesStore(
      indexFile: File('${folder.path}/state/saved-files.json'),
      documentsDirectory: Directory('${folder.path}/documents'),
    );
    await store.load();
    expect(store.items.single.path, item.localPath);
    await store.prune(DateTime.now().add(const Duration(days: 2)));
    expect(await File(item.localPath).exists(), false);
    expect(await existing.readAsString(), 'user-owned');
  }, skip: !Platform.isWindows);

  test('SAF reception, restart, forward and cleanup retain canonical URI without a second copy or leaked lease', () async {
    final folder = await fixtureDirectory();
    final selected = await Directory('${folder.path}/provider').create();
    final uri = UriFixture(selected);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReceiveDestination.channel, uri.call);
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(ReceiveDestination.channel, null),
    );
    final c = await receiver(folder, 'content://fixture/tree/selected');
    addTearDown(c.dispose);
    final item = incoming();
    c.dock = [item];
    await c.receive(item);
    expect(item.status, 'received', reason: item.error);
    expect(item.localPath, startsWith('content://'));
    expect(item.partialPath, isEmpty);
    expect(uri.handles, isEmpty);
    expect(await Directory('${folder.path}/documents').exists(), false);
    expect(await selected.list().length, 1);
    final source = await ReceivedFileAccess.open(item.localPath);
    expect(await source.file.readAsBytes(), [1, 2, 3, 4]);
    await source.close();
    final store = SavedFilesStore(
      indexFile: File('${folder.path}/state/saved-files.json'),
      documentsDirectory: Directory('${folder.path}/documents'),
    );
    await store.load();
    expect(store.items.single.path, item.localPath);
    expect(
      (await store.indexFile.readAsString()).contains(
        selected.path.replaceAll('\\', '\\\\'),
      ),
      false,
    );
    await c.renameSavedFile(c.savedFiles.single.id, '转发文件.txt');
    await c.forwardSavedFiles('peer', [c.savedFiles.single.id]);
    expect(c.sources.values.single, item.localPath);
    expect((c.api as LibraryApi).offered!['files'][0]['name'], '转发文件.txt');
    expect(uri.handles, isEmpty);
    await store.prune(DateTime.now().add(const Duration(days: 2)));
    expect(uri.files, isEmpty);
    expect(uri.handles, isEmpty);
  });
}
