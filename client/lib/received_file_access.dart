import 'dart:io';

import 'package:open_filex/open_filex.dart';

import 'receive_destination.dart';

/// A content URI is a durable identity; its native descriptor is only a lease.
/// Ordinary picked files retain their existing File contract.
class ReceivedFileAccess {
  ReceivedFileAccess._(this.location, this.file, this._handle);
  final String location;
  final File file;
  final String _handle;
  bool _closed = false;

  static bool isContentUri(String location) =>
      location.startsWith('content://');
  static String canonical(String location) =>
      isContentUri(location) ? location : File(location).absolute.path;

  static Future<ReceivedFileAccess> open(String location) async {
    if (!isContentUri(location)) {
      return ReceivedFileAccess._(location, File(location), '');
    }
    final handle = await ReceiveDestination.openHandle(location);
    return ReceivedFileAccess._(location, File(handle.ioPath), handle.handle);
  }

  static Future<bool> exists(String location) async => isContentUri(location)
      ? (await ReceiveDestination.stat(location)).exists
      : FileSystemEntity.type(location).then(
          (type) =>
              type == FileSystemEntityType.file ||
              type == FileSystemEntityType.directory,
        );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_handle.isNotEmpty) await ReceiveDestination.closeHandle(_handle);
  }

  static Future<void> openExternal(String location) async {
    if (isContentUri(location)) {
      await ReceiveDestination.openExternal(location);
      return;
    }
    final result = await OpenFilex.open(location);
    if (result.type != ResultType.done) throw StateError(result.message);
  }
}
