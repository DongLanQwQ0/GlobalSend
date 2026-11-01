import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/api.dart';
import 'package:globalsend/github_updates.dart';
import 'package:globalsend/network_proxy.dart';

class RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => NetworkProxy.bypassSystemProxy = true);

  test(
    'new and existing installations default to bypass; opt-out persists',
    () async {
      final cache = await Directory('build/test_cache/network-proxy')
          .create(recursive: true);
      final temp = await cache.createTemp('settings-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/network.json');
      final settings = NetworkSettings();
      NetworkProxy.bypassSystemProxy = false;
      await settings.load(file);
      expect(settings.bypassSystemProxy, true);
      await settings.setBypassSystemProxy(false);
      NetworkProxy.bypassSystemProxy = true;
      await NetworkSettings().load(file);
      expect(settings.bypassSystemProxy, false);
      await settings.setBypassSystemProxy(true);
      expect(jsonDecode(await file.readAsString()), {
        'bypassSystemProxy': true,
      });
    },
  );

  test('center, update and persistent websocket requests bypass a configured proxy by default', () async {
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var proxyHits = 0;
    final websockets = <WebSocket>[];
    target.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        websockets.add(ws);
        ws.add('direct');
      } else {
        request.response.write('{"route":"direct"}');
        await request.response.close();
      }
    });
    proxy.listen((request) async {
      proxyHits++;
      request.response.write('{"route":"proxy"}');
      await request.response.close();
    });
    addTearDown(() async {
      for (final ws in websockets) {
        await ws.close();
      }
      await target.close(force: true);
      await proxy.close(force: true);
    });
    await HttpOverrides.runZoned(
      () async {
        final base = 'http://127.0.0.1:${target.port}';
        final api = CenterApi(base);
        final feed = GitHubUpdateFeed();
        try {
          expect(
            (await api.call('GET', '/info', null, false))['route'],
            'direct',
          );
          expect((await feed.manifest('$base/update.json'))['route'], 'direct');
          final ws = await WebSocket.connect(
            'ws://127.0.0.1:${target.port}/ws',
            customClient: api.client,
          );
          expect(await ws.first, 'direct');
          await ws.close();
          expect(proxyHits, 0);
          // Already-created clients must change routing, not keep the old decision.
          NetworkProxy.bypassSystemProxy = false;
          expect(
            (await api.call('GET', '/info', null, false))['route'],
            'proxy',
          );
          expect((await feed.manifest('$base/update.json'))['route'], 'proxy');
          expect(proxyHits, 2);
          NetworkProxy.bypassSystemProxy = true;
          expect(
            (await api.call('GET', '/info', null, false))['route'],
            'direct',
          );
          expect(proxyHits, 2);
        } finally {
          api.close();
          feed.close();
        }
      },
      createHttpClient: RealHttp().createHttpClient,
      findProxyFromEnvironment: (_, _) => 'PROXY 127.0.0.1:${proxy.port}',
    );
  });
}
