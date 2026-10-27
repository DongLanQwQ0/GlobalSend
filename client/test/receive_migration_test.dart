import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/saved_files.dart';

import 'saved_files_test.dart' show fixtureDirectory, profile;
import 'saved_files_destination_test.dart' show UriFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'new profiles allow cellular without changing explicit saved choices',
    () {
      final p = ServerProfile(baseUrl: 'https://fixture', instanceId: 'one');
      expect(p.cellularAllowed, isTrue);
      expect(p.relayConfirmMiB, 32);
      expect(
        ServerProfile.fromJson({'baseUrl': p.baseUrl, 'instanceId': 'one'})
            .cellularAllowed,
        isTrue,
      );
      expect(
        ServerProfile.fromJson({...p.toJson(), 'cellularAllowed': false})
            .cellularAllowed,
        isFalse,
      );
    },
  );

  test('cleanup defaults include only images and text at or below 500 KB', () {
    final rules = SavedFileCleanupFilter();
    expect(rules.categories, {SavedFileCategory.image, SavedFileCategory.text});
    SavedFile item(String name, int size) => SavedFile(
      id: '',
      profileKey: '',
      deviceId: '',
      groupId: '',
      transferId: '',
      fileId: '',
      path: '',
      name: name,
      size: size,
      receivedAtMillis: 0,
    );
    for (final name in ['picture.png', 'notes.txt', 'page.html']) {
      expect(rules.matches(item(name, 500000)), isTrue);
      expect(rules.matches(item(name, 500001)), isFalse);
    }
    for (final name in ['movie.mp4', 'audio.mp3', 'archive.zip', 'other.bin']) {
      expect(rules.matches(item(name, 1)), isFalse);
    }
    expect(
      SavedFileCleanupFilter.fromJson(rules.toJson()).sizeRule,
      SavedFileSizeRule.atMost,
    );
  });

  Future<SavedFile> add(
    SavedFilesStore store,
    String base,
    String id, {
    String name = '文件.txt',
    String relative = '',
    bool directory = false,
  }) async {
    final p = profile();
    String path;
    if (directory) {
      path = await ReceiveDestination.folderDirectory(
        destinationLocation: base,
        transferKey: 'tree',
        relativePath: relative,
      );
    } else {
      var parent = base;
      if (relative.contains('/'))
        parent = await ReceiveDestination.folderDirectory(
          destinationLocation: base,
          transferKey: 'tree',
          relativePath: relative.substring(0, relative.lastIndexOf('/')),
        );
      final handle = await ReceiveDestination.create(
        destinationLocation: parent,
        name: name,
      );
      await File(handle.ioPath).writeAsString('正文 $id');
      await ReceiveDestination.closeHandle(handle.handle);
      path = handle.location;
    }
    return (await store.register(
      profile: p,
      entry: DockEntry(
        id: id,
        kind: 'file',
        title: name,
        source: 'sender',
        transferId: 'tree',
        fileId: id,
        localPath: path,
        entryKind: directory ? 'directory' : 'file',
        relativePath: relative,
      ),
      receivedAt: DateTime(2026, 10, 27, 12),
      managedLocation: true,
    ))!;
  }

  test('moving reception files preserves bytes, identities and times without overwriting a user file', () async {
    final root = await fixtureDirectory();
    final old = await Directory('${root.path}/old').create();
    final next = await Directory('${root.path}/next').create();
    final docs = await Directory('${root.path}/documents').create();
    final store = SavedFilesStore(
      indexFile: File('${root.path}/state/saved-files.json'),
      documentsDirectory: docs,
    );
    await store.setReceiveDestination(old.path, 'old');
    final a = await add(store, old.path, 'a'),
        b = await add(store, old.path, 'b');
    await File('${next.path}/文件.txt').writeAsString('原有文件不能覆盖');
    var committed = false;
    await store.setReceiveDestination(
      next.path,
      'next',
      onCommitted: () async {
        committed = true;
        expect(await File(a.path).exists(), isTrue);
        expect(await File(b.path).exists(), isTrue);
        expect(
          store.items.every((item) => File(item.path).absolute.uri.path.startsWith(next.absolute.uri.path)),
          isTrue,
        );
      },
    );
    expect(committed, isTrue);
    expect(await File(a.path).exists(), isFalse);
    expect(await File(b.path).exists(), isFalse);
    expect(await File('${next.path}/文件.txt').readAsString(), '原有文件不能覆盖');
    for (final item in store.items) {
      expect(await File(item.path).readAsString(), '正文 ${item.fileId}');
      expect(item.receivedAtMillis, a.receivedAtMillis);
      expect(item.managedLocation, isTrue);
    }
    final restored = SavedFilesStore(
      indexFile: store.indexFile,
      documentsDirectory: docs,
    );
    await restored.load();
    expect(
      restored.relocatedLocations[a.path],
      store.items.firstWhere((item) => item.id == a.id).path,
    );
    await restored.setReceiveDestination('', '');
    expect(
      restored.items.every(
        (item) => File(item.path).absolute.uri.path.startsWith(Directory('${docs.path}/GlobalSend').absolute.uri.path),
      ),
      isTrue,
    );
    expect(
      restored.relocatedLocations[a.path],
      restored.items.firstWhere((item) => item.id == a.id).path,
    );
    expect(await File(store.items.first.path).exists(), isFalse);
  });

  test('folder migration preserves hierarchy and empty directories', () async {
    final root = await fixtureDirectory();
    final old = await Directory('${root.path}/old').create();
    final next = await Directory('${root.path}/next').create();
    final store = SavedFilesStore(
      indexFile: File('${root.path}/index.json'),
      documentsDirectory: root,
    );
    await store.setReceiveDestination(old.path, 'old');
    final directory = await add(
      store,
      old.path,
      'root',
      name: '资料',
      relative: '资料',
      directory: true,
    );
    await add(
      store,
      old.path,
      'empty',
      name: '空目录',
      relative: '资料/空目录',
      directory: true,
    );
    await add(store, old.path, 'file', name: '说明.txt', relative: '资料/说明.txt');
    await store.setReceiveDestination(next.path, 'next');
    expect(await File('${next.path}/资料/说明.txt').readAsString(), '正文 file');
    expect(await Directory('${next.path}/资料/空目录').exists(), isTrue);
    expect(await Directory(directory.path).exists(), isFalse);
    expect(store.migrationCleanupPending, 0);
  });

  test('SAF files move through leased descriptors and delete the old provider copy', () async {
    final root = await fixtureDirectory();
    final provider = await Directory('${root.path}/provider').create();
    final next = await Directory('${root.path}/next').create();
    final uri = UriFixture(provider);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(ReceiveDestination.channel, uri.call);
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(ReceiveDestination.channel, null),
    );
    final store = SavedFilesStore(
      indexFile: File('${root.path}/index.json'),
      documentsDirectory: root,
    );
    await store.setReceiveDestination('content://fixture/tree', 'provider');
    final original = await add(store, 'content://fixture/tree', 'one');
    await store.setReceiveDestination(next.path, 'next');
    expect(await File(store.items.single.path).readAsString(), '正文 one');
    expect(uri.files.containsKey(original.path), isFalse);
    expect(uri.handles, isEmpty);
  });
  test('continued folder receives use the migrated root even if old user files remain',() async {
    final root=await fixtureDirectory();
    final old=await Directory('${root.path}/old').create();
    final next=await Directory('${root.path}/next').create();
    final store=SavedFilesStore(indexFile:File('${root.path}/index.json'),documentsDirectory:root);
    await store.setReceiveDestination(old.path,'old');
    final original=await add(store,old.path,'root',name:'资料',relative:'资料',directory:true);
    await File('${original.path}/user.txt').writeAsString('keep');
    await store.setReceiveDestination(next.path,'next');
    expect(await File('${original.path}/user.txt').readAsString(),'keep');
    final location=await ReceiveDestination.folderDirectory(destinationLocation:next.path,transferKey:'tree',relativePath:'资料');
    expect(location,store.items.single.path);
  });

  test('controller rewrites pending and forwarding references when the index commits', () async {
    final root = await fixtureDirectory();
    final old = await Directory('${root.path}/old').create();
    final next = await Directory('${root.path}/next').create();
    final state = await Directory('${root.path}/state').create();
    final store = SavedFilesStore(
      indexFile: File('${state.path}/saved-files.json'),
      documentsDirectory: root,
    );
    await store.setReceiveDestination(old.path, 'old');
    final original = await add(store, old.path, 'one');
    final p = profile();
    final c = SendController(documentsDirectory: () async => root)
      ..root = state
      ..profile = p
      ..profiles = [p];
    addTearDown(c.dispose);
    c.dock.add(
      DockEntry(
        id: 'one',
        kind: 'file',
        title: '文件.txt',
        source: 'sender',
        transferId: 'tree',
        fileId: 'one',
        localPath: original.path,
      ),
    );
    c.sources['forward'] = original.path;
    c.stagedFiles.add(original.path);
    await c.changeReceiveDirectory(next.path, 'next');
    final path = c.savedFiles.single.path;
    expect(c.dock.single.localPath, path);
    expect(c.sources['forward'], path);
    expect(c.stagedFiles.single, path);
    final json = jsonDecode(
      await File('${state.path}/${p.storageKey}.json').readAsString(),
    );
    expect(json['dock'][0]['localPath'], path);
    expect(json['sources']['forward'], path);
  });
}
