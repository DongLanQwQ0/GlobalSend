import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'system_bridge.dart';
import 'ui_tokens.dart';

/// Chrome for the bounded Android Activity window, not a second overlay.
/// The body/receiver remain the same engine and controller.
class AndroidReceiveWindowFrame extends StatefulWidget {
  const AndroidReceiveWindowFrame({
    super.key,
    required this.child,
    this.onWindowGesture,
  });
  final Widget child;
  final Future<bool> Function(String method, Map<String, dynamic> arguments)?
  onWindowGesture;
  @override
  State<AndroidReceiveWindowFrame> createState() =>
      _AndroidReceiveWindowFrameState();
}

class _AndroidReceiveWindowFrameState extends State<AndroidReceiveWindowFrame> {
  int? pointer, downTimeMillis, gestureDownTime;
  bool pointerSizing = false, gestureSizing = false;
  String error = '';
  void pointerDown(PointerDownEvent event, bool sizing) {
    if (pointer == null) {
      pointer = event.pointer;
      downTimeMillis = event.timeStamp.inMilliseconds;
      pointerSizing = sizing;
    }
  }

  Future<void> gesture(bool begin, bool sizing) async {
    if (begin) {
      if (pointerSizing != sizing || pointer == null) return;
      gestureDownTime = downTimeMillis;
      gestureSizing = sizing;
    } else if (gestureSizing != sizing) {
      return;
    }
    final downTime = gestureDownTime;
    if (downTime == null) return;
    if (!begin) gestureDownTime = null;
    final method = begin
        ? 'beginReceivedWindowGesture'
        : 'endReceivedWindowGesture';
    final values = <String, dynamic>{
      'downTimeMillis': downTime,
      if (begin) 'resize': sizing,
    };
    try {
      if (widget.onWindowGesture != null) {
        await widget.onWindowGesture!(method, values);
      } else {
        await SystemBridge.channel.invokeMethod<bool>(method, values);
      }
    } on PlatformException {
      if (mounted) setState(() => error = '无法调整窗口');
    }
  }

  Widget handle({required bool sizing, required Widget child}) => Listener(
    onPointerDown: (event) => pointerDown(event, sizing),
    onPointerUp: (event) {
      if (pointer == event.pointer) pointer = null;
    },
    onPointerCancel: (event) {
      if (pointer == event.pointer) pointer = null;
    },
    child: GestureDetector(
      key: ValueKey(sizing ? 'receive-window-resize' : 'receive-window-move'),
      behavior: HitTestBehavior.opaque,
      // Native Android observes the same actual pointer stream and computes
      // display-coordinate displacement. Flutter declares only the handle's
      // gesture intent, never feeds the moving view's local deltas back to it.
      onPanStart: (_) => unawaited(gesture(true, sizing)),
      onPanEnd: (_) => unawaited(gesture(false, sizing)),
      onPanCancel: () => unawaited(gesture(false, sizing)),
      child: child,
    ),
  );

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: ColoredBox(
      color: Ui.input,
      child: Stack(
        children: [
          Column(
            children: [
              handle(
                sizing: false,
                child: Semantics(
                  label: '拖动移动接收窗',
                  child: const SizedBox(
                    width: double.infinity,
                    height: 28,
                    child: Center(
                      child: Icon(Icons.drag_handle, size: 22, color: Ui.muted),
                    ),
                  ),
                ),
              ),
              Expanded(child: widget.child),
              const SizedBox(height: 28),
            ],
          ),
          if (error.isNotEmpty)
            Positioned(
              left: 12,
              bottom: 4,
              child: Text(
                error,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
          Positioned(
            right: 0,
            bottom: 0,
            child: handle(
              sizing: true,
              child: Semantics(
                label: '拖动调整接收窗大小',
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(5),
                      child: Icon(
                        Icons.south_east_rounded,
                        size: 17,
                        color: Ui.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
