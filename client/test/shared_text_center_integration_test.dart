import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

Future<void> waitFor(bool Function() condition) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 8)) {
      throw StateError('Shared editor did not converge');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'native shared editor consumes real center GET/PUT/WS in both directions',
    () async {
      final dir = await Directory('build/test-tmp').create(recursive: true);
      final work = await dir.createTemp('shared-editor-center-');
      final process = await Process.start('node', [
        'tool/start_test_center.mjs',
        work.absolute.path,
      ]);
      final log = File('${work.path}/center-stderr.log').openWrite();
      final stderr = process.stderr.listen(log.add);
      final controllers = <SendController>[];
      try {
        final line = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 15));
        final base = jsonDecode(line)['url'] as String;
        for (final name in ['Windows shared editor', 'Android shared editor']) {
          final api = CenterApi(base);
          final info = await api.call('GET', '/info', null, false);
          final session = await api.call('POST', '/devices/enroll', {
            'name': name,
            'platform': 'other',
            'groupKey': 'shared-controller-password',
          }, false);
          api.token = session['deviceToken'];
          final controller =
              SendController(
                  stateDirectory: () async =>
                      Directory('${work.path}/$name-state'),
                  documentsDirectory: () async =>
                      Directory('${work.path}/$name-files'),
                )
                ..api = api
                ..info = info
                ..profile = ServerProfile(
                  baseUrl: base,
                  instanceId: info['instanceId'],
                  deviceId: session['device']['deviceId'],
                  groupId: session['groupId'],
                );
          controllers.add(controller);
          await controller.openSocket(controller.generation);
          await controller.sharedDocument.refresh();
          expect(controller.sharedTextSupported, isTrue);
        }
        final a = controllers[0], b = controllers[1];
        a.setSharedTextDraft('电脑编辑\n保留换行');
        await a.sharedDocument.save();
        await waitFor(() => b.sharedText == '电脑编辑\n保留换行');
        expect(a.sharedTextRevision, 1);
        b.setSharedTextDraft('手机回复');
        await b.sharedDocument.save();
        await waitFor(() => a.sharedText == '手机回复');
        expect(a.sharedTextRevision, 2);

        // A remote edit arriving during local typing must not erase the draft.
        a.setSharedTextDraft('电脑尚未确认的草稿');
        b.setSharedTextDraft('手机的并发更新');
        await b.sharedDocument.save();
        await waitFor(() => a.sharedTextConflict);
        expect(a.sharedText, '电脑尚未确认的草稿');
        expect(a.sharedTextRemote, '手机的并发更新');
        await a.retrySharedText();
        await waitFor(() => b.sharedText == '电脑尚未确认的草稿');
        expect(a.sharedTextConflict, isFalse);

        b.setSharedTextDraft('');
        await b.sharedDocument.save();
        await waitFor(() => a.sharedText.isEmpty);
        expect(a.dock, isEmpty);
        expect(b.dock, isEmpty);
        expect((await a.api!.call('GET', '/transfers'))['transfers'], isEmpty);
        stdout.writeln(
          'Shared text real-center evidence: ${work.absolute.path}',
        );
      } finally {
        for (final controller in controllers) {
          controller.dispose();
        }
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 5));
        await stderr.cancel();
        await log.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 35)),
  );
}
