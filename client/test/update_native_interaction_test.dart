import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_updates.dart';
import 'package:globalsend/github_updates.dart';

import 'auto_update_engine_test.dart'
    show RealUpdateBinding, DownloadFixture, stateFile, build, feed, settle;

void main() {
  RealUpdateBinding();
  test('native drag blocks auto install; end starts only one helper and blocks exit approval during the next operation', () async {
    var calls = 0;
    final updates = AppUpdates(
      build: build(UpdatePlatform.windows),
      feed: feed(UpdatePlatform.windows),
      downloader: DownloadFixture(),
      cancelInstall: ({required automaticOnly}) async {},
      install: (_, __, {required explicit}) async {
        calls++;
        return {'state': 'started'};
      },
    );
    addTearDown(updates.dispose);
    updates.nativeInteractionChanged(true);
    updates.setForeground(false);
    await updates.initialize(await stateFile());
    await updates.check();
    await updates.downloadAndInstall();
    expect(calls, 0);
    updates.nativeInteractionChanged(false);
    await settle();
    expect(calls, 1);
    updates.nativeInteractionChanged(true);
    expect(await updates.prepareExit(), isFalse);
    updates.nativeInteractionChanged(false);
    await settle();
    expect(calls, 1);
    expect(await updates.prepareExit(), isTrue);
  });
  test('manual update survives a native busy reply and an end event racing its reply', () async {
    var calls = 0;
    final first = Completer<Map<String, dynamic>>();
    final updates = AppUpdates(
      build: build(UpdatePlatform.windows),
      feed: feed(UpdatePlatform.windows),
      automaticDownload: false,
      downloader: DownloadFixture(),
      cancelInstall: ({required automaticOnly}) async {},
      install: (_, __, {required explicit}) async {
        expect(explicit, isTrue);
        calls++;
        return calls == 1 ? first.future : {'state': 'started'};
      },
    );
    addTearDown(updates.dispose);
    await updates.initialize(await stateFile());
    await updates.check();
    final work = updates.downloadAndInstall(explicit: true);
    await settle();
    updates.nativeInteractionChanged(true);
    updates.nativeInteractionChanged(false);
    first.complete({'state': 'interaction-pending'});
    await work;
    await settle();
    expect(calls, 2);
    updates.nativeInteractionChanged(true);
    updates.nativeInteractionChanged(false);
    await settle();
    expect(calls, 2);
  });
  test('turning auto off or cancelling releases the waiting helper and does not restart it on interaction end', () async {
    var calls = 0;
    final cancellations = <bool>[];
    final updates = AppUpdates(
      build: build(UpdatePlatform.windows),
      feed: feed(UpdatePlatform.windows),
      downloader: DownloadFixture(),
      cancelInstall: ({required automaticOnly}) async {
        cancellations.add(automaticOnly);
      },
      install: (_, __, {required explicit}) async {
        calls++;
        return {'state': 'started'};
      },
    );
    addTearDown(updates.dispose);
    updates.setForeground(false);
    await updates.initialize(await stateFile());
    await updates.check();
    await updates.downloadAndInstall();
    expect(calls, 1);
    updates.nativeInteractionChanged(true);
    await updates.setAutoDownload(false);
    updates.nativeInteractionChanged(false);
    await settle();
    expect(calls, 1);
    expect(await updates.prepareExit(), isFalse);
    await updates.setAutoDownload(true);
    await settle();
    expect(calls, 2);
    await updates.cancelUpdate();
    updates.nativeInteractionChanged(true);
    updates.nativeInteractionChanged(false);
    await settle();
    expect(calls, 2);
    expect(cancellations, [true, false]);
    expect(await updates.prepareExit(), isFalse);
    await updates.downloadAndInstall(explicit: true);
    expect(calls, 3);
  });
  test('manual update remains explicit when automatic updates are switched off during persistence', () async {
    final saving = Completer<void>();
    var calls = 0;
    final updates = AppUpdates(
      build: build(UpdatePlatform.windows),
      feed: feed(UpdatePlatform.windows),
      downloader: DownloadFixture(),
      cancelInstall: ({required automaticOnly}) async {},
      install: (_, __, {required explicit}) async {
        expect(explicit, isTrue);
        calls++;
        return {'state': 'started'};
      },
    );
    addTearDown(updates.dispose);
    await updates.initialize(await stateFile());
    await updates.check();
    updates.beforeInstall = () => saving.future;
    final work = updates.downloadAndInstall(explicit: true);
    await settle();
    await updates.setAutoDownload(false);
    saving.complete();
    await work;
    expect(calls, 1);
  });
  test('cancellation survives restart and receipt from a different attempt cannot override the current one', () async {
    final file = await stateFile();
    final current = File('${file.parent.path}/updates/current-attempt.json');
    final stale = File(
      '${file.parent.path}/updates/windows-update-result.json',
    );
    var calls = 0;
    AppUpdates create() => AppUpdates(
      build: build(UpdatePlatform.windows),
      feed: feed(UpdatePlatform.windows),
      downloader: DownloadFixture(),
      cancelInstall: ({required automaticOnly}) async {},
      install: (_, __, {required explicit}) async {
        calls++;
        return {'state': 'started', 'resultPath': current.path};
      },
    );
    final first = create();
    first.setForeground(false);
    await first.initialize(file);
    await first.check();
    await first.downloadAndInstall();
    await current.writeAsString(
      jsonEncode({
        'state': 'failed',
        'version': '1.0.79',
        'build': 0,
        'message': 'this attempt failed',
      }),
    );
    await stale.writeAsString(
      jsonEncode({'state': 'ready', 'version': '1.0.79', 'build': 0}),
    );
    await first.cancelUpdate();
    await first.setAutoCheck(false);
    first.dispose();
    final second = create();
    addTearDown(second.dispose);
    second.setForeground(false);
    await second.initialize(file);
    expect(second.error, 'this attempt failed');
    await second.check(manual: true);
    second.nativeInteractionChanged(true);
    second.nativeInteractionChanged(false);
    await settle();
    expect(calls, 1);
    expect(await second.prepareExit(), isFalse);
    await second.downloadAndInstall(explicit: true);
    expect(calls, 2);
  });
}
