import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/main.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

class DockHostController extends SendController {
  DockHostController() : super(deviceName: () async => 'fixture');
  bool initialized = false;
  Completer<void>? saveWait;
  @override
  Future<void> init() async {
    initialized = true;
  }

  @override
  Future<void> refreshGroupDevices() async {}
  @override
  Future<void> save() async {
    await saveWait?.future;
  }
}

class ReceiptLatencyApi extends CenterApi {
  ReceiptLatencyApi() : super('https://fixture.invalid', token: 'test');
  bool acked = false;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path == '/devices') return {'devices': []};
    if (path.startsWith('/events?'))
      return {
        'events': [
          {
            'eventId': 'early-text',
            'type': 'text.created',
            'cursor': 1,
            'sourceDeviceId': 'phone',
            'targetDeviceId': 'self',
            'payload': {'text': 'display before save and ack'},
          },
        ],
        'cursor': 1,
        'hasMore': false,
      };
    if (path.endsWith('/ack')) {
      acked = true;
      return {};
    }
    if (path == '/transfers') return {'transfers': []};
    throw StateError('Unexpected call: $path');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'independent dock routing keeps main bounds alone and forwards actions to the one controller',
    (tester) async {
      final calls = <MethodCall>[];
      final controller = DockHostController();
      final p = ServerProfile(
        baseUrl: 'https://fixture.invalid',
        instanceId: 'fixture',
        deviceId: 'self',
      );
      controller.profile = p;
      controller.api = CenterApi(p.baseUrl, token: 'public-fixture');
      controller.connected = true;
      var presentation = 'dock';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'drainLaunchFiles')
          expect(controller.initialized, true);
        if (call.method == 'windowVisible') return true;
        if (call.method == 'presentReceiveDock')
          return {
            'presentation': presentation,
            'shown': true,
            'arrivalGeneration': (call.arguments as Map)['serial'],
          };
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      expect(
        calls.where((call) => call.method == 'drainLaunchFiles'),
        hasLength(1),
      );
      expect(
        calls.where((call) => call.method == 'prepareReceiveDock'),
        hasLength(1),
      );

      DockEntry arrive(String id) {
        final entry = DockEntry(
          id: id,
          kind: 'text',
          title: '文本',
          source: 'phone',
          text: '公开测试内容$id',
        );
        controller.dock.add(entry);
        controller.pendingReceipts[id] = entry;
        controller.latestReceipt = entry;
        controller.receiptSerial++;
        controller.changed();
        return entry;
      }

      Future<void> action(Map<String, dynamic> data) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('receiveDockAction', data),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      arrive('first');
      await tester.pumpAndSettle();
      expect(controller.receiptPresentedExternally, true);
      expect(
        calls.where((call) => call.method == 'presentReceiveDock'),
        hasLength(1),
      );
      expect(
        calls.any(
          (call) =>
              ['showReceivedWindow', 'restoreWindow'].contains(call.method),
        ),
        false,
      );
      final progressEntry = controller.pendingReceipts['first']!;
      progressEntry.progress = .4;
      controller.changed();
      await tester.pumpAndSettle();
      final progressCall = calls.lastWhere(
        (call) => call.method == 'presentReceiveDock',
      );
      expect((progressCall.arguments as Map)['serial'], 1);
      expect(
        ((progressCall.arguments as Map)['items'] as List).single['progress'],
        .4,
      );
      await action({'action': 'copy', 'id': 'first'});
      expect(calls.any((call) => call.method == 'activateWindow'), false);
      await action({'action': 'stage', 'id': 'first'});
      expect(controller.stagedTexts, ['公开测试内容first']);
      expect(calls.any((call) => call.method == 'activateWindow'), true);

      arrive('second');
      await tester.pumpAndSettle();
      await action({
        'action': 'close',
        'itemIds': ['first'],
        'serial': 1,
        'arrivalGeneration': 1,
      });
      expect(controller.pendingReceipts.keys, ['second']);
      expect(controller.dock.map((entry) => entry.id), ['first', 'second']);
      presentation = 'main';
      await action({'action': 'open', 'id': 'second'});
      expect(controller.receiptPresentedExternally, false);
      expect(controller.latestReceipt!.id, 'second');
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'delete dismisses immediately while saving and stale IDs stay dismissed',
    (tester) async {
      final controller = DockHostController();
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'windowVisible') return true;
        if (call.method == 'presentReceiveDock')
          return {
            'presentation': 'dock',
            'shown': true,
            'arrivalGeneration': 1,
          };
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      final first = DockEntry(
        id: 'delete',
        kind: 'text',
        title: 'text',
        source: 'phone',
        text: 'delete this',
      );
      final second = DockEntry(
        id: 'keep',
        kind: 'text',
        title: 'text',
        source: 'phone',
        text: 'keep this',
      );
      controller.dock.addAll([first, second]);
      controller.pendingReceipts.addAll({'delete': first, 'keep': second});
      controller.receiptSerial++;
      controller.changed();
      await tester.pumpAndSettle();
      final saving = Completer<void>();
      controller.saveWait = saving;
      Future<void> remove(String id) async {
        await messenger.handlePlatformMessage(
          SystemBridge.channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('receiveDockAction', {'action': 'delete', 'id': id}),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      await remove('delete');
      expect(saving.isCompleted, false);
      expect(controller.pendingReceipts.keys, ['keep']);
      expect(controller.dock.map((entry) => entry.id), ['keep']);
      final update = calls.lastWhere(
        (call) => call.method == 'presentReceiveDock',
      );
      expect(
        ((update.arguments as Map)['items'] as List).map((item) => item['id']),
        ['keep'],
      );
      // A stale display ID still dismisses even after its history record is gone.
      controller.dock.clear();
      await remove('keep');
      expect(controller.pendingReceipts, isEmpty);
      expect(calls.last.method, 'dismissReceiveDock');
      saving.complete();
      await tester.pumpAndSettle();
      expect(controller.pendingReceipts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'text receipt presents before blocked persistence or delivery ACK',
    (tester) async {
      final controller = DockHostController();
      final api = ReceiptLatencyApi();
      controller.profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      );
      controller.api = api;
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        calls.add(call);
        if (call.method == 'windowVisible') return true;
        if (call.method == 'presentReceiveDock')
          return {
            'presentation': 'dock',
            'shown': true,
            'arrivalGeneration': 1,
          };
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
      );
      await tester.pumpWidget(GlobalSendApp(controller: controller));
      await tester.pumpAndSettle();
      final saving = Completer<void>();
      controller.saveWait = saving;
      final sync = controller.reconcile();
      await tester.pumpAndSettle();
      expect(controller.syncing, true);
      expect(api.acked, false);
      expect(saving.isCompleted, false);
      final update = calls.lastWhere(
        (call) => call.method == 'presentReceiveDock',
      );
      expect(
        ((update.arguments as Map)['items'] as List).single['id'],
        'early-text',
      );
      saving.complete();
      await sync;
      await tester.pumpAndSettle();
      expect(api.acked, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isWindows,
  );

  testWidgets('late dock presentation cannot restore a closed receipt', (
    tester,
  ) async {
    final controller = DockHostController();
    final pending = Completer<Map<String, dynamic>>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'windowVisible') return true;
      if (call.method == 'presentReceiveDock') return pending.future;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
    );
    await tester.pumpWidget(GlobalSendApp(controller: controller));
    await tester.pumpAndSettle();
    final entry = DockEntry(
      id: 'late',
      kind: 'text',
      title: '文本',
      source: 'phone',
      text: '公开测试内容',
    );
    controller.dock.add(entry);
    controller.pendingReceipts[entry.id] = entry;
    controller.latestReceipt = entry;
    controller.receiptSerial++;
    controller.changed();
    await tester.pump();
    expect(controller.receiptPresentedExternally, true);
    controller.dismissReceipts(['late'], throughSerial: 1);
    controller.changed();
    await tester.pump();
    pending.complete({
      'presentation': 'dock',
      'shown': true,
      'arrivalGeneration': 1,
    });
    await tester.pumpAndSettle();
    expect(controller.receiptPresentedExternally, false);
    expect(controller.pendingReceipts, isEmpty);
    expect(controller.dock.single.id, 'late');
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);
}
