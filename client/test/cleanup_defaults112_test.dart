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
}
