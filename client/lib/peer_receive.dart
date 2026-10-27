import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  });
  final String transferId, fileId, attemptId;
  final File file;
  final int size, offset;
  final void Function(int) onProgress;
  final _completed = Completer<String?>();
  Completer<void>? _closed;
  StreamIterator<List<int>>? _reader;
  bool started = false, stopped = false;
  bool get finished => _completed.isCompleted;
  Future<String?> get completed => _completed.future;

  Future<void> receive(HttpRequest request, Map<String, dynamic> grant) async {
    if (stopped || started) throw StateError('接收尝试已结束');
    started = true;
    _closed = Completer<void>();
    IOSink? sink;
    String? failure;
    var count = offset;
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
      sink = file.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      final output = sink;
      onProgress(count);
      final reader = _reader = StreamIterator(
        request.timeout(const Duration(seconds: 20)),
      );
      while (await reader.moveNext()) {
        if (stopped) throw StateError('接收尝试已结束');
        final bytes = reader.current;
        if (count + bytes.length > size) {
          throw const FormatException('接收数据超过声明大小');
        }
        output.add(bytes);
        await output.flush();
        count += bytes.length;
        onProgress(count);
      }
      if (stopped || count != size) throw const FormatException('直传未接收完整');
      await output.flush();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({'bytes': count, 'attemptId': attemptId}),
      );
    } catch (error) {
      failure = '$error';
      request.response.statusCode = HttpStatus.conflict;
    } finally {
      await _reader?.cancel();
      try {
        await sink?.close();
      } catch (error) {
        failure ??= '$error';
      }
      if (!_completed.isCompleted) _completed.complete(failure);
      _closed!.complete();
    }
  }

  Future<void> stop() async {
    stopped = true;
    await _reader?.cancel();
    await _closed?.future;
    if (!_completed.isCompleted) _completed.complete('接收尝试已结束');
  }
}
