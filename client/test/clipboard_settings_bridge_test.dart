import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/system_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clipboard settings use the Windows operation-map contract on enable, retarget and disable', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    final api = CenterApi('https://center.invalid', token: 'fixture');
    final controller = SendController()
      ..api = api
      ..profile = ServerProfile(
        baseUrl: api.baseUrl,
        instanceId: 'fixture',
        deviceId: 'self',
      )
      ..devices = [
        {'deviceId': 'phone', 'name': 'Phone', 'online': true},
        {'deviceId': 'tablet', 'name': 'Tablet', 'online': true},
      ];
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      calls.add(call);
      // Match the production Windows dispatcher, not a permissive null stub.
      if (call.arguments is! Map) {
        throw PlatformException(
          code: 'BAD_ARGUMENT',
          message: 'Expected operation map',
        );
      }
      return null;
    });
    try {
      await controller.setClipboardSync(true, 'phone');
      expect(controller.clipboardEnabled, isTrue);
      expect(controller.clipboardTarget, 'phone');

      await controller.setClipboardSync(true, 'tablet');
      expect(controller.clipboardTarget, 'tablet');

      await controller.setClipboardSync(false, '');
      await Future<void>.delayed(Duration.zero);
      expect(controller.clipboardEnabled, isFalse);
      expect(controller.clipboardTarget, isEmpty);
      expect(
        calls
            .where((call) => call.method == 'cancelClipboardImage')
            .map((call) => call.arguments),
        [{}, {}, {}],
      );
      expect(
        calls
            .where((call) => call.method == 'clipboardWatch')
            .map((call) => call.arguments),
        [
          {'enabled': true},
          {'enabled': true},
          {'enabled': false},
        ],
      );
    } finally {
      controller.dispose();
      await Future<void>.delayed(Duration.zero);
      messenger.setMockMethodCallHandler(SystemBridge.channel, null);
      api.client.close(force: true);
    }
  }, skip: !Platform.isWindows);
}
