import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

final _bcrypt = DynamicLibrary.open('bcrypt.dll');
// BCRYPT_SHA256_ALG_HANDLE from the Windows SDK. Pseudo-handles are not closed.
final _sha256Algorithm = Pointer<Void>.fromAddress(0x41);
final _createHash = _bcrypt
    .lookupFunction<
      Int32 Function(
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Uint8>,
        Uint32,
        Pointer<Uint8>,
        Uint32,
        Uint32,
      ),
      int Function(
        Pointer<Void>,
        Pointer<Pointer<Void>>,
        Pointer<Uint8>,
        int,
        Pointer<Uint8>,
        int,
        int,
      )
    >('BCryptCreateHash');
typedef _NativeHashBytes = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Uint32,
  Uint32,
);
typedef _HashBytes = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
final _addHash = _bcrypt.lookupFunction<_NativeHashBytes, _HashBytes>(
  'BCryptHashData',
);
final _finishHash = _bcrypt.lookupFunction<_NativeHashBytes, _HashBytes>(
  'BCryptFinishHash',
);
final _destroyHash = _bcrypt
    .lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
      'BCryptDestroyHash',
    );

Future<String> hashWindowsReceiveFile(
  File file, {
  void Function()? check,
}) async {
  const block = 256 * 1024;
  final hash = WindowsReceiveSha256(block);
  try {
    final source = await file.open();
    try {
      while (true) {
        check?.call();
        final bytes = await source.read(block);
        if (bytes.isEmpty) return hash.finish();
        hash.add(bytes, bytes.length);
      }
    } finally {
      await source.close();
    }
  } finally {
    hash.dispose();
  }
}

/// One Windows receive writer owns the handle and its bounded scratch buffer.
final class WindowsReceiveSha256 {
  factory WindowsReceiveSha256(int batchBytes) {
    final handle = using((arena) {
      final result = arena<Pointer<Void>>();
      _check(_createHash(_sha256Algorithm, result, nullptr, 0, nullptr, 0, 0));
      return result.value;
    });
    try {
      return WindowsReceiveSha256._(
        handle,
        calloc<Uint8>(batchBytes),
        batchBytes,
      );
    } catch (_) {
      _destroyHash(handle);
      rethrow;
    }
  }

  WindowsReceiveSha256._(this._handle, this._buffer, int capacity)
    : _view = _buffer.asTypedList(capacity);

  static const _digestBytes = 32;
  final Pointer<Void> _handle;
  final Pointer<Uint8> _buffer;
  final List<int> _view;

  void add(List<int> bytes, int count) {
    _view.setRange(0, count, bytes);
    _check(_addHash(_handle, _buffer, count, 0));
  }

  String finish() {
    _check(_finishHash(_handle, _buffer, _digestBytes, 0));
    return Digest(_view.sublist(0, _digestBytes)).toString();
  }

  void dispose() {
    _destroyHash(_handle);
    calloc.free(_buffer);
  }

  static void _check(int status) {
    if (status < 0) {
      throw FileSystemException('Windows SHA-256 校验失败 ($status)');
    }
  }
}
