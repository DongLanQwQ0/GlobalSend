import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

import 'file_share.dart';
import 'models.dart';

/// UIKit owns the gesture and cross-app drag session. No pointer simulation or
/// platform-view overlay is placed over Flutter's buttons and text fields.
class IOSDragSource extends StatefulWidget {
  static void refresh() => _IOSDragSourceState.schedule();
  const IOSDragSource({
    super.key,
    required this.entry,
    required this.enabled,
    required this.child,
  });
  final DockEntry entry;
  final bool enabled;
  final Widget child;
  @override
  State<IOSDragSource> createState() => _IOSDragSourceState();
}

class _IOSDragSourceState extends State<IOSDragSource> {
  static final sources = <_IOSDragSourceState>{};
  static bool scheduled = false;
  static String last = '';
  final bounds = GlobalKey();
  static void schedule() {
    if (!Platform.isIOS || scheduled) return;
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
        var area = MatrixUtils.transformRect(
          box.getTransformTo(null),
          Offset.zero & box.size,
        );
        RenderObject child = box;
        for (
          var parent = child.parent;
          parent is RenderObject;
          parent = child.parent
        ) {
          final clip = parent.describeApproximatePaintClip(child);
          if (clip != null)
            area = area.intersect(
              MatrixUtils.transformRect(parent.getTransformTo(null), clip),
            );
          child = parent;
        }
        area = area.intersect(Offset.zero & (view.physicalSize / scale));
        if (area.isEmpty) continue;
        final entry = source.widget.entry;
        values.add({
          'left': area.left * scale,
          'top': area.top * scale,
          'right': area.right * scale,
          'bottom': area.bottom * scale,
          'paths': entry.dragPaths,
          'texts': entry.kind == 'text' ? [entry.text] : <String>[],
          'label': entry.title,
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

  @override
  void initState() {
    super.initState();
    sources.add(this);
  }

  @override
  void dispose() {
    sources.remove(this);
    schedule();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SourcePaint(
    onPaint: schedule,
    child: KeyedSubtree(key: bounds, child: widget.child),
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
