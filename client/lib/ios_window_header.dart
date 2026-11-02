import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'file_share.dart';

/// Reserves only the part of a top bar occupied by UIKit's real window controls.
/// Content below that row keeps the full window width; normal dialogs do not
/// inherit a tablet-wide blank strip.
class IosWindowHeader extends StatefulWidget {
  const IosWindowHeader({super.key, required this.child});
  final Widget child;
  @override
  State<IosWindowHeader> createState() => _IosWindowHeaderState();
}

class _IosWindowHeaderState extends State<IosWindowHeader> {
  final _anchor = GlobalKey();
  Rect? _frame;
  bool _scheduled = false;

  void _measure() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = _anchor.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final frame = box.localToGlobal(Offset.zero) & box.size;
      if (frame != _frame) setState(() => _frame = frame);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.iOS) return widget.child;
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: FileShareBridge.windowLayout,
      builder: (context, metrics, _) => LayoutBuilder(
        builder: (context, constraints) {
          _measure();
          final windowWidth =
              (metrics['width'] as num?)?.toDouble() ??
              MediaQuery.sizeOf(context).width;
          final frame = _frame ?? Rect.fromLTWH(0, 0, constraints.maxWidth, 0);
          final overlapsTop =
              frame.top <
              ((metrics['controlsBottom'] as num?)?.toDouble() ?? 0);
          final left = overlapsTop
              ? math.max(
                  0.0,
                  ((metrics['leading'] as num?)?.toDouble() ?? 0) - frame.left,
                )
              : 0.0;
          final right = overlapsTop
              ? math.max(
                  0.0,
                  ((metrics['trailing'] as num?)?.toDouble() ?? 0) -
                      (windowWidth - frame.right),
                )
              : 0.0;
          return SizedBox(
            key: _anchor,
            child: Padding(
              key: const ValueKey('ios-window-header-inset'),
              padding: EdgeInsets.only(left: left, right: right),
              child: widget.child,
            ),
          );
        },
      ),
    );
  }
}

class _WindowSafeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _WindowSafeAppBar(this.appBar);
  final AppBar appBar;
  @override
  Size get preferredSize => appBar.preferredSize;
  @override
  Widget build(BuildContext context) => IosWindowHeader(child: appBar);
}

extension IosSafeAppBar on AppBar {
  PreferredSizeWidget windowSafe() => _WindowSafeAppBar(this);
}
