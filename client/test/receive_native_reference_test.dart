import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/saved_files.dart';

import 'saved_files_test.dart' show fixtureDirectory, profile, savedEntry;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    ReceiveDestination.originRecorderForTesting = null;
    ReceiveDestination.referenceRelocatorForTesting = null;
  });
  test('final receive handle is not exposed until its app origin is recorded, before the first byte', () async {
    final work = await fixtureDirectory();
    final entered = Completer<void>(), ack = Completer<void>();
    ReceiveDestination.originRecorderForTesting = (location) async {
      expect(await File(location).length(), 0);
      entered.complete();
      await ack.future;
    };
    var exposed = false;
    final creating =
        ReceiveDestination.create(
          destinationLocation: work.path,
          name: 'image.jpg',
        ).then((handle) {
          exposed = true;
          return handle;
        });
    await entered.future;
    expect(exposed, isFalse);
    ack.complete();
    final handle = await creating;
    await File(handle.ioPath).writeAsBytes([1, 2, 3]);
    expect(await File(handle.location).readAsBytes(), [1, 2, 3]);
    var resumedOrigin = false;
    ReceiveDestination.originRecorderForTesting = (location) async {
      expect(location, handle.location);
      expect(await File(location).length(), 3);
      resumedOrigin = true;
    };
    final resumed = await ReceiveDestination.openHandle(
      handle.location,
      writable: true,
    );
    expect(resumedOrigin, isTrue);
    await ReceiveDestination.closeHandle(resumed.handle);
  });
  test('old receive bytes are removed only after the native relocation ACK and committed index', () async {
    final work = await fixtureDirectory(),
        docs = Directory('${work.path}/documents'),
        p = profile();
    final store = SavedFilesStore(
      indexFile: File('${work.path}/saved-files.json'),
      documentsDirectory: docs,
    );
    final entry = await savedEntry(docs, p, 'source');
    final old = (await store.register(profile: p, entry: entry))!.path;
    final entered = Completer<void>(), ack = Completer<void>();
    ReceiveDestination.referenceRelocatorForTesting = (locations) async {
      expect(await File(old).exists(), isTrue);
      final index = jsonDecode(await store.indexFile.readAsString());
      expect(index['relocatedLocations'][old], locations[old]);
      expect(await File(locations[old]!).length(), 4);
      entered.complete();
      await ack.future;
    };
    var finished = false;
    final moving = store.flattenLegacyLayout().then((_) {
      finished = true;
    });
    await entered.future;
    expect(finished, isFalse);
    expect(await File(old).exists(), isTrue);
    ack.complete();
    await moving;
    expect(await File(old).exists(), isFalse);
    expect(await File(store.items.single.path).length(), 4);
  });
}
