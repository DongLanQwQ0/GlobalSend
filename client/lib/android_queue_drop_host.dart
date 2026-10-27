import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'dock_platform.dart';
import 'system_bridge.dart';

/// Native system drag dispatchers cannot see Flutter DragTargets. Publish
/// only the visible queue rectangle, in FlutterView-local physical pixels.
class NativeQueueDropHost extends StatefulWidget {
  const NativeQueueDropHost({
    super.key,
    required this.target,
    required this.enabled,
    required this.child,
    this.sendNavigationTarget,
    this.sendNavigationEnabled = false,
  });
  final GlobalKey target;
  final bool enabled;
  final Widget child;
  final GlobalKey? sendNavigationTarget;
  final bool sendNavigationEnabled;
  @override
  State<NativeQueueDropHost> createState() => _NativeQueueDropHostState();
}

class _NativeQueueDropHostState extends State<NativeQueueDropHost>
    with WidgetsBindingObserver {
  bool scheduled = false;
  Rect? last;
  Rect? lastNavigation;
  Size? lastSurface;
  bool reported = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(NativeQueueDropHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    schedule();
  }

  @override
  void didChangeMetrics() => schedule();

  void schedule() {
    if (scheduled || !mounted) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (!mounted) return;
      final view = View.of(context), surface = view.physicalSize;
      Rect? boundsFor(GlobalKey? key) {
        final target = key?.currentContext?.findRenderObject();
        if (target is RenderBox && target.attached && target.hasSize) {
          var bounds = MatrixUtils.transformRect(
            target.getTransformTo(null),
            Offset.zero & target.size,
          );
          RenderObject child = target;
          for (
            var parent = child.parent;
            parent is RenderObject;
            parent = child.parent
          ) {
            final clip = parent.describeApproximatePaintClip(child);
            if (clip != null)
              bounds = bounds.intersect(
                MatrixUtils.transformRect(parent.getTransformTo(null), clip),
              );
            child = parent;
          }
          bounds = bounds.intersect(
            Offset.zero & (surface / view.devicePixelRatio),
          );
          if (!bounds.isEmpty)
            return Rect.fromLTRB(
              bounds.left * view.devicePixelRatio,
              bounds.top * view.devicePixelRatio,
              bounds.right * view.devicePixelRatio,
              bounds.bottom * view.devicePixelRatio,
            );
        }
        return null;
      }

      final area = widget.enabled ? boundsFor(widget.target) : null;
      final navigation = widget.sendNavigationEnabled
          ? boundsFor(widget.sendNavigationTarget)
          : null;
      if (reported &&
          last == area &&
          lastNavigation == navigation &&
          lastSurface == surface)
        return;
      reported = true;
      last = area;
      lastSurface = surface;
      lastNavigation = navigation;
      if (Platform.isAndroid) {
        unawaited(
          DockPlatform.setQueueDropBounds(
            area,
            surface: surface,
            sendNavigation: navigation,
          ),
        );
      } else if (Platform.isWindows) {
        unawaited(SystemBridge.setQueueDropBounds(area, surface: surface));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isAndroid) {
      unawaited(DockPlatform.setQueueDropBounds(null));
    } else if (Platform.isWindows) {
      unawaited(SystemBridge.setQueueDropBounds(null));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (_) {
          schedule();
          return false;
        },
        child: _PaintQueueBounds(onPaint: schedule, child: widget.child),
      );
}

class _PaintQueueBounds extends SingleChildRenderObjectWidget {
  const _PaintQueueBounds({required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _QueueBoundsRender(onPaint);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _QueueBoundsRender renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _QueueBoundsRender extends RenderProxyBox {
  _QueueBoundsRender(this.onPaint);
  VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPaint();
  }
}
