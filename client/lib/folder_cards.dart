import 'models.dart';

/// Presentation only. The transport and persisted history retain every member.
class FolderCardEntry extends DockEntry {
  FolderCardEntry(this.root, Iterable<DockEntry> entries)
    : members = List.unmodifiable(entries),
      super(
        id: root.id,
        kind: root.kind,
        title: root.title,
        source: root.source,
        transferId: root.transferId,
        fileId: root.fileId,
        size: entries.fold(0, (sum, item) => sum + item.size),
        localPath: root.localPath,
        outgoing: root.outgoing,
        createdAtMillis: root.createdAtMillis,
        sourceReference: root.sourceReference,
        sourceLabel: root.sourceLabel,
        relativePath: root.relativePath,
        entryKind: 'directory',
        targetDeviceId: root.targetDeviceId,
        offerRoutePreference: root.offerRoutePreference,
        receiveRoutePreference: root.receiveRoutePreference,
        route: root.route,
      ) {
    final complete = members.every(folderMemberComplete);
    final active = members
        .where((item) => !folderMemberComplete(item))
        .toList();
    final state =
        active.where((item) => item.status == 'failed').firstOrNull ??
        active.where((item) => item.locallyPaused).firstOrNull ??
        active.where((item) => item.relayConfirmationPending).firstOrNull ??
        active
            .where(
              (item) => [
                'uploading',
                'downloading',
                'directSending',
              ].contains(item.status),
            )
            .firstOrNull ??
        active
            .where(
              (item) =>
                  !['canceled', 'rejected', 'expired'].contains(item.status),
            )
            .firstOrNull ??
        active.firstOrNull ??
        root;
    status = complete ? (outgoing ? 'sent' : 'received') : state.status;
    error = state.error;
    route = state.route;
    routeDetail = complete ? root.routeDetail : state.routeDetail;
    locallyPaused = active.any((item) => item.locallyPaused);
    locallyCanceled =
        active.isNotEmpty && active.every((item) => item.locallyCanceled);
    relayConfirmationPending = active.any(
      (item) => item.relayConfirmationPending,
    );
    relayPendingBeforeAccept = active.any(
      (item) => item.relayPendingBeforeAccept,
    );
    receiveFailure = active.any((item) => item.receiveFailure);
    receivedAtMillis = members.fold(
      0,
      (value, item) =>
          item.receivedAtMillis > value ? item.receivedAtMillis : value,
    );
    receivedBytes = members.fold(
      0,
      (sum, item) =>
          sum +
          (folderMemberComplete(item)
              ? item.size
              : (item.progress * item.size).round().clamp(0, item.size)),
    );
    progress = complete
        ? 1
        : size == 0
        ? 0
        : (receivedBytes / size).clamp(0, 1);
    transferBytesPerSecond = active.fold(
      0,
      (sum, item) => sum + item.transferBytesPerSecond,
    );
  }
  final DockEntry root;
  final List<DockEntry> members;
}

bool folderMemberComplete(DockEntry item) =>
    ['received', 'sent'].contains(item.status);

String folderGroupKey(DockEntry item) =>
    '${item.outgoing}:${item.transferId}:${item.relativePath.split('/').first}';

/// Only explicit top-level directory records own children. Standalone files,
/// separate transfers and legacy orphan records remain independent.
Map<String, List<DockEntry>> groupFolderEntries(Iterable<DockEntry> entries) {
  final values = entries.toList();
  final groups = <String, List<DockEntry>>{
    for (final item in values)
      if (item.kind == 'file' &&
          item.isDirectory &&
          item.transferId.isNotEmpty &&
          item.relativePath.isNotEmpty &&
          !item.relativePath.contains('/'))
        folderGroupKey(item): <DockEntry>[],
  };
  for (final item in values) {
    if (item.kind == 'file' && item.relativePath.isNotEmpty)
      groups[folderGroupKey(item)]?.add(item);
  }
  return groups;
}

List<DockEntry> collapseFolderCards(Iterable<DockEntry> entries) {
  final values = entries.toList();
  final groups = groupFolderEntries(values);
  return [
    for (final item in values)
      if (!groups.containsKey(folderGroupKey(item)))
        item
      else if (item.isDirectory && !item.relativePath.contains('/'))
        FolderCardEntry(item, groups[folderGroupKey(item)]!),
  ];
}

List<DockEntry> folderCardMembers(DockEntry item, Iterable<DockEntry> entries) {
  if (item is FolderCardEntry) return item.members;
  if (!item.isDirectory ||
      item.relativePath.isEmpty ||
      item.relativePath.contains('/'))
    return [item];
  return groupFolderEntries(entries)[folderGroupKey(item)] ?? [item];
}
