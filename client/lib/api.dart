import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'connection_window.dart';
import 'transfer_operation.dart';

class CenterApi {
  CenterApi(this.baseUrl, {this.token = ''});
  final String baseUrl;
  CenterApi get owner => this;
  CenterApi forOperation(TransferOperation operation) =>
      _OperationApi(this, operation);
  String token;
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  Uri uri(String path) => Uri.parse('$baseUrl/api/v1$path');
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    final authenticationToken = token;
    final window = ConnectionWindow.current;
    window?.check();
    final operation = TransferOperation.current;
    operation?.check();
    final activeClient = window == null
        ? operation?.resource<HttpClient>(
                this,
                () =>
                    HttpClient()
                      ..connectionTimeout = const Duration(seconds: 3),
                (value) => value.close(force: true),
              ) ??
              client
        : window.resource<HttpClient>(
            this,
            () => HttpClient()..connectionTimeout = window.remaining,
            (value) => value.close(force: true),
          );
    final request = await activeClient.openUrl(method, uri(path));
    operation?.onCancel(() => request.abort());
    operation?.check();
    window?.onCancel(() => request.abort());
    window?.check();
    request.followRedirects = false;
    if (authenticated && authenticationToken.isNotEmpty) {
      request.headers.set('Authorization', 'Bearer $authenticationToken');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 35));
    operation?.check();
    window?.check();
    final String raw;
    if (window == null) {
      raw = await utf8.decoder.bind(response).join();
    } else {
      final body = StringBuffer(), completed = Completer<String>();
      final subscription = utf8.decoder
          .bind(response)
          .listen(
            body.write,
            onDone: () {
              if (!completed.isCompleted) completed.complete(body.toString());
            },
            onError: (Object error, StackTrace stack) {
              if (!completed.isCompleted) completed.completeError(error, stack);
            },
          );
      window.onCancel(() async {
        await subscription.cancel();
        if (!completed.isCompleted)
          completed.completeError(const SocketException('连接请求已取消'));
      });
      raw = await completed.future;
      window.check();
    }
    final decoded = raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        decoded['error']?['message'] ?? '中心请求失败',
        response: decoded,
      );
    }
    return decoded;
  }

  Future<void> upload(String path, List<int> bytes) async {
    final operation = TransferOperation.current;
    operation?.check();
    final activeClient =
        operation?.resource<HttpClient>(
          this,
          () => HttpClient()..connectionTimeout = const Duration(seconds: 3),
          (value) => value.close(force: true),
        ) ??
        client;
    final request = await activeClient.putUrl(uri(path));
    operation?.onCancel(() => request.abort());
    operation?.check();
    request.followRedirects = false;
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.contentType = ContentType.binary;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 60));
    final raw = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
        response.statusCode,
        jsonDecode(raw)['error']['message'],
      );
    }
  }

  Future<void> download(
    String path,
    File destination,
    void Function(int) progress, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    final operation = TransferOperation.current;
    operation?.check();
    if (!path.startsWith('/api/v1/downloads/') ||
        path.contains('..') ||
        path.contains('?') ||
        path.contains('#')) {
      throw const FormatException('无效下载地址');
    }
    final activeClient =
        operation?.resource<HttpClient>(
          this,
          () => HttpClient()..connectionTimeout = const Duration(seconds: 3),
          (value) => value.close(force: true),
        ) ??
        client;
    final request = await activeClient.getUrl(Uri.parse('$baseUrl$path'));
    operation?.onCancel(() => request.abort());
    operation?.check();
    request.followRedirects = false;
    var offset = await destination.exists() ? await destination.length() : 0;
    if (expectedSize != null && offset > expectedSize) offset = 0;
    if (offset > 0 && expectedSha256 != null) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      request.headers.set(
        HttpHeaders.ifRangeHeader,
        '"sha256-$expectedSha256"',
      );
    } else {
      offset = 0;
    }
    final response = await request.close().timeout(const Duration(seconds: 35));
    if (response.statusCode == 416 &&
        expectedSize != null &&
        offset == expectedSize) {
      await response.drain<void>();
      progress(offset);
      return;
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      throw ApiException(response.statusCode, '下载授权已失效，请重试');
    }
    if (response.statusCode == 206) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      if (range == null ||
          int.parse(range[1]!) != offset ||
          expectedSize != null && int.parse(range[3]!) != expectedSize ||
          expectedSha256 != null &&
              response.headers.value(HttpHeaders.etagHeader) !=
                  '"sha256-$expectedSha256"') {
        await response.drain<void>();
        throw const FormatException('中继断点响应与本地文件不匹配');
      }
    } else {
      offset = 0;
    }
    final sink = destination.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var count = offset;
    progress(count);
    try {
      await for (final bytes in response.timeout(const Duration(seconds: 45))) {
        operation?.check();
        sink.add(bytes);
        count += bytes.length;
        progress(count);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  void close() => client.close(force: true);
}

class _OperationApi extends CenterApi {
  _OperationApi(this.source, this.operation)
    : super(source.baseUrl, token: source.token);
  final CenterApi source;
  final TransferOperation operation;
  @override
  CenterApi get owner => source.owner;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    operation.check();
    final request = source.call(method, path, body, authenticated);
    final result = await operation.wait(
      request.timeout(const Duration(seconds: 3)),
    );
    operation.check();
    return result;
  }

  @override
  Future<void> upload(String path, List<int> bytes) {
    operation.check();
    return operation.wait(source.upload(path, bytes));
  }

  // Closing the per-file client aborts the body stream; wait for its sink's
  // finally before releasing a descriptor or allowing resume on the same file.
  @override
  Future<void> download(
    String path,
    File destination,
    void Function(int) progress, {
    String? expectedSha256,
    int? expectedSize,
  }) async {
    operation.check();
    await source.download(
      path,
      destination,
      progress,
      expectedSha256: expectedSha256,
      expectedSize: expectedSize,
    );
    operation.check();
  }
}

class ApiException implements Exception {
  ApiException(this.status, this.message, {this.response});
  final int status;
  final String message;
  final Map<String, dynamic>? response;
  @override
  String toString() => '$message ($status)';
}
