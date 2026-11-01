import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/copied_files.dart';

class CopyApi extends CenterApi {
  CopyApi() : super('https://center.invalid', token: 'test-token');
  final calls = <(String, String, Map<String, dynamic>?)>[];
  List<Map<String, dynamic>> offers = [];
  Completer<void>? preparing;
  Completer<void>? deleting;
  Future<void> Function(Map<String, dynamic>)? onPull;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    final value = body == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(jsonEncode(body)) as Map);
    calls.add((method, path, value));
    if (method == 'DELETE' && path == '/clipboard/files')
      await deleting?.future;
    if (method == 'GET' && path == '/clipboard/files')
      return {'offers': offers};
    if (method == 'GET' && path == '/clipboard/files/pulls')
      return {'pulls': []};
    if (method == 'PUT' && value?['state'] == 'sending')
      await preparing?.future;
    if (method == 'POST' && path.endsWith('/pull')) {
      await onPull?.call(value!);
      return {
        ...value!,
        'state': 'pending',
        'sourceDeviceId': 'source',
        'targetDeviceId': 'self',
      };
    }
    return {};
  }
}

void main() {
  late Directory temporary;
  late CopyApi api;
  late CopiedFilesClient copied;
  final sent = <(String, List<String>)>[];
  var serial = 0;
  setUp(() async {
    final root = await Directory('../artifacts/tmp/copied-files-client')
        .create(recursive: true);
    temporary = await root.createTemp('case-');
    api = CopyApi();
    sent.clear();
    serial = 0;
    copied = CopiedFilesClient(
      newId: () => 'item-${serial++}',
      sendFiles: (target, paths) async {
        sent.add((target, paths.toList()));
      },
      changed: () {},
    );
    await copied.load(File('${temporary.path}/copied-files.json'));
    await copied.connect(api, self: 'self', supported: true);
  });
  tearDown(() async {
    copied.disconnect();
    api.client.close(force: true);
    await temporary.delete(recursive: true);
  });

  Future<File> picture(String name) async =>
      File('${temporary.path}/$name').writeAsBytes([1, 2, 3]);
  Map<String, dynamic> latest() => api.calls
      .lastWhere((call) => call.$1 == 'PUT' && call.$2 == '/clipboard/files')
      .$3!;

  test('only explicit targets receive root metadata; folders stay one item and sources remain references', () async {
    final file = await picture('picture.jpg'),
        folder = await Directory('${temporary.path}/Folder').create();
    await File('${folder.path}/child.txt')
        .writeAsString('not a separate clipboard item');
    await expectLater(copied.configure(true, []), throwsFormatException);
    await copied.configure(true, ['target']);
    await copied.copiedPaths([file.path, folder.path, file.path]);
    final offer = latest(), items = offer['items'] as List;
    expect(offer['targetDeviceIds'], ['target']);
    expect(items.length, 2);
    expect(items.map((item) => item['kind']), ['file', 'directory']);
    expect(jsonEncode(offer), isNot(contains(temporary.path)));
    expect(jsonEncode(offer), isNot(contains('child.txt')));
    expect(sent, isEmpty);
    final request = {
      'sourceDeviceId': 'self',
      'targetDeviceId': 'target',
      'offerId': offer['offerId'],
      'requestId': 'pull-one',
      'itemIds': [items[1]['id']],
    };
    await Future.wait([copied.serve(request), copied.serve(request)]);
    await copied.serve(request);
    expect(sent.length, 1);
    expect(sent.single.$1, 'target');
    expect(sent.single.$2, [folder.path]);
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(await Directory(folder.path).exists(), isTrue);
    final restored = CopiedFilesClient(
      newId: () => 'restored',
      sendFiles: (_, _) async {},
      changed: () {},
    );
    await restored.load(File('${temporary.path}/copied-files.json'));
    expect(restored.enabled, isTrue);
    expect(restored.targets, ['target']);
  });

  test('replacing clipboard withdraws old offer; unknown items and removed files never start sends', () async {
    final file = await picture('removed.jpg');
    await copied.configure(true, ['target']);
    await copied.copiedPaths([file.path]);
    final offer = latest(), item = (offer['items'] as List).first;
    await file.delete();
    await copied.serve({
      'sourceDeviceId': 'self',
      'targetDeviceId': 'target',
      'offerId': offer['offerId'],
      'requestId': 'missing',
      'itemIds': [item['id']],
    });
    expect(sent, isEmpty);
    expect(api.calls.last.$3?['state'], 'failed');
    await copied.copiedPaths([]);
    expect(api.calls.last.$1, 'DELETE');
    await copied.serve({
      'sourceDeviceId': 'self',
      'targetDeviceId': 'other',
      'offerId': offer['offerId'],
      'requestId': 'unselected',
      'itemIds': [item['id']],
    });
    expect(sent, isEmpty);
    expect(api.calls.last.$3?['state'], 'failed');
  });

  test('rapid clipboard changes wait for the old withdrawal and publish only the latest roots', () async {
    final first = await picture('first.jpg'),
        second = await picture('second.jpg');
    await copied.configure(true, ['target']);
    api.calls.clear();
    api.deleting = Completer<void>();
    final earlier = copied.copiedPaths([first.path]);
    while (api.calls.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final later = copied.copiedPaths([second.path]);
    await Future<void>.delayed(Duration.zero);
    expect(api.calls.where((call) => call.$1 == 'PUT'), isEmpty);
    api.deleting!.complete();
    await Future.wait([earlier, later]);
    final publishes = api.calls
        .where((call) => call.$1 == 'PUT' && call.$2 == '/clipboard/files')
        .toList();
    expect(publishes.length, 1);
    expect(
      (publishes.single.$3!['items'] as List).single['name'],
      'second.jpg',
    );
  });
  test('revoking a target during preparation stops that send; a fast socket result is not overwritten by HTTP', () async {
    final file = await picture('picture.jpg');
    await copied.configure(true, ['target']);
    await copied.copiedPaths([file.path]);
    final offer = latest(), item = (offer['items'] as List).first;
    api.preparing = Completer<void>();
    final active = copied.serve({
      'sourceDeviceId': 'self',
      'targetDeviceId': 'target',
      'offerId': offer['offerId'],
      'requestId': 'revoked',
      'itemIds': [item['id']],
    });
    while (!api.calls.any((call) => call.$3?['state'] == 'sending')) {
      await Future<void>.delayed(Duration.zero);
    }
    await copied.configure(true, ['other']);
    api.preparing!.complete();
    await active;
    expect(sent, isEmpty);
    api.onPull = (request) async {
      await copied.handle({
        'type': 'clipboard.files.pull.updated',
        ...request,
        'sourceDeviceId': 'source',
        'targetDeviceId': 'self',
        'state': 'sent',
      });
    };
    final response = await copied.pull(
      {'offerId': 'remote', 'sourceDeviceId': 'source'},
      ['remote-file'],
    );
    expect(response['state'], 'pending');
    expect(copied.pulls[response['requestId']]?['state'], 'sent');
  });
  test('a second tap while pull acknowledgement is pending does not request a second transfer', () async {
    final gate = Completer<void>();
    api.onPull = (_) => gate.future;
    final offer = {'offerId': 'remote', 'sourceDeviceId': 'source'};
    final first = copied.pull(offer, ['file']);
    expect(copied.pulls.values.single['state'], 'pending');
    await copied.pull(offer, ['file']);
    expect(
      api.calls.where((call) => call.$1 == 'POST' && call.$2.endsWith('/pull')),
      hasLength(1),
    );
    gate.complete();
    await first;
  });
}
