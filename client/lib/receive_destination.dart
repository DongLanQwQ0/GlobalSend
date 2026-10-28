import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import 'directories.dart';
import 'models.dart';
import 'folder_transfer.dart';

class ReceiveFileInfo {
  const ReceiveFileInfo({
    required this.location,
    required this.name,
    required this.size,
    required this.exists,
  });
  final String location, name;
  final int size;
  final bool exists;
  factory ReceiveFileInfo.fromMap(Map<String, dynamic> value) =>
      ReceiveFileInfo(
        location: value['location'] as String,
        name: value['name'] as String,
        size: (value['size'] as num).toInt(),
        exists: value['exists'] as bool,
      );
}

/// [location] persists; [ioPath] and [handle] are valid only until closeHandle.
class ReceiveFileHandle {
  const ReceiveFileHandle({
    required this.location,
    required this.ioPath,
    required this.handle,
    required this.name,
    required this.size,
    this.descriptorOnly = false,
  });
  final String location, ioPath, handle, name;
  final int size;
  final bool descriptorOnly;
  factory ReceiveFileHandle.fromMap(Map<String, dynamic> value) =>
      ReceiveFileHandle(
        location: value['location'] as String,
        ioPath: value['ioPath'] as String,
        handle: value['handle'] as String,
        name: value['name'] as String,
        size: (value['size'] as num).toInt(),
        descriptorOnly: value['descriptorOnly'] == true,
      );
}

/// Direct receive destinations. Never copies a received file back into app data.
class ReceiveDestination {
  static const channel = MethodChannel('dev.globalsend/receive_destination');
  static Future<void> _registryTail = Future<void>.value();
  @visibleForTesting
  static Future<Directory> Function()? registryDirectoryForTesting;

  static Future<Map<String, String>?> pick() async {
    if (Platform.isAndroid) {
      final result = await channel.invokeMapMethod<String, dynamic>('pick');
      return result == null ? null : Map<String, String>.from(result);
    }
    if (Platform.isWindows) {
      final path = await FilePicker.getDirectoryPath(dialogTitle: '选择接收保存文件夹');
      return path == null ? null : {'location': path, 'label': path};
    }
    throw UnsupportedError('此平台尚不支持接收保存目录');
  }

  static Future<ReceiveFileHandle> openLocalRead(String path) async =>
      ReceiveFileHandle.fromMap(
        (await channel.invokeMapMethod<String, dynamic>('openLocalRead', {
          'path': path,
        }))!,
      );

  static Future<bool> localExists(String path) async =>
      (await channel.invokeMethod<bool>('localExists', {'path': path}))!;

  static Future<List<int>> readDescriptor(
    String handle,
    int offset,
    int length,
  ) async => (await channel.invokeMethod<List<int>>('readDescriptor', {
    'handle': handle,
    'offset': offset,
    'length': length,
  }))!;

  static Future<bool> allFilesAccess() async =>
      Platform.isAndroid &&
      (await channel.invokeMethod<bool>('allFilesAccess') ?? false);

  static Future<void> openAllFilesSettings() async {
    if (!Platform.isAndroid) throw UnsupportedError('仅 Android 支持所有文件访问设置');
    await channel.invokeMethod<void>('allFilesSettings');
  }

  static Future<Map<String, String>> downloads() async {
    if (!Platform.isAndroid) throw UnsupportedError('此快捷目录仅适用于 Android');
    final result = await channel.invokeMapMethod<String, dynamic>('downloads');
    return Map<String, String>.from(result!);
  }

  static Future<ReceiveFileHandle> create({
    required String destinationLocation,
    required String name,
  }) async {
    final leaf = safeName(name);
    if (destinationLocation.startsWith('content://')) {
      return ReceiveFileHandle.fromMap(
        (await channel.invokeMapMethod<String, dynamic>('create', {
          'destinationLocation': destinationLocation,
          'name': leaf,
        }))!,
      );
    }
    return _windowsRegistry((owned) async {
      final file = await _reserve(Directory(destinationLocation), leaf);
      final location = await file.resolveSymbolicLinks();
      owned[location] = file.uri.pathSegments.last;
      return ReceiveFileHandle(
        location: location,
        ioPath: location,
        handle: '',
        name: owned[location]!,
        size: 0,
      );
    });
  }

  /// One durable root per transfer/root-name, then exact nested directories.
  static Future<String> folderDirectory({
    required String destinationLocation,
    required String transferKey,
    required String relativePath,
  }) async {
    final parts = folderRelativePath(relativePath)
        .split('/')
        .map(safeName)
        .toList();
    final key = '@folder-root:$transferKey:${parts.first}';
    final root = await _windowsRegistry((owned) async {
      final previous = owned[key];
      if (previous != null && (await stat(previous)).exists) return previous;
      final location = await _directory(
        destinationLocation,
        parts.first,
        unique: true,
      );
      owned[key] = location;
      if (!location.startsWith('content://')) owned[location] = parts.first;
      return location;
    });
    return _windowsRegistry((owned) async {
      var current = root;
      for (final part in parts.skip(1)) {
        current = await _directory(current, part);
        if (!current.startsWith('content://')) owned[current] = part;
      }
      return current;
    });
  }

  /// Keep a continuing transfer attached to its migrated root, even if the
  /// user left unrelated files in the old directory.
  static Future<void> relocateFolderRoots(Map<String, String> locations) =>
      _windowsRegistry((owned) async {
        for (final key
            in owned.keys
                .where((key) => key.startsWith('@folder-root:'))
                .toList()) {
          final next = locations[owned[key]];
          if (next != null) owned[key] = next;
        }
      });

  static Future<String> _directory(
    String parent,
    String name, {
    bool unique = false,
  }) async {
    if (parent.startsWith('content://')) {
      return (await channel.invokeMethod<String>('directory', {
        'parentLocation': parent,
        'name': name,
        'unique': unique,
      }))!;
    }
    if (!await Directory(parent).exists())
      throw const FileSystemException('接收保存目录不存在，请重新选择');
    for (var index = 0; ; index++) {
      final leaf = index == 0 ? name : '$name ($index)';
      final directory = Directory('$parent${Platform.pathSeparator}$leaf');
      final type = await FileSystemEntity.type(directory.path);
      if (unique && type != FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory)
        throw FileSystemException('目录路径已被文件占用', directory.path);
      await directory.create();
      return directory.absolute.path;
    }
  }

  static Future<ReceiveFileHandle> openHandle(
    String location, {
    bool writable = false,
  }) async {
    if (location.startsWith('content://')) {
      return ReceiveFileHandle.fromMap(
        (await channel.invokeMapMethod<String, dynamic>('open', {
          'location': location,
          'writable': writable,
        }))!,
      );
    }
    if (writable && !await isOwned(location)) {
      throw const FileSystemException('只能续写本应用创建的接收文件');
    }
    final info = await stat(location);
    if (!info.exists) throw FileSystemException('文件已不存在', location);
    return ReceiveFileHandle(
      location: location,
      ioPath: location,
      handle: '',
      name: info.name,
      size: info.size,
    );
  }

  static Future<void> closeHandle(String handle, {String? error}) async {
    if (handle.isNotEmpty) {
      await channel.invokeMethod<void>('close', {
        'handle': handle,
        'error': ?error,
      });
    }
  }

  static Future<bool> isOwned(String location) async {
    if (location.startsWith('content://')) {
      return (await channel.invokeMethod<bool>('isOwned', {
        'location': location,
      }))!;
    }
    if (!Platform.isWindows && !Platform.isAndroid) return false;
    return _windowsRegistry(
      (owned) async => owned.containsKey(location),
      persist: false,
    );
  }

  static Future<ReceiveFileInfo> stat(String location) async {
    if (location.startsWith('content://')) {
      return ReceiveFileInfo.fromMap(
        (await channel.invokeMapMethod<String, dynamic>('stat', {
          'location': location,
        }))!,
      );
    }
    if (Platform.isAndroid)
      return ReceiveFileInfo.fromMap(
        (await channel.invokeMapMethod<String, dynamic>('localStat', {
          'path': location,
        }))!,
      );
    final file = File(location);
    final type = await FileSystemEntity.type(location);
    final exists =
        type == FileSystemEntityType.file ||
        type == FileSystemEntityType.directory;
    return ReceiveFileInfo(
      location: location,
      name: file.uri.pathSegments.last,
      size: type == FileSystemEntityType.file ? await file.length() : 0,
      exists: exists,
    );
  }

  static Future<bool> delete(String location) async {
    if (location.startsWith('content://')) {
      return (await channel.invokeMethod<bool>('delete', {
        'location': location,
      }))!;
    }
    return _windowsRegistry((owned) async {
      _requireOwned(owned, location);
      final file = File(location);
      final type = await FileSystemEntity.type(location);
      if (Platform.isAndroid && type == FileSystemEntityType.notFound &&
          (await stat(location)).exists) {
        throw FileSystemException('文件仍在，但暂时没有删除权限；请重新授权所在文件夹', location);
      }
      final exists =
          type == FileSystemEntityType.file ||
          type == FileSystemEntityType.directory;
      if (type == FileSystemEntityType.directory) {
        final directory = Directory(location);
        if (!(await directory.list().isEmpty)) return false;
        await directory.delete();
      } else if (exists)
        await file.delete();
      owned.remove(location);
      return exists;
    });
  }

  static Future<ReceiveFileInfo> rename(String location, String name) async {
    final leaf = safeName(name);
    if (location.startsWith('content://')) {
      return ReceiveFileInfo.fromMap(
        (await channel.invokeMapMethod<String, dynamic>('rename', {
          'location': location,
          'name': leaf,
        }))!,
      );
    }
    return _windowsRegistry((owned) async {
      _requireOwned(owned, location);
      final source = File(location);
      if (source.uri.pathSegments.last == leaf) return stat(location);
      final size = await source.length();
      final reserved = await _reserve(source.parent, leaf);
      late File moved;
      try {
        moved = await source.rename(reserved.path);
      } catch (_) {
        await reserved.delete();
        rethrow;
      }
      final nextLocation = await moved.resolveSymbolicLinks();
      owned.remove(location);
      owned[nextLocation] = moved.uri.pathSegments.last;
      return ReceiveFileInfo(
        location: nextLocation,
        name: owned[nextLocation]!,
        size: size,
        exists: true,
      );
    });
  }

  static Future<void> openExternal(String location) async {
    if (location.startsWith('content://')) {
      await channel.invokeMethod<void>('openExternal', {'location': location});
      return;
    }
    final result = await OpenFilex.open(location);
    if (result.type != ResultType.done) {
      throw FileSystemException(result.message, location);
    }
  }

  static Future<File> _reserve(Directory folder, String leaf) async {
    if (!await folder.exists()) {
      throw const FileSystemException('接收保存目录不存在，请重新选择');
    }
    final dot = leaf.lastIndexOf('.');
    final stem = dot > 0 ? leaf.substring(0, dot) : leaf;
    final extension = dot > 0 ? leaf.substring(dot) : '';
    for (var index = 0; ; index++) {
      final name = index == 0 ? leaf : '$stem ($index)$extension';
      final file = File('${folder.path}${Platform.pathSeparator}$name');
      try {
        await file.create(exclusive: true);
        return file;
      } on PathExistsException {
        continue;
      }
    }
  }

  static void _requireOwned(Map<String, String> owned, String location) {
    if (!owned.containsKey(location)) {
      throw const FileSystemException('只能清理或改名本应用创建的接收文件');
    }
  }

  static Future<T> _windowsRegistry<T>(
    Future<T> Function(Map<String, String>) action, {
    bool persist = true,
  }) {
    if (!Platform.isWindows && !Platform.isAndroid) {
      throw UnsupportedError('此平台尚不支持接收保存目录');
    }
    final result = Completer<T>();
    _registryTail = _registryTail.then((_) async {
      try {
        final root = await (registryDirectoryForTesting ?? appDataDirectory)();
        await root.create(recursive: true);
        final file = File('${root.path}/receive-destination-owned.json');
        final owned = await file.exists()
            ? Map<String, String>.from(jsonDecode(await file.readAsString()))
            : <String, String>{};
        final value = await action(owned);
        if (persist) {
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(jsonEncode(owned), flush: true);
          await temporary.rename(file.path);
        }
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }
}
