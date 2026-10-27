import 'package:flutter/material.dart';

/// A window-wide back edge also covers DialogRoute pages, which do not get
/// CupertinoPageRoute's edge recognizer. It stays out of image pan/zoom and
/// content dragging everywhere else in the viewport.
class IosBackSwipe extends StatefulWidget {
  const IosBackSwipe({
    super.key,
    required this.navigatorKey,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;
  @override
  State<IosBackSwipe> createState() => _IosBackSwipeState();
}

class _IosBackSwipeState extends State<IosBackSwipe> {
  bool canGoBack = false;
  double distance = 0;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.iOS) return widget.child;
    return NotificationListener<NavigationNotification>(
      onNotification: (notification) {
        if (canGoBack != notification.canHandlePop) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => canGoBack = notification.canHandlePop);
          });
        }
        return false;
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (canGoBack)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 28,
              child: ExcludeSemantics(
                child: GestureDetector(
                  key: const ValueKey('ios-back-swipe-edge'),
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) => distance = 0,
                  onHorizontalDragUpdate: (event) =>
                      distance += event.primaryDelta ?? 0,
                  onHorizontalDragEnd: (event) {
                    if (distance > 56 ||
                        distance > 16 && (event.primaryVelocity ?? 0) > 450) {
                      widget.navigatorKey.currentState?.maybePop();
                    }
                    distance = 0;
                  },
                  onHorizontalDragCancel: () => distance = 0,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
