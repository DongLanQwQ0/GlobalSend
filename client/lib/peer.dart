import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'connection_window.dart';
import 'candidate_routes.dart';
import 'local_ip_addresses.dart';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

import 'api.dart';
import 'received_file_access.dart';
import 'peer_receive.dart';

Map<String, String> createPeerIdentity(String id) {
  final keys = CryptoUtils.generateRSAKeyPair();
  final private = keys.privateKey as RSAPrivateKey;
  final public = keys.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem(
    {'CN': 'GlobalSend $id'},
    private,
    public,
  );
  final certificate = X509Utils.generateSelfSignedCertificate(
    private,
    csr,
    365,
    sans: ['localhost'],
    notBefore: DateTime.now().subtract(const Duration(minutes: 5)),
  );
  return {
    'certificate': certificate,
    'privateKey': CryptoUtils.encodeRSAPrivateKeyToPem(private),
  };
}

String certificateFingerprint(String pem) => sha256
    .convert(base64Decode(pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), '')))
    .toString();

/// Native authenticated HTTPS pull. Peer URLs never receive center bearer tokens.
class PeerTransport {
  PeerTransport(
    this.api,
    this.sourcePath, {
    this.onProgress,
    this.onRoute,
    this.pushEnabled = false,
    this.cellularPushAllowed,
    this.addressReader,
  });
  final CenterApi api;
  final String? Function(String fileId) sourcePath;
  final void Function(String fileId, int bytes, int total, bool finished)?
  onProgress;
  final void Function(String fileId, String route)? onRoute;
  final bool pushEnabled;
  final bool Function()? cellularPushAllowed;
  final Future<List<LocalIpAddress>> Function()? addressReader;
  final Map<String, PeerReceiveSlot> _receives = {};
  final Map<String, HttpClient> _pushClients = {};
  HttpServer? server;
  String fingerprint = '', certificate = '';
  List<String> candidates = [];
  final Set<String> canceledFiles = {};
  bool _loopbackOnly = false;
  void cancelFile(String id) {
    canceledFiles.add(id);
    _pushClients.remove(id)?.close(force: true);
    final slot = _receives.remove(id);
    if (slot != null) unawaited(slot.stop());
  }

  Future<PeerReceiveSlot> prepareReceive({
    required String transferId,
    required String fileId,
    required String attemptId,
    required File file,
    required int size,
    required int offset,
    required void Function(int) onProgress,
  }) async {
    await _receives.remove(fileId)?.stop();
    ConnectionWindow.current?.check();
    final slot = PeerReceiveSlot(
      transferId: transferId,
      fileId: fileId,
      attemptId: attemptId,
      file: file,
      size: size,
      offset: offset,
      onProgress: onProgress,
    );
    _receives[fileId] = slot;
    return slot;
  }

  Future<void> stopReceiving(PeerReceiveSlot slot) async {
    if (identical(_receives[slot.fileId], slot)) _receives.remove(slot.fileId);
    await slot.stop();
  }

  Future<void> start(
    Map<String, String> identity, {
    bool loopbackOnly = false,
  }) async {
    _loopbackOnly = loopbackOnly;
    certificate = identity['certificate']!;
    fingerprint = certificateFingerprint(certificate);
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(utf8.encode(identity['privateKey']!));
    server = await HttpServer.bindSecure(
      loopbackOnly ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv6,
      0,
      context,
      v6Only: false,
    );
    if (loopbackOnly) candidates = ['https://127.0.0.1:${server!.port}'];
    server!.listen((request) => unawaited(handle(request)));
    await publish();
  }

  static bool usableAddress(InternetAddress ip) =>
      !ip.isLoopback && !ip.isLinkLocal && !ip.address.contains('%');
  Future<void> publish() async {
    if (!_loopbackOnly && server != null) {
      final read = addressReader;
      if (read != null) {
        candidates = [
          for (final address in (await read()).where(isPublishableLocalAddress))
            Uri(
              scheme: 'https',
              host: address.address,
              port: server!.port,
            ).toString(),
        ];
      } else {
        final interfaces = await NetworkInterface.list(
          includeLoopback: false,
          includeLinkLocal: false,
        );
        candidates = [
          for (final interface in interfaces)
            for (final address in interface.addresses)
              if (usableAddress(address) && isDirectIp(address))
                Uri(
                  scheme: 'https',
                  host: address.address,
                  port: server!.port,
                ).toString(),
        ];
      }
    }
    if (server != null) {
      await api.call('POST', '/devices/me/peer', {
        'candidates': publicationCandidates(candidates),
        'certificatePem': certificate,
        'certificateSha256': fingerprint,
        if (pushEnabled) 'push': true,
        if (pushEnabled) 'cellularPush': cellularPushAllowed?.call() ?? false,
      });
    }
  }

  static bool privateAddress(InternetAddress ip) {
    final bytes = ip.rawAddress;
    if (ip.isLoopback) return true;
    if (ip.type == InternetAddressType.IPv4) {
      return bytes[0] == 10 ||
          bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 ||
          bytes[0] == 192 && bytes[1] == 168 ||
          bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
    }
    if (bytes.take(10).every((value) => value == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return privateAddress(InternetAddress.fromRawAddress(bytes.sublist(12)));
    }
    return (bytes[0] & 0xfe) == 0xfc ||
        bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0;
  }

  static bool privateCandidate(String candidate) =>
      privateAddress(candidateAddress(candidate));

  static InternetAddress candidateAddress(String value) =>
      InternetAddress(Uri.parse(value).host.replaceAll(RegExp(r'^\[|\]$'), ''));

  // Keep room for both scopes: many private interface addresses must not crowd
  // the actual global IPv4/IPv6 candidates out of the center's eight slots.
  static List<String> publicationCandidates(List<String> values) {
    final unique = values.toSet().toList();
    final local = unique.where(privateCandidate).toList();
    final public = unique.where((value) => !privateCandidate(value)).toList();
    final selected = [...local.take(4), ...public.take(4)];
    for (final value in unique) {
      if (selected.length == 8) break;
      if (!selected.contains(value)) selected.add(value);
    }
    return selected;
  }

  static Future<({List<String> lan, List<String> public})> candidateStages(
    List<String> values,
  ) async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final localV6 = interfaces
        .expand((entry) => entry.addresses)
        .where((ip) => ip.type == InternetAddressType.IPv6 && usableAddress(ip))
        .toList();
    final lan = <String>[], public = <String>[];
    for (final value in values.toSet()) {
      final ip = candidateAddress(value);
      // A matching IPv6 /64 is only a LAN candidate hint. It still has to pass
      // the pinned TLS + nonce probe; it is never accepted as reachability proof.
      final sameV6Prefix =
          ip.type == InternetAddressType.IPv6 &&
          localV6.any((local) {
            for (var index = 0; index < 8; index++) {
              if (ip.rawAddress[index] != local.rawAddress[index]) return false;
            }
            return true;
          });
      if (privateAddress(ip)) {
        lan.add(value);
      } else {
        if (sameV6Prefix) lan.add(value);
        public.add(value);
      }
    }
    return (lan: lan, public: public);
  }

  Future<void> handle(HttpRequest request) async {
    String? sendingId;
    ReceivedFileAccess? source;
    var sent = 0, total = 0;
    try {
      final push = request.uri.pathSegments;
      if (pushEnabled &&
          request.method == 'PUT' &&
          push.length == 4 &&
          push.first == 'push') {
        request.response.persistentConnection = false;
        final ticket = request.headers.value('X-GlobalSend-Ticket');
        final slot = _receives[push[2]];
        if (ticket == null ||
            slot == null ||
            slot.transferId != push[1] ||
            slot.attemptId != push[3]) {
          request.response.statusCode = HttpStatus.conflict;
          return;
        }
        final grant = await api.call('POST', '/push-tickets/verify', {
          'ticket': ticket,
          'transferId': push[1],
          'fileId': push[2],
          'attemptId': push[3],
        });
        if (!identical(_receives[push[2]], slot)) throw StateError('接收尝试已结束');
        await slot.receive(request, grant);
        return;
      }
      if (request.method != 'GET') {
        request.response.statusCode = 405;
        return;
      }
      if (request.uri.path == '/probe') {
        final nonce = request.uri.queryParameters['nonce'] ?? '';
        if (nonce.length > 128) {
          request.response.statusCode = 400;
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'nonce': nonce, 'certificateSha256': fingerprint}),
        );
        return;
      }
      final parts = request.uri.pathSegments;
      if (parts.length != 3 || parts.first != 'files') {
        request.response.statusCode = 404;
        return;
      }
      final ticket = request.headers.value('X-GlobalSend-Ticket');
      if (ticket == null) {
        request.response.statusCode = 401;
        return;
      }
      final grant = await api.call('POST', '/direct-tickets/verify', {
        'ticket': ticket,
        'transferId': parts[1],
        'fileId': parts[2],
      });
      final path = sourcePath(parts[2]);
      if (path == null) {
        request.response.statusCode = 410;
        return;
      }
      source = await ReceivedFileAccess.open(path);
      final file = source.file;
      if (await file.length() != grant['size']) {
        request.response.statusCode = 409;
        return;
      }
      request.response.headers.contentType = ContentType.binary;
      final length = grant['size'] as int;
      final etag = '"sha256-${grant['sha256']}"';
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.etagHeader, etag);
      var start = 0, end = length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      if (range != null && (ifRange == null || ifRange == etag)) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) {
          request.response.statusCode = 416;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$length',
          );
          return;
        }
        start = int.tryParse(match[1]!) ?? length;
        if (match[2]!.isNotEmpty) end = min(int.tryParse(match[2]!) ?? -1, end);
        if (start >= length || end < start) {
          request.response.statusCode = 416;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes */$length',
          );
          return;
        }
        request.response.statusCode = 206;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$length',
        );
      }
      request.response.contentLength = length == 0 ? 0 : end - start + 1;
      sendingId = parts[2];
      final connection = request.connectionInfo;
      if (connection != null) {
        final remote = connection.remoteAddress;
        final samePrefix =
            remote.type == InternetAddressType.IPv6 &&
            (remote.rawAddress[0] & 0xe0) == 0x20 &&
            candidates.any((value) {
              final local = candidateAddress(value);
              if (local.type != InternetAddressType.IPv6) return false;
              for (var index = 0; index < 8; index++) {
                if (local.rawAddress[index] != remote.rawAddress[index]) {
                  return false;
                }
              }
              return true;
            });
        onRoute?.call(
          sendingId,
          privateAddress(remote) || samePrefix ? 'lan' : 'public',
        );
      }
      total = grant['size'];
      sent = start;
      onProgress?.call(sendingId, start, total, false);
      canceledFiles.remove(parts[2]);
      final stopwatch = Stopwatch()..start();
      var lastUpdate = 0;
      await request.response.addStream(
        file
            .openRead(start, length == 0 ? 0 : end + 1)
            .takeWhile((_) => !canceledFiles.contains(parts[2]))
            .map((bytes) {
              sent += bytes.length;
              if (stopwatch.elapsedMilliseconds - lastUpdate > 150) {
                lastUpdate = stopwatch.elapsedMilliseconds;
                onProgress?.call(parts[2], sent, total, false);
              }
              return bytes;
            }),
      );
    } catch (_) {
      try {
        request.response.statusCode = 403;
      } catch (_) {}
    } finally {
      await source?.close();
      try {
        await request.response.close();
      } catch (_) {}
      if (sendingId != null) onProgress?.call(sendingId, sent, total, true);
    }
  }

  static HttpClient pinnedClient(String fingerprint, {String? sourceAddress}) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('无效设备指纹');
    }
    final context = SecurityContext(withTrustedRoots: false);
    bool accepts(X509Certificate certificate) =>
        sha256.convert(certificate.der).toString() == fingerprint &&
        DateTime.now().isAfter(certificate.startValidity) &&
        DateTime.now().isBefore(certificate.endValidity);
    final client = HttpClient(context: context)
      ..connectionTimeout = const Duration(seconds: 3)
      ..badCertificateCallback = (certificate, host, port) =>
          accepts(certificate);
    if (sourceAddress != null && sourceAddress.isNotEmpty) {
      client.connectionFactory = (url, proxyHost, proxyPort) async {
        final host = url.host.replaceAll(RegExp(r'^\[|\]$'), '');
        final tcp = await Socket.startConnect(
          proxyHost ?? host,
          proxyPort ?? url.port,
          sourceAddress: sourceAddress,
        );
        // Proxy CONNECT/TLS is still owned by HttpClient. Direct HTTPS factories
        // must return SecureSocket themselves (the SDK does not upgrade them).
        if (proxyHost != null || url.scheme != 'https') return tcp;
        final done = Completer<Socket>();
        Socket? raw;
        SecureSocket? secure;
        var canceled = false;
        unawaited(
          tcp.socket
              .then((socket) async {
                raw = socket;
                if (canceled) {
                  socket.destroy();
                  return;
                }
                secure = await SecureSocket.secure(
                  socket,
                  host: host,
                  context: context,
                  onBadCertificate: accepts,
                );
                if (canceled) {
                  secure!.destroy();
                  return;
                }
                done.complete(secure);
              })
              .catchError((Object error, StackTrace trace) {
                raw?.destroy();
                if (!done.isCompleted) done.completeError(error, trace);
              }),
        );
        return ConnectionTask.fromSocket(done.future, () {
          canceled = true;
          tcp.cancel();
          raw?.destroy();
          secure?.destroy();
          if (!done.isCompleted)
            done.completeError(const SocketException('连接已取消'));
        });
      };
    }
    return client;
  }

  static Future<String> probeCandidates(
    List<String> candidates,
    String fingerprint,
    String nonce, {
    Duration timeout = const Duration(seconds: 1),
    Map<String, String> sourceAddresses = const {},
  }) async {
    final result = Completer<String>();
    var remaining = candidates.length;
    if (remaining == 0) throw const SocketException('没有可达候选');
    final clients = <HttpClient>[];
    ConnectionWindow.current?.onCancel(() {
      for (final client in clients) {
        client.close(force: true);
      }
    });
    for (var i = 0; i < candidates.length; i++) {
      unawaited(() async {
        if (result.isCompleted) return;
        final client = pinnedClient(
          fingerprint,
          sourceAddress: sourceAddresses[candidates[i]],
        );
        clients.add(client);
        try {
          final base = Uri.parse(candidates[i]);
          if (base.scheme != 'https' ||
              base.userInfo.isNotEmpty ||
              base.path.isNotEmpty && base.path != '/') {
            throw const FormatException('无效候选地址');
          }
          final request = await client.getUrl(
            base.replace(path: '/probe', queryParameters: {'nonce': nonce}),
          );
          request.followRedirects = false;
          final response = await request.close().timeout(timeout);
          final body = jsonDecode(await utf8.decoder.bind(response).join());
          if (response.statusCode != 200 ||
              body['nonce'] != nonce ||
              body['certificateSha256'] != fingerprint) {
            throw const FormatException('设备挑战失败');
          }
          if (!result.isCompleted) result.complete(candidates[i]);
        } catch (_) {
          if (--remaining == 0 && !result.isCompleted) {
            result.completeError(const SocketException('候选地址均不可达'));
          }
        } finally {
          client.close(force: true);
        }
      }());
    }
    try {
      return await result.future.timeout(timeout);
    } finally {
      for (final client in clients) {
        client.close(force: true);
      }
    }
  }

  static Future<void> pull(
    String candidate,
    String fingerprint,
    String ticket,
    String transferId,
    String fileId,
    File file,
    void Function(int) progress, {
    String? expectedSha256,
    int? expectedSize,
    String? sourceAddress,
  }) async {
    final client = pinnedClient(fingerprint, sourceAddress: sourceAddress);
    final connection = ConnectionWindow.current;
    connection?.onCancel(() => client.close(force: true));
    IOSink? sink;
    try {
      final request = await client.getUrl(
        Uri.parse(candidate).replace(path: '/files/$transferId/$fileId'),
      );
      request.followRedirects = false;
      request.headers.set('X-GlobalSend-Ticket', ticket);
      var offset = await file.exists() ? await file.length() : 0;
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
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      connection?.check();
      if (response.statusCode == 416 &&
          expectedSize != null &&
          offset == expectedSize) {
        await response.drain<void>();
        connection?.connected();
        progress(offset);
        return;
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw const HttpException('直连授权或文件已失效');
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
          throw const FormatException('直连断点响应不匹配');
        }
      } else {
        offset = 0;
      }
      connection?.connected();
      sink = file.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      var count = offset;
      progress(count);
      await for (final data in response.timeout(const Duration(seconds: 20))) {
        sink.add(data);
        count += data.length;
        progress(count);
      }
      await sink.flush();
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }

  Future<void> push(
    String candidate,
    Map<String, dynamic> grant,
    String transferId,
    String fileId,
    String path,
    void Function(int) progress, {
    String? sourceAddress,
  }) async {
    final client = pinnedClient(
      grant['certificateSha256'],
      sourceAddress: sourceAddress,
    );
    _pushClients[fileId] = client;
    ReceivedFileAccess? source;
    Timer? idle;
    final offset = grant['offset'] as int, size = grant['size'] as int;
    try {
      source = await ReceivedFileAccess.open(path);
      canceledFiles.remove(fileId);
      if (await source.file.length() != size) {
        throw const FileSystemException('发送源文件已变化');
      }
      final request = await client.putUrl(
        Uri.parse(candidate)
            .replace(path: '/push/$transferId/$fileId/${grant['attemptId']}'),
      );
      request.followRedirects = false;
      request.headers.set('X-GlobalSend-Ticket', grant['ticket']);
      request.headers.contentType = ContentType.binary;
      request.contentLength = size - offset;
      var count = offset;
      progress(count);
      void touch() {
        idle?.cancel();
        idle = Timer(
          const Duration(seconds: 20),
          () => client.close(force: true),
        );
      }

      touch();
      await request.addStream(
        source.file.openRead(offset).timeout(const Duration(seconds: 20)).map((
          bytes,
        ) {
          if (canceledFiles.contains(fileId)) throw StateError('发送已取消');
          count += bytes.length;
          touch();
          progress(count);
          return bytes;
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response
          .fold<List<int>>([], (buffer, chunk) {
            if (buffer.length + chunk.length > 4096) {
              throw const FormatException('反向直传响应过大');
            }
            return buffer..addAll(chunk);
          })
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw HttpException('反向直传 HTTP ${response.statusCode}');
      }
      final result = jsonDecode(utf8.decode(body));
      if (result['bytes'] != size ||
          result['attemptId'] != grant['attemptId']) {
        throw const FormatException('反向直传响应不匹配');
      }
    } finally {
      idle?.cancel();
      await source?.close();
      if (identical(_pushClients[fileId], client)) _pushClients.remove(fileId);
      client.close(force: true);
    }
  }

  Future<void> close() async {
    for (final client in _pushClients.values) {
      client.close(force: true);
    }
    _pushClients.clear();
    final slots = _receives.values.toList();
    _receives.clear();
    await Future.wait(slots.map((slot) => slot.stop()));
    await server?.close(force: true);
  }
}
