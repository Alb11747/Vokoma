import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What survives a restart: the server, this device's refresh token and id.
class StoredSession {
  const StoredSession({required this.server, required this.refreshToken, required this.deviceId});

  final Uri server;
  final String refreshToken;
  final String deviceId;
}

/// Persists the session. The real implementation is [SecureTokenStore]; tests
/// use an in-memory one.
abstract interface class TokenStore {
  Future<StoredSession?> read();
  Future<void> write(StoredSession session);
  Future<void> clear();
}

/// Keeps the session in the platform keystore: on Windows a DPAPI-encrypted
/// file whose key is held in Credential Manager, on Android values encrypted
/// with a key held in the Android Keystore (flutter_secure_storage).
class SecureTokenStore implements TokenStore {
  SecureTokenStore([this._storage = const FlutterSecureStorage()]);

  static const _key = 'vokoma.session';
  final FlutterSecureStorage _storage;

  @override
  Future<StoredSession?> read() async {
    final text = await _storage.read(key: _key);
    if (text == null) return null;
    final json = jsonDecode(text) as Map<String, dynamic>;
    return StoredSession(
      server: Uri.parse(json['server'] as String),
      refreshToken: json['refreshToken'] as String,
      deviceId: json['deviceId'] as String,
    );
  }

  @override
  Future<void> write(StoredSession session) => _storage.write(
    key: _key,
    value: jsonEncode({
      'server': session.server.toString(),
      'refreshToken': session.refreshToken,
      'deviceId': session.deviceId,
    }),
  );

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
