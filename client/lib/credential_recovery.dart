import 'dart:convert';
import 'dart:io';

import 'vault.dart';

class CredentialRecoveryRecord {
  CredentialRecoveryRecord(this.directory, this.manifest);
  final Directory directory;
  final Map<String, dynamic> manifest;
  String get profileKey => manifest['profileKey'] as String;
  String get createdAt => manifest['createdAt'] as String;
  Map<String, dynamic> get profile =>
      Map<String, dynamic>.from(manifest['profile']);
  Future<Map<String, dynamic>> history() async => Map<String, dynamic>.from(
    jsonDecode(await File('${directory.path}/history.json').readAsString()),
  );
}

/// Recovery snapshots are local archives, never credentials for a new session.
/// Keep old transfer IDs confined to their read-only history instead of replaying
/// them under the replacement device's authentication.
class CredentialRecoveryStore {
  CredentialRecoveryStore(this.root, this.vault);
  final Directory root;
  final PlatformVault vault;
  Directory get directory => Directory('${root.path}/credential-recovery');

  /// The independent state is durable before profiles.json becomes the active
  /// identity pointer. A failed write never changes the previous state/key.
  Future<void> commitIdentity({
    required String storageKey,
    required Map<String, dynamic> state,
    required List<Map<String, dynamic>> profiles,
    required bool Function() canCommit,
  }) async {
    final stateFile = File('${root.path}/$storageKey.json');
    final stateTemporary = File('${stateFile.path}.tmp');
    await stateTemporary.writeAsString(jsonEncode(state), flush: true);
    await stateTemporary.rename(stateFile.path);
    final pointer = File('${root.path}/profiles.json');
    final temporary = File('${pointer.path}.recovery.tmp');
    try {
      await temporary.writeAsString(jsonEncode(profiles), flush: true);
      if (!canCommit()) throw StateError('连接已改变，原身份未替换');
      await temporary.rename(pointer.path);
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        /* Do not turn a committed pointer into a reported failure. */
      }
    }
  }

  Future<CredentialRecoveryRecord> snapshot({
    required String profileKey,
    required String storageKey,
    required Map<String, dynamic> profile,
    required Map<String, dynamic> history,
  }) async {
    await directory.create(recursive: true);
    final target = await directory.createTemp('snapshot-');
    // If this fails, the caller has not enrolled or replaced any identity.
    // An incomplete snapshot is left intact for inspection, without a manifest.
    await vault.backupProtectedFiles(Directory('${target.path}/vault'));
    await File('${target.path}/history.json')
        .writeAsString(jsonEncode(history), flush: true);
    final previousState = File('${root.path}/$storageKey.json');
    if (await previousState.exists()) {
      await previousState.copy('${target.path}/state.json');
    }
    for (final name in [
      'profiles.json',
      'recent-center.json',
      'saved-files.json',
    ]) {
      final source = File('${root.path}/$name');
      if (await source.exists()) await source.copy('${target.path}/$name');
    }
    final manifest = <String, dynamic>{
      'format': 1,
      'profileKey': profileKey,
      'storageKey': storageKey,
      'profile': profile,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    final temporary = File('${target.path}/manifest.json.tmp');
    await temporary.writeAsString(jsonEncode(manifest), flush: true);
    await temporary.rename('${target.path}/manifest.json');
    return CredentialRecoveryRecord(target, manifest);
  }

  Future<List<CredentialRecoveryRecord>> records(String profileKey) async {
    if (!await directory.exists()) return [];
    final records = <CredentialRecoveryRecord>[];
    await for (final entry in directory.list()) {
      if (entry is! Directory) continue;
      final manifest = File('${entry.path}/manifest.json');
      if (!await manifest.exists()) continue;
      final value = Map<String, dynamic>.from(
        jsonDecode(await manifest.readAsString()),
      );
      if (value['format'] == 1 && value['profileKey'] == profileKey) {
        records.add(CredentialRecoveryRecord(entry, value));
      }
    }
    records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return records;
  }
}
