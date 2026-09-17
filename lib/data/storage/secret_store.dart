import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Seam over the platform keychain: injected so tests can substitute a mock
/// or an in-memory recording backend, and so the app can swap backends
/// without touching call sites.
abstract interface class SecureKeyValueBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Production backend backed by flutter_secure_storage (Keychain on macOS,
/// Credential Manager/Keystore on Android, DPAPI/libsecret on Windows/Linux).
class FlutterSecureBackend implements SecureKeyValueBackend {
  FlutterSecureBackend([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Stores secrets that must never touch shared_preferences, the agenda cache
/// file, or the local log: the OAuth refresh/access tokens and the ICS
/// bearer URL.
class SecretStore {
  SecretStore({SecureKeyValueBackend? backend})
      : _backend = backend ?? FlutterSecureBackend();

  static const String refreshTokenKey = 'oauth.refresh_token';
  static const String accessTokenKey = 'oauth.access_token';
  static const String icsBearerUrlKey = 'ics.bearer_url';

  final SecureKeyValueBackend _backend;

  Future<String?> readRefreshToken() => _backend.read(refreshTokenKey);

  Future<void> saveRefreshToken(String? value) => _store(refreshTokenKey, value);

  Future<String?> readAccessToken() => _backend.read(accessTokenKey);

  Future<void> saveAccessToken(String? value) => _store(accessTokenKey, value);

  /// The ICS URL may embed an authentication bearer parameter and is treated
  /// as a secret: stored securely and never logged.
  Future<String?> readIcsBearerUrl() => _backend.read(icsBearerUrlKey);

  Future<void> saveIcsBearerUrl(String? value) => _store(icsBearerUrlKey, value);

  Future<void> _store(String key, String? value) =>
      value == null ? _backend.delete(key) : _backend.write(key, value);

  /// Clears the OAuth credentials only (keeps the ICS URL).
  Future<void> clearAuth() async {
    await _backend.delete(refreshTokenKey);
    await _backend.delete(accessTokenKey);
  }

  Future<void> clearAll() async {
    await clearAuth();
    await _backend.delete(icsBearerUrlKey);
  }
}
