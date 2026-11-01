import 'package:flutter/material.dart';

import 'app_icon.dart';
import 'copied_files.dart';
import 'ui_tokens.dart';

/// The same designated-device offers are used by the workspace and UI docks.
/// A remote reference is clickable, not draggable before a local copy exists.
class CopiedFileOffers extends StatelessWidget {
  const CopiedFileOffers({
    super.key,
    required this.client,
    required this.onPull,
  });
  final CopiedFilesClient client;
  final Future<void> Function(Map<String, dynamic> offer, String itemId) onPull;
  @override
  Widget build(BuildContext context) {
    final entries = client.references;
    if (entries.isEmpty) return const SizedBox.shrink();
    final palette = Ui.colors(context);
    return SizedBox(
      key: const ValueKey('copied-file-offers'),
      height: 72,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: Ui.space2,
          vertical: Ui.space1,
        ),
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: Ui.space1),
        itemBuilder: (context, index) {
          final offer = entries[index];
          final item = {
            'id': offer['itemId'],
            'name': offer['name'],
            'kind': offer['kind'],
          };
          final state = offer['state'];
          final busy = state == 'pending' || state == 'sending';
          return SizedBox(
            width: 186,
            child: TextButton(
              key: ValueKey('copied-file-${offer['offerId']}-${item['id']}'),
              onPressed: busy
                  ? null
                  : () => onPull(offer, item['id'] as String),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: Ui.space1),
                backgroundColor: palette.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: Ui.fieldRadius,
                ),
              ),
              child: Row(
                children: [
                  AppIcon(
                    item['kind'] == 'directory'
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 20,
                  ),
                  const SizedBox(width: Ui.space1),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['name'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Ui.textSm,
                            color: palette.textPrimary,
                          ),
                        ),
                        Text(
                          busy
                              ? '正在准备'
                              : state == 'failed'
                              ? '拉取失败，点击重试'
                              : offer['sourceName'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Ui.text2xs,
                            color: state == 'failed'
                                ? palette.danger
                                : palette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Ui.space0),
                  if (busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const AppIcon(Icons.download_rounded, size: 18),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
