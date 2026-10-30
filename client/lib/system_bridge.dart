import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter/services.dart';

/// Windows clipboard events and copy-only OLE import/export.
class NativeDragPreview {
  const NativeDragPreview(this.rgba, this.width, this.height);
  final Uint8List rgba;
  final int width, height;
}

class SystemBridge {
  static const channel = MethodChannel('dev.globalsend/system');
  static final _dragPreviewKey = Object();

  /// Keeps existing exporters unchanged while handing their native drag the
  /// exact card painted for this gesture. Concurrent exports have own scopes.
  static Future<T> withDragPreview<T>(
    NativeDragPreview? preview,
    Future<T> Function() export,
  ) => runZoned(export, zoneValues: {_dragPreviewKey: preview});
  static Map<String, Object> get dragPreviewArguments {
    final preview = Zone.current[_dragPreviewKey] as NativeDragPreview?;
    return preview == null
        ? const {}
        : {
            'previewRgba': preview.rgba,
            'previewWidth': preview.width,
            'previewHeight': preview.height,
          };
  }

  /// Read-only OS interface metadata; no discovery traffic or permission prompt.
  static Future<List<Map<String, dynamic>>> localIpInterfaces() async {
    final values = await channel.invokeListMethod<dynamic>(
      'localIpInterfaces',
      <String, dynamic>{},
    );
    return [
      for (final value in values ?? const [])
        Map<String, dynamic>.from(value as Map),
    ];
  }

  /// The active send queue in physical Flutter client pixels, not screen DIPs.
  static Future<void> setQueueDropBounds(
    Rect? bounds, {
    Size? surface,
    List<Map<String, Object>> devices = const [],
    String serverKey = '',
  }) async {
    if (!Platform.isWindows) return;
    bounds ??= devices.isEmpty ? null : Rect.zero;
    await channel.invokeMethod<void>('queueDropBounds', {
      'enabled': bounds != null,
      if (devices.isNotEmpty || serverKey.isNotEmpty) ...{
        'devices': devices,
        'serverKey': serverKey,
      },
      if (bounds != null) ...{
        'left': bounds.left,
        'top': bounds.top,
        'right': bounds.right,
        'bottom': bounds.bottom,
        'surfaceWidth': surface?.width,
        'surfaceHeight': surface?.height,
      },
    });
  }

  static Future<void> prepareReceiveDock() async {
    if (!Platform.isWindows) return;
    await channel.invokeMethod<bool>('prepareReceiveDock', <String, dynamic>{});
  }

  static Future<Map<String, dynamic>> presentReceiveDock({
    required List<Map<String, dynamic>> items,
    required int serial,
    Map<String, String>? appearance,
  }) async {
    if (!Platform.isWindows) {
      return const {'presentation': 'main', 'shown': true};
    }
    _install();
    final state = Map<String, dynamic>.from(
      await channel.invokeMethod<Map>('presentReceiveDock', {
            'items': items,
            'serial': serial,
            if (appearance != null) 'appearance': appearance,
          }) ??
          {},
    );
    _rememberReceiptGeneration(state);
    return state;
  }

  static Future<void> dismissReceiveDock(int arrivalGeneration) async {
    if (!Platform.isWindows) return;
    await channel.invokeMethod<void>('dismissReceiveDock', {
      'arrivalGeneration': arrivalGeneration,
    });
  }

  static Future<void> activateWindow() async {
    if (!Platform.isWindows) return;
    await channel.invokeMethod<void>('activateWindow', <String, dynamic>{});
  }

  static Future<void> drainLaunchFiles() async {
    if (!Platform.isWindows) return;
    _install();
    await channel.invokeMethod<void>('drainLaunchFiles', <String, dynamic>{});
  }

  static Future<void> showReceivedWindow({
    String title = 'GlobalSend',
    String body = '收到新内容',
  }) async {
    if (Platform.isWindows) {
      await channel.invokeMethod<void>('showReceivedWindow', {
        'title': title,
        'body': body,
      });
    }
  }

  static Future<void> openWebUrl(Uri uri) async {
    if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('网址无效');
    }
    await channel.invokeMethod<void>('openWebUrl', {'url': uri.toString()});
  }

  static int? _receiptArrivalGeneration;
  static int? get receiptArrivalGeneration => _receiptArrivalGeneration;

  static Future<void> dismissReceivedWindow({int? arrivalGeneration}) async {
    if (Platform.isWindows || Platform.isAndroid) {
      final generation = arrivalGeneration ?? _receiptArrivalGeneration;
      await channel.invokeMethod<void>('dismissReceivedWindow', {
        if (generation != null) 'arrivalGeneration': generation,
      });
    }
  }

  static Future<void> expandReceivedWindow() async {
    await channel.invokeMethod<void>('expandReceivedWindow');
  }

  static Future<Map<String, dynamic>> receivedWindowState() async {
    if (!Platform.isAndroid && !Platform.isWindows) return {};
    final state = Map<String, dynamic>.from(
      await channel.invokeMethod<Map>('receivedWindowState') ?? {},
    );
    _rememberReceiptGeneration(state);
    return state;
  }

  static void _rememberReceiptGeneration(Map<String, dynamic> state) {
    final generation = state['arrivalGeneration'];
    if (generation is int) _receiptArrivalGeneration = generation;
  }

  static Future<String> deviceName() async {
    final value = Platform.isAndroid || Platform.isIOS
        ? await channel.invokeMethod<String>('deviceName') ?? ''
        : Platform.isWindows
        ? Platform.environment['USERNAME'] ?? ''
        : Platform.localHostname;
    return String.fromCharCodes(value.trim().runes.take(80));
  }

  static final StreamController<Map<String, dynamic>> _clipboard =
      StreamController.broadcast();
  static final StreamController<Map<String, dynamic>> _drops =
      StreamController.broadcast();
  static final StreamController<Map<String, dynamic>> _windows =
      StreamController.broadcast();
  static final StreamController<void> _pasteRequests =
      StreamController.broadcast();
  static Stream<void> get pasteRequests {
    _install();
    return _pasteRequests.stream;
  }

  static String? _windowStatePath;
  static Future<void> _windowSave = Future<void>.value();
  static bool _installed = false;
  static Stream<Map<String, dynamic>> get clipboardEvents {
    _install();
    return _clipboard.stream;
  }

  static Stream<Map<String, dynamic>> get dropEvents {
    _install();
    return _drops.stream;
  }

  static Stream<Map<String, dynamic>> get windowEvents {
    _install();
    return _windows.stream;
  }

  static Future<bool> windowVisible() async {
    if (!Platform.isWindows) return true;
    _install();
    return await channel.invokeMethod<bool>(
          'windowVisible',
          <String, dynamic>{},
        ) ??
        true;
  }

  static Future<bool> autoStartEnabled() async =>
      Platform.isWindows &&
      await channel.invokeMethod<bool>('autoStartEnabled') == true;

  static Future<bool> setAutoStart(bool enabled) async {
    if (!Platform.isWindows) throw UnsupportedError('仅 Windows 支持此开机启动设置');
    return await channel.invokeMethod<bool>('setAutoStart', enabled) == true;
  }

  static Future<void> configureWindowPersistence(
    String path, {
    bool restore = true,
  }) async {
    if (!Platform.isWindows) return;
    _install();
    _windowStatePath = path;
    if (!restore) return;
    final file = File(path);
    if (await file.exists()) {
      final state = Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
      await channel.invokeMethod<void>('restoreWindow', state);
    }
  }

  static void _install() {
    if (!_installed) {
      _installed = true;
      channel.setMethodCallHandler((call) async {
        if (call.method == 'clipboardChanged') {
          _clipboard.add(Map<String, dynamic>.from(call.arguments));
        } else if (call.method == 'pasteRequested') {
          _pasteRequests.add(null);
        } else if (call.method == 'nativeDrag' || call.method == 'nativeDrop') {
          _drops.add({
            ...Map<String, dynamic>.from(call.arguments),
            'type': call.method,
          });
        } else if (call.method == 'windowVisibilityChanged') {
          _windows.add(Map<String, dynamic>.from(call.arguments));
        } else if (call.method == 'receiptPresentationChanged') {
          final state = Map<String, dynamic>.from(call.arguments);
          _rememberReceiptGeneration(state);
          _windows.add({'receiptFloating': state['floating'] == true});
        } else if (call.method == 'receiptArrival') {
          _rememberReceiptGeneration(Map<String, dynamic>.from(call.arguments));
        } else if (call.method == 'receiveDockAction') {
          _windows.add({
            'dockAction': Map<String, dynamic>.from(call.arguments),
          });
        } else if (call.method == 'receivedNotificationOpened') {
          _windows.add({'received': true});
        } else if (call.method == 'windowStateChanged') {
          final path = _windowStatePath;
          if (path != null) {
            final state = Map<String, dynamic>.from(call.arguments);
            _windowSave = _windowSave.catchError((Object _) {}).then((_) async {
              await File(path).writeAsString(jsonEncode(state), flush: true);
            });
            await _windowSave;
          }
        }
      });
    }
  }

  static Future<void> watchClipboard(bool enabled) async {
    if (!Platform.isWindows) return;
    clipboardEvents;
    await channel.invokeMethod('clipboardWatch', {'enabled': enabled});
  }

  static Future<void> copy(
    String text, {
    String originDeviceId = '',
    String sourceEventId = 'private',
    bool private = true,
  }) async {
    if (!Platform.isWindows) {
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }
    await channel.invokeMethod('writeClipboard', {
      'text': text,
      'originDeviceId': originDeviceId,
      'sourceEventId': sourceEventId,
      'private': private,
    });
  }

  /// Read only after an explicit paste-button action. Files keep their
  /// original paths; a clipboard bitmap needs one application-owned source.
  static Future<Map<String, dynamic>> readClipboard(String bitmapPath) async {
    if (Platform.isWindows) {
      return Map<String, dynamic>.from(
        await channel.invokeMethod('readClipboard', {'bitmapPath': bitmapPath})
            as Map,
      );
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    return {
      'paths': <String>[],
      'texts': text.isEmpty ? <String>[] : [text],
    };
  }

  /// Determine how an explicit Ctrl+V should be routed, without reading text
  /// or creating an image source until the user actually imports it.
  static Future<String> clipboardKind() async {
    if (!Platform.isWindows) return 'text';
    return await channel.invokeMethod<String>(
          'clipboardKind',
          <String, dynamic>{},
        ) ??
        'empty';
  }

  static Future<bool> dragOut({
    String? text,
    List<String>? paths,
    String pointerKind = 'auto',
  }) async {
    if (!Platform.isWindows) return false;
    return await channel.invokeMethod<bool>('dragOut', {
          'pointerKind': pointerKind,
          if (paths != null) 'paths': paths else 'text': text ?? '',
          ...dragPreviewArguments,
        }) ??
        false;
  }

  static Future<bool> exportFiles(
    List<String> paths, {
    String pointerKind = 'auto',
  }) => dragOut(paths: paths, pointerKind: pointerKind);

  static Future<void> revealFile(String path) async {
    if (!Platform.isWindows) return;
    try {
      await channel.invokeMethod<void>('revealFile', {'path': path});
    } on PlatformException catch (error) {
      throw StateError(error.message ?? '无法在资源管理器定位文件');
    }
  }
}
