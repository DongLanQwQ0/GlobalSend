import 'dart:io';

import 'package:flutter/services.dart';

/// Per-connection Android network operations. Control-channel sockets remain Dart-owned.
class NetworkBridge {
  static const channel = MethodChannel('dev.globalsend/network');
  static final Map<String, void Function(int)> _progress = {};
  static void _installProgressHandler() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final data = Map<String, dynamic>.from(call.arguments);
        _progress[data['operationId']]?.call(data['bytes'] as int);
      }
    });
  }

  static Future<Map<String, dynamic>> probePeer({
    required String candidate,
    required String fingerprint,
    required String nonce,
    required bool cellular,
    String? operationId,
  }) async => Map<String, dynamic>.from(
    await channel.invokeMethod('probePeer', {
      'candidate': candidate,
      'fingerprint': fingerprint,
      'nonce': nonce,
      'cellular': cellular,
      'operationId': ?operationId,
    }) as Map,
  );
  static Future<void> cancel(String operationId) async =>
      channel.invokeMethod('cancelOperation', {'operationId': operationId});
  static Future<Map<String, dynamic>> downloadPeer({
    required List<String> candidates,
    required String fingerprint,
    required String ticket,
    required String transferId,
    required String fileId,
    required String path,
    required String operationId,
    required int expectedSize,
    required String expectedSha256,
    required String nonce,
    required void Function(int) onProgress,
    String? verifiedCandidate,
  }) async {
    _installProgressHandler();
    _progress[operationId] = onProgress;
    try {
      return Map<String, dynamic>.from(
        await channel.invokeMethod('downloadPeer', {
          'candidates': candidates,
          'fingerprint': fingerprint,
          'ticket': ticket,
          'transferId': transferId,
          'fileId': fileId,
          'path': path,
          'operationId': operationId,
          'expectedSize': expectedSize,
          'expectedSha256': expectedSha256,
          'nonce': nonce,
          'verifiedCandidate': ?verifiedCandidate,
          'cellular': true,
        }) as Map,
      );
    } finally {
      _progress.remove(operationId);
    }
  }

  static Future<Map<String, dynamic>> uploadPeer({
    required List<String> candidates,
    required String fingerprint,
    required String ticket,
    required String transferId,
    required String fileId,
    required String attemptId,
    required String path,
    required int offset,
    required int expectedSize,
    required String operationId,
    required String nonce,
    required void Function(int) onProgress,
    String? verifiedCandidate,
  }) async {
    _installProgressHandler();
    _progress[operationId] = onProgress;
    try {
      return Map<String, dynamic>.from(
        await channel.invokeMethod('uploadPeer', {
          'candidates': candidates,
          'fingerprint': fingerprint,
          'ticket': ticket,
          'transferId': transferId,
          'fileId': fileId,
          'attemptId': attemptId,
          'path': path,
          'offset': offset,
          'expectedSize': expectedSize,
          'operationId': operationId,
          'nonce': nonce,
          'verifiedCandidate': ?verifiedCandidate,
          'cellular': true,
        }) as Map,
      );
    } finally {
      _progress.remove(operationId);
    }
  }

  static Future<Map<String, dynamic>> probe(
    String url, {
    bool cellular = false,
  }) async {
    if (!Platform.isAndroid) throw UnsupportedError('逐网络绑定仅用于 Android');
    return Map<String, dynamic>.from(
      await channel.invokeMethod('probe', {'url': url, 'cellular': cellular})
          as Map,
    );
  }

  /// Transfers directly from native file input, not per-chunk MethodChannel copies.
  /// HTTPS only; platform CA / hostname validation remains enabled.
  static Future<Map<String, dynamic>> putFile(
    String url,
    String path, {
    required bool cellular,
    required String authorization,
    required int offset,
    required int length,
    String? operationId,
  }) async => Map<String, dynamic>.from(
    await channel.invokeMethod('putFile', {
      'url': url,
      'path': path,
      'cellular': cellular,
      'authorization': authorization,
      'offset': offset,
      'length': length,
      'operationId': ?operationId,
    }) as Map,
  );
}
