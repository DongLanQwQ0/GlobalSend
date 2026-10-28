import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';

class DockPlatform {
  static const channel = MethodChannel('dev.globalsend/dock');
  static final StreamController<Map<String, dynamic>> _events =
      StreamController.broadcast();
  static bool _installed = false;
  static Stream<Map<String, dynamic>> get events {
    if (!_installed) {
      _installed = true;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'nativeDrop' ||
            call.method == 'nativeDrag' ||
            call.method == 'dockState') {
          _events.add({
            'type': call.method,
            ...Map<String, dynamic>.from(call.arguments),
          });
        }
      });
    }
    return _events.stream;
  }

  static Future<Map<String, dynamic>> status() async {
    if (!Platform.isAndroid) return {};
    return Map<String, dynamic>.from(
      await channel.invokeMethod('status') as Map,
    );
  }

  static Future<void> requestNotificationPermission() =>
      channel.invokeMethod('notificationPermission');
  static Future<void> importClipboard() =>
      channel.invokeMethod('importClipboard');

  /// Opens Android's image/video Photo Picker. Selections are imported through
  /// [events] / [pending], not returned here, so callers must not stage twice.
  /// Cancellation completes normally without an import event.
  static Future<void> pickMedia() => channel.invokeMethod('pickMedia');
  static Future<void> showShelf() => channel.invokeMethod('showShelf');
  static Future<List<Map<String, dynamic>>> installedApps() async =>
      (await channel.invokeListMethod<Map>('installedApps') ?? [])
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
  static Future<Map<String, dynamic>> exportApp(String package) async =>
      Map<String, dynamic>.from(
        await channel.invokeMethod<Map>('exportApp', {'package': package}) ??
            {},
      );

  static Future<Map<String, String>?> pickDirectory() async {
    final value = await channel.invokeMethod<Map>('pickDirectory');
    return value == null ? null : Map<String, String>.from(value);
  }

  static Future<List<Map<String, dynamic>>> directoryEntries(
    String location,
  ) async =>
      (await channel.invokeListMethod<dynamic>('directoryEntries', {
                'location': location,
              }) ??
              [])
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();

  static Future<void> configure({int? maxFileSize}) =>
      channel.invokeMethod('configure', {'maxFileSize': ?maxFileSize});

  static Future<void> setQueueDropBounds(
    Rect? bounds, {
    Size? surface,
    Rect? sendNavigation,
  }) => channel.invokeMethod('queueDropBounds', {
    'enabled': bounds != null,
    if (bounds != null) ...{
      'left': bounds.left,
      'top': bounds.top,
      'right': bounds.right,
      'bottom': bounds.bottom,
      'surfaceWidth': surface!.width,
      'surfaceHeight': surface.height,
    },
    if (sendNavigation != null)
      'sendNavigation': {
        'left': sendNavigation.left,
        'top': sendNavigation.top,
        'right': sendNavigation.right,
        'bottom': sendNavigation.bottom,
        'surfaceWidth': surface!.width,
        'surfaceHeight': surface.height,
      },
  });
  static Future<List<Map<String, dynamic>>> pending() async =>
      (await channel.invokeMethod<List<dynamic>>('pending') ?? [])
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
  static Future<void> startDrag({
    String? text,
    String? path,
    List<String>? paths,
    List<String>? texts,
    String label = 'GlobalSend',
  }) => channel.invokeMethod('startDrag', {
    if (paths != null || texts != null) ...{
      'paths': paths ?? const <String>[],
      'texts': texts ?? (text == null ? const <String>[] : [text]),
    } else if (path != null)
      'path': path
    else
      'text': text ?? '',
    'label': label,
  });
}
