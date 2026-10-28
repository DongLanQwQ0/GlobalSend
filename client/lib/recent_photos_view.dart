import 'app_icon.dart';

import 'package:flutter/material.dart';

import 'recent_photos.dart';
import 'ui_tokens.dart';

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
        padding: const EdgeInsets.only(left: 12, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '新图片',
                style: TextStyle(fontSize: 12, color: Ui.colors(context).muted),
              ),
            ),
            IconButton(
              tooltip: '忽略这些图片',
              visualDensity: VisualDensity.compact,
              onPressed: enabled ? onDismiss : null,
              icon: const AppIcon(Icons.close_rounded, size: 17),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          itemCount: photos.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, index) {
            final photo = photos[index];
            return AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(photo.thumbnail, fit: BoxFit.cover),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: ValueKey('suggested-photo-${photo.id}'),
                        onTap: enabled ? () => onAdd(photo.id) : null,
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: EdgeInsets.all(5),
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: Ui.colors(context).surface,
                              child: AppIcon(
                                Icons.add_rounded,
                                size: 18,
                                color: Ui.colors(context).green,
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
          },
        ),
      ),
    ],
  );
}
