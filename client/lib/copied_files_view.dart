import 'package:flutter/material.dart';

import 'copied_file_reference_card.dart';
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
          return SizedBox(
            width: 124,
            child: CopiedFileReferenceCard(
              key: ValueKey(
                'copied-file-${offer['offerId']}-${offer['itemId']}',
              ),
              reference: offer,
              onPull: () => onPull(offer, offer['itemId']!),
              onDismiss: () => client.dismiss(offer['id']!),
            ),
          );
        },
      ),
    );
  }
}
