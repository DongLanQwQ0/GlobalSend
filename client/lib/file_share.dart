import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
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
  });
  final String batchId;
  final List<String> paths, texts, temporaryPaths;
  final String? error;
  final SharedSendTarget? target;
  factory SharedBatch.fromMap(Map<Object?, Object?> value) => SharedBatch(
    batchId: value['batchId'] as String,
    paths: List<String>.from(value['paths'] as List? ?? []),
    texts: List<String>.from(value['texts'] as List? ?? []),
    temporaryPaths: List<String>.from(value['temporaryPaths'] as List? ?? []),
    error: value['error'] as String?,
    target: value['target'] is Map
        ? SharedSendTarget.fromMap(value['target'] as Map)
        : null,
  );
}

/// OS sharing only. Incoming batches remain durable until Dart stages and acks them.
abstract final class FileShareBridge {
  static const channel = MethodChannel('dev.globalsend/share');
  static bool get supported => Platform.isAndroid || Platform.isIOS;
  static final _incoming = StreamController<void>.broadcast();
  static bool _installed = false;
  static void _install() {
    if (_installed) return;
    _installed = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingChanged') _incoming.add(null);
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
  };
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
