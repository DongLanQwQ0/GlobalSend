import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'directories.dart';

/// Safe-to-display failure. Missing credentials still return null; an unreadable
/// existing credential must never look like a new device waiting to register.
class VaultException implements Exception {
  const VaultException({
    required this.operation,
    required this.code,
    this.windowsError,
  });
  final String operation, code;
  final int? windowsError;
  String get diagnostic => windowsError == null
      ? code
      : '$code / 0x${windowsError!.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  @override
  String toString() => operation == 'read'
      ? '系统暂时无法解锁原登录凭据。原身份和本机记录已保留，请重试或选择重新入组。'
      : '系统暂时无法安全保存登录凭据，原有凭据未替换。请检查系统用户配置和存储访问后重试。';
}

/// Files contain only OS-protected ciphertext. Windows: current-user DPAPI.
/// Android: non-exportable AndroidKeyStore AES-GCM key.
class PlatformVault {
  PlatformVault({Future<Directory> Function()? directory})
    : _directory = directory ?? appDataDirectory;
  final Future<Directory> Function() _directory;
  static const channel = MethodChannel('dev.globalsend/vault');
  static final Map<String, Future<void>> _writes = {};
  static int _temporarySequence = 0;
  Future<File> file(String key) async {
    final directory = Directory('${(await _directory()).path}/vault');
    await directory.create(recursive: true);
    return File('${directory.path}/${sha256.convert(utf8.encode(key))}.bin');
  }

  Future<String?> read({required String key}) async {
    Uint8List? clear;
    try {
      final target = await file(key);
      if (!await target.exists()) return null;
      final nativeBytes = await channel.invokeMethod<Uint8List>(
        'unseal',
        await target.readAsBytes(),
      );
      if (nativeBytes == null) throw const FormatException();
      // Platform-channel buffers can be read-only. Only wipe our own buffer,
      // never mutate the message owned by the engine.
      clear = Uint8List.fromList(nativeBytes);
      return utf8.decode(clear);
    } on PlatformException catch (error) {
      throw _platformFailure('read', error);
    } on FileSystemException catch (error) {
      throw VaultException(
        operation: 'read',
        code: 'VAULT_STORAGE_FAILED',
        windowsError: error.osError?.errorCode,
      );
    } on FormatException {
      throw const VaultException(
        operation: 'read',
        code: 'VAULT_FORMAT_FAILED',
      );
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<void> write({required String key, required String value}) async {
    try {
      final target = await file(key);
      final path = target.absolute.path;
      final previous = _writes[path] ?? Future<void>.value();
      final current = previous
          .catchError((Object _) {})
          .then((_) => _write(target, value));
      _writes[path] = current;
      try {
        await current;
      } finally {
        if (identical(_writes[path], current)) _writes.remove(path);
      }
    } on PlatformException catch (error) {
      throw _platformFailure('write', error);
    } on FileSystemException catch (error) {
      throw VaultException(
        operation: 'write',
        code: 'VAULT_STORAGE_FAILED',
        windowsError: error.osError?.errorCode,
      );
    }
  }

  Future<void> _write(File target, String value) async {
    final clear = Uint8List.fromList(utf8.encode(value));
    Uint8List? protected;
    try {
      protected = await channel.invokeMethod<Uint8List>('seal', clear);
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
    if (protected == null || protected.isEmpty) {
      throw const VaultException(
        operation: 'write',
        code: 'VAULT_FORMAT_FAILED',
      );
    }
    final temporary = File(
      '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.${_temporarySequence++}.tmp',
    );
    try {
      await temporary.writeAsBytes(protected, flush: true);
      await temporary.rename(target.path);
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        /* Preserve the primary error; only ciphertext remains. */
      }
    }
  }

  /// Explicit recovery only: copy protected bytes, never decrypt or replace the
  /// originals. The caller writes its manifest after the whole snapshot succeeds.
  Future<void> backupProtectedFiles(Directory destination) async {
    final source = Directory('${(await _directory()).path}/vault');
    await destination.create(recursive: true);
    if (!await source.exists()) return;
    await for (final item in source.list()) {
      if (item is File && item.path.endsWith('.bin')) {
        await item.copy('${destination.path}/${item.uri.pathSegments.last}');
      }
    }
  }

  static VaultException _platformFailure(
    String operation,
    PlatformException error,
  ) {
    final details = error.details;
    final value = details is Map ? details['windowsError'] : null;
    return VaultException(
      operation: operation,
      code: error.code,
      windowsError: value is int ? value & 0xffffffff : null,
    );
  }
}
