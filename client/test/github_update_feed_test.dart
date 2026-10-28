import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globalsend/github_updates.dart';

class LocalHttp extends HttpOverrides {}

void main() {
  test('same release URL revalidates its ETag and sees replacement platform metadata', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var revision = 1, requests = 0;
    final incoming = <String?>[];
    server.listen((request) async {
      requests++;
      final tag = '"$revision"';
      incoming.add(request.headers.value(HttpHeaders.ifNoneMatchHeader));
      request.response.headers.set(HttpHeaders.etagHeader, tag);
      if (incoming.last == tag)
        request.response.statusCode = 304;
      else
        request.response.write(
          jsonEncode({
            'schema': 1,
            'platform': 'windows',
            'version': '1.0.26',
            'build': revision,
          }),
        );
      await request.response.close();
    });
    final feed = GitHubUpdateFeed(client: LocalHttp().createHttpClient(null));
    feed.client.findProxy = (_) => 'DIRECT';
    addTearDown(() async {
      feed.close();
      await server.close(force: true);
    });
    final url =
        'http://127.0.0.1:${server.port}/globalsend-update-windows.json';
    expect((await feed.manifest(url))['build'], 1);
    expect((await feed.manifest(url))['build'], 1);
    revision = 2;
    expect((await feed.manifest(url))['build'], 2);
    expect(requests, 3);
    expect(incoming, [null, '"1"', '"1"']);
  });
}
