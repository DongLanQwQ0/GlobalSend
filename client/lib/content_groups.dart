import 'models.dart';
import 'folder_cards.dart';
export 'folder_cards.dart';

String contentKey(DockEntry entry) {
  if (entry.kind == 'text' && !entry.autoClipboard) return 'text:${entry.text}';
  if (entry.kind == 'file' &&
      !entry.isDirectory &&
      entry.contentDigest.isNotEmpty &&
      (entry.outgoing
          ? [
              'received',
              'sent',
              'ready',
              'awaitingReceipt',
            ].contains(entry.status)
          : entry.localPath.isNotEmpty)) {
    return 'file:${entry.size}:${entry.contentDigest}';
  }
  return 'entry:${entry.transferId}:${entry.id}';
}

/// Group the display, retaining each delivery and external file reference.
List<DockEntry> mergeContentCards(Iterable<DockEntry> entries) {
  final ordered = collapseFolderCards(entries)
    ..sort(
      (a, b) =>
          (b.receivedAtMillis > 0 ? b.receivedAtMillis : b.createdAtMillis)
              .compareTo(
                a.receivedAtMillis > 0 ? a.receivedAtMillis : a.createdAtMillis,
              ),
    );
  final seen = <String>{};
  return ordered
      .where((entry) => seen.add('${entry.outgoing}:${contentKey(entry)}'))
      .toList();
}
