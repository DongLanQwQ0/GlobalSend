import 'package:flutter/material.dart';

import 'app_icon_paths.dart';

/// Same icon identifiers and semantics, drawn as vectors without an icon font.
class AppIcon extends Icon {
  const AppIcon(
    super.icon, {
    super.key,
    super.size,
    super.color,
    super.semanticLabel,
    super.textDirection,
    super.applyTextScaling,
    super.shadows,
    super.fill,
    super.weight,
    super.grade,
    super.opticalSize,
    super.blendMode,
    super.fontWeight,
  });

  static bool supports(IconData value) =>
      appIconPaths.containsKey(value.codePoint);

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final extent = size ?? theme.size ?? 24;
    final scaled = (applyTextScaling ?? theme.applyTextScaling ?? false)
        ? MediaQuery.textScalerOf(context).scale(extent)
        : extent;
    final base = color ?? theme.color ?? Colors.black;
    final opacity = theme.opacity ?? 1;
    final ink = base.withValues(alpha: base.a * opacity);
    final direction = textDirection ?? Directionality.of(context);
    return Semantics(
      label: semanticLabel,
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: scaled,
          child: CustomPaint(
            painter: _VectorIconPainter(
              icon?.codePoint,
              ink,
              mirror:
                  icon?.matchTextDirection == true &&
                  direction == TextDirection.rtl,
              shadows: shadows ?? theme.shadows ?? const [],
            ),
          ),
        ),
      ),
    );
  }
}

class _VectorIconPainter extends CustomPainter {
  const _VectorIconPainter(
    this.codePoint,
    this.color, {
    required this.mirror,
    required this.shadows,
  });
  final int? codePoint;
  final Color color;
  final bool mirror;
  final List<Shadow> shadows;
  static final _paths = <int, Path>{};
  Path? path() {
    if (codePoint == null) return null;
    if (_paths[codePoint] case final cached?) return cached;
    final commands = appIconPaths[codePoint];
    assert(
      commands != null,
      'Missing vector icon 0x${codePoint!.toRadixString(16)}',
    );
    if (commands == null) return null;
    final value = Path()..fillType = PathFillType.nonZero;
    var index = 0;
    while (index < commands.length) {
      switch (commands[index++].toInt()) {
        case 0:
          value.moveTo(commands[index++], commands[index++]);
        case 1:
          value.lineTo(commands[index++], commands[index++]);
        case 2:
          value.cubicTo(
            commands[index++],
            commands[index++],
            commands[index++],
            commands[index++],
            commands[index++],
            commands[index++],
          );
        case 3:
          value.close();
      }
    }
    return _paths[codePoint!] = value;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final outline = path();
    if (outline == null) return;
    canvas.save();
    // Tight, non-square parents must not stretch a gear or a chain. Center the
    // canonical 24-unit viewport and use a uniform scale in either direction.
    final scale = size.shortestSide / 24;
    canvas.translate(
      (size.width - 24 * scale) / 2,
      (size.height - 24 * scale) / 2,
    );
    canvas.scale(scale, scale);
    if (mirror) {
      canvas.translate(24, 0);
      canvas.scale(-1, 1);
    }
    for (final shadow in shadows) {
      canvas.save();
      canvas.translate(shadow.offset.dx, shadow.offset.dy);
      canvas.drawPath(outline, shadow.toPaint());
      canvas.restore();
    }
    canvas.drawPath(
      outline,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_VectorIconPainter old) =>
      old.codePoint != codePoint ||
      old.color != color ||
      old.mirror != mirror ||
      old.shadows != shadows;
}

/// ExpansionTile's default arrow is font-based, so provide the vector explicitly.
class AppExpansionTile extends StatefulWidget {
  const AppExpansionTile({
    super.key,
    required this.title,
    required this.children,
    this.tilePadding,
    this.childrenPadding,
    this.shape,
    this.collapsedShape,
  });
  final Widget title;
  final List<Widget> children;
  final EdgeInsetsGeometry? tilePadding, childrenPadding;
  final ShapeBorder? shape, collapsedShape;
  @override
  State<AppExpansionTile> createState() => _AppExpansionTileState();
}

class _AppExpansionTileState extends State<AppExpansionTile> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: widget.title,
    tilePadding: widget.tilePadding,
    childrenPadding: widget.childrenPadding,
    shape: widget.shape,
    collapsedShape: widget.collapsedShape,
    onExpansionChanged: (value) => setState(() => expanded = value),
    trailing: AnimatedRotation(
      turns: expanded ? 0.5 : 0,
      duration: const Duration(milliseconds: 180),
      child: const AppIcon(Icons.expand_more),
    ),
    children: widget.children,
  );
}

class AppCheckedPopupMenuItem<T> extends PopupMenuItem<T> {
  AppCheckedPopupMenuItem({
    super.key,
    super.value,
    required bool checked,
    required Widget child,
  }) : super(
         child: Row(
           children: [
             SizedBox(
               width: 24,
               child: checked ? const AppIcon(Icons.done, size: 20) : null,
             ),
             const SizedBox(width: 12),
             Flexible(child: child),
           ],
         ),
       );
}
