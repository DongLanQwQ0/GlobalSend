import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/system_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one Windows handler forwards drop events without replacing clipboard events', () async {
    final drops = <Map<String, dynamic>>[];
    final clipboard = <Map<String, dynamic>>[];
    final dropSubscription = SystemBridge.dropEvents.listen(drops.add);
    final clipboardSubscription = SystemBridge.clipboardEvents.listen(
      clipboard.add,
    );
    addTearDown(dropSubscription.cancel);
    addTearDown(clipboardSubscription.cancel);
    // Accessing either getter again must not install a competing handler.
    SystemBridge.clipboardEvents;
    SystemBridge.dropEvents;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();
    Future<void> emit(String method, Map<String, dynamic> arguments) async {
      await messenger.handlePlatformMessage(
        SystemBridge.channel.name,
        codec.encodeMethodCall(MethodCall(method, arguments)),
        null,
      );
    }

    await emit('nativeDrag', {'active': true, 'importing': false});
    await emit('clipboardChanged', {'text': '原剪贴板路径', 'sequence': 12});
    await emit('nativeDrop', {
      'dropId': 'windows-native-1',
      'paths': [r'F:\测试\文件.txt'],
      'texts': <String>[],
    });
    await emit('nativeDrag', {'active': false, 'importing': false});

    expect(clipboard, [
      {'text': '原剪贴板路径', 'sequence': 12},
    ]);
    expect(drops.map((event) => event['type']), [
      'nativeDrag',
      'nativeDrop',
      'nativeDrag',
    ]);
    expect(drops[0]['active'], isTrue);
    expect(drops[1]['paths'], [r'F:\测试\文件.txt']);
    expect(drops[1]['dropId'], 'windows-native-1');
    expect(drops[2]['active'], isFalse);
  });
}
