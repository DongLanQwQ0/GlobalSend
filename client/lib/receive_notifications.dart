import 'dart:io';

import 'package:flutter/services.dart';

/// Android receipt notices; this never reads the operating-system clipboard.
class ReceivedNotifications {
  static const channel = MethodChannel('dev.globalsend/received-notifications');
  bool get supported => Platform.isAndroid;
  void Function(String)? onOpen;
  void Function(bool)? onPermission;
  void Function(Map<String, dynamic>)? onPopupState;
  void Function(Map<String, dynamic>)? onDismiss;
  bool _initialized = false;

  Future<void> initialize() async {
    if (!supported || _initialized) return;
    _initialized = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        final target = await channel.invokeMethod<String>('pendingOpen');
        if (target?.isNotEmpty == true) onOpen?.call(target!);
      } else if (call.method == 'permission') {
        onPermission?.call(call.arguments == true);
      } else if (call.method == 'popupState') {
        onPopupState?.call(Map<String, dynamic>.from(call.arguments as Map));
      } else if (call.method == 'dismiss') {
        onDismiss?.call(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
    final pending = await channel.invokeMethod<String>('pendingOpen');
    if (pending?.isNotEmpty == true) onOpen?.call(pending!);
  }

  Future<bool> status() async =>
      supported && await channel.invokeMethod<bool>('status') == true;
  Future<bool> permission({bool explicit = false}) async =>
      supported &&
      await channel.invokeMethod<bool>('permission', {'explicit': explicit}) ==
          true;
  Future<Map<String, dynamic>> popupState() async => supported
      ? Map<String, dynamic>.from(
          await channel.invokeMethod<Map>('popupState') ?? {},
        )
      : {};
  Future<Map<String, dynamic>> setPopupEnabled(bool enabled) async => supported
      ? Map<String, dynamic>.from(
          await channel.invokeMethod<Map>('popupEnabled', {
                'enabled': enabled,
              }) ??
              {},
        )
      : {};
  Future<void> openPopupSettings() async {
    if (supported) await channel.invokeMethod('popupSettings');
  }

  Future<void> openNotificationSettings() async {
    if (supported) await channel.invokeMethod('notificationSettings');
  }

  Future<void> setForeground(bool foreground) async {
    if (supported) {
      await channel.invokeMethod('foreground', {'foreground': foreground});
    }
  }

  Future<void> setScope(String scope) async {
    if (supported) await channel.invokeMethod('scope', {'scope': scope});
  }

  Future<void> clear() async {
    if (supported) await channel.invokeMethod('clear');
  }

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
    if (!supported) return;
    await channel.invokeMethod('show', {
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

  void dispose() {
    if (_initialized) channel.setMethodCallHandler(null);
    _initialized = false;
    onOpen = null;
    onPermission = null;
    onPopupState = null;
    onDismiss = null;
  }
}
