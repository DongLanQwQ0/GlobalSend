import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/system_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemBridge.channel, null),
  );

  test(
    'reveal preserves the exact original Windows file or folder path',
    () async {
      final paths = <String>[];
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        expect(call.method, 'revealFile');
        paths.add((call.arguments as Map)['path'] as String);
        return null;
      });
      for (final path in [r'F:\接收 文件,目录\中文 空格,逗号.txt', r'F:\接收 文件,目录']) {
        await SystemBridge.revealFile(path);
      }
      expect(paths, [r'F:\接收 文件,目录\中文 空格,逗号.txt', r'F:\接收 文件,目录']);
    },
  );

  test('reveal keeps the native missing-file error concise', () async {
    messenger.setMockMethodCallHandler(SystemBridge.channel, (_) async {
      throw PlatformException(code: 'REVEAL_FILE', message: '文件已不存在');
    });
    await expectLater(
      SystemBridge.revealFile(r'F:\missing.txt'),
      throwsA(
        isA<StateError>().having((error) => error.message, 'message', '文件已不存在'),
      ),
    );
  });
}
