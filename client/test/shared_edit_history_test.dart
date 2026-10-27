import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/shared_edit_history.dart';

TextEditingValue edit(String text, {TextRange composing = TextRange.empty}) =>
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing,
    );

void main() {
  test('typing coalesces, selection restores, redo branches and synchronization stays undoable', () {
    final h = SharedEditHistory()..reset(edit(''), 'group');
    final now = DateTime(2026);
    h.record(edit('a'), now: now);
    h.record(edit('ab'), now: now.add(const Duration(milliseconds: 100)));
    expect(h.undo()!.text, '');
    expect(h.redo()!.selection.extentOffset, 2);
    h.undo();
    h.record(edit('new'));
    expect(h.canRedo, false);
    h.synchronize(edit('remote'), 'group');
    expect(h.undo()!.text, 'new');
    expect(h.undo()!.text, '');
    expect(h.redo()!.text, 'new');
    expect(h.redo()!.text, 'remote');
    h.synchronize(edit('remote'), 'group');
    expect(h.undo()!.text, 'new');
    h.reset(edit('other document'), 'other group');
    expect(h.canUndo, false);
  });
  test('IME interim text is never an undo entry', () {
    final h = SharedEditHistory()..reset(edit('原文'), 'group');
    h.record(edit('原文ni', composing: const TextRange(start: 2, end: 4)));
    expect(h.canUndo, false);
    h.record(edit('原文你'));
    expect(h.undo()!.text, '原文');
    expect(h.redo()!.text, '原文你');
  });
}
