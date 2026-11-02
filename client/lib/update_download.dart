import 'dart:io';

import 'github_updates.dart';
import 'network_proxy.dart';

typedef UpdateProgress = void Function(int received, int total);

abstract interface class UpdateDownloader {
  Future<File> download(
    PlatformUpdate offer,
    File destination,
    UpdateProgress progress,
  );
  void cancel();
}

class UpdateDownloadCanceled implements Exception {}

/// Stream GitHub's selected platform asset to the application's update cache.
/// A partial file remains resumable; only a complete file becomes installable.
class HttpUpdateDownloader implements UpdateDownloader {
  HttpClient? _client;
  bool _canceled = false;

  @override
  Future<File> download(
    PlatformUpdate offer,
    File destination,
    UpdateProgress progress,
  ) async {
    _canceled = false;
    await destination.parent.create(recursive: true);
    if (await destination.exists() &&
        await destination.length() == offer.size) {
      progress(offer.size, offer.size);
      return destination;
    }
    final partial = File('${destination.path}.part');
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset > offer.size) {
      await partial.delete();
      offset = 0;
    }
    final client = NetworkProxy.client()
      ..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    IOSink? sink;
    try {
      final request = await client.getUrl(
        Uri.parse(
          offer.assetApiUrl.isNotEmpty ? offer.assetApiUrl : offer.downloadUrl,
        ),
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'GlobalSend updater');
      if (offer.assetApiUrl.isNotEmpty)
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/octet-stream',
        );
      if (offset > 0)
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode == 416 && offset == offer.size) {
        await response.drain<void>();
      } else {
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          await response.drain<void>();
          throw HttpException('下载失败（HTTP ${response.statusCode}）');
        }
        if (response.statusCode == HttpStatus.ok) offset = 0;
        if (response.statusCode == HttpStatus.partialContent &&
            !(response.headers.value(HttpHeaders.contentRangeHeader) ?? '')
                .startsWith('bytes $offset-')) {
          throw const HttpException('下载断点无效，请重试');
        }
        sink = partial.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        var received = offset;
        progress(received, offer.size);
        await for (final bytes in response.timeout(
          const Duration(seconds: 25),
        )) {
          if (_canceled) throw UpdateDownloadCanceled();
          received += bytes.length;
          if (received > offer.size)
            throw const HttpException('安装包大小已变化，请重新检查更新');
          sink.add(bytes);
          progress(received, offer.size);
        }
        await sink.flush();
        await sink.close();
        sink = null;
      }
      if (_canceled) throw UpdateDownloadCanceled();
      if (!await partial.exists() || await partial.length() != offer.size) {
        throw const HttpException('下载未完成，可重试续传');
      }
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      progress(offer.size, offer.size);
      return destination;
    } catch (_) {
      if (_canceled) throw UpdateDownloadCanceled();
      rethrow;
    } finally {
      await sink?.close();
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  @override
  void cancel() {
    _canceled = true;
    _client?.close(force: true);
  }
}
