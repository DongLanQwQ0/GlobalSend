import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/controller.dart';
import 'package:globalsend/models.dart';

class EditingApi extends CenterApi {
  EditingApi() : super('http://127.0.0.1', token: 'test');
  int calls = 0;
  bool reject = false;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls++;
    expect(method, 'PATCH');
    expect(path, '/texts/message');
    if (reject) throw ApiException(410, '消息已过期');
    return {
      'event': {
        'type': 'text.updated',
        'cursor': 3,
        'sourceDeviceId': 'self',
        'payload': {
          'sourceEventId': 'message',
          'text': (body as Map)['text'],
          'editedAt': '2026-10-25T01:00:00Z',
        },
      },
    };
  }
}

class EditingController extends SendController {
  int saves = 0;
  @override
  Future<void> save() async {
    saves++;
  }
}

void main() {
  test(
    'sent edits update the same persisted card without resending a new message',
    () async {
      final api = EditingApi();
      final item = DockEntry(
        id: 'message',
        kind: 'text',
        title: '已发送',
        source: 'self',
        text: '原文',
        outgoing: true,
      );
      final c = EditingController()
        ..api = api
        ..dock = [item]
        ..profile = ServerProfile(
          baseUrl: api.baseUrl,
          instanceId: 'test',
          deviceId: 'self',
        );
      addTearDown(c.dispose);
      await c.editSentText(item, '修改后的文字\n第二行');
      expect(c.dock.single, item);
      expect(item.text, '修改后的文字\n第二行');
      expect(c.saves, 1);
      c.applyTextUpdate({
        'cursor': 2,
        'sourceDeviceId': 'self',
        'payload': {
          'sourceEventId': 'message',
          'text': '旧修改',
          'editedAt': 'older',
        },
      });
      expect(item.text, '修改后的文字\n第二行');
      expect(DockEntry.fromJson(item.toJson()).editCursor, 3);
      expect(DockEntry.fromJson(item.toJson()).editedAt, isNotEmpty);
    },
  );
  test(
    'received messages are read-only and failed edits retain the original text',
    () async {
      final api = EditingApi();
      final c = EditingController()
        ..api = api
        ..profile = ServerProfile(
          baseUrl: api.baseUrl,
          instanceId: 'test',
          deviceId: 'self',
        );
      addTearDown(c.dispose);
      final incoming = DockEntry(
        id: 'received',
        kind: 'text',
        title: '收到',
        source: 'other',
        text: '只读',
      );
      await expectLater(c.editSentText(incoming, '不应保存'), throwsStateError);
      expect(api.calls, 0);
      final outgoing = DockEntry(
        id: 'message',
        kind: 'text',
        title: '已发',
        source: 'self',
        text: '原文',
        outgoing: true,
      );
      api.reject = true;
      c.dock = [outgoing];
      await expectLater(
        c.editSentText(outgoing, '修改'),
        throwsA(isA<ApiException>()),
      );
      expect(outgoing.text, '原文');
      expect(c.saves, 0);
    },
  );
}
