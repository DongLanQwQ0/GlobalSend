import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/saved_files.dart';
import 'package:globalsend/saved_files_screen.dart';
import 'package:globalsend/system_bridge.dart';

import 'saved_files_test.dart'
    show fixtureDirectory, savedEntry, profile, LibraryApi;

class LocalLibraryController extends SendController {
  LocalLibraryController(Directory documents)
    : super(documentsDirectory: () async => documents);
  @override
  Future<void> init() async {}
}

class ReadyLibraryController extends LocalLibraryController {
  ReadyLibraryController(super.documents);
  bool ready = false;
  @override
  Future<void> refreshSavedFiles({bool cleanup = false}) async {
    if (!ready) await super.refreshSavedFiles(cleanup: cleanup);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('local library survives center switches and logout without adding old items to the active dock', () async {
    final folder = await fixtureDirectory();
    final documents = Directory('${folder.path}/documents');
    final p = profile();
    final other = ServerProfile(
      baseUrl: 'https://other.invalid',
      instanceId: 'other',
      deviceId: 'receiver',
      groupId: 'two',
    );
    final previousFile = await savedEntry(documents, p, 'previous');
    final currentFile = await savedEntry(documents, other, 'current');
    final root = Directory('${folder.path}/state');
    final store = SavedFilesStore(
      indexFile: File('${root.path}/saved-files.json'),
      documentsDirectory: documents,
    );
    await store.register(profile: p, entry: previousFile);
    await store.register(profile: other, entry: currentFile);
    final c = LocalLibraryController(documents)
      ..root = root
      ..profile = other
      ..profiles = [p, other]
      ..dock = [currentFile];
    addTearDown(c.dispose);
    await c.refreshSavedFiles();
    expect(c.savedFiles.map((file) => file.fileId).toSet(), {
      'previous',
      'current',
    });
    expect(c.dock.single.fileId, 'current');
    final oldId = c.savedFiles
        .firstWhere((file) => file.fileId == 'previous')
        .id;
    c.profile = null;
    c.dock.clear();
    await c.renameSavedFile(oldId, '保留的旧文件.txt');
    expect(
      c.savedFiles.firstWhere((file) => file.id == oldId).name,
      '保留的旧文件.txt',
    );
    await expectLater(
      c.forwardSavedFiles('offline', [oldId]),
      throwsStateError,
    );
    final api = LibraryApi();
    c.api = api;
    c.profile = other;
    c.connected = true;
    c.devices = [
      {'deviceId': 'peer', 'name': '当前分组设备', 'online': true},
    ];
    c.info = {
      'limits': {'maxFileSize': 1024},
    };
    await c.forwardSavedFiles('peer', [oldId]);
    expect(api.offered!['targetDeviceId'], 'peer');
    expect((api.offered!['files'] as List).single['name'], '保留的旧文件.txt');
    expect(c.dock.every((entry) => entry.outgoing), isTrue);
    await c.deleteSavedFiles([oldId]);
    expect(await File(previousFile.localPath).exists(), isFalse);
    expect(await File(currentFile.localPath).exists(), isTrue);
  });

  testWidgets('saved local files remain reachable from the signed-out screen', (
    tester,
  ) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemBridge.channel,
        (call) async => call.method == 'windowVisible' ? true : null);
    addTearDown(() => messenger.setMockMethodCallHandler(SystemBridge.channel, null));
    final c = (await tester.runAsync(() async {
      final folder = await fixtureDirectory();
      final documents = Directory('${folder.path}/documents');
      final p = profile();
      final entry = await savedEntry(documents, p, 'offline');
      final root = Directory('${folder.path}/state');
      final store = SavedFilesStore(
        indexFile: File('${root.path}/saved-files.json'),
        documentsDirectory: documents,
      );
      await store.register(profile: p, entry: entry);
      final c = ReadyLibraryController(documents)..root = root;
      await c.refreshSavedFiles();
      c.ready = true;
      return c;
    }))!;
    expect(c.profile, isNull);
    await tester.pumpWidget(GlobalSendApp(controller: c));
    await tester.pumpAndSettle();
    expect(find.byTooltip('文件库'), findsOneWidget);
    await tester.tap(find.byTooltip('文件库'));
    await tester.pumpAndSettle();
    expect(find.byType(SavedFilesScreen), findsOneWidget);
    expect(find.text('offline.txt'), findsOneWidget);
    // pumpAndSettle drains frames, not the real file read used by the preview.
    // Wait for its actual result before deleting the Windows fixture.
    for (var frame = 0; frame < 50 && find.text('AAAA').evaluate().isEmpty; frame++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('AAAA'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => c.persistenceIdle);
  });
}
