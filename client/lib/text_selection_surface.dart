import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

const _selectionMarker = 'globalsend-selectable-text';
const _dragControlMarker = 'globalsend-drag-control';

/// A real action remains a control even inside a whole-content drag surface.
class ContentDragControl extends StatelessWidget {
  const ContentDragControl({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => MetaData(
    metaData: _dragControlMarker,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

bool isContentDragControlPosition(Offset position, int viewId) {
  final result = HitTestResult();
  RendererBinding.instance.hitTestInView(result, position, viewId);
  return result.path.any(
    (entry) =>
        entry.target is RenderMetaData &&
        (entry.target as RenderMetaData).metaData == _dragControlMarker,
  );
}

bool isTextSelectionPosition(Offset position, int viewId) {
  final result = HitTestResult();
  RendererBinding.instance.hitTestInView(result, position, viewId);
  final marked = result.path.any(
    (entry) =>
        entry.target is RenderMetaData &&
        (entry.target as RenderMetaData).metaData == _selectionMarker,
  );
  if (!marked) return false;
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderParagraph) {
      if (_containsGlyph(
        target.text.toPlainText(),
        target.getPositionForOffset(target.globalToLocal(position)),
        target.globalToLocal(position),
        target.getBoxesForSelection,
      ))
        return true;
    } else if (target is RenderEditable) {
      if (_containsGlyph(
        target.text?.toPlainText() ?? '',
        target.getPositionForPoint(position),
        target.globalToLocal(position),
        target.getBoxesForSelection,
      ))
        return true;
    }
  }
  return false;
}

bool _containsGlyph(
  String text,
  TextPosition position,
  Offset local,
  List<TextBox> Function(TextSelection) boxes,
) {
  for (var index in [position.offset, position.offset - 1]) {
    if (index < 0 || index >= text.length) continue;
    final code = text.codeUnitAt(index);
    if (code >= 0xdc00 && code <= 0xdfff && index > 0) index--;
    final first = text.codeUnitAt(index);
    final end = index + (first >= 0xd800 && first <= 0xdbff ? 2 : 1);
    if (text.substring(index, end).trim().isEmpty) continue;
    if (boxes(TextSelection(baseOffset: index, extentOffset: end))
        .any((box) => box.toRect().inflate(.5).contains(local)))
      return true;
  }
  return false;
}

class EditableTextSelectionSurface extends StatelessWidget {
  const EditableTextSelectionSurface({
    super.key,
    required this.child,
    this.onBlankTap,
  });
  final Widget child;
  final ValueChanged<Offset>? onBlankTap;
  @override
  Widget build(BuildContext context) => MetaData(
    metaData: _selectionMarker,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: onBlankTap == null
          ? null
          : (details) => onBlankTap!(details.globalPosition),
      child: _TextGlyphGate(child: child),
    ),
  );
}

/// Keep blank padding out of the selection gesture arena. Editable fields
/// supply their ordinary focus/caret placement through onBlankTap.
class _TextGlyphGate extends SingleChildRenderObjectWidget {
  const _TextGlyphGate({required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTextGlyphGate();
}

class _RenderTextGlyphGate extends RenderProxyBox {
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final probe = BoxHitTestResult();
    if (!super.hitTestChildren(probe, position: position)) return false;
    final global = localToGlobal(position);
    final glyph = probe.path.any((entry) {
      final target = entry.target;
      if (target is RenderParagraph) {
        return _containsGlyph(
          target.text.toPlainText(),
          target.getPositionForOffset(target.globalToLocal(global)),
          target.globalToLocal(global),
          target.getBoxesForSelection,
        );
      }
      if (target is RenderEditable) {
        return _containsGlyph(
          target.text?.toPlainText() ?? '',
          target.getPositionForPoint(global),
          target.globalToLocal(global),
          target.getBoxesForSelection,
        );
      }
      return false;
    });
    return glyph && super.hitTestChildren(result, position: position);
  }
}

class ExportPanGestureRecognizer extends PanGestureRecognizer {
  ExportPanGestureRecognizer()
    : super(supportedDevices: const {PointerDeviceKind.mouse});
  bool allowSelectedText = false;
  @override
  bool isPointerAllowed(PointerEvent event) =>
      !isContentDragControlPosition(event.position, event.viewId) &&
      (allowSelectedText ||
          !isTextSelectionPosition(event.position, event.viewId)) &&
      super.isPointerAllowed(event);
}

/// Read-only file previews can open externally; real editing text retains
/// its own word-selection gesture.
class BlankDoubleTapGestureRecognizer extends DoubleTapGestureRecognizer {
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      !isTextSelectionPosition(event.position, event.viewId) &&
      super.isPointerAllowed(event);
}

class ExportLongPressGestureRecognizer extends LongPressGestureRecognizer {
  PointerDeviceKind? pointerKind;
  bool allowSelectedText = false;
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (primaryPointer == event.pointer) pointerKind = event.kind;
  }

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      !isContentDragControlPosition(event.position, event.viewId) &&
      (allowSelectedText ||
          !isTextSelectionPosition(event.position, event.viewId)) &&
      super.isPointerAllowed(event);
}
