import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

class ImageNameTransportBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  ImageNameTransportBinding();
  test('PNG .pic is staged and offered as .png; folder members and original stay unchanged', () async {
    final work = await Directory('../artifacts/tmp/ipad102')
        .create(recursive: true);
    final root = await work.createTemp('names-');
    final process = await Process.start('node', [
      '--import',
      '../server/node_modules/tsx/dist/loader.mjs',
      'tool/start_test_center.mjs',
      root.absolute.path,
    ]);
    final log = File('${root.path}/center.log').openWrite();
    final errors = process.stderr.listen(log.add);
    final base =
        jsonDecode(
              await process.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .first
                  .timeout(const Duration(seconds: 10)),
            )['url']
            as String;
    final api = CenterApi(base), recipient = CenterApi(base);
    SendController? controller;
    try {
      final info = await api.call('GET', '/info', null, false);
      final enrollment = await api.call('POST', '/devices/enroll', {
        'name': 'iPad image provider',
        'platform': 'other',
        'groupKey': 'image-name102',
      }, false);
      final target = await recipient.call('POST', '/devices/enroll', {
        'name': 'Image recipient',
        'platform': 'android',
        'groupKey': 'image-name102',
      }, false);
      api.token = enrollment['deviceToken'];
      recipient.token = target['deviceToken'];
      await recipient.call('POST', '/devices/me/capabilities', {
        'folderTransfer': true,
      });
      final state = await Directory('${root.path}/state').create();
      controller = SendController(stateDirectory: () async => state)
        ..root = state
        ..api = api
        ..info = info
        ..profile = ServerProfile(
          baseUrl: base,
          instanceId: info['instanceId'],
          deviceId: enrollment['device']['deviceId'],
        );
      final sample = Platform.environment['GLOBALSEND_IMAGE_SAMPLE'];
      final bytes = sample == null
          ? base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGNUCOhhYGBgYgADAAuOAQCntjSiAAAAAElFTkSuQmCC',
            )
          : await File(sample).readAsBytes();
      final image = File('${root.path}/977.pic');
      await image.writeAsBytes(bytes);
      await controller.stageInputs([image.path], []);
      expect(controller.stagedFileNames[image.path], '977.png');
      await controller.offer(target['device']['deviceId'], [image.path]);
      final first =
          (await recipient.call('GET', '/transfers'))['transfers'] as List;
      final file = (first.single['files'] as List).single;
      expect(file['name'], '977.png');
      expect(file['mimeType'], 'image/png');
      expect(file['size'], bytes.length);
      expect(await image.readAsBytes(), bytes);
      final tree = await Directory('${root.path}/Album').create();
      await File('${tree.path}/977.pic').writeAsBytes(bytes);
      await controller.offer(target['device']['deviceId'], [tree.path]);
      final transfers =
          (await recipient.call('GET', '/transfers'))['transfers'] as List;
      final members = transfers
          .expand((t) => t['files'] as List)
          .where((f) => f['relativePath'] != null);
      expect(
        members.any(
          (f) => f['relativePath'] == 'Album/977.pic' && f['name'] == '977.pic',
        ),
        isTrue,
      );
      await File('${root.path}/result.json').writeAsString(
        jsonEncode({
          'sample': sample ?? 'fixture',
          'bytes': bytes.length,
          'offeredName': file['name'],
          'mimeType': file['mimeType'],
          'sourcePreserved': true,
          'folderTreePreserved': true,
        }),
      );
    } finally {
      controller?.dispose();
      if (controller != null) await controller.persistenceIdle;
      api.close();
      recipient.close();
      process.kill();
      await process.exitCode;
      await errors.cancel();
      await log.close();
    }
  });
}
