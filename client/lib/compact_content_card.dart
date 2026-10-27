import 'package:flutter/material.dart';

import 'content_preview.dart';
import 'models.dart';
import 'saved_files.dart';
import 'ui_tokens.dart';
import 'text_selection_surface.dart';

/// Shared visual contract for receive/history/library cards and the Windows
/// receive dock. Actions are supplied by the owning application session.
class CompactContentCard extends StatelessWidget {
  const CompactContentCard({
    super.key,
    required this.entry,
    required this.sender,
    required this.timestamp,
    required this.onOpen,
    this.onCopy,
    this.menu,
    this.action,
    this.status = '',
    this.speed = '',
    this.selecting = false,
    this.selected = false,
    this.onToggle,
    this.onLongPress,
    this.copyKey,
    this.surfaceColor,
    this.metadataColor,
    this.previewColor,
    this.menuColor,
  });
  final DockEntry entry;
  final String sender, timestamp, status, speed;
  final VoidCallback onOpen;
  final VoidCallback? onCopy, onToggle, onLongPress;
  final Widget? menu, action;
  final bool selecting, selected;
  final Key? copyKey;
  final Color? surfaceColor, metadataColor;
  final Color? previewColor, menuColor;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => _buildCard(context, bounds.maxWidth),
  );

  Widget _buildCard(BuildContext context, double width) {
    final compactAction =
        width < 180 * MediaQuery.textScalerOf(context).scale(1);
    final image =
        entry.kind == 'file' &&
        savedFileCategory(entry.title) == SavedFileCategory.image;
    final active = [
      'uploading',
      'downloading',
      'directSending',
    ].contains(entry.status);
    final card = Material(
      color: surfaceColor ?? Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: Ui.cardRadius,
        side: BorderSide(
          color: selected ? Ui.green : Ui.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (entry.isDirectory)
                  ColoredBox(
                    color: previewColor ?? Ui.input,
                    child: const Center(
                      child: Icon(
                        Icons.folder_outlined,
                        size: 56,
                        color: Ui.green,
                      ),
                    ),
                  )
                else
                  ContentPreview(
                    key: ValueKey('preview-${entry.id}'),
                    location: entry.localPath,
                    name: entry.title,
                    text: entry.kind == 'text' ? entry.text : null,
                    topInset: menu != null || selecting ? 28 : 0,
                    backgroundColor: previewColor,
                    borderRadius: BorderRadius.zero,
                  ),
                if (selecting)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) => onToggle?.call(),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  )
                else if (menu != null)
                  Positioned(
                    right: 5,
                    top: 5,
                    child: ContentDragControl(
                      child: Material(
                        color: menuColor ?? Colors.white.withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(width: 36, height: 32, child: menu),
                      ),
                    ),
                  ),
                if (active)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: LinearProgressIndicator(
                      value: entry.progress.clamp(0, 1),
                      minHeight: 3,
                    ),
                  ),
              ],
            ),
          ),
          if (image)
            Container(
              color: metadataColor ?? Ui.input,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (sender.isNotEmpty)
                    Text(
                      sender,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Ui.muted),
                    ),
                  Text(
                    [
                      bytesLabel(entry.size),
                      timestamp,
                    ].where((part) => part.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Ui.muted),
                  ),
                  if (!selecting && (status.isNotEmpty || speed.isNotEmpty))
                    Text(
                      [
                        status,
                        speed,
                      ].where((part) => part.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 11,
                        color: entry.status == 'failed'
                            ? Theme.of(context).colorScheme.error
                            : Ui.muted,
                      ),
                    ),
                  if (!selecting && action != null)
                    ContentDragControl(child: action!),
                ],
              ),
            )
          else
            Container(
              color: metadataColor ?? Ui.input,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (entry.kind != 'text') ...[
                    Tooltip(
                      triggerMode: TooltipTriggerMode.manual,
                      message: entry.title,
                      child: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                  ],
                  if (!selecting && (status.isNotEmpty || speed.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          status,
                          speed,
                        ].where((part) => part.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: entry.status == 'failed'
                              ? Theme.of(context).colorScheme.error
                              : Ui.muted,
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              compactAction &&
                                      (onCopy != null || action != null)
                                  ? timestamp
                                  : [
                                          entry.kind == 'text'
                                              ? '${entry.text.runes.length} 字符'
                                              : bytesLabel(entry.size),
                                          timestamp,
                                        ]
                                        .where((part) => part.isNotEmpty)
                                        .join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: Ui.muted,
                              ),
                            ),
                            if (sender.isNotEmpty)
                              Text(
                                sender,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.3,
                                  color: Ui.muted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (!selecting && onCopy != null)
                        if (compactAction)
                          ContentDragControl(
                            child: TextButton(
                              key: copyKey,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(32, 32),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: onCopy,
                              child: const Text('复制'),
                            ),
                          )
                        else
                          ContentDragControl(
                            child: TextButton.icon(
                              key: copyKey,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(36, 32),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: onCopy,
                              icon: const Icon(Icons.copy, size: 14),
                              label: const Text('复制'),
                            ),
                          ),
                      if (!selecting && action != null)
                        ContentDragControl(child: action!),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return Semantics(
      button: true,
      label: image ? entry.title : null,
      selected: selecting ? selected : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: selecting ? onToggle : onOpen,
        onLongPress: selecting ? null : onLongPress,
        child: selecting
            ? AbsorbPointer(child: card)
            : Tooltip(
                triggerMode: TooltipTriggerMode.manual,
                message: entry.title,
                child: card,
              ),
      ),
    );
  }
}
