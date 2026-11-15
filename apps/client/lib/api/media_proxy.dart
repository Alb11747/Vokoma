import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// A loopback HTTP proxy that lets the player stream file bytes across
/// access-token refreshes.
///
/// Why: mpv (through FFmpeg) reads `http-header-fields` once when it opens a
/// file and reuses those headers for every later range request, including
/// the ones a seek makes an hour into a stream. Access tokens live 15
/// minutes, so a header holding the real token would start failing with 401
/// mid-playback, and mpv has no way to swap headers on an open stream.
///
/// So the player opens `http://127.0.0.1:<port>/files/<fileId>` and sends a
/// random per-run secret in its `Authorization` header (still through mpv's
/// header option, never in the URL). For each request the proxy checks that
/// secret, then forwards it to the server with the *current* access token
/// (refreshing after a 401) and streams the response back. The real tokens
/// never reach mpv, and only file content routes are reachable through it.
class MediaProxy {
  MediaProxy._(this._api, this._server, this._secret, this._client);

  final Api _api;
  final HttpServer _server;
  final String _secret;
  final HttpClient _client;

  static Future<MediaProxy> start(Api api) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final secret = base64Url.encode(List.generate(32, (_) => random.nextInt(256)));
    final client = HttpClient()..autoUncompress = false;
    final proxy = MediaProxy._(api, server, secret, client);
    server.listen(proxy._handle);
    return proxy;
  }

  /// Where the player should open [fileId].
  Uri uriFor(String fileId) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _server.port, pathSegments: ['files', fileId]);

  /// Headers the player must send with every request to [uriFor].
  Map<String, String> get playerHeaders => {'Authorization': 'Bearer $_secret'};

  Future<void> close() async {
    await _server.close(force: true);
    _client.close(force: true);
  }

  static const _forwardedRequestHeaders = ['range', 'if-range'];
  static const _forwardedResponseHeaders = ['content-type', 'content-range', 'accept-ranges', 'last-modified', 'etag'];

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (!_authorized(request.headers.value('authorization'))) {
        return _fail(response, HttpStatus.forbidden);
      }
      if ((request.method != 'GET' && request.method != 'HEAD') || segments.length != 2 || segments[0] != 'files') {
        return _fail(response, HttpStatus.notFound);
      }
      await _forward(request, segments[1]);
    } on SessionExpiredException {
      _fail(response, HttpStatus.unauthorized);
    } catch (error) {
      // The player sees a failed request and reports a playback error. The
      // cause (no network, server down) is not something the proxy can fix.
      debugPrint('MediaProxy: request failed: $error');
      _fail(response, HttpStatus.badGateway);
    }
  }

  Future<void> _forward(HttpRequest request, String fileId) async {
    final target = _api.contentUri(fileId);
    var token = await _api.accessToken();
    var upstream = await _send(request, target, token);
    if (upstream.statusCode == HttpStatus.unauthorized) {
      await upstream.drain<void>();
      token = await _api.accessTokenAfterRejection(token);
      upstream = await _send(request, target, token);
    }

    final response = request.response
      ..statusCode = upstream.statusCode
      ..contentLength = upstream.contentLength;
    for (final name in _forwardedResponseHeaders) {
      final value = upstream.headers.value(name);
      if (value != null) response.headers.set(name, value);
    }
    try {
      // addStream applies backpressure, so the proxy never buffers more than
      // the player reads. When the player hangs up (it seeked or stopped),
      // addStream ends early and cancels its subscription to the upstream
      // response, which closes that connection, so the server stops sending
      // the rest of the file (covered by a test).
      await response.addStream(upstream);
      await response.close();
    } on Object {
      // The player is gone; there is no one left to report to.
    }
  }

  Future<HttpClientResponse> _send(HttpRequest incoming, Uri target, String token) async {
    final request = await _client.openUrl(incoming.method, target);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    // The proxy does not forward Content-Encoding (autoUncompress is off so
    // byte ranges stay exact), so the body must arrive unencoded. HttpClient
    // asks for gzip by default.
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    for (final name in _forwardedRequestHeaders) {
      final value = incoming.headers.value(name);
      if (value != null) request.headers.set(name, value);
    }
    return request.close();
  }

  bool _authorized(String? header) {
    final expected = utf8.encode('Bearer $_secret');
    final actual = utf8.encode(header ?? '');
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  }

  static void _fail(HttpResponse response, int status) {
    response
      ..statusCode = status
      ..contentLength = 0;
    // close() fails when the player already hung up; nothing is left to tell it.
    unawaited(response.close().then((_) {}, onError: (Object _) {}));
  }
}
