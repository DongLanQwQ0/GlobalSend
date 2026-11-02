import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/app_updates.dart';
import 'package:globalsend/github_updates.dart';
import 'package:globalsend/update_download.dart';
import 'package:globalsend/ui_session.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:flutter/services.dart';

import 'app_updates_test.dart' show Feed;
import 'github_updates_test.dart' show asset, release;

class RealUpdateBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class DownloadFixture implements UpdateDownloader {
  int calls = 0;
  bool fail = false;
  @override
  Future<File> download(
    PlatformUpdate offer,
    File target,
    UpdateProgress progress,
  ) async {
    calls++;
    if (fail) throw const SocketException('fixture interrupted');
    await target.parent.create(recursive: true);
    await target.writeAsBytes(List.filled(offer.size, 42));
    progress(offer.size, offer.size);
    return target;
  }

  @override
  void cancel() {}
}

Future<File> stateFile() async {
  final root = await Directory('../artifacts/tmp/automatic-updates103')
      .create(recursive: true);
  final folder = await root.createTemp('state-');
  return File('${folder.path}/updates.json');
}

AppBuildInfo build(UpdatePlatform platform) => AppBuildInfo(
  platform: platform,
  architecture: platform == UpdatePlatform.windows ? 'x64' : 'arm64-v8a',
  version: const AppReleaseVersion(1, 0, 78, 102),
);
Feed feed(UpdatePlatform platform) => Feed()
  ..rows = [
    release('v1.0.79-build103', [
      asset(
        platform == UpdatePlatform.windows
            ? 'GlobalSend-1.0.79-windows-x64.zip'
            : 'GlobalSend-1.0.79-android-arm64-v8a.apk',
        size: 8,
      ),
    ]),
  ];
Future<void> settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 25));
}

void main() {
  RealUpdateBinding();
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdates.channel, (call) async {
          if (call.method == 'cancelUpdateInstall') return null;
          throw MissingPluginException();
        }),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppUpdates.channel, null),
  );
  test('native exit handoff flushes the current window state before final idle decision', () async {
    final root = await stateFile(),
        window = File('${root.parent.path}/window.json');
    await SystemBridge.configureWindowPersistence(window.path, restore: false);
    var checks = 0;
    SystemBridge.beforeUpdateExit = () async {
      checks++;
      expect((jsonDecode(await window.readAsString()) as Map)['left'], 123);
      return false;
    };
    addTearDown(() => SystemBridge.beforeUpdateExit = null);
    final done = Completer<dynamic>();
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          SystemBridge.channel.name,
          codec.encodeMethodCall(
            const MethodCall('prepareUpdateExit', {
              'left': 123,
              'top': 456,
              'width': 950,
              'height': 650,
            }),
          ),
          (data) => done.complete(codec.decodeEnvelope(data!)),
        );
    expect(await done.future, isFalse);
    expect(checks, 1);
  }, skip: !Platform.isWindows);
  test('Windows downloads once, waits for background and idle, saves before one installation', () async {
    final downloads = DownloadFixture(), calls = <bool>[], saves = <String>[];
    var idle = false;
    final updates =
        AppUpdates(
            build: build(UpdatePlatform.windows),
            feed: feed(UpdatePlatform.windows),
            downloader: downloads,
            notifyReady: (_, __) async => true,
            install: (_, __, {required explicit}) async {
              calls.add(explicit);
              expect(saves, isNotEmpty);
              return {'state': 'started'};
            },
          )
          ..canInstall = (() => idle)
          ..beforeInstall = () async {
            saves.add('saved');
          };
    addTearDown(updates.dispose);
    await updates.initialize(await stateFile());
    await updates.check();
    await updates.downloadAndInstall();
    expect(updates.ready, isTrue);
    expect(downloads.calls, 1);
    expect(calls, isEmpty);
    updates.setForeground(false);
    await settle();
    expect(calls, isEmpty);
    idle = true;
    updates.activityChanged();
    await settle();
    expect(calls, [false]);
    expect(saves, ['saved']);
    updates.activityChanged();
    updates.setForeground(true);
    updates.setForeground(false);
    await settle();
    expect(calls.length, 1);
    idle = false;
    expect(await updates.prepareExit(), isFalse);
    idle = true;
    expect(await updates.prepareExit(), isTrue);
    expect(saves.length, 2);
  });
  test(
    'ready package and preferences survive restart without another download',
    () async {
      final file = await stateFile(), downloads = DownloadFixture();
      final firstFeed = feed(UpdatePlatform.windows);
      (firstFeed.rows.first['assets'] as List).first['url'] =
          'https://api.github.com/repos/test/releases/assets/42';
      final first = AppUpdates(
        build: build(UpdatePlatform.windows),
        feed: firstFeed,
        downloader: downloads,
      );
      await first.initialize(file);
      await first.check();
      await first.downloadAndInstall();
      await first.setAutoCheck(false);
      await first.setAutoDownload(false);
      first.dispose();
      final cached = jsonDecode(await file.readAsString()) as Map;
      expect(cached['package']['asset'], endsWith('.zip'));
      expect(
        cached['package']['assetApiUrl'],
        'https://api.github.com/repos/test/releases/assets/42',
      );
      final newFeed = Feed(),
          second = AppUpdates(
            build: build(UpdatePlatform.windows),
            feed: newFeed,
            downloader: downloads,
          );
      addTearDown(second.dispose);
      await second.initialize(file);
      await settle();
      expect(second.autoCheck, isFalse);
      expect(second.autoDownload, isFalse);
      expect(second.ready, isTrue);
      expect(
        second.available!.assetApiUrl,
        'https://api.github.com/repos/test/releases/assets/42',
      );
      expect(newFeed.reads, 0);
      expect(downloads.calls, 1);
    },
  );
  test('turning automatic updates off while saving prevents apply; manual install still works', () async {
    final saving = Completer<void>(), entered = Completer<void>();
    var calls = 0;
    final updates = AppUpdates(
      build: build(UpdatePlatform.windows),
      feed: feed(UpdatePlatform.windows),
      downloader: DownloadFixture(),
      notifyReady: (_, __) async => true,
      install: (_, __, {required explicit}) async {
        calls++;
        return {'state': 'started'};
      },
    );
    addTearDown(updates.dispose);
    await updates.initialize(await stateFile());
    await updates.check();
    await updates.downloadAndInstall();
    updates.beforeInstall = () async {
      if (!entered.isCompleted) entered.complete();
      await saving.future;
    };
    updates.setForeground(false);
    await entered.future;
    await updates.setAutoDownload(false);
    saving.complete();
    await settle();
    expect(calls, 0);
    expect(await updates.prepareExit(), isFalse);
    await updates.downloadAndInstall(explicit: true);
    expect(calls, 1);
    expect(await updates.prepareExit(), isTrue);
  });
  test('Android ready notification waits for foreground; permission resumes once and started never loops', () async {
    var notices = 0, permission = false;
    final installs = <bool>[];
    final updates = AppUpdates(
      build: build(UpdatePlatform.android),
      feed: feed(UpdatePlatform.android),
      downloader: DownloadFixture(),
      notifyReady: (_, file) async {
        expect(await file.exists(), isTrue);
        notices++;
        return true;
      },
      install: (_, __, {required explicit}) async {
        installs.add(explicit);
        return {'state': permission ? 'started' : 'permission-required'};
      },
    )..setForeground(false);
    addTearDown(updates.dispose);
    await updates.initialize(await stateFile());
    await updates.check();
    await updates.downloadAndInstall();
    expect(notices, 1);
    expect(installs, isEmpty);
    updates.setForeground(true);
    await settle();
    expect(installs, [false]);
    updates.activityChanged();
    await settle();
    expect(installs.length, 1);
    permission = true;
    updates.setForeground(false);
    updates.setForeground(true);
    await settle();
    expect(installs.length, 2);
    updates.setForeground(false);
    updates.setForeground(true);
    updates.activityChanged();
    await settle();
    expect(installs.length, 2);
    await updates.downloadAndInstall(explicit: true);
    expect(installs.last, isTrue);
    expect(installs.length, 3);
  });
  test('native install failure persists the cleared manual request and cannot reopen after restart', () async {
    final file = await stateFile();
    var attempts = 0;
    final first = AppUpdates(
      build: build(UpdatePlatform.android),
      feed: feed(UpdatePlatform.android),
      downloader: DownloadFixture(),
      install: (_, __, {required explicit}) async {
        attempts++;
        throw PlatformException(code: 'UPDATE_INSTALL', message: '安装包版本不符');
      },
    );
    await first.initialize(file);
    await first.check();
    await first.downloadAndInstall(explicit: true);
    await settle();
    expect(first.error, contains('安装包版本不符'));
    expect(attempts, 1);
    final data = jsonDecode(await file.readAsString()) as Map;
    expect(data['manualInstallRequested'], isFalse);
    first.dispose();
    var reopened = 0;
    final restarted = AppUpdates(
      build: build(UpdatePlatform.android),
      feed: feed(UpdatePlatform.android),
      downloader: DownloadFixture(),
      install: (_, __, {required explicit}) async {
        reopened++;
        return {'state': 'started'};
      },
    );
    addTearDown(restarted.dispose);
    await restarted.initialize(file);
    await restarted.check();
    await settle();
    expect(restarted.ready, isTrue);
    expect(reopened, 0);
    await restarted.redownload();
    expect(reopened, 1);
  });
  test(
    'manual install waits for active work even with automatic updates disabled',
    () async {
      var idle = false, calls = 0;
      final updates = AppUpdates(
        build: build(UpdatePlatform.windows),
        feed: feed(UpdatePlatform.windows),
        downloader: DownloadFixture(),
        install: (_, __, {required explicit}) async {
          expect(explicit, isTrue);
          calls++;
          return {'state': 'started'};
        },
      );
      updates.canInstall = () => idle;
      addTearDown(updates.dispose);
      await updates.initialize(await stateFile());
      await updates.check();
      await updates.downloadAndInstall();
      await updates.setAutoDownload(false);
      await updates.downloadAndInstall(explicit: true);
      expect(calls, 0);
      idle = true;
      updates.activityChanged();
      await settle();
      expect(calls, 1);
    },
  );
  test(
    'failed download cannot install and retry reuses the same selected offer',
    () async {
      final downloads = DownloadFixture()..fail = true;
      var installs = 0;
      final updates = AppUpdates(
        build: build(UpdatePlatform.android),
        feed: feed(UpdatePlatform.android),
        downloader: downloads,
        install: (_, __, {required explicit}) async {
          installs++;
          return {'state': 'started'};
        },
      );
      addTearDown(updates.dispose);
      await updates.initialize(await stateFile());
      await updates.check();
      await updates.downloadAndInstall();
      expect(updates.package, isNull);
      expect(updates.error, isNotEmpty);
      expect(installs, 0);
      downloads.fail = false;
      await updates.downloadAndInstall(explicit: true);
      expect(installs, 1);
      expect(updates.error, isEmpty);
    },
  );
  test('streamed HTTP download retains a partial and resumes with Range before publishing complete package', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        requests = <String>[];
    final sub = server.listen((request) async {
      expect(
        request.headers.value(HttpHeaders.acceptHeader),
        'application/octet-stream',
      );
      requests.add(request.headers.value(HttpHeaders.rangeHeader) ?? '');
      if (requests.length == 1) {
        request.response.add([1, 2, 3, 4]);
      } else {
        request.response.statusCode = 206;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 4-7/8',
        );
        request.response.add([5, 6, 7, 8]);
      }
      await request.response.close();
    });
    addTearDown(() async {
      await sub.cancel();
      await server.close(force: true);
    });
    final file = await stateFile(),
        target = File('${file.parent.path}/updates/test.apk'),
        downloader = HttpUpdateDownloader();
    final offer = PlatformUpdate(
      platform: UpdatePlatform.android,
      version: const AppReleaseVersion(1, 0, 79, 103),
      assetName: 'test.apk',
      downloadUrl: 'https://unreachable.invalid/browser-download.apk',
      assetApiUrl: 'http://127.0.0.1:${server.port}/test.apk',
      releaseUrl: 'https://github.com/release',
      size: 8,
    );
    await expectLater(
      downloader.download(offer, target, (_, __) {}),
      throwsA(isA<HttpException>()),
    );
    expect(await target.exists(), isFalse);
    expect(await File('${target.path}.part').readAsBytes(), [1, 2, 3, 4]);
    await downloader.download(offer, target, (_, __) {});
    expect(await target.readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(requests, ['', 'bytes=4-']);
    expect(await File('${target.path}.part').exists(), isFalse);
  });
  test('update draft handoff keeps text and editor state but never serializes server passwords', () async {
    final session = SendUiSession()
      ..page = 0
      ..contentTab = 1
      ..composeOpen = true
      ..composeIndex = 2
      ..readerId = 'outgoing';
    session.fields['secret'] = const TextEditingValue(
      text: 'never-save-group-secret',
    );
    session.fields['compose'] = const TextEditingValue(
      text: 'keep draft',
      selection: TextSelection.collapsed(offset: 3),
    );
    session.readerDrafts['outgoing'] = const TextEditingValue(
      text: 'edited received text',
    );
    session.sharedDraftScope = 'center:group';
    session.sharedDraft = 'unsynced shared content';
    final file = await stateFile();
    await session.saveUpdateDrafts(file);
    expect(
      await file.readAsString(),
      isNot(contains('never-save-group-secret')),
    );
    final restored = SendUiSession();
    expect(await restored.loadUpdateDrafts(file), isTrue);
    expect(restored.fields['compose']!.text, 'keep draft');
    expect(restored.composeOpen, isTrue);
    expect(restored.composeIndex, 2);
    expect(restored.readerDrafts['outgoing']!.text, 'edited received text');
    expect(restored.sharedDraft, 'unsynced shared content');
    expect(await file.exists(), isFalse);
  });
}
