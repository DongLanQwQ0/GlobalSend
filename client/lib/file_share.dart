import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'dock_platform.dart';
import 'ui_tokens.dart';

class SharedSendTarget {
  const SharedSendTarget({
    required this.serverKey,
    required this.deviceId,
    this.name = '',
    this.platform = 'other',
  });
  final String serverKey, deviceId, name, platform;
  factory SharedSendTarget.fromMap(Map value) => SharedSendTarget(
    serverKey: value['serverKey'] as String,
    deviceId: value['deviceId'] as String,
    name: value['name'] as String? ?? '',
    platform: value['platform'] as String? ?? 'other',
  );
  Map<String, String> toJson() => {
    'serverKey': serverKey,
    'deviceId': deviceId,
    'name': name,
    'platform': platform,
  };
}

class SharedBatch {
  SharedBatch({
    required this.batchId,
    required this.paths,
    required this.texts,
    required this.temporaryPaths,
    this.error,
    this.target,
    this.importing = false,
    this.completedItems = 0,
    this.totalItems = 0,
  });
  final String batchId;
  final List<String> paths, texts, temporaryPaths;
  final String? error;
  final SharedSendTarget? target;
  final bool importing;
  final int completedItems, totalItems;
  factory SharedBatch.fromMap(Map<Object?, Object?> value) => SharedBatch(
    batchId: value['batchId'] as String,
    paths: List<String>.from(value['paths'] as List? ?? []),
    texts: List<String>.from(value['texts'] as List? ?? []),
    temporaryPaths: List<String>.from(value['temporaryPaths'] as List? ?? []),
    error: value['error'] as String?,
    importing: value['importing'] == true,
    completedItems: value['completedItems'] as int? ?? 0,
    totalItems: value['totalItems'] as int? ?? 0,
    target: value['target'] is Map
        ? SharedSendTarget.fromMap(value['target'] as Map)
        : null,
  );
}

/// OS sharing only. Incoming batches remain durable until Dart stages and acks them.
abstract final class FileShareBridge {
  static const channel = MethodChannel('dev.globalsend/share');
  static bool get supported => Platform.isAndroid || Platform.isIOS;
  static Future<void> importClipboard() =>
      channel.invokeMethod('importClipboard');
  static final imageClipboardSupported = ValueNotifier<bool>(false);
  static Future<bool>? _imageClipboardCapability;
  static bool get canWriteImageClipboard =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.iOS &&
          imageClipboardSupported.value;
  static Future<bool> ensureImageClipboardCapability() {
    if (defaultTargetPlatform != TargetPlatform.iOS)
      return Future.value(canWriteImageClipboard);
    return _imageClipboardCapability ??= refreshImageClipboardCapability();
  }

  static Future<bool> refreshImageClipboardCapability() {
    if (defaultTargetPlatform != TargetPlatform.iOS)
      return Future.value(canWriteImageClipboard);
    _install();
    return _imageClipboardCapability = channel
        .invokeMethod<bool>('imageClipboardSupported')
        .then((allowed) {
          imageClipboardSupported.value = allowed == true;
          return allowed == true;
        });
  }

  static Future<bool> copyReceivedImage(String path) async {
    if (!await ensureImageClipboardCapability()) return false;
    return await channel.invokeMethod<bool>('copyReceivedImage', {
          'path': path,
        }) ==
        true;
  }

  static final _incoming = StreamController<void>.broadcast();
  static final _dragEvents = StreamController<Map<String, dynamic>>.broadcast();
  static final _clipboardSlotLeases =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get clipboardSlotLeases {
    _install();
    return _clipboardSlotLeases.stream;
  }

  static final _remoteReferences =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get remoteReferenceRequests {
    _install();
    return _remoteReferences.stream;
  }

  static Future<void> completeRemoteReference(
    String token, {
    List<String> paths = const [],
    String error = '',
  }) => channel.invokeMethod<void>('completeRemoteReference', {
    'token': token,
    'paths': paths,
    'error': error,
  });
  static bool _installed = false;
  static final windowLayout = ValueNotifier<Map<String, dynamic>>(const {});
  static Future<void> startWindowLayout() async {
    if (!Platform.isIOS) return;
    await ensureImageClipboardCapability();
    _install();
    final value = await channel.invokeMapMethod<String, dynamic>(
      'windowLayout',
    );
    if (value != null) windowLayout.value = value;
  }

  static void _install() {
    if (_installed) return;
    _installed = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'clipboardSlotLease') {
        _clipboardSlotLeases.add(
          Map<String, dynamic>.from(call.arguments as Map),
        );
        return null;
      }
      if (call.method == 'resolveRemoteReference') {
        _remoteReferences.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      if (call.method == 'pendingChanged') _incoming.add(null);
      if (call.method == 'windowLayoutChanged') {
        windowLayout.value = Map<String, dynamic>.from(call.arguments as Map);
      }
      if (call.method == 'nativeDrag')
        _dragEvents.add({
          'type': 'nativeDrag',
          ...Map<String, dynamic>.from(call.arguments),
        });
      if (call.method == 'importError')
        _incoming.addError(
          PlatformException(
            code: 'SHARE_IMPORT_FAILED',
            message: call.arguments as String?,
          ),
        );
    });
  }

  static Stream<void> get incoming {
    _install();
    return _incoming.stream;
  }

  static Stream<Map<String, dynamic>> get dragEvents {
    _install();
    return _dragEvents.stream;
  }

  static Future<void> setDropRegions(
    Rect? bounds, {
    Size? surface,
    List<Map<String, Object>> devices = const [],
    String serverKey = '',
  }) => channel.invokeMethod('setDropRegions', {
    'enabled': bounds != null || devices.isNotEmpty,
    'devices': devices,
    'serverKey': serverKey,
    if (surface != null) ...{
      'surfaceWidth': surface.width,
      'surfaceHeight': surface.height,
    },
    if (bounds != null) ...{
      'left': bounds.left,
      'top': bounds.top,
      'right': bounds.right,
      'bottom': bounds.bottom,
    },
  });

  static Future<void> share({
    List<String> paths = const [],
    String? text,
  }) async {
    if (!supported) throw UnsupportedError('此平台尚未接入系统分享');
    if (paths.isEmpty && (text == null || text.isEmpty)) return;
    await channel.invokeMethod<void>('share', {
      'paths': paths,
      if (text != null) 'text': text,
    });
  }

  static Future<List<SharedBatch>> pending() async {
    if (!supported) return [];
    _install();
    return (await channel.invokeListMethod<Object?>('pending') ?? [])
        .map((value) => SharedBatch.fromMap(value as Map))
        .toList();
  }

  static Future<void> ack(String batchId) =>
      channel.invokeMethod<void>('ack', {'batchId': batchId});

  static Future<void> recordTarget(SharedSendTarget target) =>
      channel.invokeMethod<void>('recordShareTarget', target.toJson());
}

/// Small native drag handle; it never replaces the page's existing gestures.
class BulkDragHandle extends StatefulWidget {
  const BulkDragHandle({
    super.key,
    this.paths = const [],
    this.texts = const [],
    this.size = 44,
    this.onError,
  });
  final List<String> paths, texts;
  final double size;
  final void Function(Object)? onError;
  @override
  State<BulkDragHandle> createState() => _BulkDragHandleState();
}

class _BulkDragHandleState extends State<BulkDragHandle> {
  int? platformViewId;
  Map<String, Object> get parameters => {
    'paths': widget.paths,
    'texts': widget.texts,
    'foreground': Ui.colors(context).accent.toARGB32(),
  };
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    sync();
  }

  @override
  void didUpdateWidget(BulkDragHandle oldWidget) {
    super.didUpdateWidget(oldWidget);
    sync();
  }

  void sync() {
    final id = platformViewId;
    if (id == null) return;
    unawaited(
      MethodChannel('dev.globalsend/drag-handle/$id')
          .invokeMethod<void>('update', parameters)
          .catchError((Object error) {
            if (mounted) widget.onError?.call(error);
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS)
      return SizedBox.square(
        dimension: widget.size,
        child: UiKitView(
          viewType: 'dev.globalsend/drag-handle',
          creationParams: parameters,
          creationParamsCodec: const StandardMessageCodec(),
          onPlatformViewCreated: (id) {
            platformViewId = id;
            sync();
          },
        ),
      );
    if (Platform.isAndroid)
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: (_) async {
          try {
            await DockPlatform.startDrag(
              paths: widget.paths,
              texts: widget.texts,
              label: '${widget.paths.length + widget.texts.length} 项',
            );
          } catch (error) {
            widget.onError?.call(error);
          }
        },
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(painter: _HandlePainter(Ui.colors(context).green)),
        ),
      );
    return const SizedBox.shrink();
  }
}

class _HandlePainter extends CustomPainter {
  const _HandlePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final x in [-3.0, 3.0])
      for (final y in [-7.0, 0.0, 7.0])
        canvas.drawCircle(
          Offset(size.width / 2 + x, size.height / 2 + y),
          1.7,
          paint,
        );
  }

  @override
  bool shouldRepaint(_HandlePainter old) => old.color != color;
}
