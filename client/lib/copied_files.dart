import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';
import 'received_file_access.dart';
import 'folder_transfer.dart';
import 'dock_platform.dart';

class CopiedFilesClient {
  CopiedFilesClient({
    required this.newId,
    required this.sendFiles,
    required this.changed,
    this.sendReference,
  });
  final String Function() newId;
  final Future<void> Function(String target, List<String> paths) sendFiles;
  final Future<void> Function(
    String target,
    String path,
    Map<String, dynamic> context,
  )?
  sendReference;
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
  final Map<String, Map<String, String>> _received = {};
  final Map<String, Completer<List<String>>> _waiting = {};
  static String referenceId(String source, String offer, String item) =>
      'copied:$source:$offer:$item';
  Map<String, String>? localReference(String id) => _received[id];

  final Map<String, List<Map<String, dynamic>>> _manifestCache = {};
  final Map<String, Future<List<Map<String, dynamic>>>> _manifestJobs = {};
  List<Map<String, dynamic>>? cachedManifest(String id) => _manifestCache[id];
  final Map<String, Completer<List<Map<String, dynamic>>>> _manifests = {};
  Future<List<Map<String, dynamic>>> manifest(Map<String, dynamic> reference) {
    final id = reference['id'] as String;
    if (_manifestCache[id] case final value?) return Future.value(value);
    return _manifestJobs[id] ??= _fetchManifest(reference)
        .then((value) {
          _manifestCache[id] = value;
          return value;
        })
        .whenComplete(() {
          _manifestJobs.remove(id);
        });
  }

  Future<List<Map<String, dynamic>>> _fetchManifest(
    Map<String, dynamic> reference,
  ) async {
    final api = _api;
    if (api == null) throw StateError('请连接来源中心');
    final requestId = newId();
    final result = Completer<List<Map<String, dynamic>>>();
    _manifests[requestId] = result;
    try {
      final response = await api.call(
        'POST',
        '/clipboard/files/${reference['sourceDeviceId']}/pull',
        {
          'requestId': requestId,
          'offerId': reference['offerId'],
          'itemIds': [reference['itemId']],
          'metadataOnly': true,
        },
      );
      _acceptManifest(response);
      return await result.future;
    } catch (_) {
      _manifests.remove(requestId);
      rethrow;
    }
  }

  void _acceptManifest(Map<String, dynamic> response) {
    if (response['metadataOnly'] != true) return;
    final waiter = _manifests[response['requestId']];
    if (waiter == null) return;
    if (response['state'] == 'failed') {
      _manifests.remove(response['requestId']);
      waiter.completeError(StateError(response['error'] ?? '目录元数据读取失败'));
    } else if (response['state'] == 'sent') {
      _manifests.remove(response['requestId']);
      waiter.complete(
        (response['entries'] as List)
            .map((value) => Map<String, dynamic>.from(value as Map))
            .toList(),
      );
    }
  }

  Future<void> _settingsWrites = Future.value();
  Future<void> _persist() {
    final file = _settings;
    if (file == null) return Future.value();
    final value = jsonEncode({
      'enabled': enabled,
      'targets': targets,
      'received': _received,
      'dismissed': _dismissed.toList(),
    });
    return _settingsWrites = _settingsWrites.catchError((Object _) {}).then((
      _,
    ) async {
      await file.writeAsString(value, flush: true);
    });
  }

  Future<void> rememberReceived(
    Map<String, dynamic> reference,
    String path, {
    required String transferId,
    required String fileId,
    int? completedAtMillis,
  }) async {
    final id = referenceId(
      reference['sourceDeviceId'],
      reference['offerId'],
      reference['itemId'],
    );
    if (_received[id]?['localPath'] == path &&
        _received[id]?['transferId'] == transferId &&
        _received[id]?['fileId'] == fileId &&
        _received[id]?['completedAtMillis'] != null) {
      _waiting.remove(id)?.complete([path]);
      return;
    }
    final previous = _received[id];
    final sameReceipt =
        previous?['transferId'] == transferId && previous?['fileId'] == fileId;
    if (!sameReceipt &&
        completedAtMillis != null &&
        completedAtMillis > 0 &&
        (int.tryParse(previous?['completedAtMillis'] ?? '') ?? 0) >
            completedAtMillis) {
      return;
    }
    _received[id] = {
      'localPath': path,
      'transferId': transferId,
      'fileId': fileId,
      'completedAtMillis': sameReceipt && previous?['completedAtMillis'] != null
          ? previous!['completedAtMillis']!
          : '${completedAtMillis != null && completedAtMillis > 0 ? completedAtMillis : DateTime.now().millisecondsSinceEpoch}',
    };
    await _persist();
    _waiting.remove(id)?.complete([path]);
    changed();
  }

  void receiveFailed(Map<String, dynamic> reference, String problem) {
    final id = referenceId(
      reference['sourceDeviceId'],
      reference['offerId'],
      reference['itemId'],
    );
    _waiting.remove(id)?.completeError(StateError(problem));
    for (final request in pulls.values) {
      if (request['offerId'] == reference['offerId'] &&
          (request['itemIds'] as List).contains(reference['itemId'])) {
        request['state'] = 'failed';
        request['error'] = problem;
      }
    }
    changed();
  }

  Future<void> reconcileReceived() async {
    var removed = false;
    for (final entry in _received.entries.toList()) {
      if (!await ReceivedFileAccess.exists(entry.value['localPath']!)) {
        _received.remove(entry.key);
        pulls.removeWhere(
          (_, pull) => (pull['itemIds'] as List).any(
            (item) =>
                referenceId(pull['sourceDeviceId'], pull['offerId'], item) ==
                entry.key,
          ),
        );
        removed = true;
      }
    }
    if (removed) {
      await _persist();
      changed();
    }
  }

  Future<List<String>> resolve(Map<String, dynamic> reference) async {
    final id = reference['id'] as String;
    await reconcileReceived();
    final local = _received[id];
    if (local != null) return [local['localPath']!];
    final pending = _waiting[id];
    if (pending != null) return pending.future;
    final completion = Completer<List<String>>();
    _waiting[id] = completion;
    // Install the waiter before publishing: fast direct reuse may finish first.
    unawaited(
      pull(reference, [reference['itemId'] as String]).catchError((
        Object failure,
      ) {
        _waiting.remove(id)?.completeError(failure);
        return <String, dynamic>{};
      }),
    );
    return completion.future;
  }

  Map<String, dynamic>? _local;
  File? _settings;
  CenterApi? _api;
  String _token = '', _self = '';
  int _session = 0, _copy = 0;
  Future<void>? _refresh;
  Future<void> _writes = Future.value();
  bool _refreshAgain = false;
  bool get connected => _api != null;

  List<Map<String, String>> get references {
    final values = <Map<String, String>>[
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
              'size': '${value['size'] ?? 0}',
              ...?_received[referenceId(
                offer['sourceDeviceId'],
                offer['offerId'],
                value['id'],
              )],
              'state': _referenceState(
                offer['sourceDeviceId'],
                offer['offerId'],
                value['id'],
              ),
            },
    ];
    // Arrival order remains stable until bytes are really available. Progress,
    // polling and reuse of an already completed receipt cannot promote a card.
    final positions = {
      for (var i = 0; i < values.length; i++) values[i]['id']: i,
    };
    values.sort((a, b) {
      final completed = (int.tryParse(b['completedAtMillis'] ?? '') ?? 0)
          .compareTo(int.tryParse(a['completedAtMillis'] ?? '') ?? 0);
      return completed != 0
          ? completed
          : positions[a['id']]!.compareTo(positions[b['id']]!);
    });
    return values;
  }

  String _referenceState(String source, String offer, String item) {
    if (_received.containsKey(referenceId(source, offer, item)))
      return 'received';
    final request = pulls.values
        .where(
          (pull) =>
              pull['sourceDeviceId'] == source &&
              pull['offerId'] == offer &&
              (pull['itemIds'] as List).contains(item),
        )
        .lastOrNull;
    final state = request?['state'] as String? ?? '';
    return state == 'sent' ? 'sending' : state;
  }

  void dismiss(String referenceId) {
    _dismissed.add(referenceId);
    unawaited(_persist());
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
    for (final entry in (settings['received'] as Map? ?? {}).entries) {
      _received[entry.key as String] = Map<String, String>.from(
        entry.value as Map,
      );
    }
    _dismissed.addAll((settings['dismissed'] as List? ?? []).cast<String>());
    await reconcileReceived();
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
    await _persist();
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
    for (final waiter in _waiting.values) {
      waiter.completeError(StateError('连接已断开，拉取已停止'));
    }
    _waiting.clear();
    for (final waiter in _manifests.values) {
      waiter.completeError(StateError('连接已断开'));
    }
    _manifests.clear();
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
        await reconcileReceived();
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
    await reconcileReceived();
    final local = itemIds
        .map(
          (item) =>
              _received[referenceId(
                offer['sourceDeviceId'],
                offer['offerId'],
                item,
              )],
        )
        .toList();
    if (local.every((entry) => entry != null))
      return {
        'state': 'received',
        'localPaths': local.map((entry) => entry!['localPath']).toList(),
      };
    final api = _api;
    if (api == null) throw StateError('请先连接中心');
    final existing = pulls.values
        .where(
          (value) =>
              value['sourceDeviceId'] == offer['sourceDeviceId'] &&
              value['offerId'] == offer['offerId'] &&
              (value['state'] == 'pending' ||
                  value['state'] == 'sending' ||
                  value['state'] == 'sent') &&
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
        if (message['metadataOnly'] == true) {
          _acceptManifest(message);
          return;
        }
        if (_api != null && message['targetDeviceId'] == _self) {
          pulls[message['requestId'] as String] = Map.of(message);
          if (message['state'] == 'failed') {
            for (final item in message['itemIds'] as List) {
              receiveFailed({
                ...message,
                'itemId': item,
              }, message['error'] as String? ?? '来源未能提供文件');
            }
          }
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
          if (request['metadataOnly'] == true) {
            final entries = <Map<String, dynamic>>[];
            for (final path in paths) {
              final folder = ReceivedFileAccess.isContentUri(path)
                  ? (await DockPlatform.directoryEntries(path))
                        .map(FolderEntry.fromMap)
                        .toList()
                  : await readFolderEntries(path);
              for (final item in folder) {
                var size = 0;
                if (!item.directory) {
                  final source = await ReceivedFileAccess.open(item.location);
                  try {
                    size = await source.file.length();
                  } finally {
                    await source.close();
                  }
                }
                entries.add({
                  'relativePath': item.relativePath,
                  'kind': item.directory ? 'directory' : 'file',
                  'size': size,
                });
              }
            }
            outcome = {'state': 'sent', 'entries': entries};
          } else if (sendReference == null) {
            await sendFiles(request['targetDeviceId'] as String, paths);
          } else {
            final ids = (request['itemIds'] as List).cast<String>();
            for (var index = 0; index < paths.length; index++) {
              await sendReference!(
                request['targetDeviceId'] as String,
                paths[index],
                {
                  'requestId': request['requestId'],
                  'offerId': request['offerId'],
                  'itemId': ids[index],
                },
              );
            }
          }
          // The existing file-transfer flow now owns progress and delivery.
          outcome ??= {'state': 'sent'};
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
