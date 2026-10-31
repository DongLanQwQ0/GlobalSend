import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class ClipboardSuggestionBridge {
  static MethodChannel get channel => MethodChannel(
    Platform.isAndroid
        ? 'dev.globalsend/dock'
        : Platform.isIOS
        ? 'dev.globalsend/share'
        : 'dev.globalsend/system',
  );
  static Future<Map<String, dynamic>> read() async {
    if (!Platform.isAndroid && !Platform.isIOS && !Platform.isWindows)
      return {};
    return Map<String, dynamic>.from(
      await channel.invokeMapMethod(
            'clipboardSuggestion',
            const <String, dynamic>{},
          ) ??
          {},
    );
  }

  static Future<void> dismiss(String revision) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('dismissClipboardSuggestion', {
        'revision': revision,
      });
    }
  }
}

class ClipboardSuggestion {
  const ClipboardSuggestion(this.revision, this.kind, {this.suggestedAt = 0});
  final String revision, kind;
  final int suggestedAt;
  String get label => switch (kind) {
    'image' => '图片',
    'files' => '文件',
    'url' => '链接',
    _ => '文本',
  };
}

/// Observes format/revision metadata only. Reading content remains a tap action.
class ClipboardSuggestions extends ChangeNotifier {
  ClipboardSuggestions({
    this.read = ClipboardSuggestionBridge.read,
    this.acknowledge = ClipboardSuggestionBridge.dismiss,
  });
  final Future<Map<String, dynamic>> Function() read;
  final Future<void> Function(String revision) acknowledge;
  ClipboardSuggestion? item;
  String? _handledRevision;
  Timer? _timer;
  bool _busy = false, _disposed = false;

  void setVisible(bool visible) {
    if (_disposed || visible == (_timer != null)) return;
    _timer?.cancel();
    _timer = null;
    if (visible) {
      unawaited(refresh());
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => refresh());
    }
  }

  Future<void> refresh() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final status = await read();
      if (_disposed || status['available'] != true) return;
      final revision = status['revision'] as String? ?? '';
      final kind = status['kind'] as String? ?? 'empty';
      final next =
          revision.isEmpty || kind == 'empty' || _handledRevision == revision
          ? null
          : ClipboardSuggestion(
              revision,
              kind,
              suggestedAt: status['suggestedAt'] as int? ?? 0,
            );
      if (item?.revision != next?.revision || item?.kind != next?.kind) {
        item = next;
        notifyListeners();
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> dismiss() async {
    final current = item;
    if (current == null) return;
    await dismissRevision(current.revision);
  }

  Future<void> dismissRevision(String revision) async {
    _handledRevision = revision;
    if (item?.revision == revision) {
      item = null;
      notifyListeners();
    }
    await acknowledge(revision);
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
