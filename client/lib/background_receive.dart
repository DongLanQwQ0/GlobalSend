import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Android's user-controlled foreground receive runtime. This owns no UI and
/// never reads or changes global device network or battery settings.
class BackgroundReceive {
  BackgroundReceive({required this.onChanged, this.onStopRequested});
  static const channel = MethodChannel('dev.globalsend/background-receive');
  final void Function() onChanged;
  final Future<void> Function()? onStopRequested;
  bool get supported => Platform.isAndroid;
  bool enabled = true, running = false, batteryUnrestricted = false;
  String status = '';
  int engineId = 0, engineCreatedAt = 0;
  bool _initialized = false, _ready = false, _sending = false;
  String _lastSent = '', _nativeState = '';
  Map<String, bool> _session = {
    'authenticated': false,
    'connected': false,
    'transferring': false,
  };

  Future<void> initialize() async {
    if (!supported || _initialized) return;
    _initialized = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'state') {
        _apply(Map<String, dynamic>.from(call.arguments));
      }
      if (call.method == 'pause') {
        enabled = false;
        await onStopRequested?.call();
      }
    });
    _apply(
      Map<String, dynamic>.from(
        await channel.invokeMethod<Map>('status') ?? {},
      ),
    );
  }

  void ready() {
    _ready = true;
    unawaited(_send());
  }

  void update({
    required bool authenticated,
    required bool connected,
    required bool transferring,
  }) {
    if (!supported) return;
    _session = {
      'authenticated': authenticated,
      'connected': connected,
      'transferring': transferring,
    };
    if (_ready) unawaited(_send());
  }

  String get _signature =>
      '${_session['authenticated']}/${_session['connected']}/${_session['transferring']}';
  Future<void> _send() async {
    if (!supported || !_ready || _sending || _lastSent == _signature) return;
    _sending = true;
    final signature = _signature;
    try {
      final value = await channel.invokeMethod<Map>('session', _session);
      _lastSent = signature;
      if (value != null) _apply(Map<String, dynamic>.from(value));
    } catch (_) {
      status = '回到应用后恢复后台接收';
      onChanged();
    } finally {
      _sending = false;
      if (_lastSent == signature && signature != _signature) unawaited(_send());
    }
  }

  void _apply(Map<String, dynamic> value) {
    final signature =
        '${value['enabled']}/${value['running']}/${value['batteryUnrestricted']}/${value['status']}';
    if (signature == _nativeState) return;
    _nativeState = signature;
    enabled = value['enabled'] != false;
    running = value['running'] == true;
    batteryUnrestricted = value['batteryUnrestricted'] == true;
    status = value['status'] as String? ?? '';
    engineId = value['engineId'] as int? ?? engineId;
    engineCreatedAt = value['engineCreatedAt'] as int? ?? engineCreatedAt;
    onChanged();
  }

  Future<void> setEnabled(bool value) async {
    if (!supported) return;
    final result = await channel.invokeMethod<Map>('enabled', {
      'enabled': value,
    });
    if (result != null) _apply(Map<String, dynamic>.from(result));
  }

  Future<void> openBatterySettings() async {
    if (supported) await channel.invokeMethod('batterySettings');
  }

  void dispose() {
    if (_initialized) channel.setMethodCallHandler(null);
    _initialized = _ready = false;
  }
}
