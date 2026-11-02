import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/app_updates.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/system_bridge.dart';
import 'package:globalsend/vault.dart';

import 'widget_test.dart' as preview;
import 'system_font_fixture.dart';

class FixtureVault extends PlatformVault {
  @override
  Future<String?> read({required String key}) async => 'isolated-fixture-token';
}

class QuietUpdates extends AppUpdates {
  @override
  Future<void> initialize(File file) async {}
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Fixture timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> event(int sequence, String text) async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemBridge.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('clipboardChanged', {'sequence': sequence, 'text': text}),
        ),
        (_) => done.complete(),
      );
  await done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadSystemTestFonts);
  HttpOverrides.global = null;

  test(
    'old profiles default off; explicit off and the selected device round-trip',
    () {
      final old = ServerProfile.fromJson({
        'baseUrl': 'https://fixture.invalid',
        'instanceId': 'fixture',
      });
      expect(old.clipboardSyncEnabled, isFalse);
      expect(old.clipboardSyncTarget, isEmpty);
      old.clipboardSyncTarget = 'selected-tablet';
      final restored = ServerProfile.fromJson(old.toJson());
      expect(restored.clipboardSyncEnabled, isFalse);
      expect(restored.clipboardSyncTarget, 'selected-tablet');
    },
  );

  test('production restart restores one target, survives offline/reconnect, and respects durable off independently of file-copy source', () async {
    final parent = await Directory('../artifacts/tmp/clipboard-restart114')
        .create(recursive: true);
    final work = await parent.createTemp('restart-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final texts = <Map<String, dynamic>>[];
    var listTarget = false;
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/api/v1/ws') {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(jsonEncode({'type': 'hello', 'deviceId': 'self'}));
        socket.listen((_) {});
        return;
      }
      Map<String, dynamic> result = {};
      if (path == '/api/v1/info') {
        result = {
          'protocolVersion': 1,
          'instanceId': 'fixture',
          'features': {'copiedFiles': true},
        };
      }
      if (path == '/api/v1/session/ws-ticket') {
        result = {'ticket': 'fixture-ticket'};
      }
      if (path == '/api/v1/devices') {
        result = {
          'devices': [
            if (listTarget)
              {'deviceId': 'tablet', 'name': 'Tablet', 'online': false},
          ],
        };
      }
      if (path == '/api/v1/events') {
        result = {'events': [], 'cursor': 0, 'hasMore': false};
      }
      if (path == '/api/v1/transfers') result = {'transfers': []};
      if (path == '/api/v1/clipboard/files') result = {'offers': []};
      if (path == '/api/v1/clipboard/files/pulls') result = {'pulls': []};
      if (path == '/api/v1/texts') {
        texts.add(
          Map<String, dynamic>.from(
            jsonDecode(await utf8.decoder.bind(request).join()) as Map,
          ),
        );
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final watches = <bool>[];
    var failWatch = false;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      expect(
        call.method,
        isNot(anyOf('readClipboard', 'clipboardSuggestion', 'clipboardKind')),
      );
      if (call.method == 'clipboardWatch') {
        watches.add((call.arguments as Map)['enabled'] as bool);
        if (failWatch) throw PlatformException(code: 'FIXTURE_WATCH');
      }
      if (call.method == 'clipboardFilePaths') return <String>[];
      return null;
    });
    SendController make() => SendController(
      stateDirectory: () async => work,
      documentsDirectory: () async => Directory('${work.path}/documents'),
      vault: FixtureVault(),
      updates: QuietUpdates(),
      deviceName: () async => 'Fixture',
      ipAddresses: () async => [],
    );
    final clients = <SendController>[];
    Future<void> close(SendController c) async {
      await c.save();
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    try {
      final base = 'http://127.0.0.1:${server.port}';
      final p = ServerProfile(
        baseUrl: base,
        instanceId: 'fixture',
        deviceId: 'self',
      );
      final seed = make();
      clients.add(seed);
      seed.root = work;
      seed.profile = p;
      seed.profiles.add(p);
      seed.api = CenterApi(base, token: 'isolated-fixture-token');
      seed.connected = true;
      seed.devices = [
        {'deviceId': 'phone', 'name': 'Phone', 'online': true},
        {'deviceId': 'tablet', 'name': 'Tablet', 'online': true},
      ];
      await seed.setClipboardSync(true, 'phone');
      await seed.setClipboardSync(true, 'tablet');
      final persisted =
          (jsonDecode(
                await File('${work.path}/profiles.json').readAsString(),
              ) as List).single
              as Map;
      expect(persisted['clipboardSyncEnabled'], isTrue);
      expect(persisted['clipboardSyncTarget'], 'tablet');
      // No extra save between setter completion and the next process's init.
      seed.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final restored = make();
      clients.add(restored);
      await restored.init();
      expect(restored.connected, isTrue, reason: restored.message);
      expect(restored.clipboardEnabled, isTrue);
      expect(restored.clipboardTarget, 'tablet');
      expect(
        restored.devices,
        isEmpty,
      ); // No list entry is needed to retain intent.
      expect(watches.last, isTrue);
      await event(100, 'after restart');
      await until(() => texts.length == 1);
      expect(texts.single['targetDeviceId'], 'tablet');
      expect(texts.single['clipboard'], isA<Map>());

      restored.lost(restored.generation);
      expect(restored.clipboardEnabled, isTrue);
      expect(restored.clipboardTarget, 'tablet');
      await event(101, 'offline replacement');
      expect(texts, hasLength(1));
      failWatch = true;
      await restored.openSocket(restored.generation);
      expect(
        restored.connected,
        isTrue,
      ); // Native failure must not kill center recovery.
      expect(restored.clipboardEnabled, isTrue);
      expect(restored.clipboardError, contains('FIXTURE_WATCH'));
      failWatch = false;
      await restored.openSocket(restored.generation);
      expect(restored.clipboardError, isEmpty);
      listTarget = true;
      await restored.connect(
        base,
        development: true,
      ); // Full connection teardown.
      expect(restored.clipboardEnabled, isTrue);
      expect(restored.clipboardTarget, 'tablet');
      expect(restored.devices.single['online'], isFalse);
      await event(102, 'after reconnect');
      await until(() => texts.length == 2);
      expect(texts.last['targetDeviceId'], 'tablet');
      expect(restored.dock, isEmpty);
      expect(restored.pendingReceipts, isEmpty);
      expect(restored.stagedTexts, isEmpty);

      await restored.setClipboardSync(false, '');
      expect(watches.last, isFalse);
      expect(restored.profile!.clipboardSyncTarget, 'tablet');
      await restored.setCopiedFilePush(true, ['tablet']);
      expect(watches.last, isTrue);
      await close(restored);

      final off = make();
      clients.add(off);
      await off.init();
      expect(off.connected, isTrue, reason: off.message);
      expect(off.clipboardEnabled, isFalse);
      expect(off.clipboardTarget, 'tablet');
      expect(off.copiedFiles.sourceReady, isTrue);
      expect(
        watches.last,
        isTrue,
      ); // The other watcher consumer remains active.
      await event(103, 'must remain off');
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(texts, hasLength(2));
      await off.setCopiedFilePush(false, []);
      expect(watches.last, isFalse);
      // A saved destination may be temporarily absent and the center offline.
      // Restoring its switch is a local preference, not a new device grant.
      off.stopConnections();
      off.api = null;
      await off.setClipboardSync(true, 'tablet');
      expect(off.clipboardEnabled, isTrue);
      expect(off.clipboardTarget, 'tablet');
      await expectLater(
        off.setClipboardSync(true, 'unknown'),
        throwsFormatException,
      );
      off.devices = [
        {'deviceId': 'tablet', 'revoked': true},
      ];
      await expectLater(
        off.setClipboardSync(true, 'tablet'),
        throwsFormatException,
      );
      await off.setClipboardSync(false, '');
      await close(off);
      await File('${parent.path}/evidence.json').writeAsString(
        jsonEncode({
          'fixture': 'production SendController init/save/connect/openSocket with loopback center and mocked native clipboard events',
          'durableRestartTarget': 'tablet',
          'automaticTextDeliveries': texts.length,
          'explicitOffRestored': true,
          'independentCopiedFileWatcherRestored': true,
          'nativeWatchFailureReconnectRecovered': true,
          'realClipboardAccess': false,
        }),
        flush: true,
      );
    } finally {
      for (final c in clients) {
        if (!c.disposed) c.dispose();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
      messenger.setMockMethodCallHandler(SystemBridge.channel, null);
      // Only this fixture's explicitly created tree is removed.
      await work.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  for (final online in [true, false]) {
    testWidgets(
      'disabled remembered clipboard target stays selected in settings online=$online',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method == 'windowVisible') return true;
          return null;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
        );
        final c = preview.signedIn();
        c.profile = ServerProfile.fromJson({
          ...c.profile!.toJson(),
          'clipboardSyncEnabled': false,
          'clipboardSyncTarget': 'tablet',
        });
        c.clipboardEnabled = c.profile!.clipboardSyncEnabled;
        c.clipboardTarget = c.profile!.clipboardSyncTarget;
        c.devices.add({'deviceId': 'tablet', 'name': '已选平板', 'online': online});
        await tester.pumpWidget(GlobalSendApp(controller: c));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        final tile = find.byKey(const ValueKey('clipboard-sync'));
        await tester.scrollUntilVisible(
          tile,
          250,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('settings-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(tester.widget<SwitchListTile>(tile).value, isFalse);
        expect(tester.widget<SwitchListTile>(tile).onChanged, isNotNull);
        final dropdown = find.byKey(const ValueKey('clipboard-target-tablet'));
        expect(dropdown, findsOneWidget);
        expect(
          tester.widget<DropdownButtonFormField<String>>(dropdown).onChanged,
          isNull,
        );
        expect(
          find.byKey(const ValueKey('clipboard-target-phone')),
          findsNothing,
        );
        expect(find.text(online ? '已选平板' : '已选平板 · 离线'), findsOneWidget);
        expect(c.clipboardChanges, isEmpty);
        expect(c.clipboardTarget, 'tablet');
        // Exercise the rendered control's event contract. The production
        // controller test above owns persistence and reconnect behavior.
        tester.widget<SwitchListTile>(tile).onChanged!(true);
        expect(c.clipboardChanges, [(true, 'tablet')]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
      skip: !Platform.isWindows,
    );
  }
}
