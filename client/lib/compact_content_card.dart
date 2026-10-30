import 'app_icon.dart';

import 'package:flutter/material.dart';

import 'content_preview.dart';
import 'image_kind.dart';
import 'models.dart';
import 'saved_files.dart';
import 'ui_tokens.dart';
import 'text_selection_surface.dart';
import 'incoming_receipt_state.dart';

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
    this.previewOnly = false,
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

  /// The independent dock overlays controls on its preview, without a metadata
  /// footer. Main receive/history/library cards keep their default layout.
  final bool previewOnly;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => ImageKindBuilder(
      location: entry.kind == 'file' && !entry.isDirectory
          ? entry.localPath
          : '',
      name: entry.title,
      builder: (context, image) => _buildCard(context, bounds.maxWidth, image),
    ),
  );

  Widget _buildCard(BuildContext context, double width, bool detectedImage) {
    final receive = IncomingReceiptState(entry);
    final stateLabel = status.isNotEmpty ? status : receive.label;
    final compactAction =
        width < 180 * MediaQuery.textScalerOf(context).scale(1);
    final image =
        entry.kind == 'file' &&
        detectedImage &&
        (!receive.incomingFile || receive.canExport);
    final active =
        ['uploading', 'downloading', 'directSending'].contains(entry.status) ||
        receive.showProgress;
    final category = detectedImage
        ? SavedFileCategory.image
        : savedFileCategory(entry.title);
    final canPreview =
        entry.kind == 'text' ||
        receive.canExport &&
            entry.localPath.isNotEmpty &&
            const {
              SavedFileCategory.image,
              SavedFileCategory.text,
            }.contains(category);
    final card = Material(
      color: surfaceColor ?? Ui.colors(context).surface,
      shape: RoundedRectangleBorder(
        borderRadius: Ui.cardRadius,
        side: BorderSide(
          color: selected
              ? Ui.colors(context).green
              : Ui.colors(context).border,
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
                if (previewOnly && (entry.isDirectory || !canPreview))
                  _DockFileSummary(
                    entry: entry,
                    bottomSpace:
                        stateLabel.isNotEmpty ||
                            speed.isNotEmpty ||
                            action != null
                        ? 42
                        : 8,
                    color: previewColor,
                  )
                else if (entry.isDirectory)
                  ColoredBox(
                    color: previewColor ?? Ui.colors(context).input,
                    child: Center(
                      child: AppIcon(
                        Icons.folder_outlined,
                        size: 56,
                        color: Ui.colors(context).green,
                      ),
                    ),
                  )
                else
                  ContentPreview(
                    key: ValueKey('preview-${entry.id}'),
                    location: entry.localPath,
                    name: entry.title,
                    text: entry.kind == 'text' ? entry.text : null,
                    topInset: menu != null || selecting
                        ? (previewOnly ? 24 : 28)
                        : 0,
                    maxTextLines: previewOnly && onCopy != null ? 3 : null,
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
                        color:
                            menuColor ??
                            Ui.colors(context).surface.withValues(alpha: .94),
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(width: 36, height: 32, child: menu),
                      ),
                    ),
                  ),
                if (previewOnly && !selecting && onCopy != null)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: ContentDragControl(
                      child: Material(
                        color: Ui.colors(context).surface
                            .withValues(alpha: .82),
                        borderRadius: BorderRadius.circular(10),
                        child: TextButton(
                          key: copyKey,
                          style: TextButton.styleFrom(
                            minimumSize: const Size(40, 28),
                            padding: const EdgeInsets.symmetric(horizontal: 7),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(fontSize: 12),
                          ),
                          onPressed: onCopy,
                          child: const Text('复制'),
                        ),
                      ),
                    ),
                  ),
                if (previewOnly &&
                    !selecting &&
                    (stateLabel.isNotEmpty ||
                        speed.isNotEmpty ||
                        action != null))
                  Positioned(
                    left: 5,
                    right: 5,
                    bottom: 6,
                    child: Material(
                      color: Ui.colors(context).surface.withValues(alpha: .82),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (stateLabel.isNotEmpty)
                                    Text(
                                      stateLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: entry.status == 'failed'
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .error
                                            : Ui.colors(context).ink,
                                      ),
                                    ),
                                  if (speed.isNotEmpty)
                                    Text(
                                      speed,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Ui.colors(context).muted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (action != null)
                              ContentDragControl(
                                child: TextButtonTheme(
                                  data: TextButtonThemeData(
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(28, 26),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      textStyle: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(fontSize: 12),
                                    ),
                                  ),
                                  child: action!,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (active)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: LinearProgressIndicator(
                      value: receive.showProgress
                          ? receive.progressValue
                          : entry.progress.clamp(0, 1),
                      minHeight: 3,
                    ),
                  ),
              ],
            ),
          ),
          if (!previewOnly && image)
            Container(
              color: metadataColor ?? Ui.colors(context).input,
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
                      style: TextStyle(
                        fontSize: 11,
                        color: Ui.colors(context).muted,
                      ),
                    ),
                  Text(
                    [
                      bytesLabel(entry.size),
                      timestamp,
                    ].where((part) => part.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Ui.colors(context).muted,
                    ),
                  ),
                  if (!selecting && (stateLabel.isNotEmpty || speed.isNotEmpty))
                    Text(
                      [
                        stateLabel,
                        speed,
                      ].where((part) => part.isNotEmpty).join(' · '),
                      style: TextStyle(
                        fontSize: 11,
                        color: entry.status == 'failed'
                            ? Theme.of(context).colorScheme.error
                            : Ui.colors(context).muted,
                      ),
                    ),
                  if (!selecting && action != null)
                    ContentDragControl(child: action!),
                ],
              ),
            )
          else if (!previewOnly)
            Container(
              color: metadataColor ?? Ui.colors(context).input,
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
                  if (!selecting && (stateLabel.isNotEmpty || speed.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [
                          stateLabel,
                          speed,
                        ].where((part) => part.isNotEmpty).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: entry.status == 'failed'
                              ? Theme.of(context).colorScheme.error
                              : Ui.colors(context).muted,
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
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: Ui.colors(context).muted,
                              ),
                            ),
                            if (sender.isNotEmpty)
                              Text(
                                sender,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.3,
                                  color: Ui.colors(context).muted,
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
                              icon: const AppIcon(Icons.copy, size: 14),
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

class _DockFileSummary extends StatelessWidget {
  const _DockFileSummary({
    required this.entry,
    required this.bottomSpace,
    this.color,
  });
  final DockEntry entry;
  final double bottomSpace;
  final Color? color;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: color ?? Ui.colors(context).input,
    child: Padding(
      padding: EdgeInsets.fromLTRB(10, 24, 10, bottomSpace),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(
            entry.isDirectory
                ? Icons.folder_outlined
                : switch (savedFileCategory(entry.title)) {
                    SavedFileCategory.image => Icons.image_outlined,
                    SavedFileCategory.video => Icons.movie_outlined,
                    SavedFileCategory.audio => Icons.music_note_outlined,
                    SavedFileCategory.archive => Icons.folder_zip_outlined,
                    _ => Icons.insert_drive_file_outlined,
                  },
            size: bottomSpace > 8 ? 28 : 40,
            color: Ui.colors(context).green,
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: Ui.colors(context).ink,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
