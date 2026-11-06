import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'ui_tokens.dart';

/// History and the file library size their columns from their own pane,
/// after the scroll view has applied its insets.
class AdaptiveContentGrid extends SliverGridDelegate {
  AdaptiveContentGrid(BuildContext context)
    : desktop = MediaQuery.sizeOf(context).width >= 900,
      textScale = MediaQuery.textScalerOf(context);

  final bool desktop;
  final TextScaler textScale;

  static double _footerHeight(TextScaler text) =>
      Ui.space1 +
      Ui.space2 +
      Ui.space0 +
      (text.scale(Ui.textXs) + 2 * text.scale(Ui.text2xs)) * Ui.leadingTight;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    const gap = Ui.space2;
    final minWidth = desktop ? 118 : 148;
    final available = constraints.crossAxisExtent;
    final columns = math.max(1, ((available + gap) / (minWidth + gap)).floor());
    final cardWidth = (available - gap * (columns - 1)) / columns;
    final textPreviewHeight =
        Ui.space2 + Ui.space4 + Ui.space1 +
        2 * textScale.scale(Ui.textSm) * Ui.leadingNormal;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: gap,
      mainAxisSpacing: gap,
      mainAxisExtent: math.max(
        cardWidth + Ui.space4,
        _footerHeight(textScale) + textPreviewHeight,
      ),
    ).getLayout(constraints);
  }

  @override
  bool shouldRelayout(AdaptiveContentGrid oldDelegate) =>
      desktop != oldDelegate.desktop || textScale != oldDelegate.textScale;
}
