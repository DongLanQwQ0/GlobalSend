import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

import 'file_share.dart';
import 'models.dart';
import 'text_selection_surface.dart';

/// UIKit owns the gesture and cross-app drag session. No pointer simulation or
/// platform-view overlay is placed over Flutter's buttons and text fields.
class IOSDragSource extends StatefulWidget {
  static void refresh() => _IOSDragSourceState.schedule();
  const IOSDragSource({
    super.key,
    required this.entry,
    required this.enabled,
    required this.child,
  }) : clipboardRevision = null,
       mediaAssetId = null,
       onDragAccepted = null;
  const IOSDragSource.clipboard({
    super.key,
    required String revision,
    required this.enabled,
    required this.child,
    this.onDragAccepted,
  }) : entry = null,
       mediaAssetId = null,
       clipboardRevision = revision;
  const IOSDragSource.media({
    super.key,
    required String assetId,
    required this.enabled,
    required this.child,
    this.onDragAccepted,
  }) : entry = null,
       clipboardRevision = null,
       mediaAssetId = assetId;
  final DockEntry? entry;
  final String? clipboardRevision;
  final String? mediaAssetId;
  final VoidCallback? onDragAccepted;
  final bool enabled;
  final Widget child;
  @override
  State<IOSDragSource> createState() => _IOSDragSourceState();
}

class _IOSDragSourceState extends State<IOSDragSource> {
  static final sources = <_IOSDragSourceState>{};
  static bool scheduled = false;
  static String last = '';
  static int nextId = 0;
  final sourceId = 'ios-drag-${nextId++}';
  final bounds = GlobalKey();
  int pointerGeneration = 0;
  StreamSubscription<Map<String, dynamic>>? clipboardDragEvents;
  static void schedule() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS || scheduled) {
      return;
    }
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      final values = <Map<String, Object>>[];
      Size? surface;
      for (final source in sources) {
        if (!source.mounted || !source.widget.enabled) continue;
        if (ModalRoute.of(source.context)?.isCurrent == false) continue;
        final box = source.bounds.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) continue;
        final view = View.of(source.context), scale = view.devicePixelRatio;
        surface = view.physicalSize;
        final fullArea = MatrixUtils.transformRect(
          box.getTransformTo(null),
          Offset.zero & box.size,
        );
        var area = fullArea;
        RenderObject child = box;
        for (
          var parent = child.parent;
          parent is RenderObject;
          parent = child.parent
        ) {
          final clip = parent.describeApproximatePaintClip(child);
          if (clip != null) {
            area = area.intersect(
              MatrixUtils.transformRect(parent.getTransformTo(null), clip),
            );
          }
          child = parent;
        }
        area = area.intersect(Offset.zero & (view.physicalSize / scale));
        if (area.isEmpty) continue;
        final entry = source.widget.entry;
        values.add({
          'sourceId': source.sourceId,
          'left': area.left * scale,
          'top': area.top * scale,
          'right': area.right * scale,
          'bottom': area.bottom * scale,
          'previewLeft': fullArea.left * scale,
          'previewTop': fullArea.top * scale,
          'previewWidth': fullArea.width * scale,
          'previewHeight': fullArea.height * scale,
          'paths': entry?.dragPaths ?? <String>[],
          'texts': entry?.kind == 'text' ? [entry!.text] : <String>[],
          'label':
              entry?.title ??
              (source.widget.mediaAssetId == null ? '剪贴板' : '媒体'),
          'clipboardRevision': ?source.widget.clipboardRevision,
          'mediaAssetId': ?source.widget.mediaAssetId,
        });
      }
      final signature = '$surface:$values';
      if (last == signature) return;
      last = signature;
      unawaited(
        FileShareBridge.channel.invokeMethod<void>('setDragSources', {
          'sources': values,
          if (surface != null) ...{
            'surfaceWidth': surface.width,
            'surfaceHeight': surface.height,
          },
        }),
      );
    });
  }

  Future<void> prepare(PointerDownEvent event) async {
    if (!widget.enabled || defaultTargetPlatform != TargetPlatform.iOS) return;
    final generation = ++pointerGeneration;
    final blocked = isContentDragControlPosition(event.position, event.viewId);
    await FileShareBridge.channel.invokeMethod<void>('prepareDragSource', {
      'sourceId': sourceId,
      'generation': generation,
      'blocked': blocked,
    });
    if (blocked || !mounted) return;
    var boundary = bounds.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      boundary = bounds.currentContext?.findRenderObject();
    }
    if (boundary is! RenderRepaintBoundary ||
        !boundary.attached ||
        boundary.debugNeedsPaint) {
      return;
    }
    // Flutter is a GPU-backed view: UIView snapshots can be empty. Read only
    // this card once per press, before UIKit begins its native long-press lift.
    final image = await boundary.toImage(
      pixelRatio: math.min(
        MediaQuery.devicePixelRatioOf(context),
        1024 / boundary.size.longestSide,
      ),
    );
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null || !mounted || generation != pointerGeneration) return;
      await FileShareBridge.channel.invokeMethod<void>('setDragPreview', {
        'sourceId': sourceId,
        'generation': generation,
        'width': image.width,
        'height': image.height,
        'rgba': bytes.buffer.asUint8List(),
      });
    } finally {
      image.dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    sources.add(this);
    syncClipboardEvents();
  }

  @override
  void didUpdateWidget(IOSDragSource oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncClipboardEvents();
  }

  void syncClipboardEvents() {
    if ((widget.clipboardRevision != null || widget.mediaAssetId != null) &&
        clipboardDragEvents == null) {
      clipboardDragEvents = FileShareBridge.dragEvents.listen((event) {
        final matches = widget.clipboardRevision != null
            ? event['clipboardRevision'] == widget.clipboardRevision
            : event['mediaAssetId'] == widget.mediaAssetId;
        if (matches && event['operation'] == 'copy') {
          widget.onDragAccepted?.call();
        }
      });
    } else if (widget.clipboardRevision == null &&
        widget.mediaAssetId == null &&
        clipboardDragEvents != null) {
      unawaited(clipboardDragEvents!.cancel());
      clipboardDragEvents = null;
    }
  }

  @override
  void dispose() {
    sources.remove(this);
    unawaited(clipboardDragEvents?.cancel());
    schedule();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SourcePaint(
    onPaint: schedule,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => unawaited(prepare(event)),
      child: RepaintBoundary(key: bounds, child: widget.child),
    ),
  );
}

class _SourcePaint extends SingleChildRenderObjectWidget {
  const _SourcePaint({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SourceRender(onPaint);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _SourceRender renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _SourceRender extends RenderProxyBox {
  _SourceRender(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
