import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'token_store.dart';

/// Client for the M0 server API (docs/milestones/M0.md).
///
/// Hand-written for M0. Once `contracts/openapi.json` is on main, this is
/// replaced by the generated Dart client (docs/ARCHITECTURE.md, section 5).
///
/// Tokens: the access token lives in memory only; the refresh token and
/// device id are kept in the platform keystore through [TokenStore]. Tokens
/// are only ever sent in the `Authorization` header and never logged.
class Api {
  Api._(this.server, this._store, this._http, this._session);

  /// Refresh this long before the access token expires, so a request started
  /// just before expiry does not need a second round trip.
  static const refreshMargin = Duration(seconds: 60);

  final Uri server;
  final TokenStore _store;
  final http.Client _http;
  StoredSession _session;

  String? _accessToken;
  DateTime _accessExpiry = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String>? _refreshing;
  bool _signedOut = false;

  /// The refresh's session write in progress, if any.
  Future<void>? _writing;

  /// Called once when the server rejects the refresh token, which means the
  /// device was revoked or the token expired and the user must log in again.
  void Function()? onSignedOut;

  /// Overridable clock for tests.
  DateTime Function() now = DateTime.now;

  /// Accepts `host`, `host:port` or a full URL with an optional base path.
  /// A missing scheme means https.
  static Uri parseServerAddress(String input) {
    var text = input.trim();
    if (text.isEmpty) throw const FormatException('Enter the server address.');
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.parse(text);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('The address must start with http:// or https://.');
    }
    if (uri.host.isEmpty) throw const FormatException('The address has no host.');
    if (uri.userInfo.isNotEmpty) {
      // Credentials never go in URLs (AGENTS.md).
      throw const FormatException('Do not put a user name or password in the address.');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, pathSegments: segments);
  }

  /// `GET /api/server`, used to check the address before logging in.
  static Future<ServerInfo> fetchServerInfo(Uri server, {http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final json = _decode(await c.get(_apiUri(server, ['server'])));
      return ServerInfo.fromJson(json);
    } finally {
      if (client == null) c.close();
    }
  }

  /// `POST /api/auth/login`. Stores the session and returns a signed-in [Api].
  static Future<Api> login({
    required Uri server,
    required String username,
    required String password,
    required String deviceName,
    required String platform,
    required TokenStore store,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    try {
      final json = _decode(
        await c.post(
          _apiUri(server, ['auth', 'login']),
          headers: _jsonHeaders,
          body: jsonEncode({
            'username': username,
            'password': password,
            'deviceName': deviceName,
            'platform': platform,
          }),
        ),
      );
      final grant = TokenGrant.fromJson(json);
      final session = StoredSession(server: server, refreshToken: grant.refreshToken, deviceId: grant.deviceId);
      await store.write(session);
      return Api._(server, store, c, session).._accept(grant);
    } catch (_) {
      if (client == null) c.close();
      rethrow;
    }
  }

  /// Builds an [Api] from a stored session without contacting the server.
  /// The first request refreshes the access token.
  static Future<Api?> restore(TokenStore store, {http.Client? client}) async {
    final session = await store.read();
    if (session == null) return null;
    return Api._(session.server, store, client ?? http.Client(), session);
  }

  String get deviceId => _session.deviceId;

  Future<List<MediaRoot>> roots() async {
    final json = await _getJson(['roots']);
    return [for (final r in json['roots'] as List) MediaRoot.fromJson(r as Map<String, dynamic>)];
  }

  /// `GET /api/roots/{rootId}/entries?path=`. An empty [path] means the root.
  Future<Listing> entries(String rootId, {String path = ''}) async {
    final json = await _getJson(['roots', rootId, 'entries'], query: path.isEmpty ? null : {'path': path});
    return Listing.fromJson(json);
  }

  /// `POST /api/diagnostics/benchmark`: stores the engine benchmark results
  /// file ([content], JSON Lines) on the server. Returns the server's file name.
  Future<String> uploadBenchmark({required String content, required String device, required String appVersion}) async {
    final json = await _postJson(
      ['diagnostics', 'benchmark'],
      {'device': device, 'appVersion': appVersion, 'content': content},
    );
    return json['name'] as String;
  }

  /// URL of a file's bytes. It carries no credentials; requests to it need
  /// the `Authorization` header like every other route.
  Uri contentUri(String fileId) => _apiUri(server, ['files', fileId, 'content']);

  /// `POST /api/auth/logout`, which revokes this device. The local session is
  /// cleared even when the request fails; the error is rethrown so the caller
  /// can say that the server did not confirm the revocation.
  Future<void> logout() async {
    try {
      final token = await accessToken();
      final response = await _http.post(_apiUri(server, ['auth', 'logout']), headers: _auth(token));
      if (response.statusCode != 204) _decode(response);
    } finally {
      await _signOut(notify: false);
    }
  }

  /// A currently valid access token, refreshing it first when it is missing
  /// or about to expire.
  Future<String> accessToken() async {
    final token = _accessToken;
    if (token != null && now().isBefore(_accessExpiry.subtract(refreshMargin))) return token;
    return _refresh();
  }

  /// Called after the server rejected [rejected] with 401. Refreshes unless
  /// another caller already replaced that token, and returns the new one.
  Future<String> accessTokenAfterRejection(String rejected) async {
    final current = _accessToken;
    if (current != null && current != rejected) return current;
    _accessToken = null;
    return _refresh();
  }

  void close() => _http.close();

  // One refresh at a time: the refresh token rotates, so two parallel
  // refreshes would race and the loser would present a spent token.
  Future<String> _refresh() => _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<String> _doRefresh() async {
    if (_signedOut) throw const SessionExpiredException();
    final response = await _http.post(
      _apiUri(server, ['auth', 'refresh']),
      headers: _jsonHeaders,
      body: jsonEncode({'refreshToken': _session.refreshToken}),
    );
    if (response.statusCode == 401) {
      await _signOut(notify: true);
      throw const SessionExpiredException();
    }
    final grant = TokenGrant.fromJson(_decode(response));
    // Logout may have started while the request was in flight. Its clear must
    // win: neither store nor use what the server sent.
    if (_signedOut) throw const SessionExpiredException();
    _session = StoredSession(server: server, refreshToken: grant.refreshToken, deviceId: grant.deviceId);
    // Persist the rotated token before using the new access token. If this
    // write fails, the error surfaces; the server still accepts the previous
    // refresh token for a short grace period. _signOut waits for this write
    // before clearing, so a logout during it still leaves the store empty.
    final write = _writing = _store.write(_session);
    try {
      await write;
    } finally {
      _writing = null;
    }
    if (_signedOut) throw const SessionExpiredException();
    _accept(grant);
    return grant.accessToken;
  }

  void _accept(TokenGrant grant) {
    _accessToken = grant.accessToken;
    _accessExpiry = now().add(Duration(seconds: grant.expiresInSeconds));
  }

  Future<void> _signOut({required bool notify}) async {
    if (_signedOut) return;
    _signedOut = true;
    _accessToken = null;
    // Clear after a refresh's write in progress, or that write would restore
    // the session. Its error, if any, is reported to the refresh's caller.
    await _writing?.then((_) {}, onError: (Object _) {});
    await _store.clear();
    if (notify) onSignedOut?.call();
  }

  Future<Map<String, dynamic>> _getJson(List<String> path, {Map<String, String>? query}) async {
    final uri = _apiUri(server, path, query: query);
    var token = await accessToken();
    var response = await _http.get(uri, headers: _auth(token));
    if (response.statusCode == 401) {
      token = await accessTokenAfterRejection(token);
      response = await _http.get(uri, headers: _auth(token));
    }
    return _decode(response);
  }

  Future<Map<String, dynamic>> _postJson(List<String> path, Map<String, Object?> body) async {
    final uri = _apiUri(server, path);
    final encoded = utf8.encode(jsonEncode(body));
    Future<http.Response> send(String token) =>
        _http.post(uri, headers: {..._auth(token), ..._jsonHeaders}, body: encoded);
    var token = await accessToken();
    var response = await send(token);
    if (response.statusCode == 401) {
      token = await accessTokenAfterRejection(token);
      response = await send(token);
    }
    return _decode(response);
  }

  static Map<String, String> _auth(String token) => {'Authorization': 'Bearer $token'};

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  static Uri _apiUri(Uri server, List<String> path, {Map<String, String>? query}) =>
      server.replace(pathSegments: [...server.pathSegments, 'api', ...path], queryParameters: query);

  static Map<String, dynamic> _decode(http.Response response) {
    final status = response.statusCode;
    Object? body;
    try {
      body = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    if (status >= 200 && status < 300 && body is Map<String, dynamic>) return body;
    if (body is Map<String, dynamic> && body['error'] is Map<String, dynamic>) {
      final error = body['error'] as Map<String, dynamic>;
      throw ApiException(status, error['code'] as String? ?? 'unknown', error['message'] as String? ?? '');
    }
    throw ApiException(status, 'bad_response', 'Unexpected response from the server (HTTP $status).');
  }
}

class ApiException implements Exception {
  const ApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => message.isEmpty ? 'Server error $code (HTTP $statusCode)' : message;
}

/// The server no longer accepts this device's refresh token.
class SessionExpiredException implements Exception {
  const SessionExpiredException();

  @override
  String toString() => 'Signed out: log in again.';
}

class ServerInfo {
  const ServerInfo({required this.name, required this.version, required this.apiVersion});

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
    name: json['name'] as String,
    version: json['version'] as String,
    apiVersion: (json['apiVersion'] as num).toInt(),
  );

  final String name;
  final String version;
  final int apiVersion;
}

class TokenGrant {
  const TokenGrant(this.accessToken, this.expiresInSeconds, this.refreshToken, this.deviceId);

  factory TokenGrant.fromJson(Map<String, dynamic> json) => TokenGrant(
    json['accessToken'] as String,
    (json['expiresInSeconds'] as num).toInt(),
    json['refreshToken'] as String,
    json['deviceId'] as String,
  );

  final String accessToken;
  final int expiresInSeconds;
  final String refreshToken;
  final String deviceId;
}

class MediaRoot {
  const MediaRoot({required this.id, required this.name, required this.kind});

  factory MediaRoot.fromJson(Map<String, dynamic> json) =>
      MediaRoot(id: json['id'] as String, name: json['name'] as String, kind: json['kind'] as String);

  final String id;
  final String name;

  /// `anime`, `stream`, `movie` or `tv`.
  final String kind;
}

class Listing {
  const Listing({required this.path, required this.entries});

  factory Listing.fromJson(Map<String, dynamic> json) => Listing(
    path: json['path'] as String,
    entries: [for (final e in json['entries'] as List) Entry.fromJson(e as Map<String, dynamic>)],
  );

  /// Relative to the root, normalised by the server, '' for the root itself.
  final String path;
  final List<Entry> entries;
}

sealed class Entry {
  const Entry(this.name);

  factory Entry.fromJson(Map<String, dynamic> json) => switch (json['type']) {
    'folder' => FolderEntry(json['name'] as String),
    'file' => FileEntry(
      json['name'] as String,
      fileId: json['fileId'] as String,
      sizeBytes: (json['sizeBytes'] as num).toInt(),
      duration: json['durationMs'] == null ? null : Duration(milliseconds: (json['durationMs'] as num).round()),
    ),
    final type => throw FormatException('Unknown entry type: $type'),
  };

  final String name;
}

class FolderEntry extends Entry {
  const FolderEntry(super.name);
}

class FileEntry extends Entry {
  const FileEntry(super.name, {required this.fileId, required this.sizeBytes, this.duration});

  final String fileId;
  final int sizeBytes;
  final Duration? duration;
}
