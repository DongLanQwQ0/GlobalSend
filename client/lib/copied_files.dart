import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';

class CopiedFilesClient {
  CopiedFilesClient({
    required this.newId,
    required this.sendFiles,
    required this.changed,
  });
  final String Function() newId;
  final Future<void> Function(String target, List<String> paths) sendFiles;
  final void Function() changed;
  bool enabled = false;
  List<String> targets = [];
  bool get sourceReady => enabled && targets.isNotEmpty;
  List<Map<String, dynamic>> offers = [];
  String error = '', sourceError = '';
  final Map<String, Map<String, dynamic>> pulls = {};
  final Set<String> _dismissed = {};
  final Map<String, String> _sources = {};
  final Map<String, Future<void>> _serving = {};
  final Map<String, Map<String, dynamic>> _outcomes = {};
  Map<String, dynamic>? _local;
  File? _settings;
  CenterApi? _api;
  String _token = '', _self = '';
  int _session = 0, _copy = 0;
  Future<void>? _refresh;
  Future<void> _writes = Future.value();
  bool _refreshAgain = false;
  bool get connected => _api != null;

  List<Map<String, String>> get references => [
    for (final offer in offers)
      for (final value in offer['items'] as List)
        if (!_dismissed.contains(
          'copied:${offer['sourceDeviceId']}:${offer['offerId']}:${value['id']}',
        ))
          {
            'id':
                'copied:${offer['sourceDeviceId']}:${offer['offerId']}:${value['id']}',
            'sourceDeviceId': offer['sourceDeviceId'] as String,
            'sourceName': offer['sourceName'] as String,
            'offerId': offer['offerId'] as String,
            'itemId': value['id'] as String,
            'name': value['name'] as String,
            'kind': value['kind'] as String,
            'state':
                pulls.values
                        .where(
                          (pull) =>
                              pull['offerId'] == offer['offerId'] &&
                              (pull['itemIds'] as List? ?? []).contains(
                                value['id'],
                              ),
                        )
                        .lastOrNull?['state']
                    as String? ??
                '',
          },
  ];
  void dismiss(String referenceId) {
    _dismissed.add(referenceId);
    changed();
  }

  Future<void> load(File file) async {
    _settings = file;
    if (!await file.exists()) return;
    final settings = jsonDecode(await file.readAsString()) as Map;
    enabled = settings['enabled'] == true;
    targets = (settings['targets'] as List? ?? [])
        .cast<String>()
        .toSet()
        .toList();
  }

  Future<void> configure(bool value, Iterable<String> destinationIds) async {
    final selected = destinationIds.toSet().toList();
    if (value && selected.contains(_self)) {
      throw const FormatException('请先指定其他目标设备');
    }
    enabled = value;
    targets = selected;
    ++_copy;
    _sources.clear();
    _outcomes.clear();
    _local = null;
    final file = _settings;
    if (file != null) {
      await file.writeAsString(
        jsonEncode({'enabled': enabled, 'targets': targets}),
        flush: true,
      );
    }
    final api = _api;
    if (api != null) await _write(api, _session, _copy, 'DELETE');
    changed();
  }

  Future<void> connect(
    CenterApi api, {
    required String self,
    required bool supported,
  }) async {
    final session = ++_session;
    _api = supported ? api : null;
    _token = api.token;
    _self = self;
    offers = [];
    pulls.clear();
    _dismissed.clear();
    if (!supported) {
      changed();
      return;
    }
    if (sourceReady && _local != null) {
      try {
        await _write(api, session, _copy, 'PUT', _local);
        sourceError = '';
      } catch (failure) {
        sourceError = '$failure';
      }
    }
    if (!_current(session, api)) return;
    await refresh();
    final pending = await api.call('GET', '/clipboard/files/pulls');
    if (!_current(session, api)) return;
    for (final request in pending['pulls'] as List? ?? []) {
      unawaited(serve(Map<String, dynamic>.from(request as Map)));
    }
  }

  bool _current(int session, CenterApi api) =>
      session == _session && identical(api, _api) && api.token == _token;

  Future<void> _write(
    CenterApi api,
    int session,
    int copy,
    String method, [
    Object? body,
  ]) {
    // A slow old DELETE must finish before a newer clipboard is published.
    // Superseded queued work is unnecessary; an in-flight request is awaited.
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      if (_current(session, api) && copy == _copy)
        await api.call(method, '/clipboard/files', body);
    });
  }

  void disconnect() {
    ++_session;
    _api = null;
    offers = [];
    pulls.clear();
    _refresh = null;
    _refreshAgain = false;
  }

  Future<void> refresh() {
    if (_refresh != null) {
      _refreshAgain = true;
      return _refresh!;
    }
    final api = _api, session = _session;
    if (api == null) return Future.value();
    return _refresh = () async {
      try {
        do {
          _refreshAgain = false;
          final response = await api.call('GET', '/clipboard/files');
          if (!_current(session, api)) return;
          offers = [
            for (final item in response['offers'] as List? ?? [])
              Map<String, dynamic>.from(item as Map),
          ];
          error = '';
          changed();
        } while (_refreshAgain && _current(session, api));
      } catch (failure) {
        if (_current(session, api)) {
          error = '$failure';
          changed();
        }
      } finally {
        if (_current(session, api)) _refresh = null;
      }
    }();
  }

  /// Inspect just the copied roots. Do not enumerate folders, read file bytes,
  /// hash files or put source files into the user's outgoing draft queue.
  Future<void> copiedPaths(Iterable<String> paths) async {
    if (!sourceReady) return;
    final copy = ++_copy;
    _sources.clear();
    _outcomes.clear();
    _local = null;
    final api = _api, session = _session;
    if (api != null) await _write(api, session, copy, 'DELETE');
    final sources = <String, String>{};
    final items = <Map<String, dynamic>>[];
    for (final path in paths.toSet()) {
      final type = await FileSystemEntity.type(path);
      if (copy != _copy) return;
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory)
        continue;
      final itemId = newId();
      final name = File(path).uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      items.add({
        'id': itemId,
        'name': name,
        'kind': type == FileSystemEntityType.directory ? 'directory' : 'file',
        if (type == FileSystemEntityType.file)
          'size': await File(path).length(),
      });
      sources[itemId] = path;
    }
    if (copy != _copy || !enabled) return;
    _sources.addAll(sources);
    if (items.isEmpty) {
      sourceError = '';
      changed();
      return;
    }
    _local = {
      'offerId': newId(),
      'targetDeviceIds': targets.toList(),
      'items': items,
    };
    if (api != null && _current(session, api))
      await _write(api, session, copy, 'PUT', _local);
    sourceError = '';
    changed();
  }

  Future<Map<String, dynamic>> pull(
    Map<String, dynamic> offer,
    List<String> itemIds,
  ) async {
    final api = _api;
    if (api == null) throw StateError('请先连接中心');
    final existing = pulls.values
        .where(
          (value) =>
              value['sourceDeviceId'] == offer['sourceDeviceId'] &&
              value['offerId'] == offer['offerId'] &&
              (value['state'] == 'pending' || value['state'] == 'sending') &&
              itemIds.every((id) => (value['itemIds'] as List).contains(id)),
        )
        .firstOrNull;
    if (existing != null) return existing;
    final session = _session, requestId = newId();
    final pending = <String, dynamic>{
      'requestId': requestId,
      'offerId': offer['offerId'],
      'sourceDeviceId': offer['sourceDeviceId'],
      'targetDeviceId': _self,
      'itemIds': itemIds.toList(),
      'state': 'pending',
    };
    pulls[requestId] = pending;
    changed();
    try {
      final response = await api.call(
        'POST',
        '/clipboard/files/${offer['sourceDeviceId']}/pull',
        {
          'offerId': offer['offerId'],
          'requestId': requestId,
          'itemIds': itemIds,
        },
      );
      if (_current(session, api)) {
        // A source's socket result can arrive before this HTTP response.
        if (identical(pulls[requestId], pending)) pulls[requestId] = response;
        changed();
      }
      return response;
    } catch (failure) {
      if (_current(session, api) && identical(pulls[requestId], pending)) {
        pulls[requestId] = {...pending, 'state': 'failed', 'error': '$failure'};
        changed();
      }
      rethrow;
    }
  }

  Future<void> handle(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'clipboard.files.changed':
        await refresh();
      case 'clipboard.files.pull':
        await serve(message);
      case 'clipboard.files.pull.updated':
        if (_api != null && message['targetDeviceId'] == _self) {
          pulls[message['requestId'] as String] = Map.of(message);
          changed();
        }
    }
  }

  Future<void> serve(Map<String, dynamic> request) {
    final key = '${request['targetDeviceId']}/${request['requestId']}';
    final active = _serving[key];
    if (active != null) return active;
    final future = _serve(request, key);
    _serving[key] = future;
    unawaited(future.whenComplete(() => _serving.remove(key)));
    return future;
  }

  Future<void> _serve(Map<String, dynamic> request, String key) async {
    final api = _api, session = _session;
    if (api == null || request['sourceDeviceId'] != _self) return;
    final route =
        '/clipboard/files/pulls/${request['targetDeviceId']}/${request['requestId']}';
    try {
      var outcome = _outcomes[key];
      if (outcome == null) {
        final paths = <String>[];
        try {
          if (!enabled ||
              request['offerId'] != _local?['offerId'] ||
              !targets.contains(request['targetDeviceId'])) {
            throw StateError('复制内容或目标设备已更换');
          }
          for (final id in request['itemIds'] as List) {
            final path = _sources[id];
            if (path == null ||
                await FileSystemEntity.type(path) ==
                    FileSystemEntityType.notFound) {
              throw const FileSystemException('来源文件已移除');
            }
            paths.add(path);
          }
          if (!_current(session, api)) return;
          await api.call('PUT', route, {'state': 'sending'});
          if (!_current(session, api)) return;
          if (!enabled ||
              request['offerId'] != _local?['offerId'] ||
              !targets.contains(request['targetDeviceId'])) {
            throw StateError('目标设备已取消文件复制推送');
          }
          await sendFiles(request['targetDeviceId'] as String, paths);
          // The existing file-transfer flow now owns progress and delivery.
          outcome = {'state': 'sent'};
        } catch (failure) {
          outcome = {'state': 'failed', 'error': '$failure'};
        }
        _outcomes[key] = outcome;
      }
      if (_current(session, api)) await api.call('PUT', route, outcome);
    } catch (failure) {
      if (_current(session, api) && request['offerId'] == _local?['offerId']) {
        error = '$failure';
        changed();
      }
    }
  }
}
