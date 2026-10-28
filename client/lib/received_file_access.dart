import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';

import 'receive_destination.dart';

/// A content URI is a durable identity; its native descriptor is only a lease.
/// Ordinary picked files retain their existing File contract.
class ReceivedFileAccess {
  ReceivedFileAccess._(
    this.location,
    this.file,
    this._handle, [
    String? nativeLocation,
  ]) : _nativeLocation = nativeLocation ?? location;
  final String location;
  final File file;
  final String _handle;
  final String _nativeLocation;
  bool _closed = false;

  static bool isContentUri(String location) =>
      location.startsWith('content://');
  static String canonical(String location) =>
      isContentUri(location) ? location : File(location).absolute.path;

  static Future<ReceivedFileAccess> open(String location) async {
    if (!isContentUri(location)) {
      if (Platform.isAndroid) {
        final handle = await ReceiveDestination.openLocalRead(location);
        return _fromHandle(location, handle);
      }
      return ReceivedFileAccess._(location, File(location), '');
    }
    final handle = await ReceiveDestination.openHandle(location);
    return _fromHandle(location, handle);
  }

  static ReceivedFileAccess _fromHandle(
    String location,
    ReceiveFileHandle handle,
  ) => ReceivedFileAccess._(
    location,
    handle.descriptorOnly ? _DescriptorFile(handle) : File(handle.ioPath),
    handle.handle,
    handle.location,
  );

  bool get descriptorOnly => file is _DescriptorFile;

  static Future<bool> exists(String location) async => isContentUri(location)
      ? (await ReceiveDestination.stat(location)).exists
      : Platform.isAndroid
      ? ReceiveDestination.localExists(location)
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
    if (Platform.isAndroid) {
      final source = await open(location);
      try {
        if (isContentUri(source._nativeLocation)) {
          await ReceiveDestination.openExternal(source._nativeLocation);
          return;
        }
      } finally {
        await source.close();
      }
    }
    final result = await OpenFilex.open(location);
    if (result.type != ResultType.done) throw StateError(result.message);
  }
}

/// Read-only File adapter over an already granted Android descriptor. The URI
/// remains its native identity; no /proc reopen or disk-cache copy is required.
class _DescriptorFile implements File {
  _DescriptorFile(this.handle);
  final ReceiveFileHandle handle;
  @override
  String get path => handle.location;
  @override
  Uri get uri => Uri.parse(path);
  @override
  File get absolute => this;
  @override
  Future<bool> exists() async => true;
  @override
  Future<int> length() async => handle.size;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    if (mode != FileMode.read) throw UnsupportedError('文件读取授权不允许写入');
    return _DescriptorReader(handle);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    var offset = start ?? 0;
    final limit = end ?? handle.size;
    while (limit < 0 || offset < limit) {
      final length = limit < 0 || limit - offset > 65536
          ? 65536
          : limit - offset;
      final bytes = await ReceiveDestination.readDescriptor(
        handle.handle,
        offset,
        length,
      );
      if (bytes.isEmpty) break;
      offset += bytes.length;
      yield bytes;
    }
  }

  @override
  Future<Uint8List> readAsBytes() async {
    final output = BytesBuilder(copy: false);
    await for (final bytes in openRead()) {
      output.add(bytes);
    }
    return output.takeBytes();
  }

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async =>
      encoding.decode(await readAsBytes());
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DescriptorReader implements RandomAccessFile {
  _DescriptorReader(this.handle);
  final ReceiveFileHandle handle;
  int offset = 0;
  bool closed = false;
  @override
  String get path => handle.location;
  @override
  Future<int> length() async => handle.size;
  @override
  Future<int> position() async => offset;
  @override
  Future<RandomAccessFile> setPosition(int position) async {
    if (position < 0) throw RangeError.value(position);
    offset = position;
    return this;
  }

  @override
  Future<Uint8List> read(int bytes) async {
    if (closed) throw const FileSystemException('文件读取已关闭');
    final result = Uint8List.fromList(
      await ReceiveDestination.readDescriptor(handle.handle, offset, bytes),
    );
    offset += result.length;
    return result;
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async {
    final bytes = await read((end ?? buffer.length) - start);
    buffer.setRange(start, start + bytes.length, bytes);
    return bytes.length;
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
