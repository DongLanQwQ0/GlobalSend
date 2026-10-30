import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/url_intents.dart';

const id = '12345678-1234-1234-1234-123456789abc';
const caller = 'com.donglan.chrona';
final clock = DateTime.utc(2026, 10, 28, 12);
Map<String, dynamic> intent({String state = 'queued', DateTime? expiry}) => {
  'requestId': id,
  'sourceDeviceId': 'source',
  'targetDeviceId': 'target',
  'callerAppId': caller,
  'url': 'https://example.org/path',
  'state': state,
  'createdAt': clock.toIso8601String(),
  'updatedAt': clock.toIso8601String(),
  'expiresAt': (expiry ?? clock.add(const Duration(seconds: 120)))
      .toIso8601String(),
};

class Center extends CenterApi {
  Center() : super('http://unused', token: 'private-token');
  final calls = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> pending = [];
  Map<String, dynamic> status = intent();
  bool failAccepted = false;
  bool failTextOnce = false;
  ApiException? textError;
  String? deliveredState;
  @override
  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Object? body,
    bool authenticated = true,
  ]) async {
    calls.add({'method': method, 'path': path, 'body': body});
    if (path == '/texts') {
      if (textError != null) throw textError!;
      if (failTextOnce) {
        failTextOnce = false;
        throw TimeoutException('reply lost');
      }
      return {
        'event': {'id': (body as Map)['eventId'], 'type': 'text.created'},
      };
    }
    if (path == '/url-intents/pending') return {'intents': pending};
    if (path.endsWith('/result')) {
      final value = body as Map;
      if (value['state'] == 'launch_accepted' && failAccepted)
        throw const SocketException('offline after OS launch');
      return {
        ...status,
        'state': value['state'] == 'delivered'
            ? deliveredState ?? 'delivered'
            : value['state'],
      };
    }
    if (path == '/url-intents' && method == 'POST')
      return {...status, ...body as Map, 'sourceDeviceId': 'target'};
    return status;
  }
}

class Native extends UrlIntentNativeBridge {
  Native() : super(android: true);
  final acknowledgements = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> receipts = [];
  @override
  void install(
    Future<Map<String, dynamic>> Function(Map<String, dynamic>) request,
    Future<void> Function(Map<String, dynamic>) result,
  ) {}
  @override
  Future<void> announceReady() async {
    ready = true;
  }

  @override
  Future<Map<String, dynamic>> open(Map<String, dynamic> intent) async => {
    'state': 'needs_tap',
    'resultId': 'result-v1',
  };
  @override
  Future<List<Map<String, dynamic>>> pendingResults() async => receipts;
  @override
  Future<void> ackResult(Map<String, dynamic> value) async {
    acknowledgements.add(value);
  }

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late Center api;
  late UrlIntentSession? active;
  late List<Map<String, dynamic>> peers;
  late int opens;
  late UrlIntentIntegration integration;
  late File file;
  UrlIntentIntegration create({Native? native}) => UrlIntentIntegration(
    session: () => active,
    devices: () => peers,
    refreshDevices: () async {},
    changed: () {},
    platform: native == null ? 'windows' : 'android',
    native: native,
    now: () => clock,
    openWebUrl: (_) async {
      opens++;
    },
  );
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> extra = const {},
  ]) => integration.handleLocalRequest({
    'callerAppId': caller,
    'request': {'v': 1, 'requestId': id, 'method': method, ...extra},
  });
  setUp(() async {
    final base = Directory('build/test-tmp/url-intents');
    await base.create(recursive: true);
    folder = await base.createTemp('case-');
    file = File('${folder.path}/intents.json');
    api = Center();
    active = UrlIntentSession(
      api: api,
      scope: 'scope',
      deviceId: 'target',
      supported: true,
    );
    peers = [
      {'deviceId': 'target', 'name': 'Self'},
      {
        'deviceId': 'peer',
        'name': '电脑',
        'platform': 'windows',
        'online': false,
        'openUrlIntentV1': true,
        'deviceToken': 'secret',
        'peer': {
          'addresses': ['private'],
        },
      },
      {'deviceId': 'revoked', 'revoked': true},
    ];
    opens = 0;
    integration = create();
    await integration.initialize(file);
  });
  tearDown(() {
    integration.dispose();
    api.close();
  });

  test('approved local device projection omits self, revoked, credentials and addresses', () async {
    final response = await request('list_devices', {'refresh': true});
    final devices = response['result']['devices'] as List;
    expect(devices, hasLength(1));
    expect(devices.single, {
      'deviceId': 'peer',
      'name': '电脑',
      'platform': 'windows',
      'online': false,
      'sendable': true,
      'capabilities': {'openUrlIntentV1': true, 'sendLinkV1': true},
    });
    expect(jsonEncode(response), isNot(contains('secret')));
  });
  test('offline is rejected, malformed requests return envelopes', () async {
    active = null;
    expect((await request('hello'))['result']['connected'], false);
    expect((await request('send_open_url'))['error']['code'], 'not_connected');
    expect(
      (await integration.handleLocalRequest({'request': 42}))['ok'],
      false,
    );
    expect(api.calls, isEmpty);
  });
  test('source RPC takes native caller identity and isolates status from other callers', () async {
    final result = await request('send_open_url', {
      'targetDeviceId': 'peer',
      'url': 'https://example.org/',
      'callerAppId': 'fake',
    });
    expect(result['ok'], true);
    expect(api.calls.last['body']['callerAppId'], caller);
    expect(result['result'].containsKey('callerAppId'), false);
    api.status = {
      ...intent(),
      'callerAppId': 'other',
      'sourceDeviceId': 'target',
    };
    expect((await request('status'))['error']['code'], 'request_not_found');
    api.status = {
      ...intent(),
      'callerAppId': caller,
      'sourceDeviceId': 'target',
    };
    expect((await request('status'))['ok'], true);
  });
  test(
    'ordinary URLs are not an intent and unsupported centers use no endpoint',
    () async {
      await integration.synchronize();
      expect(opens, 0);
      active = UrlIntentSession(
        api: api,
        scope: 'scope',
        deviceId: 'target',
        supported: false,
      );
      api.calls.clear();
      api.pending = [intent()];
      await integration.synchronize();
      expect(api.calls, isEmpty);
      expect(opens, 0);
    },
  );
  test('pending duplicate and process restart only launch once, even when result POST failed', () async {
    api.pending = [intent(), intent()];
    api.failAccepted = true;
    await integration.synchronize();
    expect(opens, 1);
    var stored = jsonDecode(await file.readAsString())['records'] as Map;
    expect(stored.values.single['state'], 'launch_accepted');
    integration.dispose();
    integration = create();
    await integration.initialize(file);
    api.failAccepted = false;
    await integration.synchronize();
    expect(opens, 1);
    stored = jsonDecode(await file.readAsString())['records'] as Map;
    expect(stored.values.single['resultPending'], false);
  });
  test('expired requests and center terminal result never launch', () async {
    api.pending = [intent(expiry: clock)];
    await integration.synchronize();
    expect(opens, 0);
    api.pending = [intent()];
    api.deliveredState = 'expired';
    // A separate scope represents an independent identity at another center.
    active = UrlIntentSession(
      api: api,
      scope: 'scope2',
      deviceId: 'target',
      supported: true,
    );
    await integration.synchronize();
    expect(opens, 0);
  });
  test('crash fence needs explicit tap; repeated taps serialize to a single system launch', () async {
    integration.dispose();
    await file.writeAsString(
      jsonEncode({
        'records': {
          'scope\nsource\n$id': {
            ...intent(),
            'scope': 'scope',
            'stage': 'launching',
            'resultPending': false,
          },
        },
      }),
    );
    integration = create();
    await integration.initialize(file);
    await integration.synchronize();
    expect(opens, 0);
    expect(integration.needsAttention, hasLength(1));
    final item = integration.needsAttention.single;
    await Future.wait([
      integration.openManually(item),
      integration.openManually(item),
    ]);
    expect(opens, 1);
    expect(integration.needsAttention, isEmpty);
  });
  test('Android versions ACK only after center accepted; stale callback cannot regress launch', () async {
    final native = Native();
    integration.dispose();
    integration = create(native: native);
    await integration.initialize(file);
    api.pending = [intent()];
    await integration.synchronize();
    expect(native.acknowledgements.single['resultId'], 'result-v1');
    final result = {
      'sourceDeviceId': 'source',
      'requestId': id,
      'state': 'launch_accepted',
      'resultId': 'result-v2',
    };
    api.failAccepted = true;
    await integration.acceptNativeResult(result);
    expect(native.acknowledgements, hasLength(1));
    api.failAccepted = false;
    await integration.synchronize();
    expect(native.acknowledgements.last['resultId'], 'result-v2');
    await integration.acceptNativeResult({
      ...result,
      'state': 'needs_tap',
      'resultId': 'old',
    });
    final stored = jsonDecode(await file.readAsString())['records'] as Map;
    expect(stored.values.single['state'], 'launch_accepted');
    expect(native.acknowledgements.last['resultId'], 'old');
  });
  test('cold engine queue consumes original TTL and never sends an already expired URL', () async {
    final response = await integration.handleLocalRequest({
      'callerAppId': caller,
      'receivedAtMillis': clock
          .subtract(const Duration(seconds: 120))
          .millisecondsSinceEpoch,
      'request': {
        'v': 1,
        'requestId': id,
        'method': 'send_open_url',
        'targetDeviceId': 'peer',
        'url': 'https://example.org/',
      },
    });
    expect(response['result']['state'], 'expired');
    expect(api.calls, isEmpty);
  });
  test('iPad links use ordinary text without remote-open capability or a new center', () async {
    peers = [
      {
        'deviceId': 'ipad',
        'name': 'iPad',
        'platform': 'other',
        'online': true,
        'openUrlIntentV1': false,
      },
    ];
    active = UrlIntentSession(
      api: api,
      scope: 'scope',
      deviceId: 'target',
      supported: false,
    );
    expect(
      (await request('hello'))['result']['capabilities'],
      contains('send_link'),
    );
    final device =
        ((await request('list_devices'))['result']['devices'] as List).single;
    expect(device['capabilities'], {
      'openUrlIntentV1': false,
      'sendLinkV1': true,
    });
    final result = await request('send_link', {
      'targetDeviceId': 'ipad',
      'url': 'http://10.0.0.2:8765/',
    });
    expect(result['ok'], true);
    expect(result['result']['state'], 'sent');
    expect(result['result']['deliveryMode'], 'link');
    expect(result['result'].containsKey('expiresAt'), false);
    expect(api.calls.single, {
      'method': 'POST',
      'path': '/texts',
      'body': {
        'eventId': id,
        'targetDeviceId': 'ipad',
        'text': 'http://10.0.0.2:8765/',
      },
    });
    expect(opens, 0);
    integration.dispose();
    integration = create();
    await integration.initialize(file);
    final status = await request('status', {'deliveryMode': 'link'});
    expect(status['result']['state'], 'sent');
    expect(api.calls, hasLength(1));
    peers = []; // A completed request stays completed after presence changes.
    await request('send_link', {
      'targetDeviceId': 'ipad',
      'url': 'http://10.0.0.2:8765/',
    });
    expect(api.calls, hasLength(1));
  });
  test('ambiguous link result persists queued; status does not resend and explicit retry keeps ID', () async {
    api.failTextOnce = true;
    const body = {'targetDeviceId': 'peer', 'url': 'https://example.org/'};
    expect(
      (await request('send_link', body))['error']['code'],
      'timeout_unknown',
    );
    integration.dispose();
    integration = create();
    await integration.initialize(file);
    expect(
      (await request('status', {'deliveryMode': 'link'}))['result']['state'],
      'queued',
    );
    expect(api.calls, hasLength(1));
    expect((await request('send_link', body))['result']['state'], 'sent');
    expect(api.calls, hasLength(2));
    expect(api.calls.map((c) => c['body']['eventId']), [id, id]);
    expect(
      (await request('send_link', {
        ...body,
        'url': 'https://other.example/',
      }))['error']['code'],
      'conflict',
    );
    final foreign = await integration.handleLocalRequest({
      'callerAppId': 'other.app',
      'request': {
        'v': 1,
        'requestId': id,
        'method': 'status',
        'deliveryMode': 'link',
      },
    });
    expect(foreign['error']['code'], 'request_not_found');
    expect(api.calls, hasLength(2));
  });
  test(
    'definitive link rejection remains failed until an explicit same-ID retry',
    () async {
      api.textError = ApiException(
        403,
        'target left',
        response: {
          'error': {'code': 'FORBIDDEN'},
        },
      );
      const body = {'targetDeviceId': 'peer', 'url': 'https://example.org/'};
      expect((await request('send_link', body))['error']['code'], 'forbidden');
      final rejected = await request('status', {'deliveryMode': 'link'});
      expect(rejected['result']['state'], 'failed');
      expect(rejected['result']['error']['code'], 'forbidden');
      expect(api.calls, hasLength(1));
      api.textError = null;
      final sent = await request('send_link', body);
      expect(sent['result']['state'], 'sent');
      expect(sent['result'].containsKey('error'), false);
      expect(api.calls.map((c) => c['body']['eventId']), [id, id]);
    },
  );
  test('open requests never silently become a link and legacy status remains remote', () async {
    peers = [
      {'deviceId': 'ipad', 'openUrlIntentV1': false},
    ];
    expect(
      (await request('send_open_url', {
        'targetDeviceId': 'ipad',
        'url': 'https://example.org/',
      }))['error']['code'],
      'unsupported_target',
    );
    expect(api.calls, isEmpty);
    await request('send_link', {
      'targetDeviceId': 'ipad',
      'url': 'https://example.org/',
    });
    await request('status');
    expect(api.calls.last['path'], '/url-intents/$id');
    expect(opens, 0);
  });
}
