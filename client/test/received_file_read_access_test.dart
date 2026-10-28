import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/received_file_access.dart';
import 'package:globalsend/saved_image_preview.dart';
import 'package:globalsend/text_viewer.dart';
import 'package:globalsend/saved_files.dart';
import 'package:globalsend/models.dart';
import 'package:crypto/crypto.dart';

import 'saved_files_test.dart' show fixtureDirectory;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const uri =
      'content://external-documents/document/primary%3ADownload%2Fphoto.png';
  final calls = <String>[];
  var bytes = Uint8List(0);
  var unavailable = false;
  setUp(() {
    calls.clear();
    unavailable = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReceiveDestination.channel, (call) async {
          calls.add(call.method);
          final args = call.arguments as Map;
          switch (call.method) {
            case 'isOwned':
              return true;
            case 'open':
              return {
                'location': args['location'],
                'ioPath': '',
                'handle': 'granted-descriptor',
                'name': 'external.png',
                'size': bytes.length,
                'descriptorOnly': true,
              };
            case 'readDescriptor':
              expect(args['handle'], 'granted-descriptor');
              final start = args['offset'] as int;
              final end = (start + (args['length'] as int)).clamp(
                0,
                bytes.length,
              );
              return Uint8List.sublistView(
                bytes,
                start.clamp(0, bytes.length),
                end,
              );
            case 'close':
              return null;
            case 'stat':
              if (args['location'] == 'content://deleted')
                return {
                  'location': args['location'],
                  'name': 'deleted.bin',
                  'size': 0,
                  'exists': false,
                };
              if (unavailable)
                throw PlatformException(
                  code: 'RECEIVE_DIRECTORY',
                  message: '目录读取授权暂不可用',
                );
              return {
                'location': uri,
                'name': 'external.png',
                'size': bytes.length,
                'exists': true,
              };
          }
          throw StateError(
            'Unexpected filesystem/copy operation: ${call.method}',
          );
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ReceiveDestination.channel, null),
  );

  test('unavailable external files keep their references while deleted files are pruned and reuse falls back', () async {
    final root = await fixtureDirectory();
    bytes = Uint8List.fromList([1, 2, 3]);
    final digest = sha256.convert(bytes).toString();
    SavedFile saved(String id, String location) => SavedFile(
      id: id,
      profileKey: 'profile',
      deviceId: 'device',
      groupId: 'group',
      transferId: 'transfer',
      fileId: id,
      path: location,
      name: '$id.bin',
      size: bytes.length,
      receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
      managedLocation: true,
      contentDigest: digest,
    );
    final index = File('${root.path}/index.json');
    await index.writeAsString(
      jsonEncode({
        'files': [
          saved('kept', uri).toJson(),
          saved('gone', 'content://deleted').toJson(),
        ],
      }),
    );
    final store = SavedFilesStore(indexFile: index, documentsDirectory: root);
    await store.load();
    unavailable = true;
    final removed = await store.prune(DateTime.now(), removeExpired: false);
    expect(removed.map((file) => file.id), ['gone']);
    expect(store.items.map((file) => file.id), ['kept']);
    final offer = DockEntry(
      id: 'again',
      kind: 'file',
      title: 'again.bin',
      source: 'sender',
      size: bytes.length,
      contentDigest: digest,
    );
    expect(await store.reusableFile(offer), isNull);
    unavailable = false;
    expect((await store.reusableFile(offer))!.path, uri);
    expect(store.items.map((file) => file.id), ['kept']);
  });

  test('readable SAF descriptor streams and seeks without a /proc reopen or copied file', () async {
    bytes = Uint8List.fromList(List.generate(150000, (i) => i % 251));
    final access = await ReceivedFileAccess.open(uri);
    expect(access.descriptorOnly, true);
    expect(access.file.path, uri);
    expect(await access.file.length(), bytes.length);
    final all = await access.file.readAsBytes();
    expect(all, bytes);
    final reader = await access.file.open();
    await reader.setPosition(777);
    expect(await reader.read(37), bytes.sublist(777, 814));
    await reader.close();
    expect(calls.where((call) => call == 'close'), isEmpty);
    await access.close();
    expect(calls.where((call) => call == 'close'), hasLength(1));
  });

  test('external text preview reads from the granted descriptor rather than File(contentURI)', () async {
    bytes = Uint8List.fromList(utf8.encode('外部目录文本\nHello'));
    final preview = await readTextFilePreview(uri, title: 'notes.txt');
    expect(preview!.text, '外部目录文本\nHello');
    expect(calls.where((call) => call == 'close'), hasLength(1));
  });

  testWidgets(
    'image backed only by a granted descriptor paints a real thumbnail',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(const Color(0xff20785d), BlendMode.src);
        final image = await recorder.endRecording().toImage(24, 16);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        bytes = data!.buffer.asUint8List();
        image.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SavedFilePicture(
            location: uri,
            cacheWidth: 160,
            fit: BoxFit.cover,
            errorBuilder: (_, error, stack) => Text('decode error: $error'),
          ),
        ),
      );
      for (
        var i = 0;
        i < 40 &&
            (find.byType(RawImage).evaluate().isEmpty ||
                tester.widget<RawImage>(find.byType(RawImage)).image == null);
        i++
      ) {
        await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      expect(find.textContaining('decode error:'), findsNothing);
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      expect(image, isNotNull);
      expect(image!.width, 24);
      expect(image.height, 16);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.where((call) => call == 'close'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
