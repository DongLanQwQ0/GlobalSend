import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/saved_files.dart';

import 'saved_files_test.dart'
    show fixtureDirectory, profile, savedEntry, LibraryApi;
import 'saved_files_destination_test.dart'
    show receiver, incoming, InterruptedApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ordinary receives write the final flat file immediately and never replace a same-name original', () async {
    final work = await fixtureDirectory();
    final c = await receiver(work, '');
    addTearDown(c.dispose);
    final base = await Directory('${work.path}/documents/GlobalSend')
        .create(recursive: true);
    final original = await File('${base.path}/收到的文件.txt')
        .writeAsString('original');
    final entry = incoming();
    c.dock = [entry];
    await c.receive(entry);
    expect(entry.status, 'received', reason: entry.error);
    expect(
      await File(entry.localPath).parent.resolveSymbolicLinks(),
      await base.resolveSymbolicLinks(),
    );
    expect(File(entry.localPath).uri.pathSegments.last, '收到的文件 (1).txt');
    expect(await File(entry.localPath).readAsBytes(), [1, 2, 3, 4]);
    expect(await original.readAsString(), 'original');
    expect((await base.list().toList()).every((file) => file is File), isTrue);
    expect(await ReceiveDestination.isOwned(entry.localPath), isTrue);
    expect(c.savedFiles.single.path, entry.localPath);
  });

  test('interrupted flat receive retains the final path and committed prefix across restart', () async {
    final work = await fixtureDirectory();
    final c = await receiver(work, '');
    addTearDown(c.dispose);
    c.api = InterruptedApi();
    final entry = incoming();
    c.dock = [entry];
    await c.receive(entry);
    final partial = entry.partialPath;
    expect(File(partial).uri.pathSegments.last, entry.title);
    expect(await File(partial).readAsBytes(), [1, 2]);
    final restored = DockEntry.fromJson(entry.toJson());
    final next = await receiver(work, '');
    addTearDown(next.dispose);
    next.dock = [restored];
    await next.receive(restored);
    expect(restored.status, 'received', reason: restored.error);
    expect(restored.localPath, partial);
    expect(restored.partialPath, isEmpty);
    expect(await File(partial).readAsBytes(), [1, 2, 3, 4]);
  });

  test('legacy indexed hierarchy migrates once, updates reuse aliases and retains external files', () async {
    final work = await fixtureDirectory(),
        docs = Directory('${work.path}/documents');
    final p = profile();
    final store = SavedFilesStore(
      indexFile: File('${work.path}/index.json'),
      documentsDirectory: docs,
    );
    final entry = await savedEntry(docs, p, 'old');
    entry.contentDigest = sha256.convert(List.filled(4, 65)).toString();
    final before = (await store.register(profile: p, entry: entry))!;
    final outside = await File('${docs.path}/GlobalSend/old.txt')
        .writeAsString('user');
    final unregistered = await File('${File(before.path).parent.path}/keep.txt')
        .writeAsString('keep');
    await store.flattenLegacyLayout();
    final moved = store.items.single;
    expect(
      await File(moved.path).parent.resolveSymbolicLinks(),
      await Directory('${docs.path}/GlobalSend').resolveSymbolicLinks(),
    );
    expect(File(moved.path).uri.pathSegments.last, 'old (1).txt');
    expect(moved.id, before.id);
    expect(moved.receivedAtMillis, before.receivedAtMillis);
    expect(await File(before.path).exists(), isFalse);
    expect(await outside.readAsString(), 'user');
    expect(await unregistered.readAsString(), 'keep');
    expect(store.relocatedLocations[before.path], moved.path);
    final reload = SavedFilesStore(
      indexFile: store.indexFile,
      documentsDirectory: docs,
    );
    await reload.load();
    await reload.flattenLegacyLayout();
    expect(reload.items.single.path, moved.path);
    final state = await Directory('${work.path}/state').create();
    await store.indexFile.copy('${state.path}/saved-files.json');
    final controller = SendController(documentsDirectory: () async => docs)
      ..root = state
      ..profile = p
      ..profiles = [p];
    addTearDown(controller.dispose);
    final oldSent = DockEntry(
      id: 'sent-reference',
      kind: 'file',
      title: entry.title,
      source: p.deviceId,
      transferId: 'sent',
      fileId: 'sent',
      size: 4,
      outgoing: true,
      localPath: before.path,
      status: 'ready',
    );
    controller.dock = [entry, oldSent];
    controller.sources['sent'] = before.path;
    await controller.refreshSavedFiles();
    expect(controller.dock, contains(oldSent));
    expect(oldSent.localPath, moved.path);
    expect(entry.localPath, moved.path);
    expect(controller.sources['sent'], moved.path);
    expect(
      (await reload.reusableFile(
        DockEntry(
          id: 'new',
          kind: 'file',
          title: 'other.txt',
          source: 'peer',
          transferId: 'next',
          fileId: 'new',
          size: 4,
          contentDigest: entry.contentDigest,
        ),
      ))!.path,
      moved.path,
    );
  });

  test('legacy partial migrates its prefix to the flat file before the network resumes', () async {
    final work = await fixtureDirectory(), c = await receiver(work, '');
    addTearDown(c.dispose);
    final item = incoming(), p = c.profile!;
    final old = File(
      '${work.path}/documents/GlobalSend/${p.key}/${p.deviceId}/${item.fileId}/${item.title}.part',
    );
    await old.parent.create(recursive: true);
    await old.writeAsBytes([1, 2]);
    item.partialPath = old.absolute.path;
    item.receivedBytes = 2;
    c.dock = [item];
    c.api = InterruptedApi();
    await c.receive(item);
    expect(
      await File(item.partialPath).parent.resolveSymbolicLinks(),
      await Directory('${work.path}/documents/GlobalSend')
          .resolveSymbolicLinks(),
    );
    expect(File(item.partialPath).uri.pathSegments.last, item.title);
    expect(await File(item.partialPath).readAsBytes(), [1, 2]);
    expect(await old.exists(), isFalse);
    c.api = LibraryApi();
    await c.receive(item);
    expect(item.status, 'received', reason: item.error);
  });

  test(
    'only known empty ID shells are removed, including missing indexed bytes',
    () async {
      final work = await fixtureDirectory(),
          docs = Directory('${work.path}/documents'),
          p = profile();
      final store = SavedFilesStore(
        indexFile: File('${work.path}/index.json'),
        documentsDirectory: docs,
      );
      final missing = await savedEntry(docs, p, 'missing');
      await store.register(profile: p, entry: missing);
      final missingShell = File(missing.localPath).parent;
      await File(missing.localPath).delete();
      final user = await Directory(
        '${docs.path}/GlobalSend/keep-empty-user-folder',
      ).create();
      await store.flattenLegacyLayout();
      expect(await missingShell.exists(), isFalse);
      expect(await user.exists(), isTrue);
      final historical = await savedEntry(docs, p, 'historic');
      final historicalShell = File(historical.localPath).parent;
      await File(historical.localPath).delete();
      expect(await store.register(profile: p, entry: historical), isNull);
      expect(await historicalShell.exists(), isFalse);
      expect(await user.exists(), isTrue);
    },
  );
  test('restart rolls back only its interrupted migration copy and leaves the complete old file available', () async {
    final work = await fixtureDirectory(),
        docs = Directory('${work.path}/documents'),
        p = profile();
    final store = SavedFilesStore(
      indexFile: File('${work.path}/index.json'),
      documentsDirectory: docs,
    );
    final old = await savedEntry(docs, p, 'recover');
    await store.register(profile: p, entry: old);
    final base = Directory('${docs.path}/GlobalSend');
    final target = await ReceiveDestination.create(
      destinationLocation: base.path,
      name: 'recover.txt',
    );
    await store.beginPartialRelocation(target.location);
    await File(target.ioPath).writeAsBytes([65, 65]);
    final user = await File('${base.path}/user.txt').writeAsString('user');
    await store.finishMigrationCleanup();
    expect(
      await File(target.location).exists(),
      isTrue,
      reason: 'live migration copy must not be reclaimed',
    );
    final restarted = SavedFilesStore(
      indexFile: store.indexFile,
      documentsDirectory: docs,
    );
    await restarted.load();
    expect(await File(target.location).exists(), isFalse);
    expect(await File(old.localPath).readAsBytes(), [65, 65, 65, 65]);
    expect(await user.readAsString(), 'user');
    await restarted.flattenLegacyLayout();
    expect(await File(restarted.items.single.path).readAsBytes(), [
      65,
      65,
      65,
      65,
    ]);
    expect(restarted.migrationCleanupPending, 0);
  });
}
