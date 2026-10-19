import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The single secure-storage boundary for the user's proxy URL.
///
/// The Android implementation is supplied by flutter_secure_storage and uses
/// Android Keystore-backed encryption; callers must not mirror the value into
/// SharedPreferences or download-history JSON.
abstract interface class ProxySecretStore {
  Future<String?> readProxy();
  Future<void> writeProxy(String? proxy);
}

class FlutterSecureProxySecretStore implements ProxySecretStore {
  FlutterSecureProxySecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? FlutterSecureStorage();

  static const _key = 'proxy_url';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readProxy() => _storage.read(key: _key);

  @override
  Future<void> writeProxy(String? proxy) async {
    if (proxy == null || proxy.isEmpty) {
      await _storage.delete(key: _key);
    } else {
      await _storage.write(key: _key, value: proxy);
    }
  }
}
