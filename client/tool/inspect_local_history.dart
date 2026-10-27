import 'dart:convert';
import 'dart:io';
import 'package:globalsend/local_history.dart';
import 'package:globalsend/models.dart';

/// Read-only migration inspection. Never opens vault files or prints content.
Future<void> main(List<String> args) async {
  final root = Directory(args.first);
  final profilesFile = File('${root.path}/profiles.json');
  final profiles = await profilesFile.exists()
      ? (jsonDecode(await profilesFile.readAsString()) as List)
          .map((value) => ServerProfile.fromJson(Map<String, dynamic>.from(value))).toList()
      : <ServerProfile>[];
  final store = LocalHistoryStore(root);
  await store.load(profiles);
  Map<String, Object>? comparison;
  if (args.length == 2) {
    final current = LocalHistoryStore(Directory(args[1]));
    await current.load(const []);
    final removed = store.records.entries
        .where((record) => current.hidden.contains(record.key))
        .map((record) => record.value.entry)
        .toList();
    var existingPaths = 0;
    for (final entry in removed.where((entry) => entry.kind == 'file')) {
      if (entry.localPath.isNotEmpty &&
          await FileSystemEntity.type(entry.localPath) != FileSystemEntityType.notFound) {
        existingPaths++;
      }
    }
    comparison = {
      'removedTexts': removed.where((entry) => entry.kind == 'text').length,
      'removedFileReferences': removed.where((entry) => entry.kind == 'file').length,
      'removedFilePathsStillExist': existingPaths,
    };
  }
  stdout.writeln(jsonEncode({
    'readOnly': true,
    'profiles': profiles.length,
    'historyRecords': store.records.length,
    'textRecords': store.records.values.where((record) => record.entry.kind == 'text').length,
    'fileReferences': store.records.values.where((record) => record.entry.kind == 'file').length,
    'hiddenRecords': store.hidden.length,
    if (comparison != null) 'currentComparison': comparison,
  }));
}
