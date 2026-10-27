import 'dart:async';
import 'dart:math';

import 'api.dart';

/// One revisioned document per center group. Local typing is never replaced by
/// a concurrent remote edit; the two explicit conflict actions resolve it.
class GroupSharedText {
  GroupSharedText({required this.onChanged, this.onRemoteApplied});
  final void Function() onChanged;
  final void Function(Map<String, dynamic>)? onRemoteApplied;
  CenterApi? _api;
  bool supported = false, online = false;
  String text = '', remoteText = '', status = '';
  int revision = 0;
  bool dirty = false, conflict = false, _saving = false;
  String _ownMutation = '';
  Timer? _debounce;
  int _epoch = 0;

  void connect(CenterApi api, {required bool enabled}) {
    if (!identical(_api, api)) {
      reset();
      _api = api;
    }
    supported = enabled;
    online = true;
  }

  void disconnected() {
    online = false;
    _debounce?.cancel();
    if (dirty) status = '离线待同步';
  }

  void reset() {
    _epoch++;
    _debounce?.cancel();
    _api = null;
    supported = online = dirty = conflict = _saving = false;
    text = remoteText = status = _ownMutation = '';
    revision = 0;
  }

  Future<void> refresh() async {
    final api = _api, epoch = _epoch;
    if (!supported || !online || api == null) return;
    try {
      final document = await api.call('GET', '/group/shared-text');
      if (epoch != _epoch) return;
      applyRemote(document);
      if (dirty && !conflict && !_saving) _schedule();
    } catch (_) {
      if (epoch != _epoch) return;
      status = dirty ? '同步失败，稍后重试' : '暂未连接';
      onChanged();
    }
  }

  void setDraft(String value) {
    if (value == text) return;
    text = value;
    dirty = value != remoteText;
    if (!dirty) conflict = false;
    status = !dirty
        ? '已同步'
        : conflict
        ? '其他设备已更新'
        : online
        ? '编辑中'
        : '离线待同步';
    _schedule();
    onChanged();
  }

  void _schedule() {
    _debounce?.cancel();
    if (!supported || !online || !dirty || conflict) return;
    _debounce = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(save()),
    );
  }

  void applyRemote(Map<String, dynamic> document) {
    final nextRevision = document['revision'] as int;
    if (nextRevision < revision) return;
    final nextText = document['text'] as String;
    final changedRemote = nextRevision > revision;
    final own =
        _ownMutation.isNotEmpty && document['mutationId'] == _ownMutation;
    revision = nextRevision;
    remoteText = nextText;
    if (!dirty || text == nextText) {
      text = nextText;
      dirty = conflict = false;
      status = '已同步';
    } else if (changedRemote && !own) {
      conflict = true;
      status = '其他设备已更新';
      _debounce?.cancel();
    }
    if (changedRemote && !own) onRemoteApplied?.call(document);
    onChanged();
  }

  Future<void> save() async {
    final api = _api, epoch = _epoch;
    if (_saving || !supported || !online || !dirty || conflict || api == null) {
      return;
    }
    if (text.length > 100000) {
      status = '文本最多 100000 字符';
      onChanged();
      return;
    }
    final snapshot = text;
    _saving = true;
    status = '同步中';
    final mutation =
        '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
    _ownMutation = mutation;
    onChanged();
    try {
      final document = await api.call('PUT', '/group/shared-text', {
        'text': snapshot,
        'baseRevision': revision,
        'mutationId': mutation,
      });
      if (epoch != _epoch) return;
      applyRemote(document);
    } on ApiException catch (error) {
      if (epoch != _epoch) return;
      final current = error.response?['current'];
      if (error.status == 409 && current is Map) {
        applyRemote(Map<String, dynamic>.from(current));
        conflict = dirty;
        status = conflict ? '其他设备已更新' : '已同步';
      } else {
        status = '同步失败，点击重试';
      }
    } catch (_) {
      if (epoch != _epoch) return;
      status = '同步失败，点击重试';
    } finally {
      if (epoch == _epoch) {
        _saving = false;
        _ownMutation = '';
        if (dirty && !conflict && text != snapshot) _schedule();
        onChanged();
      }
    }
  }

  Future<void> keepMine() async {
    conflict = false;
    dirty = text != remoteText;
    await save();
  }

  void useRemote() {
    _debounce?.cancel();
    text = remoteText;
    dirty = conflict = false;
    status = '已同步';
    onChanged();
  }
}
