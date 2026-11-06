import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'text_selection_surface.dart';
import 'ui_tokens.dart';

/// Compact artwork stays close to the edge without shrinking the dismiss
/// button's touch target. The add mark belongs to the media tile's tap action.
class SuggestionCardCorner extends StatelessWidget {
  const SuggestionCardCorner.add({super.key})
    : onDismiss = null,
      tooltip = null,
      overImage = false;

  const SuggestionCardCorner.dismiss({
    super.key,
    required this.onDismiss,
    required String this.tooltip,
    this.overImage = false,
  });

  final VoidCallback? onDismiss;
  final String? tooltip;
  final bool overImage;
  static const _artSize = Ui.space4;

  @override
  Widget build(BuildContext context) {
    final colors = Ui.colors(context);
    if (tooltip == null) {
      return Positioned(
        right: Ui.space0,
        bottom: Ui.space0,
        child: IgnorePointer(
          child: CircleAvatar(
            radius: _artSize / 2,
            backgroundColor: colors.surface,
            child: AppIcon(
              Icons.add_rounded,
              size: Ui.iconSm,
              color: colors.accent,
            ),
          ),
        ),
      );
    }

    const hitSize = Ui.space6;
    const centerOffset = hitSize - _artSize - 2 * Ui.space0;
    return Positioned(
      top: 0,
      right: 0,
      child: ContentDragControl(
        child: SizedBox.square(
          dimension: hitSize,
          child: IconButton(
            tooltip: tooltip,
            padding: const EdgeInsets.only(
              left: centerOffset,
              bottom: centerOffset,
            ),
            style: IconButton.styleFrom(
              minimumSize: const Size.square(hitSize),
              visualDensity: VisualDensity.standard,
              foregroundColor: overImage ? Colors.white : colors.textSecondary,
            ),
            onPressed: onDismiss,
            icon: AppIcon(
              Icons.close_rounded,
              size: Ui.iconSm,
              shadows: overImage
                  ? const [Shadow(color: Colors.black, blurRadius: 3)]
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
