import 'package:flutter/material.dart';

import 'copied_file_reference_card.dart';
import 'copied_files.dart';
import 'models.dart';
import 'ios_drag_source.dart';
import 'content_drag_surface.dart';
import 'ui_tokens.dart';

/// The same designated-device offers are used by the workspace and UI docks.
/// Remote references use native on-demand providers; ready copies use ordinary drag.
class CopiedFileOffers extends StatelessWidget {
  const CopiedFileOffers({
    super.key,
    required this.client,
    required this.onPull,
    this.onExport,
  });
  final CopiedFilesClient client;
  final Future<void> Function(Map<String, dynamic> offer, String itemId) onPull;
  final Future<void> Function(
    Map<String, dynamic> reference,
    String pointerKind,
  )?
  onExport;
  @override
  Widget build(BuildContext context) {
    final entries = client.references;
    if (entries.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey('copied-file-offers'),
      height: 140,
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
          final tile = CopiedFileReferenceCard(
            key: ValueKey('copied-file-${offer['offerId']}-${offer['itemId']}'),
            reference: offer,
            onPull: () => onPull(offer, offer['itemId']!),
            onDismiss: () => client.dismiss(offer['id']!),
          );
          return SizedBox(
            width: 124,
            child: onExport == null
                ? tile
                : Theme.of(context).platform == TargetPlatform.iOS &&
                      offer['state'] != 'received'
                ? IOSDragSource.remote(
                    remoteReference: offer,
                    enabled: true,
                    child: tile,
                  )
                : ContentDragSurface(
                    entry: DockEntry(
                      id: offer['id']!,
                      kind: 'file',
                      title: offer['name']!,
                      source: offer['sourceDeviceId']!,
                      localPath: offer['localPath'] ?? '',
                      status: offer['state'] == 'received'
                          ? 'received'
                          : 'offered',
                      entryKind: offer['kind'] == 'directory'
                          ? 'directory'
                          : 'file',
                    ),
                    nativeOnly:
                        Theme.of(context).platform == TargetPlatform.windows &&
                        offer['state'] != 'received',
                    onExport: (kind) => onExport!(offer, kind),
                    child: tile,
                  ),
          );
        },
      ),
    );
  }
}
