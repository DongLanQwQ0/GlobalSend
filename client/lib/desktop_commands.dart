import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

typedef CommandAccepted = void Function(String kind, String id);

/// Commands operate on the running controller, never its visible draft queue.
class DesktopCommands {
  DesktopCommands({
    required this.snapshot,
    required this.devices,
    required this.refresh,
    required this.send,
  });
  final Map<String, dynamic> Function() snapshot;
  final List<Map<String, dynamic>> Function() devices;
  final Future<void> Function() refresh;
  final Future<void> Function(
    String target,
    List<String> paths,
    String? text,
    CommandAccepted accepted,
  )
  send;
  static const channel = MethodChannel('dev.globalsend/commands');
  final _jobs = <String, _CommandJob>{};
  final _waiters = <String, List<Completer<void>>>{};
  int _serial = 0;
  bool _closed = false;
  bool _started = false;

  Future<void> start() async {
    if (!Platform.isWindows) return;
    _started = true;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'request') throw MissingPluginException();
      return handleJson(call.arguments as String);
    });
    await channel.invokeMethod<void>('ready');
  }

  Future<Map<String, Object>> handleJson(String input) async {
    var json = false;
    try {
      final value = jsonDecode(input);
      if (value is! Map) throw const FormatException('命令需要JSON对象');
      final request = Map<String, dynamic>.from(value);
      json = request['json'] == true;
      final data = await execute(request);
      final failed = data['state'] == 'failed';
      return {
        'exitCode': failed ? 1 : 0,
        'output': json
            ? jsonEncode({'ok': !failed, 'data': data})
            : _text(data),
      };
    } on FormatException catch (error) {
      return _error(2, error.message, json);
    } on TimeoutException {
      return _error(3, '等待收件确认超时，传输仍可继续；使用status查询，不要重复发送', json);
    } catch (error) {
      return _error(1, error.toString(), json);
    }
  }

  Map<String, Object> _error(int code, String message, bool json) => {
    'exitCode': code,
    'output': json
        ? jsonEncode({'ok': false, 'error': message})
        : 'GlobalSend: $message',
  };

  Future<Map<String, dynamic>> execute(Map<String, dynamic> request) async {
    if (_closed) throw StateError('客户端正在退出');
    switch (request['command']) {
      case 'devices':
        if (request['refresh'] == true) await refresh();
        return {
          'command': 'devices',
          'connected': snapshot()['connected'],
          'devices': [
            for (final device in devices())
              {
                'deviceId': device['deviceId'],
                'name': device['name'],
                'platform': device['platform'],
                'online': device['online'] == true,
              },
          ],
        };
      case 'status':
        final id = request['id'] as String? ?? '';
        if (id.isEmpty) {
          return {
            'command': 'status',
            ...snapshot(),
            'jobs': [for (final job in _jobs.values) _jobSnapshot(job)],
          };
        }
        final job = _jobs[id];
        if (job != null) return _jobSnapshot(job);
        final state = snapshot();
        final entries = (state['entries'] as List)
            .where(
              (dynamic entry) => entry['id'] == id || entry['transferId'] == id,
            )
            .toList();
        if (entries.isEmpty) throw StateError('没有找到任务或传输：$id');
        return {'command': 'status', 'id': id, 'entries': entries};
      case 'send':
        if (snapshot()['connected'] != true) throw StateError('客户端尚未连接中心');
        final target = request['deviceId'] as String? ?? '';
        if (target.isEmpty) throw const FormatException('必须通过--device指定设备ID');
        if (!devices().any((device) => device['deviceId'] == target)) {
          throw StateError('目标设备不可用；运行devices查看设备ID');
        }
        final paths = List<String>.from(request['paths'] as List? ?? const []);
        final text = request['text'] as String?;
        if ((text == null || text.trim().isEmpty) && paths.isEmpty) {
          throw const FormatException('没有待发送的文本或文件');
        }
        if (text != null && text.length > 100000) {
          throw const FormatException('文本超过100000字符');
        }
        // Validate the whole batch before sending even its first text. Paths
        // come from the CLI process's working directory, already made absolute.
        for (final path in paths) {
          if (!File(path).isAbsolute ||
              await FileSystemEntity.type(path) ==
                  FileSystemEntityType.notFound) {
            throw FormatException('文件或文件夹不存在：$path');
          }
        }
        final id = 'cli-${DateTime.now().microsecondsSinceEpoch}-${++_serial}';
        final job = _CommandJob(id, target);
        _jobs[id] = job;
        unawaited(_submit(job, paths, text));
        if (request['wait'] == true) {
          final waiter = Completer<void>();
          (_waiters[id] ??= []).add(waiter);
          notifyChanged();
          final millis = (request['timeoutMs'] as num?)?.toInt() ?? 60000;
          try {
            await waiter.future.timeout(Duration(milliseconds: millis));
          } finally {
            _waiters[id]?.remove(waiter);
            if (_waiters[id]?.isEmpty ?? false) _waiters.remove(id);
          }
        }
        return _jobSnapshot(job);
      default:
        throw const FormatException('未知命令');
    }
  }

  Future<void> _submit(
    _CommandJob job,
    List<String> paths,
    String? text,
  ) async {
    try {
      await send(job.target, paths, text, (kind, id) {
        (kind == 'text' ? job.texts : job.transfers).add(id);
      });
      job.submitted = true;
    } catch (error) {
      job.error = error.toString();
    }
    notifyChanged();
  }

  Map<String, dynamic> _jobSnapshot(_CommandJob job) {
    final state = snapshot();
    final entries = (state['entries'] as List? ?? const [])
        .where(
          (dynamic entry) =>
              job.texts.contains(entry['id']) ||
              job.transfers.contains(entry['transferId']),
        )
        .toList();
    var phase = job.submitted ? 'waiting' : 'preparing';
    if (job.error.isNotEmpty ||
        entries.any(
          (dynamic entry) => [
            'failed',
            'rejected',
            'canceled',
            'expired',
          ].contains(entry['status']),
        )) {
      phase = 'failed';
    } else if (job.submitted &&
        job.texts.every((id) => entries.any((dynamic e) => e['id'] == id)) &&
        job.transfers.every(
          (id) => entries.any((dynamic e) => e['transferId'] == id),
        ) &&
        entries.isNotEmpty &&
        entries.every((dynamic entry) => entry['status'] == 'received')) {
      phase = 'received';
    }
    return {
      'command': 'send',
      'requestId': job.id,
      'deviceId': job.target,
      'state': phase,
      'textIds': job.texts,
      'transferIds': job.transfers,
      'entries': entries,
      if (job.error.isNotEmpty) 'error': job.error,
    };
  }

  void notifyChanged() {
    for (final entry in _waiters.entries.toList()) {
      final phase = _jobSnapshot(_jobs[entry.key]!)['state'];
      if (phase != 'received' && phase != 'failed') continue;
      for (final waiter in entry.value.toList()) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  String _text(Map<String, dynamic> data) {
    if (data['command'] == 'devices') {
      final list = data['devices'] as List;
      if (list.isEmpty) return data['connected'] == true ? '没有可发送设备' : '尚未连接中心';
      return list
          .map(
            (dynamic d) =>
                '${d['deviceId']}\t${d['platform']}\t${d['name']}\t${d['online'] == true ? '在线' : '离线保留'}',
          )
          .join('\n');
    }
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  void dispose() {
    _closed = true;
    if (_started) channel.setMethodCallHandler(null);
    for (final waiters in _waiters.values) {
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.completeError(StateError('客户端正在退出'));
      }
    }
    _waiters.clear();
  }
}

class _CommandJob {
  _CommandJob(this.id, this.target);
  final String id, target;
  final texts = <String>[], transfers = <String>[];
  bool submitted = false;
  String error = '';
}
