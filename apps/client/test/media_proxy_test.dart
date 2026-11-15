import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vokoma/api/api.dart';
import 'package:vokoma/api/media_proxy.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late Api api;
  late MediaProxy proxy;
  late HttpClient client;

  setUp(() async {
    server = await FakeServer.start();
    api = await Api.login(
      server: server.uri,
      username: FakeServer.username,
      password: FakeServer.password,
      deviceName: 'test',
      platform: 'android',
      store: MemoryTokenStore(),
    );
    proxy = await MediaProxy.start(api);
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.close();
    await server.close();
  });

  Future<HttpClientResponse> get(Uri uri, {Map<String, String> headers = const {}}) async {
    final request = await client.getUrl(uri);
    headers.forEach(request.headers.set);
    return request.close();
  }

  Future<List<int>> bytesOf(HttpClientResponse r) async => [for (final chunk in await r.toList()) ...chunk];

  test('the player URL holds no token and points at loopback', () {
    final uri = proxy.uriFor('f1');
    expect(uri.host, '127.0.0.1');
    expect(uri.hasQuery, isFalse);
    expect(uri.toString(), isNot(contains('access')));
  });

  test('refuses requests without the per-run secret', () async {
    expect((await get(proxy.uriFor('f1'))).statusCode, 403);
    expect((await get(proxy.uriFor('f1'), headers: {'authorization': 'Bearer wrong'})).statusCode, 403);
    expect(server.requests.where((r) => r.uri.path.contains('/content')), isEmpty);
  });

  test('only file content is reachable', () async {
    final r = await get(proxy.uriFor('f1').replace(path: '/roots'), headers: proxy.playerHeaders);
    expect(r.statusCode, 404);
  });

  test('forwards ranges with the real access token', () async {
    final r = await get(proxy.uriFor('f1'), headers: {...proxy.playerHeaders, 'range': 'bytes=1000-1999'});
    expect(r.statusCode, 206);
    expect(r.headers.value('content-range'), 'bytes 1000-1999/${server.content.length}');
    expect(r.headers.value('accept-ranges'), 'bytes');
    expect(await bytesOf(r), server.content.sublist(1000, 2000));
    final upstream = server.requests.last;
    expect(upstream.uri.path, '/api/files/f1/content');
    expect(upstream.auth, startsWith('Bearer access-'));
    // The proxy drops Content-Encoding, so it must not ask for gzip.
    expect(upstream.acceptEncoding, 'identity');
  });

  test('keeps serving after the access token expires mid-playback', () async {
    final first = await get(proxy.uriFor('f1'), headers: {...proxy.playerHeaders, 'range': 'bytes=0-99'});
    await bytesOf(first);
    server.expireAccessTokens(); // fifteen minutes later
    final seek = await get(proxy.uriFor('f1'), headers: {...proxy.playerHeaders, 'range': 'bytes=200000-200099'});
    expect(seek.statusCode, 206);
    expect(await bytesOf(seek), server.content.sublist(200000, 200100));
    expect(server.refreshCalls, 1);
  });

  test('a player hang-up stops the upstream transfer', () async {
    // A transfer that takes about ten seconds unless it is cut short.
    server.content = Uint8List(4 * 1024 * 1024);
    server.chunkDelay = const Duration(milliseconds: 10);
    final done = server.contentResponses.stream.first;
    final r = await get(proxy.uriFor('f1'), headers: proxy.playerHeaders);
    final socket = await r.detachSocket();
    await socket.first; // some bytes arrived
    socket.destroy();
    final result = await done.timeout(const Duration(seconds: 5));
    expect(result.complete, isFalse);
    expect(result.written, lessThan(server.content.length));
  });
}
