import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/file_share.dart';
import 'package:globalsend/dock_platform.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

class PolicyApi extends CenterApi {
  PolicyApi() : super('http://127.0.0.1:1', token: 'fixture');
  List<Map<String, dynamic>> events = [];
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    if (path == '/devices') return {'devices': []};
    if (path.startsWith('/events?'))
      return {'events': events, 'hasMore': false, 'cursor': events.length};
    if (path == '/transfers') return {'transfers': []};
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final entry in [
    (TargetPlatform.android, false),
    (TargetPlatform.iOS, false),
    (TargetPlatform.iOS, true),
  ]) {
    test(
      'automatic and manual image clipboard policy ${entry.$1} pad=${entry.$2}, text and newer-slot barrier remain',
      () async {
        debugDefaultTargetPlatformOverride = entry.$1;
        final parent = await Directory('../artifacts/tmp/image-clipboard113')
                .create(recursive: true),
            state = await parent.createTemp('policy-');
        final image = await File('${state.path}/image.png')
            .writeAsBytes([1, 2, 3]);
        final native = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(FileShareBridge.channel, (
          call,
        ) async {
          if (call.method == 'imageClipboardSupported') return entry.$2;
          if (call.method == 'copyReceivedImage') {
            native.add('apple-image');
            return true;
          }
          return null;
        });
        messenger.setMockMethodCallHandler(DockPlatform.channel, (call) async {
          if (call.method == 'copyReceivedImage') native.add('android-image');
          return false;
        });
        messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
          if (call.method == 'writeClipboard') native.add('text');
          return null;
        });
        if (entry.$1 == TargetPlatform.iOS)
          await FileShareBridge.refreshImageClipboardCapability();
        final api = PolicyApi(),
            now = DateTime.now(),
            expires = DateTime.now().add(const Duration(days: 1));
        final c =
            SendController(
                stateDirectory: () async => state,
                documentsDirectory: () async => state,
              )
              ..root = state
              ..api = api
              ..profile = ServerProfile(
                baseUrl: api.baseUrl,
                instanceId: 'fixture',
                deviceId: 'self',
              )
              ..info = {'features': {}};
        final imageEntry = DockEntry(
          id: 'image',
          kind: 'file',
          title: 'image.png',
          source: 'source',
          transferId: 'transfer',
          fileId: 'image',
          status: 'received',
          localPath: image.path,
          autoClipboard: true,
          originDeviceId: 'source',
          sourceEventId: 'image-event',
          createdAtMillis: now.millisecondsSinceEpoch,
          expiresAtMillis: expires.millisecondsSinceEpoch,
        );
        c.dock.add(imageEntry);
        try {
          c.updateTransfer({
            'transferId': 'transfer',
            'sourceDeviceId': 'source',
            'targetDeviceId': 'self',
            'createdAt': now.toIso8601String(),
            'expiresAt': expires.toIso8601String(),
            'clipboard': {
              'originDeviceId': 'source',
              'sourceEventId': 'image-event',
            },
            'files': [
              {
                'fileId': 'image',
                'name': 'image.png',
                'size': 3,
                'status': 'received',
                'offset': 3,
                'transport': 'direct',
              },
            ],
          });
          final ready = Completer<void>();
          void changed() {
            if (c.clipboardSlot != null && !ready.isCompleted) ready.complete();
          }

          c.addListener(changed);
          changed();
          await ready.future.timeout(const Duration(seconds: 5));
          expect(await c.copyClipboardSlot(), entry.$2);
          expect(c.canCopyClipboardSlot, entry.$2);
          expect(c.clipboardSlot?.kind, 'file');
          expect(c.historyDock, isEmpty);
          expect(c.pendingReceipts, isEmpty);
          expect(c.clipboardError, isEmpty);
          api.events = [
            {
              'eventId': 'old-text',
              'cursor': 1,
              'type': 'text.created',
              'sourceDeviceId': 'source',
              'targetDeviceId': 'self',
              'createdAt': now
                  .subtract(const Duration(minutes: 1))
                  .toIso8601String(),
              'expiresAt': expires.toIso8601String(),
              'payload': {
                'text': 'older automatic text',
                'clipboard': {
                  'originDeviceId': 'source',
                  'sourceEventId': 'older-event',
                },
              },
            },
          ];
          await c.reconcile();
          expect(native.where((value) => value == 'text'), isEmpty);
          expect(c.clipboardSlot?.kind, 'file');
          expect(
            native.where((value) => value.endsWith('-image')).isNotEmpty,
            entry.$2,
          );
          expect(native.contains('android-image'), false);
          await c.clipboard.receive(
            DockEntry(
              id: 'text',
              kind: 'text',
              title: 'text',
              source: 'source',
              text: 'manual text copy',
              autoClipboard: true,
              createdAtMillis: now.millisecondsSinceEpoch + 1,
            ),
          );
          expect(c.canCopyClipboardSlot, true);
          expect(await c.copyClipboardSlot(), true);
          expect(native.where((value) => value == 'text'), hasLength(1));
        } finally {
          c.dispose();
          api.close();
          debugDefaultTargetPlatformOverride = null;
          for (final channel in [
            FileShareBridge.channel,
            DockPlatform.channel,
            SystemBridge.channel,
          ])
            messenger.setMockMethodCallHandler(channel, null);
          await state.delete(recursive: true);
        }
      },
    );
  }
}
