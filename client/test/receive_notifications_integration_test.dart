import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/receive_notifications.dart';
import 'package:globalsend/receive_destination.dart';
import 'package:globalsend/vault.dart';
import 'package:globalsend/background_receive.dart';

class RecordingBackground extends BackgroundReceive {
  RecordingBackground() : super(onChanged: () {});
  final sessions = <Map<String, bool>>[];
  @override
  bool get supported => true;
  @override
  Future<void> initialize() async {}
  @override
  void ready() {}
  @override
  Future<void> setEnabled(bool value) async {
    enabled = value;
  }

  @override
  void update({
    required bool authenticated,
    required bool connected,
    required bool transferring,
  }) {
    sessions.add({
      'authenticated': authenticated,
      'connected': connected,
      'transferring': transferring,
    });
  }

  @override
  void dispose() {}
}

class NotificationTestVault extends PlatformVault {
  final values = <String, String>{};
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<String?> read({required String key}) async => values[key];
}

class RecordingNotifications extends ReceivedNotifications {
  final messages = <Map<String, dynamic>>[];
  String scope = '';
  int clears = 0;
  @override
  bool get supported => true;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> status() async => true;
  @override
  Future<bool> permission({bool explicit = false}) async => true;
  @override
  Future<void> setScope(String value) async {
    scope = value;
  }

  @override
  Future<void> clear() async {
    scope = '';
    clears++;
  }

  @override
  Future<void> show({
    required String scope,
    required String conversation,
    required String itemId,
    required String version,
    required String sourceName,
    String? text,
    String? fileName,
    String? localPath,
    int? size,
    bool updated = false,
    String target = 'receive',
  }) async {
    messages.add({
      'scope': scope,
      'conversation': conversation,
      'itemId': itemId,
      'version': version,
      'sourceName': sourceName,
      'text': text,
      'fileName': fileName,
      'localPath': localPath,
      'size': size,
      'updated': updated,
      'target': target,
    });
  }

  @override
  void dispose() {}
}

Future<void> until(
  bool Function() condition, [
  Future<void> Function()? refresh,
]) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 10)) {
      throw StateError('Notification event did not arrive');
    }
    if (refresh != null) await refresh();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('messages and files notify; collaborative edits stay silent across reconnect', () async {
    final root = await Directory('build/test-tmp').create(recursive: true);
    final work = await root.createTemp('received-notifications-');
    ReceiveDestination.registryDirectoryForTesting = () async =>
        Directory('${work.path}/registry');
    final process = await Process.start('node', [
      'tool/start_test_center.mjs',
      work.absolute.path,
    ]);
    final log = File('${work.path}/center.log').openWrite();
    final errors = process.stderr.listen(log.add);
    final controllers = <SendController>[];
    final outputs = <RecordingNotifications>[];
    final receiverBackground = RecordingBackground();
    try {
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final base = jsonDecode(line)['url'] as String;
      for (var index = 0; index < 2; index++) {
        final api = CenterApi(base);
        final info = await api.call('GET', '/info', null, false);
        final session = await api.call('POST', '/devices/enroll', {
          'name': index == 0 ? '电脑' : '手机',
          'platform': 'other',
          'groupKey': 'notification-group-password',
        }, false);
        api.token = session['deviceToken'];
        final output = RecordingNotifications();
        outputs.add(output);
        final state = Directory('${work.path}/state-$index');
        await state.create();
        final controller =
            SendController(
                receivedNotifications: output,
                vault: NotificationTestVault(),
                backgroundReceive: index == 1 ? receiverBackground : null,
                stateDirectory: () async => state,
                documentsDirectory: () async =>
                    Directory('${work.path}/files-$index'),
              )
              ..api = api
              ..info = info
              ..root = state
              ..profile = ServerProfile(
                baseUrl: base,
                instanceId: info['instanceId'],
                deviceId: session['device']['deviceId'],
                groupId: session['groupId'],
                autoReceive: false,
              );
        controllers.add(controller);
        controller.profiles.add(controller.profile!);
        await controller.vault.write(
          key: 'token_${controller.profile!.key}',
          value: api.token,
        );
        await controller.openSocket(controller.generation);
        await controller.sharedDocument.refresh();
      }
      final sender = controllers[0],
          receiver = controllers[1],
          sentNotices = outputs[0],
          receivedNotices = outputs[1];
      final target = receiver.profile!.deviceId;
      stdout.writeln(
        'Scopes configured: ${outputs.map((value) => value.scope.isNotEmpty).toList()}',
      );
      await sender.sendText(target, '收到后通知');
      await until(
        () => receivedNotices.messages.any((m) => m['text'] == '收到后通知'),
      );
      expect(sentNotices.messages, isEmpty);
      stdout.writeln('New text notice received');
      final received = receiver.dock.singleWhere(
        (item) => item.text == '收到后通知',
      );
      await until(() => sender.dock.any((item) => item.text == '收到后通知'));
      final outgoing = sender.dock.singleWhere((item) => item.text == '收到后通知');
      await sender.editSentText(outgoing, '修改后的完整正文');
      await until(
        () => receivedNotices.messages.any((m) => m['text'] == '修改后的完整正文'),
      );
      final editNotice = receivedNotices.messages.last;
      stdout.writeln('Edited text notice received');
      expect(editNotice['itemId'], received.id);
      expect(editNotice['updated'], isTrue);
      receivedNotices.onDismiss?.call({
        'versions': {received.id: 'stale-version'},
        'arrivalGeneration': 1,
      });
      expect(receiver.pendingReceipts.containsKey(received.id), isTrue);
      expect(receiver.nativeDismissedReceiptIds, isNot(contains(received.id)));
      receivedNotices.onDismiss?.call({
        'versions': {received.id: editNotice['version']},
        'arrivalGeneration': 2,
      });
      expect(receiver.pendingReceipts.containsKey(received.id), isFalse);
      expect(receiver.nativeDismissedReceiptIds, contains(received.id));
      expect(receiver.latestReceipt, isNull);
      expect(sentNotices.messages, isEmpty);
      final beforeReplay = receivedNotices.messages.length;
      await receiver.reconcile();
      await receiver.notificationIdle;
      expect(receivedNotices.messages.length, beforeReplay);

      await sender.api!.call('POST', '/texts', {
        'eventId': newId(),
        'targetDeviceId': target,
        'text': '新同步的剪贴板文本',
        'clipboard': {},
      });
      await until(
        () => receivedNotices.messages.any((m) => m['text'] == '新同步的剪贴板文本'),
      );
      stdout.writeln('Clipboard text notice received');

      final sharedNoticeCount = receivedNotices.messages.length;
      final receiptCount = receiver.receiptSerial;
      sender.setSharedTextDraft('远端共享更新');
      await sender.sharedDocument.save();
      await until(() => receiver.sharedText == '远端共享更新');
      await receiver.notificationIdle;
      expect(receivedNotices.messages.length, sharedNoticeCount);
      expect(receiver.receiptSerial, receiptCount);
      stdout.writeln('Shared text applied silently');
      expect(sentNotices.messages, isEmpty);
      final count = receivedNotices.messages.length;
      await receiver.sharedDocument.refresh();
      await receiver.notificationIdle;
      expect(receivedNotices.messages.length, count);

      await receiver.socket!.close();
      await until(() => !receiver.connected);
      receiver.reconnect?.cancel();
      sender.setSharedTextDraft('离线期间的共享修改');
      await sender.sharedDocument.save();
      await receiver.openSocket(receiver.generation);
      await until(() => receiver.sharedText == '离线期间的共享修改');
      await receiver.notificationIdle;
      expect(receivedNotices.messages.length, sharedNoticeCount);
      expect(receiver.receiptSerial, receiptCount);
      expect(sentNotices.messages, isEmpty);

      // Replacing a live socket must not let the old onDone mark the new one offline.
      final oldSocket = receiver.socket!;
      await receiver.openSocket(receiver.generation);
      expect(receiver.socket, isNot(same(oldSocket)));
      await oldSocket.done;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(receiver.connected, isTrue);
      expect(receiver.reconnect?.isActive, isNot(true));

      final file = File('${work.path}/测试文件.txt');
      await file.writeAsString('实际收到文件之后提醒');
      await sender.offer(target, [file.path], routePreferenceOverride: 'relay');
      await until(
        () => receivedNotices.messages.any(
          (m) => m['fileName'] == '待接收 · 测试文件.txt',
        ),
        () => receiver.reconcile(),
      );
      final item = receiver.dock.singleWhere(
        (item) => item.title == '测试文件.txt',
      );
      await receiver.acceptSelected(item, [item.fileId]);
      await until(() => item.status == 'received', () async {
        await sender.reconcile();
        await receiver.reconcile();
      });
      await receiver.notificationIdle;
      final completed = receivedNotices.messages
          .where((m) => m['fileName'] == '测试文件.txt')
          .toList();
      expect(completed.length, 1);
      expect(completed.single['text'], isNull);
      expect(completed.single['localPath'], item.localPath);
      expect(completed.single['size'], await file.length());
      expect(await File(item.localPath).readAsString(), '实际收到文件之后提醒');
      expect(sentNotices.messages, isEmpty);

      // The new background switch must not disable original foreground use.
      await receiver.setBackgroundEnabled(false);
      expect(receiver.connected, isTrue);
      receiver.setProbeForeground(false);
      expect(
        receiver.connected,
        isTrue,
        reason: 'inactive notification shade or permission dialogs do not pause foreground use',
      );
      receiver.setAppForeground(false);
      expect(receiver.connected, isFalse);
      expect(receiver.api!.token.isNotEmpty, isTrue);
      receiver.setProbeForeground(true);
      receiver.setAppForeground(true);
      await until(() => receiver.connected);
      expect(receiverBackground.enabled, isFalse);
      await receiver.setBackgroundEnabled(true);
      expect(receiverBackground.enabled, isTrue);

      receivedNotices.onOpen?.call('receive');
      expect(receiver.notificationOpenTarget, 'receive');
      expect(receiver.notificationOpenSerial, 1);
      receivedNotices.onOpen?.call('shared');
      expect(receiver.notificationOpenTarget, 'receive');
      expect(receiver.notificationOpenSerial, 1);
      final clears = receivedNotices.clears;
      await receiver.signOutLocal();
      expect(receivedNotices.clears, clears + 1);
      stdout.writeln(
        'Receipt notification event evidence: ${work.absolute.path}',
      );
    } catch (error) {
      stdout.writeln(
        'Notification diagnostics: ${jsonEncode(outputs.map((value) => value.messages).toList())}',
      );
      stdout.writeln(
        'Controller states: ${controllers.map((value) => '${value.connected}/${value.message}').toList()}',
      );
      rethrow;
    } finally {
      for (final controller in controllers) {
        controller.dispose();
      }
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await errors.cancel();
      await log.close();
      ReceiveDestination.registryDirectoryForTesting = null;
    }
  }, timeout: const Timeout(Duration(seconds: 50)));
}
