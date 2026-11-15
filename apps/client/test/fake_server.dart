import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vokoma/api/token_store.dart';

/// A small in-process stand-in for the M0 server API (docs/milestones/M0.md),
/// enough to exercise the client: login, rotating refresh tokens, listings
/// and ranged file content. Tokens are opaque counters.
class FakeServer {
  FakeServer._(this._server) {
    _server.listen(_handle);
  }

  static const username = 'user';
  static const password = 'secret';

  static Future<FakeServer> start() async => FakeServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  int accessTtlSeconds = 900;

  /// The bytes of file `f1`.
  Uint8List content = Uint8List.fromList(List.generate(256 * 1024, (i) => i % 251));

  final validAccess = <String>{};
  String? validRefresh;
  int refreshCalls = 0;
  int logoutCalls = 0;
  int _counter = 0;

  // Like the real server, a retry with the previous refresh token within 60 s
  // of rotating it gets the same new refresh token (and a new access token).
  String? _previousRefresh;
  DateTime _previousRefreshUntil = DateTime(0);

  /// Every request: method, full URI, Authorization and Accept-Encoding.
  final requests = <({String method, Uri uri, String? auth, String? acceptEncoding})>[];

  /// Bodies of benchmark uploads received.
  final benchmarkUploads = <Map<String, dynamic>>[];

  /// Completes with the number of bytes written when a content response
  /// ends, early or not.
  final contentResponses = StreamController<({int written, bool complete})>.broadcast();

  /// Pause after each 4 KB content chunk, to model a slow network.
  Duration chunkDelay = Duration.zero;

  /// Delays each refresh response, to let parallel callers pile up.
  Duration refreshDelay = Duration.zero;

  Uri get uri => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);

  /// Makes every access token issued so far invalid, as after 15 minutes.
  void expireAccessTokens() => validAccess.clear();

  Future<void> close() async {
    await _server.close(force: true);
    await contentResponses.close();
  }

  Map<String, Object> _grant({String? refresh}) {
    final access = 'access-${++_counter}';
    refresh ??= 'refresh-${++_counter}';
    validAccess.add(access);
    validRefresh = refresh;
    return {'accessToken': access, 'expiresInSeconds': accessTtlSeconds, 'refreshToken': refresh, 'deviceId': 'dev-1'};
  }

  Future<void> _handle(HttpRequest request) async {
    final auth = request.headers.value('authorization');
    requests.add((
      method: request.method,
      uri: request.uri,
      auth: auth,
      acceptEncoding: request.headers.value('accept-encoding'),
    ));
    final path = request.uri.path;
    final res = request.response;

    if (path == '/api/server') return _json(res, 200, {'name': 'Test', 'version': '0.0.0', 'apiVersion': 1});

    if (path == '/api/auth/login' && request.method == 'POST') {
      final body = await _body(request);
      if (body['username'] != username || body['password'] != password) {
        return _error(res, 401, 'invalid_credentials');
      }
      return _json(res, 200, _grant());
    }

    if (path == '/api/auth/refresh' && request.method == 'POST') {
      refreshCalls++;
      final body = await _body(request);
      await Future<void>.delayed(refreshDelay);
      final presented = body['refreshToken'];
      if (presented == validRefresh && presented != null) {
        _previousRefresh = presented as String;
        _previousRefreshUntil = DateTime.now().add(const Duration(seconds: 60));
        return _json(res, 200, _grant());
      }
      // validRefresh is null once the device is revoked, which ends the grace.
      if (presented == _previousRefresh && validRefresh != null && DateTime.now().isBefore(_previousRefreshUntil)) {
        return _json(res, 200, _grant(refresh: validRefresh));
      }
      return _error(res, 401, 'invalid_token');
    }

    final token = auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null;
    if (token == null || !validAccess.contains(token)) return _error(res, 401, 'invalid_token');

    if (path == '/api/auth/logout' && request.method == 'POST') {
      logoutCalls++;
      validAccess.clear();
      validRefresh = null;
      res.statusCode = 204;
      return res.close();
    }

    if (path == '/api/roots') {
      return _json(res, 200, {
        'roots': [
          {'id': 'r1', 'name': 'Anime', 'kind': 'anime'},
        ],
      });
    }

    if (path == '/api/roots/r1/entries') {
      final folder = request.uri.queryParameters['path'] ?? '';
      if (folder.contains('..')) return _error(res, 400, 'unsafe_path');
      return _json(res, 200, {
        'path': folder,
        'entries': [
          {'name': 'Season 1', 'type': 'folder'},
          {'name': 'a.mkv', 'type': 'file', 'fileId': 'f1', 'sizeBytes': content.length, 'durationMs': 1440000},
          {'name': 'b.ts', 'type': 'file', 'fileId': 'f2', 'sizeBytes': 10},
        ],
      });
    }

    if (path == '/api/files/f1/content') return _content(request);

    if (path == '/api/diagnostics/benchmark' && request.method == 'POST') {
      benchmarkUploads.add(await _body(request));
      return _json(res, 201, {'name': 'benchmark-1.jsonl'});
    }

    return _error(res, 404, 'not_found');
  }

  Future<void> _content(HttpRequest request) async {
    final res = request.response;
    var start = 0, end = content.length - 1;
    final range = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(request.headers.value('range') ?? '');
    res.headers.set('accept-ranges', 'bytes');
    res.headers.contentType = ContentType.binary;
    if (range != null) {
      start = int.parse(range[1]!);
      if (range[2]!.isNotEmpty) end = int.parse(range[2]!);
      res.statusCode = 206;
      res.headers.set('content-range', 'bytes $start-$end/${content.length}');
    }
    res.contentLength = end - start + 1;
    if (request.method == 'HEAD') return res.close();
    // Write the body on the raw socket: in testing, HttpResponse.flush() never
    // reported a client that had hung up, and the hang-up test must see it.
    final socket = await res.detachSocket();
    var gone = false;
    socket.listen((_) {}, onDone: () => gone = true, onError: (Object _) => gone = true);
    var written = 0;
    try {
      for (var i = start; i <= end && !gone; i += 4096) {
        final chunk = content.sublist(i, i + 4096 > end + 1 ? end + 1 : i + 4096);
        socket.add(chunk);
        await socket.flush();
        written += chunk.length;
        // Yield so a hang-up is noticed even without a delay.
        await Future<void>.delayed(chunkDelay);
      }
      await socket.close();
    } on SocketException {
      gone = true;
    }
    contentResponses.add((written: written, complete: !gone && written == end - start + 1));
  }

  static Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;

  static Future<void> _json(HttpResponse res, int status, Object body) {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    return res.close();
  }

  static Future<void> _error(HttpResponse res, int status, String code) => _json(res, status, {
    'error': {'code': code, 'message': 'fake $code'},
  });
}

class MemoryTokenStore implements TokenStore {
  StoredSession? session;
  int writes = 0;

  @override
  Future<StoredSession?> read() async => session;

  @override
  Future<void> write(StoredSession value) async {
    session = value;
    writes++;
  }

  @override
  Future<void> clear() async => session = null;
}
