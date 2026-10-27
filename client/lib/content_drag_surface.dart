import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'content_preview.dart';
import 'models.dart';
import 'text_selection_surface.dart';
import 'ui_tokens.dart';

/// Desktop uses an in-window preview before native export. Android hands the
/// original long press directly to the system, preserving its drag shadow.
class ContentDragSurface extends StatefulWidget {
  const ContentDragSurface({
    super.key,
    required this.entry,
    required this.child,
    required this.onExport,
    this.enabled = true,
    this.selectedText = false,
    this.touchDrags = true,
  });
  final DockEntry entry;
  final Widget child;
  final Future<void> Function(String kind) onExport;
  final bool enabled, selectedText, touchDrags;

  /// Windows long-press touch/pen belongs to drag, not the mouse context menu.
  /// Real mouse/trackpad secondary clicks and other platforms retain menus.
  static bool allowsContextMenu(
    BuildContext context,
    PointerDeviceKind? kind,
  ) =>
      Theme.of(context).platform != TargetPlatform.windows ||
      kind == null ||
      kind == PointerDeviceKind.mouse ||
      kind == PointerDeviceKind.trackpad;
  @override
  State<ContentDragSurface> createState() => _ContentDragSurfaceState();
}

class _ContentDragSurfaceState extends State<ContentDragSurface> {
  final external = ValueNotifier(false);
  String pointerKind = 'mouse';
  int? sourcePointer;
  bool nativePending = false;
  @override
  void dispose() {
    external.dispose();
    super.dispose();
  }

  void update(DragUpdateDetails details) {
    if (nativePending ||
        external.value ||
        (Offset.zero & MediaQuery.sizeOf(context))
            .inflate(2)
            .contains(details.globalPosition))
      return;
    external.value = true;
    nativePending = true;
    // OLE owns the physical pointer from here. Retire only Flutter's pointer
    // stream so its avatar/recognizer cannot wait forever for an OS-consumed up.
    final pointer = sourcePointer;
    if (pointer != null) GestureBinding.instance.cancelPointer(pointer);
    unawaited(() async {
      try {
        await widget.onExport(pointerKind);
      } finally {
        nativePending = false;
        sourcePointer = null;
        if (mounted) external.value = false;
      }
    }());
  }

  Widget feedback() => ValueListenableBuilder<bool>(
    valueListenable: external,
    builder: (_, exporting, child) => exporting ? const SizedBox() : child!,
    child: Opacity(
      opacity: .9,
      child: Material(
        key: ValueKey('drag-feedback-${widget.entry.id}'),
        color: Colors.white,
        elevation: 8,
        shadowColor: Colors.black26,
        borderRadius: Ui.cardRadius,
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 184,
          height: 140,
          child: Column(
            children: [
              Expanded(
                child: ContentPreview(
                  location: widget.entry.localPath,
                  name: widget.entry.title,
                  text: widget.entry.kind == 'text' ? widget.entry.text : null,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.add, size: 16, color: Ui.green),
                    SizedBox(width: 6),
                    Text('复制', style: TextStyle(fontSize: 12, color: Ui.green)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.android) {
      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          if (widget.enabled && widget.touchDrags)
            ExportLongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  ExportLongPressGestureRecognizer
                >(ExportLongPressGestureRecognizer.new, (recognizer) {
                  recognizer.allowSelectedText = widget.selectedText;
                  recognizer.onLongPress = () =>
                      nativeExport(recognizer.pointerKind?.name ?? 'touch');
                }),
          if (widget.enabled)
            ExportPanGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  ExportPanGestureRecognizer
                >(ExportPanGestureRecognizer.new, (recognizer) {
                  recognizer.allowSelectedText = widget.selectedText;
                  recognizer.onStart = (_) => nativeExport('mouse');
                }),
        },
        child: widget.child,
      );
    }
    Widget draggable(bool delayed, Widget child) => _ContentDraggable(
      enabled: widget.enabled,
      delayed: delayed,
      allowSelectedText: () => widget.selectedText,
      onKind: (kind) {
        pointerKind = kind.name;
      },
      data: widget.entry,
      feedback: feedback(),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedbackOffset: const Offset(12, 12),
      onDragStarted: () => external.value = false,
      onDragUpdate: update,
      onDragEnd: (_) {
        if (mounted) external.value = false;
      },
      child: child,
    );
    return Listener(
      onPointerDown: (event) {
        sourcePointer ??= event.pointer;
      },
      onPointerUp: (event) {
        if (sourcePointer == event.pointer) sourcePointer = null;
      },
      onPointerCancel: (event) {
        if (sourcePointer == event.pointer) sourcePointer = null;
      },
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.grab : MouseCursor.defer,
        child: draggable(
          false,
          widget.touchDrags ? draggable(true, widget.child) : widget.child,
        ),
      ),
    );
  }

  Future<void> nativeExport(String kind) async {
    if (nativePending) return;
    nativePending = true;
    try {
      await widget.onExport(kind);
    } finally {
      nativePending = false;
    }
  }
}

class _ContentDraggable extends Draggable<DockEntry> {
  const _ContentDraggable({
    required bool enabled,
    required this.delayed,
    required this.allowSelectedText,
    required this.onKind,
    required super.data,
    required super.child,
    required super.feedback,
    required super.dragAnchorStrategy,
    required super.feedbackOffset,
    required super.onDragStarted,
    required super.onDragUpdate,
    required super.onDragEnd,
  }) : super(
         maxSimultaneousDrags: enabled ? 1 : 0,
         hitTestBehavior: HitTestBehavior.opaque,
       );
  final bool delayed;
  final bool Function() allowSelectedText;
  final void Function(PointerDeviceKind) onKind;
  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) =>
      (delayed
            ? _ContentDelayedRecognizer(onKind, allowSelectedText)
            : _ContentMouseRecognizer(onKind, allowSelectedText))
        ..onStart = onStart;
}

class _ContentMouseRecognizer extends ImmediateMultiDragGestureRecognizer {
  _ContentMouseRecognizer(this.onKind, this.allowSelectedText)
    : super(supportedDevices: const {PointerDeviceKind.mouse});
  final void Function(PointerDeviceKind) onKind;
  final bool Function() allowSelectedText;
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      !isContentDragControlPosition(event.position, event.viewId) &&
      (allowSelectedText() ||
          !isTextSelectionPosition(event.position, event.viewId)) &&
      super.isPointerAllowed(event);
  @override
  void addAllowedPointer(PointerDownEvent event) {
    onKind(event.kind);
    super.addAllowedPointer(event);
  }
}

class _ContentDelayedRecognizer extends DelayedMultiDragGestureRecognizer {
  _ContentDelayedRecognizer(this.onKind, this.allowSelectedText)
    : super(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
        allowedButtonsFilter: (buttons) =>
            buttons == kPrimaryButton || buttons == kSecondaryButton,
      );
  final void Function(PointerDeviceKind) onKind;
  final bool Function() allowSelectedText;
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      !isContentDragControlPosition(event.position, event.viewId) &&
      (allowSelectedText() ||
          !isTextSelectionPosition(event.position, event.viewId)) &&
      super.isPointerAllowed(event);
  @override
  void addAllowedPointer(PointerDownEvent event) {
    onKind(event.kind);
    super.addAllowedPointer(event);
  }
}
