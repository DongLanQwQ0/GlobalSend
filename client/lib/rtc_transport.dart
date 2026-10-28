import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'api.dart';
import 'rtc_candidates.dart';
import 'rtc_connection.dart';
import 'connection_window.dart';

const rtcFileChannel = 'globalsend-file-v1';
const rtcChunkBytes = 16 * 1024;
const rtcWindowBytes = 512 * 1024;

/// One disk-backed file per authenticated, receiver-owned WebRTC attempt.
/// Center credentials stay in signaling requests, never in the data channel.
class RtcFileTransport {
  RtcFileTransport(
    this.api, {
    this.iceServers = const [],
    this.cellularAllowed,
    this.parallelProbes = false,
    this.onNetwork,
    RtcConnectionFactory? connectionFactory,
  }) : connectionFactory = connectionFactory ?? createRtcDataConnection;
  final CenterApi api;
  final bool parallelProbes;
  final List<Map<String, dynamic>> iceServers;
  final bool Function()? cellularAllowed;
  final void Function(String fileId, String network, String family)? onNetwork;
  final RtcConnectionFactory connectionFactory;
  final Map<String, _RtcFileSession> _active = {};
  final Set<_RtcFileSession> _retiring = {};
  bool _closed = false;
  static Future<void>? _initialization;

  static Future<void> initialize() => _initialization ??= () async {
    if (Platform.isAndroid) {
      await AndroidRtcConnection.prepare();
    } else {
      await WebRTC.initialize();
    }
  }();

  bool get cellularCapable => Platform.isAndroid;

  Future<void> publish() => api.call('POST', '/devices/me/rtc', {
    'scopes': ['lan', 'public'],
    if (parallelProbes) 'parallelProbes': true,
  });

  Future<void> receive({
    required String fileRoute,
    required String attemptId,
    required String scope,
    required File destination,
    required int size,
    required void Function(int) onProgress,
  }) async {
    final offset = await destination.exists() ? await destination.length() : 0;
    if (offset > size) throw StateError('本地接收断点大于文件长度');
    final session = await _prepare(
      fileRoute,
      attemptId,
      scope,
      size,
      offset,
      onProgress,
    );
    var completed = false;
    final connection = ConnectionWindow.current;
    try {
      connection?.onCancel(() async {
        await session.stopWriting();
        cleanupConnection(() async {
          await api.call('POST', '${session.route}/stop', {});
        });
        if (identical(_active[fileRoute], session)) _active.remove(fileRoute);
        _retiring.add(session);
        unawaited(
          session.close().then<void>(
            (_) {
              _retiring.remove(session);
            },
            onError: (Object _, StackTrace __) {
              /* Retain failed cleanup for close/revoke. */
            },
          ),
        );
      });
      connection?.check();
      final result = await api.call('POST', '$fileRoute/rtc', {
        'attemptId': attemptId,
        'scope': scope,
        'offset': offset,
      });
      await session.receive(
        destination,
        Map<String, dynamic>.from(result['rtc']),
      );
      completed = true;
    } catch (error) {
      if (connection?.canceled != true) await session.reportFailure(error);
      rethrow;
    } finally {
      await session.close();
      if (identical(_active[fileRoute], session)) _active.remove(fileRoute);
      if (!completed) {
        cleanupConnection(() async {
          await api.call('POST', '${session.route}/stop', {});
        });
      }
    }
  }

  Future<void> send({
    required String fileRoute,
    required Map<String, dynamic> attempt,
    required File source,
    required int size,
    required void Function(int) onProgress,
  }) async {
    final session = await _prepare(
      fileRoute,
      attempt['attemptId'],
      attempt['scope'],
      size,
      attempt['offset'],
      onProgress,
    );
    try {
      if (await source.length() != size) throw StateError('原文件已改变');
      await session.send(source);
    } catch (error) {
      await session.reportFailure(error);
      rethrow;
    } finally {
      await session.close();
      if (identical(_active[fileRoute], session)) _active.remove(fileRoute);
    }
  }

  Future<_RtcFileSession> _prepare(
    String fileRoute,
    String attemptId,
    String scope,
    int size,
    int offset,
    void Function(int) progress,
  ) async {
    if (_closed) throw StateError('直连会话已关闭');
    final previous = _active[fileRoute];
    if (previous != null) await _retire(fileRoute, previous);
    ConnectionWindow.current?.check();
    if (_closed) throw StateError('直连会话已关闭');
    final session = _RtcFileSession(
      api,
      fileRoute,
      attemptId,
      scope,
      size,
      offset,
      progress,
      iceServers,
      rtcCellularPolicy(
        android: cellularCapable,
        scope: scope,
        permission: cellularAllowed?.call() ?? false,
      ),
      connectionFactory,
      (network, family) =>
          onNetwork?.call(fileRoute.split('/').last, network, family),
    );
    _active[fileRoute] = session;
    return session;
  }

  Future<void> cancelFile(String fileId) async {
    final entries = _active.entries
        .where((entry) => entry.key.endsWith('/files/$fileId'))
        .toList();
    for (final entry in entries) {
      await _retire(entry.key, entry.value);
    }
  }

  Future<void> revokeCellular() async {
    final entries = _active.entries
        .where((entry) => entry.value.allowCellular)
        .toList();
    await Future.wait(entries.map((entry) => _retire(entry.key, entry.value)));
    await Future.wait(
      _retiring
          .where((session) => session.allowCellular)
          .map((session) => session.close()),
    );
  }

  Future<void> close() async {
    _closed = true;
    final values = _active.entries.toList();
    await Future.wait(values.map((entry) => _retire(entry.key, entry.value)));
    await Future.wait(_retiring.toList().map((session) => session.close()));
  }

  Future<void> _retire(String route, _RtcFileSession session) async {
    // Keep closing owners discoverable by revoke/close until their native
    // creation, writer and network lease have all finished shutting down.
    try {
      await session.close();
    } finally {
      if (identical(_active[route], session)) _active.remove(route);
    }
  }
}

class _RtcFileSession {
  _RtcFileSession(
    this.api,
    String fileRoute,
    String attemptId,
    this.scope,
    this.size,
    this.offset,
    this.progress,
    this.iceServers,
    this.allowCellular,
    this.connectionFactory,
    this.network,
  ) : route = '$fileRoute/rtc/$attemptId',
      count = offset,
      acknowledged = offset;
  final CenterApi api;
  final String route, scope;
  final int size, offset;
  final void Function(int) progress;
  final List<Map<String, dynamic>> iceServers;
  final bool allowCellular;
  final RtcConnectionFactory connectionFactory;
  final void Function(String network, String family) network;
  final _result = Completer<String?>();
  final _opened = Completer<void>();
  RtcDataConnection? pc;
  Future<RtcDataConnection>? _creating;
  RtcDataChannel? channel;
  RandomAccessFile? writer;
  Future<RandomAccessFile>? _openingWriter;
  Future<void>? _writerClosing;
  Future<void> _writes = Future.value(), _signals = Future.value();
  Future<void>? _closing, _pumping;
  RtcCandidatePolicy? policy;
  final List<Map<String, dynamic>> _localCandidates = [];
  final List<Map<String, dynamic>> _remoteCandidates = [];
  final Set<String> _seenCandidates = {};
  bool stopped = false, receiver = false, remoteDescription = false;
  bool _ready = false, _ended = false, _completeSent = false;
  int count, acknowledged, queuedBytes = 0, _lastFlush = 0;
  DateTime _lastActivity = DateTime.now();
  Timer? _watchdog;

  void fail(Object error) {
    if (!_result.isCompleted) _result.complete('$error');
  }

  void success() {
    if (!_result.isCompleted) _result.complete(null);
  }

  void check() {
    if (stopped || _result.isCompleted) throw StateError('直连会话已结束');
  }

  void activity() => _lastActivity = DateTime.now();

  Future<void> setup() async {
    await RtcFileTransport.initialize();
    check();
    final interfaces = await NetworkInterface.list(includeLinkLocal: true);
    check();
    policy = RtcCandidatePolicy(
      scope,
      interfaces.expand((value) => value.addresses).toList(),
    );
    _creating = connectionFactory(
      scope: scope,
      allowCellular: allowCellular,
      iceServers: scope == 'public' ? iceServers : [],
    );
    pc = await _creating;
    if (stopped) {
      await pc!.close();
      throw StateError('直连已取消');
    }
    pc!.onIceCandidate = (candidate) {
      final text = candidate.candidate ?? '';
      if (!stopped && policy!.allows(text)) {
        _localCandidates.add(candidate.toMap());
      }
    };
    pc!.onNetwork = (value, family) {
      if (!stopped) network(value, family);
    };
    pc!.onConnectionState = (state) {
      if (!stopped &&
          [
            RTCPeerConnectionState.RTCPeerConnectionStateFailed,
            RTCPeerConnectionState.RTCPeerConnectionStateClosed,
          ].contains(state)) {
        if (_completeSent) {
          success();
        } else {
          fail('WebRTC连接已关闭');
        }
      }
    };
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      final limit = _ready
          ? const Duration(seconds: 45)
          : const Duration(seconds: 18);
      if (DateTime.now().difference(_lastActivity) > limit) fail('WebRTC连接超时');
    });
  }

  void attach(RtcDataChannel value) {
    if (stopped || channel != null || value.label != rtcFileChannel) {
      unawaited(value.close());
      if (value.label != rtcFileChannel) fail('未知文件通道');
      return;
    }
    channel = value;
    value.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        activity();
        if (!_opened.isCompleted) _opened.complete();
      } else if (state == RTCDataChannelState.RTCDataChannelClosed &&
          !stopped) {
        if (_completeSent) {
          success();
        } else {
          fail('文件通道已关闭');
        }
      }
    };
    value.onMessage = message;
    if (value.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_opened.isCompleted) {
      _opened.complete();
    }
  }

  Future<void> signal(String suffix, Map<String, dynamic> body) async {
    check();
    await api.call('POST', '$route/$suffix', body);
    check();
  }

  Future<void> setDescription(String type, String sdp) async {
    final description = RTCSessionDescription(
      RtcCandidatePolicy.withoutCandidates(sdp),
      type,
    );
    await pc!.setRemoteDescription(description);
    remoteDescription = true;
  }

  Future<void> describe(String type) async {
    // flutter_webrtc defaults to receiving audio/video even without tracks.
    // Explicit data-only constraints avoid media m-lines and permissions.
    const constraints = {
      'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
      'optional': <Object>[],
    };
    final description = type == 'offer'
        ? await pc!.createOffer(constraints)
        : await pc!.createAnswer(constraints);
    await pc!.setLocalDescription(description);
    await signal('description', {
      'type': type,
      'sdp': RtcCandidatePolicy.withoutCandidates(description.sdp!),
    });
  }

  Future<void> sync() async {
    check();
    final state = Map<String, dynamic>.from(
      (await api.call('GET', route))['rtc'],
    );
    check();
    if (state['state'] == 'failed') {
      throw StateError(state['error'] ?? '对方直连失败');
    }
    if (!remoteDescription) {
      final description = state[receiver ? 'answer' : 'offer'];
      if (description is Map) {
        await setDescription(description['type'], description['sdp']);
        if (!receiver) await describe('answer');
      }
    }
    for (final candidate in List<Map<String, dynamic>>.from(
      (state['candidates'] as Map)[receiver ? 'source' : 'target'],
    )) {
      final key = jsonEncode(candidate);
      if (_seenCandidates.add(key) && policy!.allows(candidate['candidate'])) {
        _remoteCandidates.add(candidate);
      }
    }
    if (remoteDescription) {
      while (_remoteCandidates.isNotEmpty) {
        final candidate = _remoteCandidates.removeAt(0);
        await pc!.addCandidate(
          RTCIceCandidate(
            candidate['candidate'],
            candidate['sdpMid'],
            candidate['sdpMLineIndex'],
          ),
        );
      }
    }
    while (_localCandidates.isNotEmpty) {
      await signal('candidate', _localCandidates.removeAt(0));
    }
  }

  Future<void> polling() async {
    while (!stopped && !_result.isCompleted) {
      try {
        await sync();
      } catch (error) {
        if (!_result.isCompleted) fail(error);
      }
      if (!_result.isCompleted) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> receive(File destination, Map<String, dynamic> attempt) async {
    receiver = true;
    await setup();
    check();
    attach(await pc!.createDataChannel(rtcFileChannel));
    await describe('offer');
    _signals = polling();
    // Race with an error result so a canceled negotiation cannot leave a
    // listener awaiting an open event forever.
    await Future.any([_opened.future, _result.future]);
    if (!_result.isCompleted) {
      await pc!.authorizeData();
      check();
      await signal('started', {});
      check();
      ConnectionWindow.current?.connected();
      _openingWriter = destination.open(mode: FileMode.append);
      writer = await _openingWriter;
      if (stopped) {
        await closeWriter();
        throw StateError('直连已取消');
      }
      if (await writer!.length() != offset) throw StateError('接收断点已改变');
      _lastFlush = offset;
      _ready = true;
      activity();
      await control({'type': 'ready', 'offset': offset, 'size': size});
      progress(offset);
    }
    final error = await _result.future;
    if (error != null) throw StateError(error);
  }

  Future<void> send(File source) async {
    await setup();
    pc!.onDataChannel = attach;
    _source = source;
    _signals = polling();
    final error = await _result.future;
    if (error != null) throw StateError(error);
  }

  File? _source;
  Future<void> control(Map<String, Object> value) =>
      channel!.send(RTCDataChannelMessage(jsonEncode(value)));

  void message(RTCDataChannelMessage message) {
    if (stopped || _result.isCompleted) return;
    activity();
    if (message.isBinary) {
      final bytes = message.binary;
      if (!receiver ||
          !_ready ||
          _ended ||
          bytes.length > rtcChunkBytes ||
          count + queuedBytes + bytes.length > size ||
          queuedBytes + bytes.length > rtcWindowBytes) {
        fail('文件数据超出协商范围');
        return;
      }
      queuedBytes += bytes.length;
      _writes = _writes
          .then((_) async {
            if (stopped) return;
            await writer!.writeFrom(bytes);
            count += bytes.length;
            queuedBytes -= bytes.length;
            if (count - _lastFlush >= 64 * 1024 || count == size) {
              await writer!.flush();
              _lastFlush = count;
              await control({'type': 'ack', 'offset': count});
              progress(count);
            }
          })
          .catchError((Object error) {
            fail(error);
          });
      return;
    }
    try {
      final value = jsonDecode(message.text) as Map<String, dynamic>;
      switch (value['type']) {
        case 'ready':
          if (receiver ||
              _ready ||
              value['offset'] != offset ||
              value['size'] != size) {
            throw StateError('直连断点不匹配');
          }
          _ready = true;
          _pumping = pump().catchError((Object error) {
            fail(error);
          });
        case 'ack':
          final next = value['offset'];
          if (receiver || next is! int || next < acknowledged || next > count) {
            throw StateError('无效接收确认');
          }
          acknowledged = next;
          progress(next);
        case 'end':
          if (!receiver || !_ready || _ended || value['size'] != size) {
            throw StateError('无效文件结束标记');
          }
          _ended = true;
          _writes = _writes
              .then((_) async {
                if (stopped) return;
                if (count != size) throw StateError('直连文件长度不符');
                await writer!.flush();
                progress(count);
                _completeSent = true;
                await control({'type': 'complete', 'size': size});
                // Let the source consume the final commit before teardown. A
                // source close is the normal completion signal; the grace is for
                // browsers that do not promptly report SCTP shutdown.
                Future<void>.delayed(const Duration(seconds: 1), () {
                  if (_completeSent && !stopped) success();
                });
              })
              .catchError((Object error) {
                fail(error);
              });
        case 'complete':
          if (receiver || !_ended || value['size'] != size) {
            throw StateError('无效完成确认');
          }
          acknowledged = size;
          progress(size);
          success();
        default:
          throw StateError('未知文件控制消息');
      }
    } catch (error) {
      fail(error);
    }
  }

  Future<void> pump() async {
    await pc!.authorizeData();
    check();
    final file = await _source!.open();
    try {
      await file.setPosition(offset);
      progress(offset);
      while (count < size) {
        check();
        while (count - acknowledged >= rtcWindowBytes ||
            await channel!.getBufferedAmount() > 256 * 1024) {
          check();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final bytes = await file.read(min(rtcChunkBytes, size - count));
        if (bytes.isEmpty) throw StateError('原文件已改变');
        count += bytes.length;
        await channel!.send(RTCDataChannelMessage.fromBinary(bytes));
      }
      _ended = true;
      await control({'type': 'end', 'size': size});
    } finally {
      await file.close();
    }
  }

  Future<void> reportFailure(Object error) async {
    try {
      final text = '$error';
      await api.call('POST', '$route/fail', {
        'error': text.substring(0, min(text.length, 512)),
      });
    } catch (_) {
      // The receiver may already have stopped the old route.
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> stopWriting() async {
    stopped = true;
    fail('直连已取消');
    _watchdog?.cancel();
    await _writes;
    await closeWriter();
  }

  Future<void> closeWriter() => _writerClosing ??= () async {
    final value = writer ?? await _openingWriter;
    await value?.close();
    writer = null;
  }();
  Future<void> _close() async {
    stopped = true;
    fail('直连已取消');
    _watchdog?.cancel();
    try {
      await _writes;
      await closeWriter();
    } finally {
      writer = null;
      try {
        await _pumping;
      } finally {
        try {
          await channel?.close();
        } finally {
          final value = pc ?? await _creating;
          await value?.close();
        }
      }
    }
    // Read-only signaling may still be awaiting a slow center response. The
    // stopped flag fences its continuation; writer/channel teardown must not
    // wait on a network timeout before the next route can resume the file.
    unawaited(_signals);
  }
}
