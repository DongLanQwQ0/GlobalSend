import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// One local history for this installation. Remote authorizations remain in
/// their sessions; these records contain content/references, never tokens.
class LocalHistoryRecord {
  LocalHistoryRecord(
    this.profileKey,
    this.deviceId,
    this.entry, {
    this.localTextEdit = false,
  });
  final String profileKey, deviceId;
  final DockEntry entry;
  bool localTextEdit;
  String get key => '$profileKey:${entry.id}';
  Map<String, dynamic> toJson() => {
    'profileKey': profileKey,
    'deviceId': deviceId,
    'entry': entry.toJson(),
    if (localTextEdit) 'localTextEdit': true,
  };
}

class LocalHistoryStore {
  LocalHistoryStore(this.root);
  final Directory root;
  final records = <String, LocalHistoryRecord>{};
  final hidden = <String>{};
  File get file => File('${root.path}/local-history.json');

  Future<void> load(List<ServerProfile> profiles) async {
    if (await file.exists()) {
      final value = jsonDecode(await file.readAsString()) as Map;
      hidden.addAll(List<String>.from(value['hidden'] ?? []));
      for (final item in value['entries'] as List) {
        final record = LocalHistoryRecord(
          item['profileKey'],
          item['deviceId'] ?? '',
          DockEntry.fromJson(Map<String, dynamic>.from(item['entry'])),
          localTextEdit: item['localTextEdit'] == true,
        );
        if (!hidden.contains(record.key)) records[record.key] = record;
      }
    }
    final owners = {
      for (final profile in profiles) profile.storageKey: profile,
    };
    if (await root.exists()) {
      // Include state files left by an older identity even if its profile was
      // replaced. The filename's first 64 characters are its logical center.
      await for (final item in root.list()) {
        if (item is! File) continue;
        final name = item.uri.pathSegments.last;
        if (!RegExp(r'^[0-9a-f]{64}(?:\.[A-Za-z0-9_-]{1,80})?\.json$')
            .hasMatch(name)) {
          continue;
        }
        final storageKey = name.substring(0, name.length - 5);
        final owner = owners[storageKey];
        _importState(
          owner?.key ?? storageKey.substring(0, 64),
          owner?.deviceId ?? '',
          Map<String, dynamic>.from(jsonDecode(await item.readAsString())),
        );
      }
    }
    final recovery = Directory('${root.path}/credential-recovery');
    if (await recovery.exists()) {
      await for (final directory in recovery.list()) {
        if (directory is! Directory) continue;
        final manifest = File('${directory.path}/manifest.json');
        final history = File('${directory.path}/history.json');
        if (!await manifest.exists() || !await history.exists()) continue;
        final metadata = jsonDecode(await manifest.readAsString()) as Map;
        if (metadata['format'] != 1) continue;
        _importState(
          metadata['profileKey'],
          metadata['profile']['deviceId'] ?? '',
          Map<String, dynamic>.from(jsonDecode(await history.readAsString())),
        );
      }
    }
  }

  void _importState(
    String profileKey,
    String deviceId,
    Map<String, dynamic> state,
  ) {
    final sources = Map<String, String>.from(state['sources'] ?? {});
    for (final id in List<String>.from(state['hiddenDockIds'] ?? [])) {
      hidden.add('$profileKey:$id');
      records.remove('$profileKey:$id');
    }
    for (final value in state['dock'] as List? ?? []) {
      final entry = DockEntry.fromJson(Map<String, dynamic>.from(value));
      if (entry.autoClipboard) continue;
      if (entry.localPath.isEmpty) {
        entry.localPath = sources[entry.fileId] ?? '';
      }
      final record = LocalHistoryRecord(profileKey, deviceId, entry);
      if (!hidden.contains(record.key)) {
        records.putIfAbsent(record.key, () => record);
      }
    }
  }

  void capture(
    ServerProfile profile,
    Iterable<DockEntry> entries,
    Map<String, String> sources,
  ) {
    for (final item in entries) {
      if (item.autoClipboard) continue;
      final entry = DockEntry.fromJson(item.toJson());
      if (entry.localPath.isEmpty) {
        entry.localPath = sources[entry.fileId] ?? '';
      }
      final record = LocalHistoryRecord(profile.key, profile.deviceId, entry);
      if (!hidden.contains(record.key)) {
        restoreLocalEdit(profile.key, entry);
        record.localTextEdit = records[record.key]?.localTextEdit == true;
        records[record.key] = record;
      }
    }
  }

  LocalHistoryRecord? recordFor(DockEntry entry) => records.values
      .where((record) => identical(record.entry, entry))
      .firstOrNull;

  bool isHidden(String profileKey, String id) =>
      hidden.contains('$profileKey:$id');

  /// Session files and old event snapshots are not authoritative for a text
  /// edited locally while its original session was inactive.
  void restoreLocalEdit(String profileKey, DockEntry entry) {
    final record = records['$profileKey:${entry.id}'];
    if (record == null || entry.kind != 'text') return;
    if (!record.localTextEdit && record.entry.editCursor <= entry.editCursor)
      return;
    entry.text = record.entry.text;
    entry.editedAt = record.entry.editedAt;
    entry.editCursor = record.entry.editCursor;
  }

  bool hasLocalTextEdit(String profileKey, String id) =>
      records['$profileKey:$id']?.localTextEdit == true;

  void confirmRemoteTextEdit(String profileKey, String id) {
    records['$profileKey:$id']?.localTextEdit = false;
  }

  void remove(String key) {
    hidden.add(key);
    records.remove(key);
  }

  Future<void> save() async {
    await root.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'format': 1,
        'entries': records.values.map((record) => record.toJson()).toList(),
        'hidden': hidden.toList(),
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
