import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/saved_files.dart';

void main() {
  test('only the entire legacy default preset upgrades and persists', () async {
    final parent = await Directory('../artifacts/tmp/cleanup-library112')
        .create(recursive: true);
    final work = await parent.createTemp('defaults-');
    addTearDown(() => work.delete(recursive: true));
    final previous = {
      'retentionHours': 24,
      'cleanupFilter': {
        'categories': ['text', 'image'],
        'sizeRule': 'atMost',
        'sizeMiB': 500000 / 1048576,
      },
      'files': [],
    };
    final index = File('${work.path}/saved.json');
    for (final customized in [false, true]) {
      await index.writeAsString(
        jsonEncode({...previous, if (customized) 'retentionHours': 72}),
      );
      final store = SavedFilesStore(
        indexFile: index,
        documentsDirectory: Directory('${work.path}/files'),
      );
      await store.load();
      expect(store.retentionHours, customized ? 72 : 48);
      expect(
        store.cleanupFilter.sizeMiB * 1048576,
        customized ? 500000 : 200000,
      );
      expect(
        store.cleanupFilter.categories,
        customized
            ? {SavedFileCategory.text, SavedFileCategory.image}
            : {SavedFileCategory.image},
      );
      final persisted = jsonDecode(await index.readAsString()) as Map;
      expect(persisted['retentionHours'], customized ? 72 : 48);
    }
  });

  test('forgetEntry removes only exact clipboard metadata and preserves physical files', () async {
    final parent = await Directory('../artifacts/tmp/cleanup-library112')
        .create(recursive: true);
    final work = await parent.createTemp('forget-');
    addTearDown(() => work.delete(recursive: true));
    final file = await File('${work.path}/user-image.png')
        .writeAsString('preserved');
    final first = SavedFile(
      id: 'clipboard',
      profileKey: 'profile',
      deviceId: 'self',
      groupId: 'g',
      transferId: 'transfer',
      fileId: 'file',
      path: file.path,
      name: 'user-image.png',
      size: 9,
      receivedAtMillis: 0,
    );
    final other = SavedFile(
      id: 'normal',
      profileKey: 'profile',
      deviceId: 'self',
      groupId: 'g',
      transferId: 'other-transfer',
      fileId: 'file',
      path: file.path,
      name: 'user-image.png',
      size: 9,
      receivedAtMillis: 0,
    );
    final index = File('${work.path}/index.json');
    await index.writeAsString(
      jsonEncode({
        'files': [first.toJson(), other.toJson()],
      }),
    );
    final store = SavedFilesStore(indexFile: index, documentsDirectory: work);
    await store.forgetEntry('profile', 'transfer', 'file');
    expect(store.items.map((item) => item.id), ['normal']);
    expect(await file.readAsString(), 'preserved');
    final fresh = SavedFilesStore(indexFile: index, documentsDirectory: work);
    await fresh.load();
    expect(fresh.items.map((item) => item.id), ['normal']);
  });

  test('category filter separates folder roots from suffix-based files', () {
    SavedFile entry(String name, {bool directory = false}) => SavedFile(
      id: name,
      profileKey: '',
      deviceId: '',
      groupId: '',
      transferId: '',
      fileId: '',
      path: '',
      name: name,
      size: 0,
      receivedAtMillis: 0,
      directory: directory,
    );
    expect(
      savedFileMatchesCategory(
        entry('PHOTO.JPG'),
        SavedFilesCategoryFilter.image,
      ),
      isTrue,
    );
    expect(
      savedFileMatchesCategory(
        entry('photo.jpg', directory: true),
        SavedFilesCategoryFilter.image,
      ),
      isFalse,
    );
    expect(
      savedFileMatchesCategory(
        entry('photo.jpg', directory: true),
        SavedFilesCategoryFilter.folder,
      ),
      isTrue,
    );
    expect(
      savedFileMatchesCategory(
        entry('paper.pdf'),
        SavedFilesCategoryFilter.other,
      ),
      isTrue,
    );
    expect(
      savedFileMatchesCategory(
        entry('folder', directory: true),
        SavedFilesCategoryFilter.other,
      ),
      isFalse,
    );
    expect(
      savedFileMatchesCategory(entry('any'), SavedFilesCategoryFilter.all),
      isTrue,
    );
  });
  test('store cleanup removes expired image members but keeps suffix-named folder roots and their contents', () async {
    final parent = await Directory('../artifacts/tmp/cleanup-directory112')
        .create(recursive: true);
    final work = await parent.createTemp('store-');
    addTearDown(() => work.delete(recursive: true));
    final root = await Directory(
      '${work.path}/GlobalSend/profile/device/root/album.png',
    ).create(recursive: true);
    final sub = await Directory('${root.path}/notes.txt').create();
    final photo = await File('${sub.path}/photo.png').writeAsString('image');
    final keep = await File('${sub.path}/keep.txt').writeAsString('keep');
    final stamp = DateTime.now()
        .subtract(const Duration(hours: 50))
        .millisecondsSinceEpoch;
    SavedFile entry(
      String id,
      String path,
      String name, {
      bool directory = false,
      int size = 0,
    }) => SavedFile(
      id: id,
      profileKey: 'profile',
      deviceId: 'device',
      groupId: 'g',
      transferId: 'tree',
      fileId: 'root',
      path: path,
      name: name,
      size: size,
      receivedAtMillis: stamp,
      directory: directory,
      relativePath: path
          .substring(root.parent.path.length + 1)
          .replaceAll('\\', '/'),
    );
    final records = [
      entry('root', root.path, 'album.png', directory: true),
      entry('sub', sub.path, 'notes.txt', directory: true),
      entry('image', photo.path, 'photo.png', size: 5),
      entry('text', keep.path, 'keep.txt', size: 4),
    ];
    final index = File('${work.path}/index.json');
    await index.writeAsString(
      jsonEncode({'files': records.map((file) => file.toJson()).toList()}),
    );
    final store = SavedFilesStore(indexFile: index, documentsDirectory: work);
    await store.load();
    expect(store.cleanupFilter.matches(records.first), isFalse);
    expect(
      SavedFileCleanupFilter(
        categories: {SavedFileCategory.text},
        sizeRule: SavedFileSizeRule.any,
      ).matches(records[1]),
      isFalse,
    );
    expect(await store.ownsExisting(records.first), isTrue);
    expect((await store.prune(DateTime.now())).map((file) => file.id), [
      'image',
    ]);
    expect(await photo.exists(), isFalse);
    expect(await keep.readAsString(), 'keep');
    expect(await root.exists(), isTrue);
    expect(await sub.exists(), isTrue);
    final fresh = SavedFilesStore(indexFile: index, documentsDirectory: work);
    await fresh.load();
    expect(fresh.items.map((file) => file.id).toSet(), {'root', 'sub', 'text'});
    expect(folderLibraryCards(fresh.items).map((file) => file.id), ['root']);
  });
}
