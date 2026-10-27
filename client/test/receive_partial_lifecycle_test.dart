import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_destination.dart';

import 'saved_files_destination_test.dart' show incoming, receiver, UriFixture;
import 'saved_files_test.dart' show LibraryApi, fixtureDirectory;

class PartialApi extends LibraryApi {
  PartialApi({this.interrupt = false});
  final bool interrupt;
  String downloadedTo = '';
  int resumedBytes = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path.endsWith('/cancel')) return {};
    return super.call(method, path, body, authenticated);
  }

  @override
  Future<void> download(
    String path,
    File destination,
    void Function(int) progress, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    downloadedTo = destination.path;
    resumedBytes = await destination.exists() ? await destination.length() : 0;
    await destination.writeAsBytes(
      interrupt ? content.take(2).toList() : content,
    );
    progress(interrupt ? 2 : content.length);
    if (interrupt) throw const SocketException('fixture connection lost');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('changing destination after interrupted default receive resumes its original partial', () async {
    final folder = await fixtureDirectory();
    final first = await receiver(folder, '');
    addTearDown(() {
      if (!first.disposed) first.dispose();
    });
    first.api?.close();
    first.api = PartialApi(interrupt: true);
    final item = incoming();
    first.dock = [item];
    await first.receive(item);
    expect(item.status, 'failed');
    final original = item.partialPath;
    final state = jsonDecode(
      await File('${first.root!.path}/${first.profile!.key}.json')
          .readAsString(),
    );
    first.dispose();
    final selected = await Directory('${folder.path}/new-destination').create();
    final next = await receiver(folder, selected.absolute.path);
    addTearDown(next.dispose);
    final api = PartialApi();
    next.api?.close();
    next.api = api;
    final resumed = DockEntry.fromJson(
      Map<String, dynamic>.from(state['dock'][0]),
    );
    next.dock = [resumed];
    await next.receive(resumed);
    expect(resumed.status, 'received', reason: resumed.error);
    expect(api.downloadedTo, original);
    expect(api.resumedBytes, 2);
    expect(await File(original).exists(), isFalse);
    expect(await File(resumed.localPath).readAsBytes(), [1, 2, 3, 4]);
    expect(await selected.list().length, 0);
    expect(next.hasCustomReceiveDirectory, isTrue);
  });

  for (final destination in ['default', 'custom', 'SAF']) {
    test(
      'canceling failed $destination receive deletes its registered partial',
      () async {
        final folder = await fixtureDirectory();
        final selected = await Directory('${folder.path}/selected').create();
        final uri = UriFixture(selected);
        if (destination == 'SAF') {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(ReceiveDestination.channel, uri.call);
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(ReceiveDestination.channel, null),
          );
        }
        final c = await receiver(folder, switch (destination) {
          'custom' => selected.absolute.path,
          'SAF' => 'content://fixture/tree/selected',
          _ => '',
        });
        addTearDown(c.dispose);
        c.api?.close();
        c.api = PartialApi(interrupt: true);
        final item = incoming();
        c.dock = [item];
        await c.receive(item);
        expect(item.status, 'failed');
        final partial = item.partialPath;
        final backing = destination == 'SAF'
            ? uri.files[partial]!
            : File(partial);
        expect(await backing.length(), 2);
        await c.cancel(item);
        expect(await backing.exists(), isFalse);
        expect(item.partialPath, isEmpty);
        expect(item.receivedBytes, 0);
        expect(uri.handles, isEmpty);
      },
    );
  }
}
