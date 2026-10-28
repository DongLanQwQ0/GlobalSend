import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'api.dart';
import 'connection_window.dart';
import 'system_bridge.dart';

const _requestIdPattern =
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';

class UrlIntentSession {
  UrlIntentSession({
    required this.api,
    required this.scope,
    required this.deviceId,
    required this.supported,
  }) : token = api.token;
  final CenterApi api;
  final String scope, deviceId, token;
  final bool supported;
}

/// Private engine channel. Local caller identity is supplied by the approved
/// Android service, never by a request JSON field or a center credential export.
class UrlIntentNativeBridge {
  UrlIntentNativeBridge({bool? android})
    : android = android ?? Platform.isAndroid;
  static const channel = MethodChannel('dev.globalsend/integration');
  final bool android;
  bool ready = false;
  void install(
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) request,
    Future<void> Function(Map<String, dynamic>) result,
  ) {
    if (!android) return;
    channel.setMethodCallHandler((call) async {
      final data = Map<String, dynamic>.from(call.arguments as Map? ?? {});
      if (call.method == 'request') return request(data);
      if (call.method == 'urlIntentResult') {
        await result(data);
        return null;
      }
      throw MissingPluginException('Unknown integration method');
    });
  }

  Future<void> announceReady() async {
    if (android) {
      await channel.invokeMethod<void>('ready');
      ready = true;
    }
  }

  Future<Map<String, dynamic>> open(Map<String, dynamic> intent) async =>
      Map<String, dynamic>.from(
        await channel.invokeMethod<Map>('openUrlIntent', intent) ?? {},
      );
  Future<List<Map<String, dynamic>>> pendingResults() async =>
      (await channel.invokeListMethod<Map>('pendingResults') ?? [])
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
  Future<void> ackResult(Map<String, dynamic> value) =>
      channel.invokeMethod<void>('ackResult', {
        'sourceDeviceId': value['sourceDeviceId'],
        'requestId': value['requestId'],
        'resultId': value['resultId'],
      });
  Future<void> manageAssociations() =>
      channel.invokeMethod<void>('manageAssociations');
  void dispose() {
    if (android) channel.setMethodCallHandler(null);
  }
}

class _IntegrationFailure implements Exception {
  const _IntegrationFailure(this.code, this.message, {this.retryable = false});
  final String code, message;
  final bool retryable;
}

/// Explicit short-lived URL intents do not enter text/file history. The launch
/// fence is persisted before invoking the OS so a reconnect cannot open twice.
class UrlIntentIntegration {
  UrlIntentIntegration({
    required this.session,
    required this.devices,
    required this.refreshDevices,
    required this.changed,
    String? platform,
    UrlIntentNativeBridge? native,
    Future<void> Function(Uri)? openWebUrl,
    DateTime Function()? now,
  }) : platform =
           platform ??
           (Platform.isWindows
               ? 'windows'
               : Platform.isAndroid
               ? 'android'
               : 'other'),
       native = native ?? UrlIntentNativeBridge(),
       openWebUrl = openWebUrl ?? SystemBridge.openWebUrl,
       now = now ?? DateTime.now;
  final UrlIntentSession? Function() session;
  final List<Map<String, dynamic>> Function() devices;
  final Future<void> Function() refreshDevices;
  final void Function() changed;
  final String platform;
  final UrlIntentNativeBridge native;
  final Future<void> Function(Uri) openWebUrl;
  final DateTime Function() now;
  final Map<String, Map<String, dynamic>> _records = {};
  final Completer<void> _initialized = Completer<void>();
  File? _file;
  Future<void> _writes = Future.value();
  Future<void> _receiverWork = Future.value();
  Future<void>? _syncWork;
  bool _again = false, _disposed = false, _loadFailed = false;
  String lastError = '';
  bool get supported =>
      !_loadFailed &&
      (platform == 'windows' || platform == 'android' && native.ready);

  Future<void> initialize(File file) async {
    if (_file != null) return _initialized.future;
    _file = file;
    native.install(handleLocalRequest, acceptNativeResult);
    try {
      if (await file.exists()) {
        final stored = jsonDecode(await file.readAsString()) as Map;
        for (final entry in Map<String, dynamic>.from(
          stored['records'] as Map? ?? {},
        ).entries) {
          _records[entry.key] = Map<String, dynamic>.from(entry.value as Map);
        }
      }
    } catch (_) {
      _loadFailed = true;
      lastError = '网页打开记录暂不可读';
    } finally {
      if (!_initialized.isCompleted) _initialized.complete();
    }
    try {
      await native.announceReady();
    } catch (_) {
      lastError = '本机集成需要匹配的 Android 客户端';
    }
    changed();
  }

  bool _current(UrlIntentSession value) {
    final active = session();
    return !_disposed &&
        active != null &&
        active.scope == value.scope &&
        active.deviceId == value.deviceId &&
        identical(active.api, value.api) &&
        active.token == value.token;
  }

  String _key(UrlIntentSession value, String source, String id) =>
      '${value.scope}\n$source\n$id';
  void _check(UrlIntentSession value) {
    if (!_current(value))
      throw const _IntegrationFailure(
        'not_connected',
        'GlobalSend 连接已切换',
        retryable: true,
      );
  }

  Future<Map<String, dynamic>> _call(
    UrlIntentSession value,
    String method,
    String path, [
    Object? body,
  ]) async {
    _check(value);
    final result = await ConnectionWindow(const Duration(milliseconds: 4200))
        .run(() => value.api.call(method, path, body));
    _check(value);
    return result;
  }

  Future<void> _save() {
    if (_loadFailed || _file == null)
      throw const _IntegrationFailure('local_state_unavailable', '网页打开记录暂不可写');
    final encoded = jsonEncode({'records': _records});
    final file = _file!;
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsString(encoded, flush: true);
      await partial.rename(file.path);
    });
  }

  Map<String, dynamic> _success(String id, Map<String, dynamic> result) => {
    'v': 1,
    'requestId': id,
    'ok': true,
    'result': result,
  };
  Map<String, dynamic> _failure(
    String id,
    String code,
    String message, [
    bool retryable = false,
  ]) => {
    'v': 1,
    'requestId': id,
    'ok': false,
    'error': {'code': code, 'message': message, 'retryable': retryable},
  };
  static Uri? validUrl(Object? value) {
    if (value is! String || value.length > 4096) return null;
    final uri = Uri.tryParse(value);
    return uri != null &&
            ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  Future<Map<String, dynamic>> handleLocalRequest(
    Map<String, dynamic> call,
  ) async {
    var id = '';
    try {
      if (call['request'] is! Map || call['callerAppId'] is! String)
        return _failure(id, 'invalid_request', '无效的本机请求');
      final request = Map<String, dynamic>.from(call['request'] as Map);
      id = request['requestId'] is String ? request['requestId'] as String : '';
      final caller = call['callerAppId'] as String;
      await _initialized.future;
      if (caller.isEmpty)
        throw const _IntegrationFailure('caller_not_allowed', '未授权的本机调用');
      if (request['v'] != 1)
        throw const _IntegrationFailure('unsupported_version', '不支持此集成协议');
      if (!RegExp(_requestIdPattern).hasMatch(id))
        throw const _IntegrationFailure(
          'invalid_request',
          'requestId 必须是 UUID',
        );
      if (request['method'] == 'hello') {
        return _success(id, {
          'protocolVersion': 1,
          'appVersion': '',
          'connected': session() != null,
          'associationState': 'authorized',
          'capabilities': ['list_devices', 'send_open_url'],
        });
      }
      final active = session();
      if (active == null)
        throw const _IntegrationFailure(
          'not_connected',
          'GlobalSend 尚未连接',
          retryable: true,
        );
      if (request['method'] == 'list_devices') {
        if (request['refresh'] == true)
          await refreshDevices().timeout(const Duration(milliseconds: 3500));
        _check(active);
        return _success(id, {
          'devices': devices()
              .where(
                (d) => d['deviceId'] != active.deviceId && d['revoked'] != true,
              )
              .map(
                (d) => {
                  'deviceId': d['deviceId'],
                  'name': d['name'],
                  'platform': d['platform'],
                  'online': d['online'] == true,
                  'sendable': true,
                  'capabilities': {
                    'openUrlIntentV1': d['openUrlIntentV1'] == true,
                  },
                },
              )
              .toList(),
          'updatedAt': now().toUtc().toIso8601String(),
        });
      }
      if (!active.supported)
        throw const _IntegrationFailure('unsupported_version', '中心尚不支持定向打开网页');
      if (request['method'] == 'send_open_url') {
        final target = request['targetDeviceId'];
        if (target is! String || target == active.deviceId)
          throw const _IntegrationFailure('target_unavailable', '请选择其它设备');
        final peer = devices()
            .where(
              (device) =>
                  device['deviceId'] == target && device['revoked'] != true,
            )
            .firstOrNull;
        if (peer == null)
          throw const _IntegrationFailure(
            'target_unavailable',
            '目标设备暂不可用',
            retryable: true,
          );
        if (peer['openUrlIntentV1'] != true)
          throw const _IntegrationFailure('unsupported_target', '目标设备尚不支持打开网页');
        final uri = validUrl(request['url']);
        if (uri == null)
          throw const _IntegrationFailure(
            'invalid_url',
            '请输入有效的 HTTP 或 HTTPS 地址',
          );
        final duration = request['expiresInMs'] ?? 120000;
        if (duration is! int || duration <= 0 || duration > 120000)
          throw const _IntegrationFailure('invalid_request', '网页请求最长保留 120 秒');
        final receivedAt = call['receivedAtMillis'];
        final elapsed = receivedAt is int
            ? (now().millisecondsSinceEpoch - receivedAt).clamp(0, 120000)
            : 0;
        final remaining = duration - elapsed;
        if (remaining <= 0) {
          final timestamp = now().toUtc().toIso8601String();
          return _success(id, {
            'requestId': id,
            'targetDeviceId': target,
            'state': 'expired',
            'createdAt': timestamp,
            'expiresAt': timestamp,
            'updatedAt': timestamp,
          });
        }
        // Caller identity is injected from the native service, not request JSON.
        final result = await _call(active, 'POST', '/url-intents', {
          'requestId': id,
          'targetDeviceId': target,
          'url': uri.toString(),
          'expiresInMs': remaining,
          'callerAppId': caller,
        });
        if (result['callerAppId'] != null && result['callerAppId'] != caller)
          throw const _IntegrationFailure('conflict', 'requestId 已用于另一次请求');
        return _success(id, _publicStatus(result));
      }
      if (request['method'] == 'status') {
        final result = await _call(active, 'GET', '/url-intents/$id');
        if (result['callerAppId'] != caller ||
            result['sourceDeviceId'] != active.deviceId) {
          throw const _IntegrationFailure('request_not_found', '未找到本应用的请求');
        }
        return _success(id, _publicStatus(result));
      }
      throw const _IntegrationFailure('invalid_request', '未知的集成方法');
    } on _IntegrationFailure catch (error) {
      return _failure(id, error.code, error.message, error.retryable);
    } on ApiException catch (error) {
      if (error.status >= 500)
        return _failure(
          id,
          'timeout_unknown',
          '中心结果尚未确认，请使用原 requestId 查询',
          true,
        );
      final remote = error.response?['error'];
      final code = remote is Map
          ? (remote['code'] as String? ?? '').toLowerCase()
          : '';
      return _failure(
        id,
        code.isEmpty ? 'request_failed' : code,
        error.message,
        error.status >= 500,
      );
    } on TimeoutException {
      return _failure(
        id,
        'timeout_unknown',
        '请求结果尚未确认，请使用原 requestId 查询',
        true,
      );
    } on SocketException {
      return _failure(id, 'timeout_unknown', '网络暂不可用，请使用原 requestId 查询', true);
    } on HttpException {
      return _failure(id, 'timeout_unknown', '连接已中断，请使用原 requestId 查询', true);
    } catch (_) {
      return _failure(id, 'request_failed', '暂时无法完成本机请求', true);
    }
  }

  Map<String, dynamic> _publicStatus(Map<String, dynamic> value) => {
    for (final field in [
      'requestId',
      'targetDeviceId',
      'state',
      'createdAt',
      'expiresAt',
      'updatedAt',
      'error',
    ])
      if (value.containsKey(field)) field: value[field],
  };

  Future<void> synchronize() {
    if (_syncWork != null) {
      _again = true;
      return _syncWork!;
    }
    if (!_initialized.isCompleted || _disposed || !supported)
      return Future.value();
    return _syncWork = _serial(() async {
      do {
        _again = false;
        await _synchronize();
      } while (_again && !_disposed);
    }).whenComplete(() => _syncWork = null);
  }

  Future<void> _serial(Future<void> Function() work) {
    final next = _receiverWork.catchError((Object _) {}).then((_) => work());
    _receiverWork = next;
    return next;
  }

  Future<void> _synchronize() async {
    final active = session();
    if (active == null || !active.supported) return;
    try {
      if (native.android) {
        for (final result in await native.pendingResults()) {
          if (!_current(active)) return;
          await _acceptNativeResult(active, result);
        }
      }
      for (final record in _records.values.toList()) {
        if (!_current(active)) return;
        if (record['scope'] != active.scope) continue;
        if (record['stage'] == 'launching') {
          await _finish(
            active,
            record,
            _expired(record) ? 'expired' : 'needs_tap',
            error: {'code': 'interrupted', 'message': '上次打开结果未确认，请手动打开'},
          );
        } else if (record['resultPending'] == true) {
          await _flush(active, record);
        } else if (record['state'] == 'needs_tap' && _expired(record)) {
          await _finish(active, record, 'expired');
        }
      }
      final pending = await _call(active, 'GET', '/url-intents/pending');
      for (final raw in pending['intents'] as List? ?? []) {
        if (!_current(active)) return;
        await _receive(active, Map<String, dynamic>.from(raw as Map));
      }
      lastError = '';
    } catch (_) {
      if (_current(active)) {
        lastError = '网页请求等待重新同步';
        changed();
      }
    }
  }

  Future<void> _receive(
    UrlIntentSession active,
    Map<String, dynamic> intent,
  ) async {
    final source = intent['sourceDeviceId'] as String?,
        id = intent['requestId'] as String?;
    if (source == null ||
        id == null ||
        !RegExp(_requestIdPattern).hasMatch(id) ||
        intent['targetDeviceId'] != active.deviceId)
      return;
    final key = _key(active, source, id);
    var record = _records[key];
    if (record == null) {
      record = {
        ...intent,
        'scope': active.scope,
        'stage': 'received',
        'resultPending': false,
      };
      _records[key] = record;
      await _save();
    }
    if (record['stage'] == 'finished') {
      if (record['resultPending'] == true) await _flush(active, record);
      return;
    }
    if (_expired(record)) {
      await _finish(active, record, 'expired');
      return;
    }
    if (record['stage'] == 'launching') {
      // A crash may have happened after the OS accepted the request but before
      // its result was saved. Ask for a tap instead of invoking the OS twice.
      await _finish(
        active,
        record,
        'needs_tap',
        error: {'code': 'interrupted', 'message': '上次打开结果未确认，请手动打开'},
      );
      return;
    }
    if (validUrl(record['url']) == null) {
      await _finish(
        active,
        record,
        'failed',
        error: {'code': 'invalid_url', 'message': '无效的网址'},
      );
      return;
    }
    final delivered = await _call(active, 'POST', '/url-intents/$id/result', {
      'sourceDeviceId': source,
      'state': 'delivered',
    });
    if (delivered['state'] != 'delivered') {
      await _finish(active, record, delivered['state'] as String? ?? 'expired');
      return;
    }
    if (_expired(record)) {
      await _finish(active, record, 'expired');
      return;
    }
    record['stage'] = 'launching';
    await _save();
    _check(active);
    await _launch(active, record);
  }

  bool _expired(Map<String, dynamic> record) {
    final expiry = DateTime.tryParse(record['expiresAt'] as String? ?? '');
    return expiry == null || !now().isBefore(expiry);
  }

  Future<void> _launch(
    UrlIntentSession active,
    Map<String, dynamic> record,
  ) async {
    String state;
    Map<String, dynamic>? error;
    try {
      if (native.android) {
        final outcome = await native.open({
          for (final field in [
            'requestId',
            'sourceDeviceId',
            'url',
            'expiresAt',
            'callerAppId',
          ])
            field: record[field],
        });
        _check(active);
        if (![
          'launch_accepted',
          'needs_tap',
          'failed',
          'expired',
        ].contains(outcome['state']))
          throw StateError('Invalid native launch result');
        state = outcome['state'] as String;
        error = outcome['error'] is Map
            ? Map<String, dynamic>.from(outcome['error'] as Map)
            : null;
        record['nativeReceipt'] = {
          ...outcome,
          'requestId': record['requestId'],
          'sourceDeviceId': record['sourceDeviceId'],
        };
      } else {
        await openWebUrl(validUrl(record['url'])!);
        _check(active);
        state = 'launch_accepted';
      }
    } on _IntegrationFailure {
      rethrow;
    } catch (_) {
      state = 'failed';
      error = {'code': 'launch_failed', 'message': '系统未能打开浏览器'};
    }
    // A failed center ACK must not rewrite a successful system launch as failed.
    await _finish(active, record, state, error: error);
  }

  Future<void> _finish(
    UrlIntentSession active,
    Map<String, dynamic> record,
    String state, {
    Map<String, dynamic>? error,
  }) async {
    record['stage'] = 'finished';
    record['state'] = state;
    record['resultPending'] = true;
    if (error == null)
      record.remove('error');
    else
      record['error'] = error;
    if (state != 'needs_tap') record.remove('url');
    await _save();
    changed();
    await _flush(active, record);
  }

  Future<void> _flush(
    UrlIntentSession active,
    Map<String, dynamic> record,
  ) async {
    final response = await _call(
      active,
      'POST',
      '/url-intents/${record['requestId']}/result',
      {
        'sourceDeviceId': record['sourceDeviceId'],
        'state': record['state'],
        if (record['error'] != null) 'error': record['error'],
      },
    );
    record['state'] = response['state'] ?? record['state'];
    record['resultPending'] = false;
    if (record['state'] != 'needs_tap') record.remove('url');
    await _save();
    changed();
    final receipt = record['nativeReceipt'];
    if (native.android && receipt is Map) {
      await native.ackResult(Map<String, dynamic>.from(receipt));
      record.remove('nativeReceipt');
      await _save();
    }
  }

  Future<void> acceptNativeResult(Map<String, dynamic> result) async {
    await _initialized.future;
    final active = session();
    if (active == null || !active.supported) return;
    try {
      await _serial(() async {
        if (_current(active)) await _acceptNativeResult(active, result);
      });
    } catch (_) {
      if (_current(active)) {
        lastError = '网页打开结果等待重新同步';
        changed();
      }
    }
  }

  Future<void> _acceptNativeResult(
    UrlIntentSession active,
    Map<String, dynamic> result,
  ) async {
    final source = result['sourceDeviceId'],
        id = result['requestId'],
        state = result['state'];
    if (source is! String ||
        id is! String ||
        !['launch_accepted', 'needs_tap', 'failed', 'expired'].contains(state))
      return;
    final record = _records[_key(active, source, id)];
    if (record == null) return; // A receipt for another center/account is not ours to acknowledge.
    // Never regress a confirmed launch when an older notification callback arrives.
    if (record['state'] == 'launch_accepted' && state != 'launch_accepted') {
      await native.ackResult(result);
      return;
    }
    record['nativeReceipt'] = result;
    await _finish(
      active,
      record,
      state as String,
      error: result['error'] is Map
          ? Map<String, dynamic>.from(result['error'] as Map)
          : null,
    );
  }

  List<Map<String, dynamic>> get needsAttention {
    final active = session();
    if (!['windows', 'android'].contains(platform) || active == null) return [];
    return _records.values
        .where(
          (item) =>
              item['scope'] == active.scope &&
              item['stage'] == 'finished' &&
              item['state'] == 'needs_tap' &&
              (platform == 'windows' ||
                  item['error']?['code'] == 'interrupted') &&
              !_expired(item),
        )
        .toList();
  }

  Future<void> openManually(Map<String, dynamic> record) => _serial(() async {
    final active = session();
    if (active == null ||
        record['scope'] != active.scope ||
        record['state'] != 'needs_tap')
      return;
    try {
      if (_expired(record)) {
        await _finish(active, record, 'expired');
        return;
      }
      record['stage'] = 'launching';
      await _save();
      _check(active);
      await _launch(active, record);
    } catch (_) {
      lastError = '网页请求等待重新同步';
      changed();
    }
  });
  Future<void> dismiss(Map<String, dynamic> record) => _serial(() async {
    final active = session();
    if (active == null || record['scope'] != active.scope) return;
    try {
      await _finish(
        active,
        record,
        'failed',
        error: {'code': 'user_dismissed', 'message': '用户已关闭打开请求'},
      );
    } catch (_) {
      lastError = '网页请求等待重新同步';
      changed();
    }
  });
  void dispose() {
    _disposed = true;
    native.dispose();
  }
}
