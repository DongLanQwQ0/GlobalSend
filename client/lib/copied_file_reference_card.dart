import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'ui_tokens.dart';

/// A remote reference has no local bytes to preview or drag. Reuse the normal
/// card surface, corner action and quiet footer in the workspace and dock.
class CopiedFileReferenceCard extends StatelessWidget {
  const CopiedFileReferenceCard({
    super.key,
    required this.reference,
    required this.onPull,
    required this.onDismiss,
    this.compact = false,
    this.surfaceColor,
  });
  final Map<String, dynamic> reference;
  final VoidCallback onPull, onDismiss;
  final bool compact;
  final Color? surfaceColor;

  @override
  Widget build(BuildContext context) {
    final palette = Ui.colors(context);
    final state = reference['state'];
    final busy = state == 'pending' || state == 'sending';
    final failed = state == 'failed';
    final name = reference['name'] as String;
    final status = busy
        ? '正在准备'
        : failed
        ? '拉取失败'
        : '';
    final glyph = AppIcon(
      reference['kind'] == 'directory'
          ? Icons.folder_outlined
          : Icons.insert_drive_file_outlined,
      size: compact ? 24 : 30,
      color: palette.accent,
    );
    final title = Text(
      name,
      maxLines: compact ? 1 : 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: Ui.textSm,
        height: Ui.leadingCompact,
        color: palette.textPrimary,
      ),
    );
    final source = Text(
      status.isNotEmpty ? status : reference['sourceName'] as String,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: Ui.text2xs,
        height: Ui.leadingCompact,
        color: failed ? palette.danger : palette.textSecondary,
      ),
    );
    return Material(
      color: surfaceColor ?? palette.surfaceMuted,
      shape: RoundedRectangleBorder(
        borderRadius: Ui.cardRadius,
        side: BorderSide(color: palette.line, width: Ui.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Semantics(
            button: true,
            label: '拉取 $name',
            enabled: !busy,
            child: InkWell(
              onTap: busy ? null : onPull,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  Ui.space2,
                  compact ? Ui.space1 : 28,
                  Ui.space2,
                  Ui.space1,
                ),
                child: compact
                    ? Row(
                        children: [
                          glyph,
                          const SizedBox(width: Ui.space1),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                title,
                                const SizedBox(height: Ui.space0),
                                source,
                              ],
                            ),
                          ),
                          const SizedBox(width: 28),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: Center(child: glyph)),
                          const SizedBox(height: Ui.space0),
                          title,
                          const SizedBox(height: Ui.space0),
                          Padding(
                            padding: const EdgeInsets.only(right: 20),
                            child: source,
                          ),
                          const SizedBox(height: Ui.space1),
                        ],
                      ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: '忽略此条目',
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: const EdgeInsets.all(7),
              icon: const AppIcon(Icons.close, size: 18),
              onPressed: onDismiss,
            ),
          ),
          if (busy)
            const Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 3),
            )
          else
            Positioned(
              bottom: Ui.space1,
              right: Ui.space1,
              child: IgnorePointer(
                child: AppIcon(
                  failed ? Icons.refresh_rounded : Icons.download_rounded,
                  size: 16,
                  color: failed ? palette.danger : palette.accent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
