import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/dock_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'media events stage image and video once, refresh state and never send',
    () async {
      final parent = Directory('../artifacts/client/build/media-picker-dart');
      await parent.create(recursive: true);
      final root = await parent.createTemp('selection-');
      final photo = await File('${root.path}/照片.heic').writeAsBytes([1, 2, 3]);
      final video = await File('${root.path}/视频.mp4')
          .writeAsBytes([4, 5, 6, 7]);
      final paths = [photo.absolute.path, video.absolute.path];
      final controller = SendController();
      final imported = Completer<void>();
      var refreshes = 0;
      controller.addListener(() => refreshes++);
      final subscription = DockPlatform.events.listen((event) async {
        await controller.handleNativeDockEvent(event);
        if (event['type'] == 'nativeDrop' && !imported.isCompleted) {
          imported.complete();
        }
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();
      Future<void> emit(String method, Map<String, dynamic> arguments) async {
        await messenger.handlePlatformMessage(
          DockPlatform.channel.name,
          codec.encodeMethodCall(MethodCall(method, arguments)),
          null,
        );
        await Future<void>.delayed(Duration.zero);
      }

      addTearDown(() async {
        messenger.setMockMethodCallHandler(DockPlatform.channel, null);
        await subscription.cancel();
        // Dispose starts unawaited staging cleanup. Release test-owned native
        // imports through the awaited entry point before removing their folder.
        for (final path in controller.stagedFiles.toList()) {
          await controller.removeStagedFile(path);
        }
        controller.dispose();
        await root.delete(recursive: true);
      });
      final payload = {
        'dropId': 'media-picker-selection',
        'paths': paths,
        'temporaryPaths': paths,
        'texts': <String>[],
      };
      final calls = <String>[];
      messenger.setMockMethodCallHandler(DockPlatform.channel, (call) async {
        calls.add(call.method);
        if (call.method == 'pending') return [payload];
        return null;
      });

      await DockPlatform.pickMedia();
      expect(calls, ['pickMedia']);
      expect(controller.stagedFiles, isEmpty);
      await emit('nativeDrag', {'active': false, 'importing': true});
      expect(controller.nativeImporting, isTrue);
      await emit('nativeDrop', payload);
      await imported.future;
      for (final pending in await DockPlatform.pending()) {
        await controller.handleNativeDockEvent({
          'type': 'nativeDrop',
          ...pending,
        });
      }
      await emit('nativeDrag', {'active': false, 'importing': false});
      expect(controller.nativeImporting, isFalse);
      expect(controller.stagedFiles, paths);
      expect(controller.sources, isEmpty);
      expect(controller.dock, isEmpty);
      expect(refreshes, greaterThanOrEqualTo(3));
      expect(await photo.readAsBytes(), [1, 2, 3]);
      expect(await video.readAsBytes(), [4, 5, 6, 7]);
    },
  );
}
