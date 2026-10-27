import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/system_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  test(
    'window state restores and saves normal bounds including negative monitors',
    () async {
      final parent = await Directory('build/test-tmp/window-state')
          .create(recursive: true);
      final directory = await parent.createTemp('case-');
      final file = File('${directory.path}/window.json');
      final state = {
        'left': -1600,
        'top': 80,
        'width': 950,
        'height': 650,
        'maximized': true,
      };
      await file.writeAsString(jsonEncode(state));
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        calls.add(call);
        return call.method == 'windowVisible' ? false : null;
      });
      await SystemBridge.configureWindowPersistence(file.path);
      expect(calls.single.method, 'restoreWindow');
      expect(calls.single.arguments, state);
      expect(await SystemBridge.windowVisible(), false);
      final saved = {...state, 'width': 1100, 'maximized': false};
      await messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        codec.encodeMethodCall(MethodCall('windowStateChanged', saved)),
        (_) {},
      );
      expect(jsonDecode(await file.readAsString()), saved);
      messenger.setMockMethodCallHandler(SystemBridge.channel, null);
      await directory.delete(recursive: true);
    },
  );

  test(
    'window visibility shares handler without swallowing native drops',
    () async {
      final window = SystemBridge.windowEvents.first;
      final drop = SystemBridge.dropEvents.first;
      await messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        codec.encodeMethodCall(
          const MethodCall('windowVisibilityChanged', {'visible': false}),
        ),
        (_) {},
      );
      await messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        codec.encodeMethodCall(
          const MethodCall('nativeDrop', {
            'dropId': 'one',
            'paths': ['F:/file'],
          }),
        ),
        (_) {},
      );
      expect(await window, {'visible': false});
      expect(await drop, {
        'type': 'nativeDrop',
        'dropId': 'one',
        'paths': ['F:/file'],
      });
    },
  );

  test('native startup only binds future saves, never reads or reapplies late bounds', () async {
    final parent = await Directory('build/test-tmp/window-state')
        .create(recursive: true);
    final directory = await parent.createTemp('native-startup-');
    final file = File('${directory.path}/window.json');
    // Native already consumed this startup input. Dart must not read it again
    // after the first frame, even while application initialization was delayed.
    await file.writeAsString('{not-readable-as-a-window-state');
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      calls.add(call);
      return null;
    });
    await SystemBridge.configureWindowPersistence(file.path, restore: false);
    expect(calls, isEmpty);
    final saved = {
      'left': -1200,
      'top': 100,
      'width': 1100,
      'height': 700,
      'maximized': true,
    };
    await messenger.handlePlatformMessage(
      SystemBridge.channel.name,
      codec.encodeMethodCall(MethodCall('windowStateChanged', saved)),
      (_) {},
    );
    expect(jsonDecode(await file.readAsString()), saved);
    messenger.setMockMethodCallHandler(SystemBridge.channel, null);
    await directory.delete(recursive: true);
  });
}
