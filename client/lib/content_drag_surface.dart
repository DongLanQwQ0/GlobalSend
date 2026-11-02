import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_icon.dart';
import 'content_preview.dart';
import 'models.dart';
import 'ios_drag_source.dart';
import 'system_bridge.dart';
import 'text_selection_surface.dart';
import 'ui_tokens.dart';

/// Windows hands the first painted preview to native export at drag start,
/// before its source window can be hidden by a virtual-desktop switch. Android
/// hands the original long press directly to the system, preserving its shadow.
class ContentDragSurface extends StatefulWidget {
  static const previewSize = Size(184, 140);
  const ContentDragSurface({
    super.key,
    required this.entry,
    required this.child,
    required this.onExport,
    this.enabled = true,
    this.selectedText = false,
    this.touchDrags = true,
    this.itemCount,
    this.nativeOnly = false,
    this.previewFromSource = true,
  });
  final DockEntry entry;
  final Widget child;
  final Future<void> Function(String kind) onExport;
  final bool enabled, selectedText, touchDrags;
  final int? itemCount;

  /// Content resolved on demand (for example clipboard recommendations) must
  /// use the native drop target, not a placeholder Flutter drag payload.
  final bool nativeOnly;

  /// Clipboard controls export content resolved by the native provider, not a
  /// picture of the toolbar button. Ordinary content cards keep their pixels.
  final bool previewFromSource;

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
  final previewKey = GlobalKey();

  Map<String, int> get previewPalette {
    final colors = Ui.colors(context);
    return {
      'background': colors.surface.toARGB32(),
      'ink': colors.textPrimary.toARGB32(),
      'accent': colors.accent.toARGB32(),
      'line': colors.line.toARGB32(),
    };
  }

  void retireFlutterDrag(int pointer) {
    if (!mounted || sourcePointer != pointer || !nativePending) return;
    external.value = true;
    GestureBinding.instance.cancelPointer(pointer);
  }

  Future<NativeDragPreview?> capturePreview() async {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    // The newly mounted long-press avatar needs one paint before readback.
    var element = previewKey.currentContext;
    var boundary = element?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return null;
      element = previewKey.currentContext;
      boundary = element?.findRenderObject();
    }
    if (boundary is! RenderRepaintBoundary ||
        !boundary.attached ||
        boundary.debugNeedsPaint) {
      return null;
    }
    if (!mounted || element == null || !element.mounted) return null;
    var opacity = 1.0;
    element.visitAncestorElements((element) {
      final ancestor = element.widget;
      if (ancestor is Opacity) opacity *= ancestor.opacity;
      return true;
    });
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return null;
      final rgba = bytes.buffer.asUint8List();
      if (opacity < 1) {
        // rawRgba is premultiplied; the dock's ancestor opacity scales every
        // channel, matching its in-window card rather than just the alpha.
        for (var i = 0; i < rgba.length; i++)
          rgba[i] = (rgba[i] * opacity).round();
      }
      return NativeDragPreview(rgba, image.width, image.height);
    } finally {
      image.dispose();
    }
  }

  void preparePreview() {
    if (Platform.isWindows && nativePending) return;
    external.value = false;
    if (Theme.of(context).platform == TargetPlatform.windows) {
      // The avatar is already mounted by Draggable. Capture its first paint,
      // then let OLE own the drag even if the pointer never leaves this window.
      promoteNativeDrag();
    }
  }

  @override
  void dispose() {
    external.dispose();
    super.dispose();
  }

  void update(DragUpdateDetails details) {
    final nativeDesktop = Theme.of(context).platform == TargetPlatform.windows;
    if (nativePending ||
        external.value ||
        (!nativeDesktop &&
            (Offset.zero & MediaQuery.sizeOf(context))
                .inflate(2)
                .contains(details.globalPosition)))
      return;
    promoteNativeDrag();
  }

  void promoteNativeDrag() {
    if (nativePending || external.value) return;
    final pointer = sourcePointer;
    if (pointer == null) return;
    final kind = pointerKind;
    final windowsHandoff =
        Platform.isWindows &&
        Theme.of(context).platform == TargetPlatform.windows;
    nativePending = true;
    // Preparing an export is not pointer ownership. Retire Flutter's stream
    // only after native acknowledgement, or when this request finishes.
    unawaited(() async {
      try {
        // Refresh the pixels at the handoff: image decoding may have finished
        // after the first drag frame. Keep the avatar mounted until readback.
        final card = Platform.isWindows ? await capturePreview() : null;
        if (!mounted || sourcePointer != pointer) return;
        if (!windowsHandoff) retireFlutterDrag(pointer);
        await SystemBridge.withDragPreview(
          card,
          () => widget.onExport(kind),
          palette: previewPalette,
          // Keep the painted card until Windows actually enters OLE. Queuing
          // an export/reading its pixels does not transfer pointer ownership.
          onStarted: windowsHandoff ? () => retireFlutterDrag(pointer) : null,
        );
      } finally {
        if (sourcePointer == pointer) {
          GestureBinding.instance.cancelPointer(pointer);
          sourcePointer = null;
        }
        nativePending = false;
        if (mounted) external.value = false;
      }
    }());
  }

  Widget feedback() => ValueListenableBuilder<bool>(
    valueListenable: external,
    builder: (_, exporting, child) => exporting ? const SizedBox() : child!,
    child: RepaintBoundary(
      key: previewKey,
      child: Opacity(
        opacity: .9,
        child: Material(
          key: ValueKey('drag-feedback-${widget.entry.id}'),
          color: Ui.colors(context).surface,
          elevation: Ui.elevationModal,
          // Material takes one colour, not a BoxShadow: mirror Ui.shadow3.
          shadowColor: Ui.colors(context)
              .shadowAt(Ui.colors(context).isDark ? .52 : .18),
          shape: RoundedRectangleBorder(
            borderRadius: Ui.cardRadius,
            side: BorderSide(color: Ui.colors(context).line),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: ContentDragSurface.previewSize.width,
            height: ContentDragSurface.previewSize.height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ContentPreview(
                    borderRadius: BorderRadius.zero,
                    location: widget.entry.localPath,
                    name: widget.entry.title,
                    text: widget.entry.kind == 'text'
                        ? widget.entry.text
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Ui.space2,
                    vertical: Ui.space1,
                  ),
                  child: Row(
                    children: [
                      AppIcon(
                        Icons.add,
                        size: 16,
                        color: Ui.colors(context).accent,
                      ),
                      const SizedBox(width: Ui.space1),
                      Text(
                        widget.itemCount == null
                            ? '复制'
                            : '复制 ${widget.itemCount} 项',
                        style: TextStyle(
                          fontSize: Ui.text2xs,
                          height: Ui.leadingNormal,
                          color: Ui.colors(context).accent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return IOSDragSource(
        entry: widget.entry,
        enabled: widget.enabled && widget.touchDrags,
        child: widget.child,
      );
    }
    if (Theme.of(context).platform == TargetPlatform.android ||
        widget.nativeOnly) {
      final gestures = RawGestureDetector(
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
      if (!widget.nativeOnly) return gestures;
      return Listener(
        onPointerDown: (event) => sourcePointer ??= event.pointer,
        onPointerUp: (event) {
          if (sourcePointer == event.pointer) sourcePointer = null;
        },
        onPointerCancel: (event) {
          if (sourcePointer == event.pointer) sourcePointer = null;
        },
        child: MouseRegion(
          cursor: widget.enabled ? SystemMouseCursors.grab : MouseCursor.defer,
          child: RepaintBoundary(key: previewKey, child: gestures),
        ),
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
      dragAnchorStrategy: (_, _, _) => Offset(
        ContentDragSurface.previewSize.width / 2,
        ContentDragSurface.previewSize.height / 2,
      ),
      feedbackOffset: Offset.zero,
      onDragStarted: preparePreview,
      onDragUpdate: update,
      onDragEnd: (_) {
        // cancelPointer retires the avatar during native handoff. It must not
        // re-enable Flutter feedback while the same OLE operation is running.
        if (mounted &&
            (!Platform.isWindows ||
                Theme.of(context).platform != TargetPlatform.windows ||
                !nativePending)) {
          external.value = false;
        }
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
    final pointer = sourcePointer;
    final windowsHandoff =
        Platform.isWindows &&
        Theme.of(context).platform == TargetPlatform.windows;
    nativePending = true;
    try {
      if (widget.nativeOnly) {
        final preview = widget.previewFromSource
            ? await capturePreview()
            : null;
        if (!mounted || pointer == null || sourcePointer != pointer) return;
        if (!windowsHandoff) GestureBinding.instance.cancelPointer(pointer);
        await SystemBridge.withDragPreview(
          preview,
          () => widget.onExport(kind),
          palette: previewPalette,
          onStarted: windowsHandoff ? () => retireFlutterDrag(pointer) : null,
        );
      } else {
        await widget.onExport(kind);
      }
    } finally {
      if (widget.nativeOnly && windowsHandoff) {
        if (pointer != null && sourcePointer == pointer) {
          GestureBinding.instance.cancelPointer(pointer);
          sourcePointer = null;
        }
        if (mounted) external.value = false;
      }
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
