import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The file transport needs data-only operations, not the plugin's media API.
abstract class RtcDataConnection {
  set onIceCandidate(void Function(RTCIceCandidate)? value);
  set onConnectionState(void Function(RTCPeerConnectionState)? value);
  set onDataChannel(void Function(RtcDataChannel)? value);
  set onNetwork(void Function(String network, String family)? value);
  Future<RTCSessionDescription> createOffer(Map<String, dynamic> constraints);
  Future<RTCSessionDescription> createAnswer(Map<String, dynamic> constraints);
  Future<void> setLocalDescription(RTCSessionDescription description);
  Future<void> setRemoteDescription(RTCSessionDescription description);
  Future<void> addCandidate(RTCIceCandidate candidate);
  Future<RtcDataChannel> createDataChannel(String label);
  Future<void> authorizeData();
  Future<void> close();
}

abstract class RtcDataChannel {
  String? get label;
  RTCDataChannelState? get state;
  set onDataChannelState(void Function(RTCDataChannelState)? value);
  set onMessage(void Function(RTCDataChannelMessage)? value);
  Future<int> getBufferedAmount();
  Future<void> send(RTCDataChannelMessage message);
  Future<void> close();
}

typedef RtcConnectionFactory = Future<RtcDataConnection> Function({
  required String scope,
  required bool allowCellular,
  required List<Map<String, dynamic>> iceServers,
});

bool rtcCellularPolicy({
  required bool android,
  required String scope,
  required bool permission,
}) => android && scope == 'public' && permission;

Future<RtcDataConnection> createRtcDataConnection({
  required String scope,
  required bool allowCellular,
  required List<Map<String, dynamic>> iceServers,
}) async {
  if (Platform.isAndroid) {
    return AndroidRtcConnection.create(
      scope: scope,
      allowCellular: allowCellular,
      iceServers: iceServers,
    );
  }
  return _PluginConnection(
    await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    }),
  );
}

/// A probe can observe a working connection, never activate cellular itself.
Future<RtcDataConnection> createRtcProbeConnection({
  required String scope,
  required bool allowCellular,
  required List<Map<String, dynamic>> iceServers,
}) async {
  if (Platform.isAndroid) {
    return AndroidRtcConnection.create(
      scope: scope,
      allowCellular: false,
      iceServers: const [],
      probe: true,
    );
  }
  return createRtcDataConnection(
    scope: scope,
    allowCellular: false,
    iceServers: const [],
  );
}

class _PluginConnection implements RtcDataConnection {
  _PluginConnection(this.peer);
  final RTCPeerConnection peer;
  Future<void>? _closing;
  @override
  set onIceCandidate(void Function(RTCIceCandidate)? value) =>
      peer.onIceCandidate = value;
  @override
  set onConnectionState(void Function(RTCPeerConnectionState)? value) =>
      peer.onConnectionState = value;
  @override
  set onDataChannel(void Function(RtcDataChannel)? value) =>
      peer.onDataChannel = value == null
      ? null
      : (channel) => value(_PluginChannel(channel));
  @override
  set onNetwork(void Function(String, String)? value) {}
  @override
  Future<RTCSessionDescription> createOffer(Map<String, dynamic> constraints) =>
      peer.createOffer(constraints);
  @override
  Future<RTCSessionDescription> createAnswer(
    Map<String, dynamic> constraints,
  ) => peer.createAnswer(constraints);
  @override
  Future<void> setLocalDescription(RTCSessionDescription value) =>
      peer.setLocalDescription(value);
  @override
  Future<void> setRemoteDescription(RTCSessionDescription value) =>
      peer.setRemoteDescription(value);
  @override
  Future<void> addCandidate(RTCIceCandidate value) => peer.addCandidate(value);
  @override
  Future<RtcDataChannel> createDataChannel(String label) async =>
      _PluginChannel(
        await peer.createDataChannel(
          label,
          RTCDataChannelInit()..ordered = true,
        ),
      );
  @override
  Future<void> authorizeData() async {}
  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    // Windows Dispose detaches the observer/event subscription; Close then
    // removes the remaining native peer entry. Both run exactly once.
    try {
      await peer.dispose();
    } finally {
      await peer.close();
    }
  }
}

class _PluginChannel implements RtcDataChannel {
  _PluginChannel(this.channel);
  final RTCDataChannel channel;
  Future<void>? _closing;
  @override
  String? get label => channel.label;
  @override
  RTCDataChannelState? get state => channel.state;
  @override
  set onDataChannelState(void Function(RTCDataChannelState)? value) =>
      channel.onDataChannelState = value;
  @override
  set onMessage(void Function(RTCDataChannelMessage)? value) =>
      channel.onMessage = value;
  @override
  Future<int> getBufferedAmount() => channel.getBufferedAmount();
  @override
  Future<void> send(RTCDataChannelMessage value) => channel.send(value);
  @override
  Future<void> close() => _closing ??= channel.close();
}

/// Project-owned Android data-channel bridge. One native owner per attempt;
/// cellular authorization is immutable for that owner's entire lifetime.
class AndroidRtcConnection implements RtcDataConnection {
  AndroidRtcConnection._(this.sessionId);
  static const channel = MethodChannel('dev.globalsend/rtc');
  static int _sequence = 0;
  static final Map<String, AndroidRtcConnection> _connections = {};
  final String sessionId;
  bool _closed = false;
  _AndroidChannel? _dataChannel;
  final List<Map<String, dynamic>> _earlyEvents = [];
  void Function(RTCIceCandidate)? _candidate;
  void Function(RTCPeerConnectionState)? _state;
  void Function(RtcDataChannel)? _channel;
  void Function(String, String)? _network;
  Future<void>? _closing;

  static Future<void> prepare() async {
    _installEvents();
    await channel.invokeMethod<void>('prepare');
  }

  static void _installEvents() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        final value = Map<String, dynamic>.from(call.arguments);
        _connections[value['sessionId']]?._event(value);
      }
    });
  }

  static Future<AndroidRtcConnection> create({
    required String scope,
    required bool allowCellular,
    required List<Map<String, dynamic>> iceServers,
    bool probe = false,
  }) async {
    _installEvents();
    final value = AndroidRtcConnection._('rtc-${++_sequence}');
    _connections[value.sessionId] = value;
    try {
      await value._call('create', {
        'scope': scope,
        'allowCellular': !probe && scope == 'public' && allowCellular,
        'iceServers': probe ? const [] : iceServers,
        'probe': probe,
      });
      return value;
    } catch (_) {
      await value.close();
      rethrow;
    }
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic> value = const {}]) =>
      channel.invokeMethod<T>(method, {'sessionId': sessionId, ...value});

  @override
  set onIceCandidate(void Function(RTCIceCandidate)? value) {
    _candidate = value;
    _flush();
  }

  @override
  set onConnectionState(void Function(RTCPeerConnectionState)? value) {
    _state = value;
    _flush();
  }

  @override
  set onDataChannel(void Function(RtcDataChannel)? value) {
    _channel = value;
    _flush();
  }

  @override
  set onNetwork(void Function(String, String)? value) {
    _network = value;
    _flush();
  }

  void _flush() {
    final values = [..._earlyEvents];
    _earlyEvents.clear();
    for (final value in values) {
      _event(value);
    }
  }

  void _event(Map<String, dynamic> event) {
    if (_closed) return;
    switch (event['type']) {
      case 'candidate':
        if (_candidate == null) {
          _earlyEvents.add(event);
          return;
        }
        final value = event['candidate'] as Map;
        _candidate!(
          RTCIceCandidate(
            value['candidate'],
            value['sdpMid'],
            value['sdpMLineIndex'],
          ),
        );
      case 'connection':
        if (_state == null) {
          _earlyEvents.add(event);
          return;
        }
        final state = switch (event['state']) {
          'connected' => RTCPeerConnectionState.RTCPeerConnectionStateConnected,
          'connecting' =>
            RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
          'disconnected' =>
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
          'closed' => RTCPeerConnectionState.RTCPeerConnectionStateClosed,
          'failed' => RTCPeerConnectionState.RTCPeerConnectionStateFailed,
          _ => RTCPeerConnectionState.RTCPeerConnectionStateNew,
        };
        _state!(state);
      case 'network':
        if (_network == null) {
          _earlyEvents.add(event);
          return;
        }
        _network!(event['network'], event['family']);
      case 'channel':
        final isRemote = event['remote'] == true;
        if (isRemote && _channel == null) {
          _earlyEvents.add(event);
          return;
        }
        final data = _dataChannel ??= _AndroidChannel(this, event['label']);
        if (isRemote && !data._announced) {
          data._announced = true;
          _channel!(data);
        }
        data._update(event['state']);
      case 'message':
        final data = _dataChannel;
        if (data == null || data._message == null) {
          _earlyEvents.add(event);
          return;
        }
        final message = event['binary'] == true
            ? RTCDataChannelMessage.fromBinary(event['data'])
            : RTCDataChannelMessage(event['data']);
        data._message!(message);
    }
  }

  @override
  Future<RTCSessionDescription> createOffer(Map<String, dynamic> constraints) =>
      _description('offer');
  @override
  Future<RTCSessionDescription> createAnswer(
    Map<String, dynamic> constraints,
  ) => _description('answer');
  Future<RTCSessionDescription> _description(String type) async {
    final result = await _call<Map>('description', {'type': type});
    return RTCSessionDescription(result!['sdp'], result['type']);
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription value) =>
      _call('localDescription', value.toMap());
  @override
  Future<void> setRemoteDescription(RTCSessionDescription value) =>
      _call('remoteDescription', value.toMap());
  @override
  Future<void> addCandidate(RTCIceCandidate value) =>
      _call('candidate', value.toMap());
  @override
  Future<RtcDataChannel> createDataChannel(String label) async {
    final data = _dataChannel ??= _AndroidChannel(this, label);
    final state = await _call<String>('createChannel', {'label': label});
    data._update(state!);
    return data;
  }

  @override
  Future<void> authorizeData() => _call('authorize');
  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _connections.remove(sessionId);
    _earlyEvents.clear();
    await _call('close');
  }
}

class _AndroidChannel implements RtcDataChannel {
  _AndroidChannel(this.owner, this.label);
  final AndroidRtcConnection owner;
  @override
  final String label;
  @override
  RTCDataChannelState state = RTCDataChannelState.RTCDataChannelConnecting;
  bool _announced = false;
  void Function(RTCDataChannelState)? _state;
  void Function(RTCDataChannelMessage)? _message;
  @override
  set onDataChannelState(void Function(RTCDataChannelState)? value) =>
      _state = value;
  @override
  set onMessage(void Function(RTCDataChannelMessage)? value) {
    _message = value;
    owner._flush();
  }

  void _update(String value) {
    state = switch (value) {
      'open' => RTCDataChannelState.RTCDataChannelOpen,
      'closing' => RTCDataChannelState.RTCDataChannelClosing,
      'closed' => RTCDataChannelState.RTCDataChannelClosed,
      _ => RTCDataChannelState.RTCDataChannelConnecting,
    };
    _state?.call(state);
  }

  @override
  Future<int> getBufferedAmount() async =>
      (await owner._call<num>('bufferedAmount'))!.toInt();
  @override
  Future<void> send(RTCDataChannelMessage message) => owner._call('send', {
    'binary': message.isBinary,
    'data': message.isBinary ? message.binary : message.text,
  });
  @override
  Future<void> close() => owner._call('closeChannel');
}
