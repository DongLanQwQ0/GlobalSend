import 'dart:io';

import 'package:archive/archive_io.dart';

/// Streams files into a ZIP, retaining the selected directory and empty
/// directories. The only generated content is this transfer archive.
Future<String> createFolderArchive(Map<String, String> request) async {
  final source = Directory(request['source']!).absolute;
  final destination = File(request['destination']!).absolute;
  final excluded = Directory(request['excluded']!).absolute.path;
  final rootName = source.uri.pathSegments
      .where((part) => part.isNotEmpty)
      .last;
  final encoder = ZipFileEncoder();
  await destination.parent.create(recursive: true);
  encoder.create(destination.path);
  try {
    encoder.addArchiveFile(ArchiveFile.directory('$rootName/'));
    Future<void> addDirectory(Directory directory, String relative) async {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity.absolute.path == excluded) continue;
        final leaf = entity.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last;
        final name = '$relative/$leaf';
        if (entity is Directory) {
          encoder.addArchiveFile(ArchiveFile.directory('$name/'));
          await addDirectory(entity, name);
        } else if (entity is File) {
          await encoder.addFile(entity, name);
        }
      }
    }

    await addDirectory(source, rootName);
    await encoder.close();
    return destination.path;
  } catch (_) {
    await encoder.close();
    if (await destination.exists()) await destination.delete();
    rethrow;
  }
}
