import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'models.dart';

/// One installation-wide current value, deliberately outside receipt/history.
class ClipboardSlot {
  ClipboardSlot({required this.changed});
  final void Function() changed;
  bool enabled = true;
  DockEntry? _value;
  File? _record;
  Future<void> _writes = Future.value();
  Directory? _cache;
  final Map<String, int> _leases = {};
  final Map<String, String> _retired = {};
  DockEntry? get value => enabled ? _value : null;

  String _key(String path) {
    final value = File(path).absolute.uri
        .normalizePath()
        .toFilePath()
        .replaceAll('\\', '/');
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  void retain(String path) {
    if (path.isNotEmpty) {
      final key = _key(path);
      _leases[key] = (_leases[key] ?? 0) + 1;
    }
  }

  Future<void> release(String path) async {
    if (path.isEmpty) return;
    final key = _key(path), count = _leases[key] ?? 0;
    if (count > 1) {
      _leases[key] = count - 1;
    } else {
      _leases.remove(key);
    }
    await _collect(key);
  }

  Future<void> _retire(String path) async {
    final cache = _cache;
    if (path.isEmpty ||
        cache == null ||
        !_key(path).startsWith('${_key(cache.path)}/'))
      return;
    final key = _key(path);
    _retired[key] = path;
    await _collect(key);
  }

  Future<void> _collect(String key) async {
    final path = _retired[key];
    if (path == null ||
        (_leases[key] ?? 0) > 0 ||
        _value?.kind == 'file' && _key(_value!.localPath) == key)
      return;
    _retired.remove(key);
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<void> load(Directory state) async {
    _record = File('${state.path}/clipboard-slot.json');
    if (await _record!.exists()) {
      final record = jsonDecode(await _record!.readAsString()) as Map;
      enabled = record['enabled'] != false;
      if (record['value'] is Map) {
        final value = DockEntry.fromJson(
          Map<String, dynamic>.from(record['value']),
        );
        if (value.kind == 'text' || await File(value.localPath).exists())
          _value = value;
      }
    }
    // A process restart ends the old native drag leases. Only this private
    // directory is scavenged; received files and user originals are untouched.
    final cache = _cache = Directory('${state.path}/clipboard-slot-cache');
    if (await cache.exists()) {
      await for (final entry in cache.list()) {
        if (entry is File &&
            _key(entry.path) != (_value == null ? '' : _key(_value!.localPath)))
          await _retire(entry.path);
      }
    }
  }

  Future<void> _save() {
    final record = _record;
    if (record == null) return Future.value();
    final content = jsonEncode({'enabled': enabled, 'value': _value?.toJson()});
    return _writes = _writes.catchError((Object _) {}).then((_) async {
      await record.parent.create(recursive: true);
      final temporary = File('${record.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      await temporary.rename(record.path);
    });
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    await _save();
    changed();
  }

  Future<void> clear() async {
    final previous = _value;
    _value = null;
    await _save();
    changed();
    if (previous?.kind == 'file') await _retire(previous!.localPath);
  }

  Future<bool> receive(DockEntry entry) async {
    if (!enabled ||
        entry.outgoing ||
        !entry.autoClipboard ||
        entry.kind == 'file' && entry.status != 'received' ||
        entry.createdAtMillis < (_value?.createdAtMillis ?? -1))
      return false;
    if (_value?.sourceEventId == entry.sourceEventId &&
        _value?.originDeviceId == entry.originDeviceId &&
        entry.sourceEventId.isNotEmpty)
      return false;
    final previous = _value;
    _value = DockEntry.fromJson({
      ...entry.toJson(),
      'id': 'clipboard-slot',
      'autoClipboard': true,
    });
    await _save();
    changed();
    if (previous?.kind == 'file') await _retire(previous!.localPath);
    return true;
  }
}

/// A painted slot is a real file consumer until the framework replaces it.
class ClipboardSlotLease extends StatefulWidget {
  const ClipboardSlotLease({
    super.key,
    required this.slot,
    required this.entry,
    required this.child,
  });
  final ClipboardSlot slot;
  final DockEntry entry;
  final Widget child;
  @override
  State<ClipboardSlotLease> createState() => _ClipboardSlotLeaseState();
}

class _ClipboardSlotLeaseState extends State<ClipboardSlotLease> {
  String get path => widget.entry.kind == 'file' ? widget.entry.localPath : '';
  @override
  void initState() {
    super.initState();
    widget.slot.retain(path);
  }

  @override
  void didUpdateWidget(ClipboardSlotLease old) {
    super.didUpdateWidget(old);
    final previous = old.entry.kind == 'file' ? old.entry.localPath : '';
    if (old.slot != widget.slot || previous != path) {
      widget.slot.retain(path);
      unawaited(old.slot.release(previous));
    }
  }

  @override
  void dispose() {
    unawaited(widget.slot.release(path));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
