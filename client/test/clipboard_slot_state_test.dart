import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/clipboard_slot.dart';
import 'package:globalsend/models.dart';

void main() {
  test('one persisted slot replaces sources without deleting an active drag source', () async {
    final parent = await Directory('../artifacts/tmp/receive-reference112')
        .create(recursive: true);
    final state = await parent.createTemp('slot-');
    try {
      final cache = await Directory('${state.path}/clipboard-slot-cache')
          .create();
      final slot = ClipboardSlot(changed: () {});
      await slot.load(state);
      final first = await File('${cache.path}/first.png').writeAsBytes([1]);
      final second = await File('${cache.path}/second.png').writeAsBytes([2]);
      DockEntry image(String source, String path, int at) => DockEntry(
        id: source,
        kind: 'file',
        title: 'photo.png',
        source: source,
        localPath: path,
        status: 'received',
        autoClipboard: true,
        createdAtMillis: at,
        originDeviceId: source,
        sourceEventId: source,
      );
      expect(await slot.receive(image('one', first.path, 1)), true);
      slot.retain(first.path);
      expect(await slot.receive(image('two', second.path, 2)), true);
      expect(slot.value?.localPath, second.path);
      expect(
        await first.exists(),
        true,
        reason: 'An OS drag provider can still be reading the old value.',
      );
      await slot.release(first.path);
      expect(
        await first.exists(),
        false,
        reason: 'The last real consumer ended; no timer or restart is needed.',
      );
      final restored = ClipboardSlot(changed: () {});
      await restored.load(state);
      expect(restored.value?.source, 'two');
      expect(await first.exists(), false);
      await restored.setEnabled(false);
      expect(restored.value, isNull);
      expect(await restored.receive(image('three', second.path, 3)), false);
      await restored.setEnabled(true);
      expect(restored.value?.source, 'two');
      await restored.clear();
      expect(restored.value, isNull);
    } finally {
      await state.delete(recursive: true);
    }
  });
}
