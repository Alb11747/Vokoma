import 'package:flutter_test/flutter_test.dart';
import 'package:vokoma/api/api.dart';
import 'package:vokoma/api/token_store.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late MemoryTokenStore store;

  setUp(() async {
    server = await FakeServer.start();
    store = MemoryTokenStore();
  });
  tearDown(() => server.close());

  Future<Api> login() => Api.login(
    server: server.uri,
    username: FakeServer.username,
    password: FakeServer.password,
    deviceName: 'test',
    platform: 'windows',
    store: store,
  );

  group('parseServerAddress', () {
    test('defaults to https and keeps a base path', () {
      expect(Api.parseServerAddress(' media.example:8443/vokoma/ ').toString(), 'https://media.example:8443/vokoma');
      expect(Api.parseServerAddress('http://10.0.0.2').toString(), 'http://10.0.0.2');
    });

    test('refuses credentials and other schemes', () {
      expect(() => Api.parseServerAddress('https://u:p@media.example'), throwsFormatException);
      expect(() => Api.parseServerAddress('ftp://media.example'), throwsFormatException);
      expect(() => Api.parseServerAddress(''), throwsFormatException);
    });

    test('API routes go under the base path', () async {
      final api = Api.restore(store);
      expect(await api, isNull);
      store.session = StoredSession(
        server: Api.parseServerAddress('https://media.example/vokoma'),
        refreshToken: 'r',
        deviceId: 'd',
      );
      expect(
        (await Api.restore(store))!.contentUri('f 1').toString(),
        'https://media.example/vokoma/api/files/f%201/content',
      );
    });
  });

  test('server info', () async {
    final info = await Api.fetchServerInfo(server.uri);
    expect((info.name, info.apiVersion), ('Test', 1));
  });

  test('login stores the refresh token and device id, not the access token', () async {
    final api = await login();
    expect(store.session!.refreshToken, server.validRefresh);
    expect(store.session!.deviceId, 'dev-1');
    expect(api.deviceId, 'dev-1');
  });

  test('wrong password is a 401 ApiException with the server code', () async {
    await expectLater(
      Api.login(
        server: server.uri,
        username: 'user',
        password: 'nope',
        deviceName: 'x',
        platform: 'windows',
        store: store,
      ),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.code, 'code', 'invalid_credentials'),
      ),
    );
    expect(store.session, isNull);
  });

  test('roots and entries parse, folders and files', () async {
    final api = await login();
    final roots = await api.roots();
    expect(roots.single.kind, 'anime');
    final listing = await api.entries('r1', path: 'Season 1/Extras');
    expect(listing.path, 'Season 1/Extras');
    expect(listing.entries[0], isA<FolderEntry>());
    final a = listing.entries[1] as FileEntry;
    expect((a.fileId, a.duration), ('f1', const Duration(minutes: 24)));
    expect((listing.entries[2] as FileEntry).duration, isNull);
    expect(server.requests.last.uri.queryParameters['path'], 'Season 1/Extras');
  });

  test('server errors surface their code', () async {
    final api = await login();
    await expectLater(
      api.entries('r1', path: '../x'),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'unsafe_path')),
    );
  });

  test('a 401 refreshes once, rotates and persists the refresh token, and retries', () async {
    final api = await login();
    final firstRefresh = store.session!.refreshToken;
    server.expireAccessTokens();
    expect((await api.roots()).length, 1);
    expect(server.refreshCalls, 1);
    expect(store.session!.refreshToken, isNot(firstRefresh));
    expect(store.session!.refreshToken, server.validRefresh);
  });

  test('parallel requests with an expired token share one refresh', () async {
    final api = await login();
    server.expireAccessTokens();
    server.refreshDelay = const Duration(milliseconds: 50);
    await Future.wait([api.roots(), api.entries('r1'), api.roots(), api.entries('r1')]);
    expect(server.refreshCalls, 1);
  });

  test('refreshes before the access token expires', () async {
    server.accessTtlSeconds = 900;
    final api = await login();
    var clock = DateTime.now();
    api.now = () => clock;
    await api.roots();
    expect(server.refreshCalls, 0);
    clock = clock.add(const Duration(minutes: 14, seconds: 30));
    await api.roots();
    expect(server.refreshCalls, 1);
  });

  test('a restored session refreshes on first use', () async {
    await login();
    final restored = (await Api.restore(store))!;
    expect((await restored.roots()).length, 1);
    expect(server.refreshCalls, 1);
  });

  test('a rejected refresh token signs out and clears the store', () async {
    final api = await login();
    var signedOut = 0;
    api.onSignedOut = () => signedOut++;
    server.expireAccessTokens();
    server.validRefresh = null; // revoked on the server
    await expectLater(api.roots(), throwsA(isA<SessionExpiredException>()));
    expect(signedOut, 1);
    expect(store.session, isNull);
    await expectLater(api.roots(), throwsA(isA<SessionExpiredException>()));
    expect(server.refreshCalls, 1);
  });

  test('logout revokes on the server and clears the store', () async {
    final api = await login();
    await api.logout();
    expect(server.logoutCalls, 1);
    expect(store.session, isNull);
  });

  test('logout clears the store even when the server is unreachable', () async {
    final api = await login();
    await server.close();
    await expectLater(api.logout(), throwsA(anything));
    expect(store.session, isNull);
  });

  test('tokens only ever travel in headers', () async {
    final api = await login();
    server.expireAccessTokens();
    await api.roots();
    await api.entries('r1', path: 'Season 1');
    final tokens = {...server.validAccess, server.validRefresh!, 'access-1', 'refresh-2'};
    for (final r in server.requests) {
      for (final t in tokens) {
        expect(r.uri.toString(), isNot(contains(t)));
      }
    }
    expect(
      server.requests.where((r) => r.uri.path == '/api/roots').every((r) => r.auth!.startsWith('Bearer access-')),
      isTrue,
    );
  });
}
