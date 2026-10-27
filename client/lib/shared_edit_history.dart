import 'package:flutter/services.dart';

/// Committed local and synchronized edits share one undo timeline per document.
class SharedEditHistory {
  TextEditingValue value = TextEditingValue.empty;
  String scope = '';
  final _undo = <TextEditingValue>[];
  final _redo = <TextEditingValue>[];
  DateTime? _lastEdit;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void reset(TextEditingValue next, String nextScope) {
    value = next;
    scope = nextScope;
    _undo.clear();
    _redo.clear();
    _lastEdit = null;
  }

  void synchronize(TextEditingValue next, String nextScope) {
    if (scope != nextScope) {
      reset(next, nextScope);
      return;
    }
    if (next.text != value.text) {
      _undo.add(value);
      _redo.clear();
      _lastEdit = null;
    }
    value = next.copyWith(composing: TextRange.empty);
  }

  void record(TextEditingValue next, {DateTime? now}) {
    if (next.composing.isValid && !next.composing.isCollapsed) return;
    if (next.text == value.text) {
      if (next.selection != value.selection) _lastEdit = null;
      value = next;
      return;
    }
    final time = now ?? DateTime.now();
    final typing =
        (next.text.length - value.text.length).abs() == 1 &&
        next.selection.isCollapsed &&
        value.selection.isCollapsed &&
        (next.selection.extentOffset - value.selection.extentOffset).abs() <= 1;
    if (!typing ||
        _lastEdit == null ||
        time.difference(_lastEdit!) > const Duration(milliseconds: 500)) {
      _undo.add(value);
    }
    value = next.copyWith(composing: TextRange.empty);
    _redo.clear();
    _lastEdit = typing ? time : null;
  }

  TextEditingValue? undo() {
    if (!canUndo) return null;
    _redo.add(value);
    value = _undo.removeLast();
    _lastEdit = null;
    return value;
  }

  TextEditingValue? redo() {
    if (!canRedo) return null;
    _undo.add(value);
    value = _redo.removeLast();
    _lastEdit = null;
    return value;
  }
}
