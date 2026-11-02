import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/copied_file_reference_card.dart';
import 'package:globalsend/copied_files.dart';
import 'package:globalsend/copied_files_view.dart';

final offers = <Map<String, dynamic>>[
  {
    'sourceDeviceId': 'source',
    'sourceName': 'Source',
    'offerId': 'batch',
    'items': [
      {'id': 'first', 'name': 'first.bin', 'kind': 'file'},
      {'id': 'folder', 'name': 'folder', 'kind': 'directory'},
      {'id': 'pending', 'name': 'pending.bin', 'kind': 'file'},
    ],
  },
];
Map<String, dynamic> ref(String item) => {
  'id': 'copied:source:batch:$item',
  'sourceDeviceId': 'source',
  'offerId': 'batch',
  'itemId': item,
};
CopiedFilesClient create([void Function()? changed]) => CopiedFilesClient(
  newId: () => 'unused',
  sendFiles: (_, _) async {},
  changed: changed ?? () {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'receipt order persists, local reuse and stale replay never re-promote',
    () async {
      final root = await Directory('../artifacts/tmp/copied-order114')
          .create(recursive: true);
      final work = await root.createTemp('native-model-');
      addTearDown(() => work.delete(recursive: true));
      final file = await File('${work.path}/first.bin').writeAsString('first');
      final folder = await Directory('${work.path}/folder').create();
      await Directory('${folder.path}/empty').create();
      final settings = File('${work.path}/copied-files.json'),
          client = create();
      await client.load(settings);
      client.offers = offers;
      await client.rememberReceived(
        ref('folder'),
        folder.path,
        transferId: 'folder-transfer',
        fileId: 'root',
        completedAtMillis: 200,
      );
      await client.rememberReceived(
        ref('first'),
        file.path,
        transferId: 'first-transfer',
        fileId: 'file',
        completedAtMillis: 100,
      );
      expect(client.references.map((r) => r['itemId']), [
        'folder',
        'first',
        'pending',
      ]);
      await client.rememberReceived(
        ref('first'),
        file.path,
        transferId: 'first-transfer',
        fileId: 'file',
        completedAtMillis: 900,
      );
      expect(await client.resolve(ref('first')), [file.path]);
      await client.pull(ref('first'), ['first']);
      final restored = create();
      await restored.load(settings);
      restored.offers = offers;
      expect(restored.references.map((r) => r['itemId']), [
        'folder',
        'first',
        'pending',
      ]);
      expect(
        restored.localReference(
          'copied:source:batch:first',
        )?['completedAtMillis'],
        '100',
      );
      await restored.rememberReceived(
        ref('first'),
        file.path,
        transferId: 'new-transfer',
        fileId: 'file',
        completedAtMillis: 300,
      );
      await restored.rememberReceived(
        ref('first'),
        file.path,
        transferId: 'first-transfer',
        fileId: 'file',
        completedAtMillis: 100,
      );
      expect(restored.references.map((r) => r['itemId']), [
        'first',
        'folder',
        'pending',
      ]);
      expect(restored.references, hasLength(3));
      expect(await Directory('${folder.path}/empty').exists(), isTrue);
    },
  );
  testWidgets(
    'actual card list promotes only ready copies and retains local identity',
    (tester) async {
      final root = Directory('../artifacts/tmp/copied-order114')
        ..createSync(recursive: true);
      final work = root.createTempSync('native-view-');
      addTearDown(() => work.deleteSync(recursive: true));
      final folder = Directory('${work.path}/folder')..createSync();
      void Function() rebuild = () {};
      final client = create(() => rebuild());
      client.offers = offers;
      tester.view.physicalSize = const Size(1000, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) {
                rebuild = () => setState(() {});
                return CopiedFileOffers(
                  client: client,
                  onPull: (_, _) async {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      List<String> cards() => tester
          .widgetList<CopiedFileReferenceCard>(
            find.byType(CopiedFileReferenceCard),
          )
          .map((card) => card.reference['itemId'] as String)
          .toList();
      expect(cards(), ['first', 'folder', 'pending']);
      await client.rememberReceived(
        ref('folder'),
        folder.path,
        transferId: 'folder-transfer',
        fileId: 'root',
        completedAtMillis: 200,
      );
      await tester.pumpAndSettle();
      expect(cards(), ['folder', 'first', 'pending']);
      final card = tester
          .widgetList<CopiedFileReferenceCard>(
            find.byType(CopiedFileReferenceCard),
          )
          .first;
      expect(card.reference['localPath'], folder.path);
      expect(card.reference['kind'], 'directory');
      await client.rememberReceived(
        ref('folder'),
        folder.path,
        transferId: 'folder-transfer',
        fileId: 'root',
        completedAtMillis: 900,
      );
      client.pulls['progress'] = {
        'sourceDeviceId': 'source',
        'offerId': 'batch',
        'itemIds': ['pending'],
        'state': 'sending',
      };
      rebuild();
      // A live transfer intentionally animates forever; wait for its state
      // frame, not for the progress indicator to stop animating.
      await tester.pump();
      expect(cards(), ['folder', 'first', 'pending']);
      expect(
        tester.getTopLeft(find.text('folder')).dx,
        lessThan(tester.getTopLeft(find.text('first.bin')).dx),
      );
      rebuild = () {};
      await tester.pumpWidget(const SizedBox());
    },
  );
}
