import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/controller.dart';

void main() {
  test('native drag snapshots separate hover from import progress', () async {
    final controller = SendController();
    addTearDown(controller.dispose);
    await controller.handleNativeDockEvent({
      'type': 'nativeDrag',
      'active': true,
      'importing': false,
    });
    expect(controller.nativeDragActive, isTrue);
    expect(controller.nativeImporting, isFalse);
    await controller.handleNativeDockEvent({
      'type': 'nativeDrag',
      'active': false,
      'importing': true,
    });
    expect(controller.nativeDragActive, isFalse);
    expect(controller.nativeImporting, isTrue);
    await controller.handleNativeDockEvent({
      'type': 'nativeDrag',
      'active': false,
      'importing': false,
    });
    expect(controller.nativeImporting, isFalse);
  });

  test(
    'native drop stages content once and never sends without confirmation',
    () async {
      final controller = SendController();
      addTearDown(controller.dispose);
      final drop = {
        'type': 'nativeDrop',
        'dropId': 'same-import',
        'paths': <String>[],
        'texts': ['拖入的独立文本'],
      };
      await controller.handleNativeDockEvent(drop);
      await controller.handleNativeDockEvent(drop);
      expect(controller.stagedTexts, ['拖入的独立文本']);
      expect(controller.dock, isEmpty);
      expect(controller.pendingTexts, isEmpty);
    },
  );

  test('resumed native status restores current import feedback', () async {
    final controller = SendController();
    addTearDown(controller.dispose);
    await controller.handleNativeDockEvent({
      'type': 'dockState',
      'active': false,
      'importing': true,
    });
    expect(controller.nativeDragActive, isFalse);
    expect(controller.nativeImporting, isTrue);
    await controller.handleNativeDockEvent({
      'type': 'dockState',
      'active': false,
      'importing': false,
    });
    expect(controller.nativeImporting, isFalse);
  });
}
