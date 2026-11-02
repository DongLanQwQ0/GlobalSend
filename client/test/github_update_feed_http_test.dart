import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/github_updates.dart';

import 'auto_update_engine_test.dart' show RealUpdateBinding;
import 'github_updates_test.dart' show asset, release;

// The real HttpClient follows redirects and keeps normal HTTP caching headers;
// only the origin is routed to a project-owned local fixture.
class RoutedClient implements HttpClient {
  RoutedClient(this.port);
  final int port;
  final HttpClient inner = HttpClient()..findProxy = (_) => 'DIRECT';
  @override
  Future<HttpClientRequest> getUrl(Uri url) => inner.getUrl(
    Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: url.path,
      query: url.hasQuery ? url.query : null,
    ),
  );
  @override
  set connectionTimeout(Duration? value) {
    inner.connectionTimeout = value;
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  RealUpdateBinding();
  test('public manifest uses release asset API, follows its redirect and reuses ETag without authentication', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final urls = <String>[];
    final browser =
        'https://github.com/download/globalsend-update-windows.json';
    final rows = [
      release('v1.0.80', [
        asset('GlobalSend-1.0.80-windows-x64.zip'),
        {
          ...asset('globalsend-update-windows.json'),
          'url': 'https://api.github.com/repos/test/releases/assets/42',
        },
      ]),
    ];
    final sub = server.listen((request) async {
      urls.add(request.uri.path);
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      if (request.uri.path.endsWith('/releases')) {
        expect(
          request.headers.value(HttpHeaders.acceptHeader),
          'application/vnd.github+json',
        );
        request.response.write(jsonEncode(rows));
      } else if (request.uri.path.endsWith('/42')) {
        expect(
          request.headers.value(HttpHeaders.acceptHeader),
          'application/octet-stream',
        );
        if (request.headers.value(HttpHeaders.ifNoneMatchHeader) ==
            '"manifest1"') {
          request.response.statusCode = 304;
        } else {
          request.response.statusCode = 302;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${server.port}/binary-manifest',
          );
        }
      } else if (request.uri.path == '/binary-manifest') {
        request.response.headers.set(HttpHeaders.etagHeader, '"manifest1"');
        request.response.write(
          jsonEncode({
            'schema': 1,
            'platform': 'windows',
            'version': '1.0.80',
            'build': 104,
          }),
        );
      } else {
        fail('Unexpected browser download request ${request.uri}');
      }
      await request.response.close();
    });
    final feed = GitHubUpdateFeed(client: RoutedClient(server.port));
    addTearDown(() async {
      feed.close();
      await sub.cancel();
      await server.close(force: true);
    });
    expect((await feed.releases()).length, 1);
    expect((await feed.manifest(browser))['build'], 104);
    expect((await feed.manifest(browser))['build'], 104);
    expect(urls.where((url) => url == '/binary-manifest').length, 1);
    expect(urls.where((url) => url.endsWith('/42')).length, 2);
  });
}
