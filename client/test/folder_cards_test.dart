import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/content_groups.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files.dart';

DockEntry entry(
  String id,
  String path, {
  bool directory = false,
  String status = 'offered',
  int size = 0,
  String transfer = 'one',
}) => DockEntry(
  id: id,
  fileId: id,
  kind: 'file',
  source: 'sender',
  title: path.split('/').last,
  transferId: transfer,
  relativePath: path,
  entryKind: directory ? 'directory' : 'file',
  size: size,
  status: status,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('offered children share one receipt, even when the root is last in the manifest', () {
    final c = SendController()..profile = ServerProfile(baseUrl: 'https://fixture.invalid', instanceId: 'one', deviceId: 'receiver');
    c.profile!.autoReceive = false;
    addTearDown(c.dispose);
    c.updateTransfer({'transferId': 'offered', 'sourceDeviceId': 'sender', 'targetDeviceId': 'receiver',
      'files': [for (var i = 0; i < 1000; i++) {'fileId': 'f$i', 'name': '$i.txt', 'relativePath': '资料/$i.txt', 'size': 10, 'offset': 0, 'status': 'offered', 'transport': 'relay'},
        {'fileId': 'root', 'name': '资料', 'relativePath': '资料', 'entryKind': 'directory', 'size': 0, 'offset': 0, 'status': 'offered', 'transport': 'relay'}]});
    expect(c.dock.length, 1001);
    expect(c.pendingReceipts.length, 1);
    expect(c.pendingReceipts.values.single.id, 'root');
    expect(c.pendingReceipts.values.single.size, 10000);
    expect(c.expandFolderSelection('offered', ['root']).length, 1001);
  });
  test('large nested folders collapse regardless of root order, without changing engine records', () {
    final entries = [
      for (var i = 0; i < 2000; i++) entry('f$i', '资料/sub/$i.txt', size: 10),
      entry('sub', '资料/sub', directory: true),
      entry('root', '资料', directory: true),
      entry('empty', '空文件夹', directory: true),
      entry('loose', '', size: 10),
      entry('other', '资料', directory: true, transfer: 'two'),
    ];
    final cards = mergeContentCards(entries);
    expect(cards.length, 4);
    final folder = cards.whereType<FolderCardEntry>().singleWhere(
      (card) => card.id == 'root',
    );
    expect(folder.members.length, 2002);
    expect(folder.size, 20000);
    expect(folder.status, 'offered');
    expect(folder.progress, 0);
    expect(entries.length, 2005);
    expect(entries.every((item) => item.status == 'offered'), isTrue);
  });
  test('creating the directory does not complete its card; bytes and failures aggregate', () {
    final root = entry('root', '资料', directory: true, status: 'received');
    final file = entry('file', '资料/a.txt', size: 100, status: 'downloading')
      ..progress = .4;
    final cards = [root, file];
    var folder = collapseFolderCards(cards).single;
    expect(folder.status, 'downloading');
    expect(folder.progress, .4);
    file.status = 'failed';
    file.error = 'no space';
    folder = collapseFolderCards(cards).single;
    expect(folder.status, 'failed');
    expect(folder.error, 'no space');
    file.status = 'received';
    file.receivedAtMillis = 123;
    folder = collapseFolderCards(cards).single;
    expect(folder.status, 'received');
    expect(folder.progress, 1);
    expect(folder.receivedAtMillis, 123);
    expect(root.size, 0);
  });
  test('folder selection, pause and deletion include descendants, not unrelated siblings', () async {
    final work = await Directory('build/test-tmp').create(recursive: true);
    final state = await work.createTemp('folder-cards-');
    final c = SendController()..root = state;
    addTearDown(c.dispose);
    final root = entry('root', '资料', directory: true, status: 'received');
    final child = entry('child', '资料/a.txt', size: 100, status: 'accepted');
    final loose = entry('loose', '', status: 'received');
    c.dock.addAll([root, child, loose]);
    expect(c.expandFolderSelection('one', ['root']).toSet(), {'root', 'child'});
    final card = mergeContentCards(c.historyDock)
        .whereType<FolderCardEntry>()
        .single;
    expect(c.canControlTransfer(card), isTrue);
    await c.pause(card);
    expect(child.locallyPaused, isTrue);
    expect(root.status, 'received');
    await c.removeHistoryEntries([root]);
    expect(c.dock, [loose]);
    expect(c.pendingReceipts, isEmpty);
  });
  test('library hides nested records while preserving path ownership and full index', () {
    final records = [
      for (final item in [
        entry('root', '资料', directory: true),
        entry('f', '资料/a.txt', size: 20),
      ])
        SavedFile(
          id: item.id,
          profileKey: 'p',
          deviceId: 'd',
          groupId: 'g',
          transferId: item.transferId,
          fileId: item.fileId,
          path: '/inbox/${item.relativePath}',
          name: item.title,
          size: item.size,
          receivedAtMillis: 1,
          directory: item.isDirectory,
          relativePath: item.relativePath,
        ),
    ];
    final visible = folderLibraryCards(records);
    expect(visible.single.id, 'root');
    expect(visible.single.size, 20);
    expect(visible.single.managedLocation, isFalse);
    expect(records.length, 2);
    expect(records.first.size, 0);
  });
}
