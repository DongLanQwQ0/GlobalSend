import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

class ShelfController extends SendController {
  ShelfController() {
    profile = ServerProfile(
      baseUrl: 'http://fixture',
      instanceId: 'fixture',
      deviceId: 'self',
    );
    api = CenterApi('http://fixture', token: 'fixture');
    devices = [
      {'deviceId': 'one', 'name': '同名', 'online': true},
      {'deviceId': 'two', 'name': '同名', 'online': true},
    ];
  }
  final calls = <String>[];
  bool fail = false;
  @override
  Future<void> offer(
    String target,
    List<String> paths, {
    String? routePreferenceOverride,
    Map<String, String>? displayNames,
  }) async {
    calls.add('$target:${paths.join(',')}');
    if (fail) throw StateError('offline');
  }

  @override
  Future<void> sendText(String target, String text) async {
    calls.add('$target:$text');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'shelf drop sends by unique ID and leaves all pending drafts intact',
    () async {
      final c = ShelfController();
      addTearDown(c.dispose);
      c.stagedFiles.add('draft.pdf');
      c.stagedTexts.addAll(['draft', 'shared']);
      await c.sendDockSelection({
        'serverKey': c.profile!.key,
        'deviceId': 'two',
        'paths': ['picture.jpg', 'folder'],
        'texts': ['shared', 'second'],
      });
      expect(c.calls, ['two:picture.jpg,folder', 'two:shared', 'two:second']);
      expect(c.stagedFiles, ['draft.pdf']);
      expect(c.stagedTexts, ['draft', 'shared']);
    },
  );
  test(
    'stale center or absent device never redirects to a same-name device',
    () async {
      final c = ShelfController();
      addTearDown(c.dispose);
      await expectLater(
        c.sendDockSelection({
          'serverKey': 'old-center',
          'deviceId': 'two',
          'texts': ['text'],
        }),
        throwsStateError,
      );
      await expectLater(
        c.sendDockSelection({
          'serverKey': c.profile!.key,
          'deviceId': 'missing',
          'texts': ['text'],
        }),
        throwsStateError,
      );
      expect(c.calls, isEmpty);
    },
  );
  test(
    'failed file offer reports failure and does not send the remaining text',
    () async {
      final c = ShelfController()..fail = true;
      addTearDown(c.dispose);
      await expectLater(
        c.sendDockSelection({
          'serverKey': c.profile!.key,
          'deviceId': 'one',
          'paths': ['image.jpg'],
          'texts': ['text'],
        }),
        throwsStateError,
      );
      expect(c.calls, ['one:image.jpg']);
    },
  );
}
