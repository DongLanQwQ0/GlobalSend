import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'recent_photos.dart';
import 'suggestion_card_corner.dart';
import 'ui_tokens.dart';

class RecentPhotoTile extends StatelessWidget {
  const RecentPhotoTile({
    super.key,
    required this.photo,
    required this.onAdd,
    this.onDismiss,
    this.onDrag,
  });
  final SuggestedPhoto photo;
  final VoidCallback? onAdd, onDismiss, onDrag;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: Ui.cardRadius,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(photo.thumbnail, fit: BoxFit.cover),
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('suggested-photo-${photo.id}'),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed))
                return Ui.colors(context).accent.withValues(alpha: .12);
              if (states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.focused))
                return Ui.colors(context).accent.withValues(alpha: .06);
              return null;
            }),
            onTap: onAdd,
            onLongPress: onDrag,
            child: const SizedBox.expand(),
          ),
        ),
        const SuggestionCardCorner.add(),
        if (onDismiss != null)
          SuggestionCardCorner.dismiss(
            tooltip: '忽略此媒体建议',
            onDismiss: onDismiss,
            overImage: true,
          ),
      ],
    ),
  );
}

class RecentPhotosView extends StatelessWidget {
  const RecentPhotosView({
    super.key,
    required this.photos,
    required this.onAdd,
    required this.onDismiss,
    this.enabled = true,
  });
  final List<SuggestedPhoto> photos;
  final ValueChanged<String> onAdd;
  final VoidCallback onDismiss;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: Ui.space2, right: Ui.space0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '新图片',
                style: TextStyle(
                  fontSize: Ui.text2xs,
                  height: Ui.leadingCompact,
                  color: Ui.colors(context).textSecondary,
                ),
              ),
            ),
            IconButton(
              tooltip: '忽略这些图片',
              visualDensity: VisualDensity.compact,
              onPressed: enabled ? onDismiss : null,
              icon: const AppIcon(Icons.close_rounded, size: Ui.iconSm),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(
            Ui.space2,
            0,
            Ui.space2,
            Ui.space1,
          ),
          itemCount: photos.length,
          separatorBuilder: (_, _) => const SizedBox(width: Ui.space1),
          itemBuilder: (_, index) {
            final photo = photos[index];
            return AspectRatio(
              aspectRatio: 1,
              child: RecentPhotoTile(
                photo: photo,
                onAdd: enabled ? () => onAdd(photo.id) : null,
              ),
            );
          },
        ),
      ),
    ],
  );
}
