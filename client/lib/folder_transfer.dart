import 'dart:io';

/// References to original content, never an archive or copied folder.
class FolderEntry {
  const FolderEntry({
    required this.location,
    required this.relativePath,
    required this.directory,
  });
  final String location, relativePath;
  final bool directory;
  String get name => relativePath.split('/').last;
  factory FolderEntry.fromMap(Map<String, dynamic> value) => FolderEntry(
    location: value['location'] as String,
    relativePath: value['relativePath'] as String,
    directory: value['entryKind'] == 'directory',
  );
}

String folderRelativePath(String value) {
  final parts = value.split('/');
  if (parts.any(
    (part) =>
        part.isEmpty ||
        part == '.' ||
        part == '..' ||
        RegExp(r'[\\:\x00-\x1f]').hasMatch(part),
  )) {
    throw const FormatException('文件夹路径必须位于接收目录内');
  }
  return value;
}

Future<List<FolderEntry>> readFolderEntries(String location) async {
  final root = Directory(location).absolute;
  final rootName = root.uri.pathSegments.where((part) => part.isNotEmpty).last;
  final entries = <FolderEntry>[];
  Future<void> visit(Directory directory, String relative) async {
    entries.add(
      FolderEntry(
        location: directory.path,
        relativePath: folderRelativePath(relative),
        directory: true,
      ),
    );
    await for (final item in directory.list(followLinks: false)) {
      final leaf = item.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (item is Directory) {
        await visit(item, '$relative/$leaf');
      } else if (item is File) {
        entries.add(
          FolderEntry(
            location: item.path,
            relativePath: folderRelativePath('$relative/$leaf'),
            directory: false,
          ),
        );
      } else if (item is Link) {
        throw FileSystemException('文件夹包含链接，请直接选择链接指向的文件夹', item.path);
      }
      if (entries.length > 10000)
        throw const FormatException('文件夹超过 10000 项，请拆分后发送');
    }
  }

  await visit(root, rootName);
  return entries;
}
