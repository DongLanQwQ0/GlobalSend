import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';
import 'package:globalsend/vault.dart';

class MemoryVault extends PlatformVault {
  final Map<String, String> values = {};
  @override
  Future<String?> read({required String key}) async => values[key];
  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }
}

class SessionController extends SendController {
  SessionController(PlatformVault vault) : super(vault: vault);
  @override
  Future<void> start() async {}
}

void main() {
  test('strong group key is a fresh 256-bit base64url joining credential', () {
    final key = newGroupKey();
    expect(key, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(newGroupKey(), isNot(key));
  });
  test(
    'same center new device/group and local sign-out discard old active state',
    () async {
      final vault = MemoryVault();
      final c = SessionController(vault);
      final p = ServerProfile(
        baseUrl: 'https://example.test/Base',
        instanceId: 'server',
        deviceId: 'old',
        groupId: 'group-a',
        cursor: 99,
        autoReceive: false,
      );
      c.profile = p;
      c.profiles = [p];
      c.api = CenterApi(p.baseUrl, token: 'old-token');
      c.dock = [
        DockEntry(
          id: 'old-item',
          kind: 'text',
          title: 'old',
          source: 'old-peer',
          text: 'old group text',
        ),
      ];
      c.sources = {'old-file': '/not-read'};
      c.pendingTexts = {'old-text': 'old-event'};
      c.busyFiles.add('old-file');
      await c.adoptEnrollment({
        'deviceToken': 'new-token',
        'groupId': 'group-b',
        'device': {'deviceId': 'new', 'groupId': 'group-b'},
      }, 'new device');
      expect(p.groupId, 'group-b');
      expect(p.autoReceive, isTrue);
      expect(p.cursor, 0);
      expect(c.api!.token, 'new-token');
      expect(c.dock, isEmpty);
      expect(c.sources, isEmpty);
      expect(c.pendingTexts, isEmpty);
      expect(c.busyFiles, isEmpty);
      expect(vault.values.values, ['new-token']);
      await c.signOutLocal();
      expect(p.deviceId, isEmpty);
      expect(p.groupId, isEmpty);
      expect(c.api!.token, isEmpty);
      await c.adoptEnrollment({
        'deviceToken': 'third-token',
        'groupId': 'group-c',
        'device': {'deviceId': 'third', 'groupId': 'group-c'},
      }, 'third');
      expect(c.dock, isEmpty);
      expect(p.groupId, 'group-c');
      expect(vault.values.values, ['third-token']);
      c.dispose();
    },
  );
}
