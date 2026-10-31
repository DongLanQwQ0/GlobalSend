import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/system_bridge.dart';

class ExportController extends SendController {
  ExportController(Directory folder)
    : super(stateDirectory: () async => folder);
  int saves = 0;
  @override
  Future<void> save() async {
    saves++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory folder;
  late ExportController c;
  setUp(() async {
    folder = Directory('../artifacts/tmp/windows-suggestions86/model').absolute;
    await folder.create(recursive: true);
    c = ExportController(folder);
  });
  tearDown(() async {
    c.dispose();
    messenger.setMockMethodCallHandler(SystemBridge.channel, null);
    expect(
      folder.path,
      startsWith(
        Directory('../artifacts/tmp/windows-suggestions86').absolute.path,
      ),
    );
    await folder.delete(recursive: true);
  });
  test(
    'text and multiple original files export without confirming a queued send',
    () async {
      final files = [
        File('${folder.path}/original.txt'),
        File('${folder.path}/second.jpg'),
      ];
      for (final file in files) await file.writeAsString('original');
      var kind = 'text';
      final exports = <Map>[];
      messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
        if (call.method == 'readClipboard')
          return kind == 'text'
              ? {
                  'texts': ['first', 'second'],
                }
              : {'paths': files.map((f) => f.path).toList()};
        if (call.method == 'dragOut') {
          exports.add(call.arguments as Map);
          return kind != 'text';
        }
        return null;
      });
      expect(await c.dragClipboard(pointerKind: 'mouse'), isFalse);
      expect(exports.last['text'], 'first\nsecond');
      kind = 'files';
      expect(await c.dragClipboard(pointerKind: 'touch'), isTrue);
      expect(exports.last['paths'], files.map((f) => f.path).toList());
      expect(exports.last['pointerKind'], 'touch');
      expect(c.stagedFiles, isEmpty);
      expect(c.stagedTexts, isEmpty);
      expect(c.dock, isEmpty);
      for (final file in files) expect(await file.readAsString(), 'original');
    },
  );
  test('bitmap snapshots survive accepted drops, preserve referenced drafts, and clean canceled or superseded copies', () async {
    final generated = <String>[];
    var accepted = true;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'readClipboard') {
        final path = ((call.arguments as Map)['bitmapPath'] as String)
            .replaceAll('.bmp', '.png');
        await File(path).writeAsBytes([1, 2, 3]);
        generated.add(path);
        return {
          'paths': [path],
          'temporaryPaths': [path],
        };
      }
      if (call.method == 'dragOut') return accepted;
      return null;
    });
    expect(await c.dragClipboard(), isTrue);
    expect(await File(generated[0]).exists(), isTrue);
    c.stagedFiles.add(generated[0]);
    expect(await c.dragClipboard(), isTrue);
    expect(await File(generated[0]).exists(), isTrue);
    c.stagedFiles.clear();
    accepted = false;
    expect(await c.dragClipboard(), isFalse);
    for (final path in generated) expect(await File(path).exists(), isFalse);
  });
  test('empty clipboard has no drag and failed export removes only its generated bitmap', () async {
    var empty = true;
    String? generated;
    var exports = 0;
    messenger.setMockMethodCallHandler(SystemBridge.channel, (call) async {
      if (call.method == 'readClipboard') {
        if (empty) return <String, Object>{};
        generated = (call.arguments as Map)['bitmapPath'] as String;
        await File(generated!).writeAsBytes([1]);
        return {
          'paths': [generated!],
          'temporaryPaths': [generated!],
        };
      }
      if (call.method == 'dragOut') {
        exports++;
        throw PlatformException(code: 'fixture');
      }
      return null;
    });
    expect(await c.dragClipboard(), isFalse);
    expect(exports, 0);
    empty = false;
    await expectLater(c.dragClipboard(), throwsA(isA<PlatformException>()));
    expect(await File(generated!).exists(), isFalse);
    expect(c.stagedFiles, isEmpty);
  });
}
