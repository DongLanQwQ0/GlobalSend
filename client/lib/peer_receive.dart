import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'windows_receive_sha256.dart';

const peerWriteBatchBytes = 256 * 1024;

class PeerPartialRecoveryException implements Exception {
  const PeerPartialRecoveryException(this.cause);
  final Object cause;

  @override
  String toString() => '无法恢复连续断点：$cause';
}

/// Write bounded batches, reporting only bytes written to the destination.
/// The caller owns the input iterator so it can cancel a blocked network read.
Future<({int bytes, String? digest})> writePeerReceiveBody(
  StreamIterator<List<int>> reader,
  File file, {
  required int offset,
  required int? expectedSize,
  required void Function(int) onProgress,
  void Function()? check,
  bool hashWhileWriting = false,
  bool positioned = false,
}) async {
  check?.call();
  final output = await file.open(
    mode: offset > 0 || positioned ? FileMode.append : FileMode.write,
  );
  WindowsReceiveSha256? hash;
  try {
    final batch = Uint8List(peerWriteBatchBytes);
    var committed = offset, used = 0;
    onProgress(committed);
    if (hashWhileWriting) {
      // Digest the same file handle used for writes. Keep the resume prefix
      // stable while hashing it and appending the rest of the file.
      await output.lock(FileLock.exclusive);
      if (await output.length() != offset) {
        throw const FileSystemException('本机半文件已变化');
      }
      hash = WindowsReceiveSha256(batch.length);
      if (offset > 0) {
        await output.setPosition(0);
        var remaining = offset;
        while (remaining > 0) {
          check?.call();
          final prefix = await output.read(
            remaining < batch.length ? remaining : batch.length,
          );
          if (prefix.isEmpty) throw const FileSystemException('本机半文件已变化');
          hash.add(prefix, prefix.length);
          remaining -= prefix.length;
        }
      }
    } else if (offset > 0 || positioned) {
      await output.setPosition(offset);
    }

    Future<void> writeBatch() async {
      check?.call();
      await output.writeFrom(batch, 0, used);
      hash?.add(batch, used);
      committed += used;
      used = 0;
      onProgress(committed);
    }

    while (await reader.moveNext()) {
      check?.call();
      final bytes = reader.current;
      if (expectedSize != null &&
          committed + used + bytes.length > expectedSize) {
        throw const FormatException('接收数据超过声明大小');
      }
      for (var start = 0; start < bytes.length;) {
        final available = batch.length - used;
        final remaining = bytes.length - start;
        final count = remaining < available ? remaining : available;
        batch.setRange(used, used + count, bytes, start);
        used += count;
        start += count;
        if (used == batch.length) await writeBatch();
      }
    }
    check?.call();
    if (used > 0) await writeBatch();
    if (expectedSize != null && committed != expectedSize) {
      throw const FormatException('直传未接收完整');
    }
    return (bytes: committed, digest: hash?.finish());
  } finally {
    hash?.dispose();
    await output.close();
  }
}

/// One receiver-owned write attempt. A stopped slot never writes another byte.
/// The caller keeps the destination (including a SAF lease) alive until stop.
class PeerReceiveSlot {
  PeerReceiveSlot({
    required this.transferId,
    required this.fileId,
    required this.attemptId,
    required this.file,
    required this.size,
    required this.offset,
    required this.onProgress,
    this.hashWhileWriting = false,
    this.connections = 1,
  });
  final String transferId, fileId, attemptId;
  final File file;
  final int size, offset;
  final void Function(int) onProgress;
  final bool hashWhileWriting;
  final int connections;
  String? digest;
  final _completed = Completer<String?>();
  Completer<void>? _closed;
  StreamIterator<List<int>>? _reader;
  Future<void>? _parallelInit, _parallelStop;
  PeerPartialRecoveryException? recoveryError;
  final _parts = <int, _PeerReceivePart>{};
  bool started = false, stopped = false;
  bool get finished => _completed.isCompleted;
  Future<String?> get completed => _completed.future;

  Future<void> receive(HttpRequest request, Map<String, dynamic> grant) async {
    if (connections > 1) {
      await _receivePart(request, grant);
      return;
    }
    if (stopped || started) throw StateError('接收尝试已结束');
    started = true;
    _closed = Completer<void>();
    String? failure;
    try {
      if (grant['attemptId'] != attemptId ||
          grant['offset'] != offset ||
          grant['size'] != size ||
          request.contentLength != size - offset) {
        throw const FormatException('直传接收偏移或大小不匹配');
      }
      final actual = await file.exists() ? await file.length() : 0;
      if (actual != offset) throw const FormatException('本机半文件已变化');
      if (stopped) throw StateError('接收尝试已结束');
      final reader = _reader = StreamIterator(
        request.timeout(const Duration(seconds: 20)),
      );
      final result = await writePeerReceiveBody(
        reader,
        file,
        offset: offset,
        expectedSize: size,
        onProgress: onProgress,
        hashWhileWriting: hashWhileWriting,
        check: () {
          if (stopped) throw StateError('接收尝试已结束');
        },
      );
      if (stopped) throw StateError('接收尝试已结束');
      digest = result.digest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'bytes': result.bytes, 'attemptId': attemptId}),
      );
    } catch (error) {
      failure = '$error';
      request.response.statusCode = HttpStatus.conflict;
    } finally {
      try {
        await _reader?.cancel();
      } catch (error) {
        failure ??= '$error';
      }
      if (!_completed.isCompleted) _completed.complete(failure);
      _closed!.complete();
    }
  }

  Future<void> stop() async {
    if (connections > 1) {
      if (finished && _parallelStop == null) return;
      await _stopParts('接收尝试已结束');
      return;
    }
    stopped = true;
    await _reader?.cancel();
    await _closed?.future;
    if (!_completed.isCompleted) _completed.complete('接收尝试已结束');
  }

  Future<void> _checkPartial() async {
    final length = await file.exists() ? await file.length() : 0;
    if (length != offset) throw const FileSystemException('本机半文件已变化');
  }

  Future<void> _receivePart(
    HttpRequest request,
    Map<String, dynamic> grant,
  ) async {
    if (stopped || finished) throw StateError('接收尝试已结束');
    final range = grant['part'];
    if (grant['attemptId'] != attemptId ||
        grant['offset'] != offset ||
        grant['size'] != size ||
        grant['connections'] != connections ||
        range is! Map) {
      throw const FormatException('分段授权不匹配');
    }
    final start = range['offset'] as int, end = range['end'] as int;
    if (start < offset ||
        end > size ||
        start >= end ||
        request.contentLength != end - start ||
        _parts.values.any((part) => start < part.end && end > part.start)) {
      throw const FormatException('分段范围不匹配');
    }
    started = true;
    final part = _parts[start] = _PeerReceivePart(
      start,
      end,
      StreamIterator(request.timeout(const Duration(seconds: 20))),
    );
    String? failure;
    try {
      await (_parallelInit ??= _checkPartial());
      await writePeerReceiveBody(
        part.reader,
        file,
        offset: start,
        expectedSize: end,
        positioned: true,
        check: () {
          if (stopped) throw StateError('接收尝试已结束');
        },
        onProgress: (bytes) {
          part.committed = bytes;
          onProgress(
            offset + _parts.values.fold(0, (n, p) => n + p.committed - p.start),
          );
        },
      );
      if (stopped) throw StateError('接收尝试已结束');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'bytes': end, 'attemptId': attemptId}),
      );
      part.succeeded = true;
    } catch (error) {
      failure = '$error';
      request.response.statusCode = HttpStatus.conflict;
    } finally {
      try {
        await part.reader.cancel();
      } catch (error) {
        failure ??= '$error';
      }
      part.closed.complete();
    }
    if (failure != null) {
      await _stopParts(failure);
    } else if (!stopped &&
        _parts.length == connections &&
        _parts.values.every(
          (part) => part.succeeded && part.closed.isCompleted,
        )) {
      _completed.complete(null);
    }
  }

  Future<void> _stopParts(String failure) {
    stopped = true;
    return _parallelStop ??= _truncateIncompleteParts(failure);
  }

  Future<void> _truncateIncompleteParts(String failure) async {
    try {
      final parts = _parts.values.toList()
        ..sort((a, b) => a.start.compareTo(b.start));
      await Future.wait(
        parts.map((part) async {
          try {
            await part.reader.cancel();
          } catch (error) {
            failure = '$failure；$error';
          } finally {
            await part.closed.future;
          }
        }),
        eagerError: false,
      );
      if (_parallelInit != null) {
        await _parallelInit;
        var prefix = offset;
        for (final part in parts) {
          if (part.start != prefix) break;
          prefix = part.committed;
        }
        if (await file.exists()) {
          final handle = await file.open(mode: FileMode.append);
          try {
            await handle.truncate(prefix);
          } finally {
            await handle.close();
          }
        }
      }
    } catch (error) {
      final recovery = recoveryError = PeerPartialRecoveryException(error);
      failure = '$failure；$recovery';
    } finally {
      if (!_completed.isCompleted) _completed.complete(failure);
    }
  }
}

class _PeerReceivePart {
  _PeerReceivePart(this.start, this.end, this.reader) : committed = start;
  final int start, end;
  final StreamIterator<List<int>> reader;
  final closed = Completer<void>();
  int committed;
  bool succeeded = false;
}
