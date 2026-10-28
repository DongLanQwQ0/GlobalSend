import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_updates.dart';
import 'package:globalsend/github_updates.dart';

import 'github_updates_test.dart' show asset, release;

class Feed implements UpdateFeed {
  List<Map<String, dynamic>> rows = [];
  int reads = 0;
  bool closed = false, fail = false;
  Completer<void>? gate;
  @override
  Future<List<Map<String, dynamic>>> releases() async {
    reads++;
    await gate?.future;
    if (fail) throw const SocketException('fixture offline');
    return rows;
  }

  @override
  Future<Map<String, dynamic>> manifest(String url) async => {};
  @override
  void close() {
    closed = true;
  }
}

AppUpdates service(
  Feed feed, {
  UpdatePlatform platform = UpdatePlatform.windows,
  UpdateNotifier? notify,
  DateTime Function()? now,
}) => AppUpdates(
  build: AppBuildInfo(
    platform: platform,
    architecture: platform == UpdatePlatform.android ? 'arm64-v8a' : 'x64',
    version: const AppReleaseVersion(1, 0, 20, 20),
  ),
  feed: feed,
  notify: notify ?? (_) async => true,
  now: now,
);
Future<File> cache() async {
  final parent = await Directory('build/test-tmp/updates')
          .create(recursive: true),
      folder = await parent.createTemp('case-');
  addTearDown(() => folder.delete(recursive: true));
  return File('${folder.path}/updates.json');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('automatic start, focus and runtime checks are throttled; manual check is immediate', () async {
    var now = DateTime(2026, 10, 28);
    final feed = Feed(), updates = service(feed, now: () => now);
    addTearDown(updates.dispose);
    await updates.initialize(await cache());
    await updates.check();
    expect(feed.reads, 1);
    updates.setForeground(false);
    updates.setForeground(true);
    await updates.check();
    expect(feed.reads, 1);
    await updates.check(manual: true);
    expect(feed.reads, 2);
    now = now.add(AppUpdates.interval);
    await updates.check();
    expect(feed.reads, 3);
  });
  test('concurrent checks share the same feed request and failed manual checks can retry', () async {
    final feed = Feed()..gate = Completer<void>(), updates = service(feed);
    addTearDown(updates.dispose);
    final one = updates.check(manual: true), two = updates.check(manual: true);
    expect(feed.reads, 1);
    feed.gate!.complete();
    await Future.wait([one, two]);
    expect(updates.busy, false);
    feed.fail = true;
    await updates.check(manual: true);
    expect(updates.error, isNotEmpty);
    expect(updates.busy, false);
    feed.fail = false;
    await updates.check(manual: true);
    expect(updates.error, isEmpty);
  });
  test('background notices require a newer platform asset and do not repeat after restart', () async {
    final file = await cache();
    var notices = 0;
    final feed = Feed()
      ..rows = [
        release('v1.0.30', [asset('GlobalSend-1.0.30-android-arm64-v8a.apk')]),
      ];
    final updates = service(
      feed,
      notify: (_) async {
        notices++;
        return true;
      },
    )..setForeground(false);
    await updates.initialize(file);
    await updates.check();
    expect(notices, 0);
    expect(updates.available, isNull);
    feed.rows = [
      release('v1.0.30', [asset('GlobalSend-1.0.30-windows-x64.zip')]),
    ];
    await updates.check(manual: true);
    expect(notices, 1);
    await updates.check(manual: true);
    expect(notices, 1);
    updates.dispose();
    final restarted = service(
      Feed()..rows = feed.rows,
      notify: (_) async {
        notices++;
        return true;
      },
    )..setForeground(false);
    addTearDown(restarted.dispose);
    await restarted.initialize(file);
    await restarted.check();
    expect(notices, 1);
  });
  test('a foreground offer never invokes the receive notification path; dismissal persists until manual check', () async {
    final file = await cache(),
        feed = Feed()
          ..rows = [
            release('v1.0.25', [asset('GlobalSend-1.0.25.ipa')]),
          ];
    var notices = 0;
    final updates = service(
      feed,
      platform: UpdatePlatform.ios,
      notify: (_) async {
        notices++;
        return true;
      },
    );
    addTearDown(updates.dispose);
    await updates.initialize(file);
    await updates.check();
    expect(notices, 0);
    expect(updates.showBanner, true);
    updates.presented();
    updates.dismiss();
    expect(updates.showBanner, false);
    await updates.check(manual: true);
    expect(updates.showBanner, true);
  });
}
