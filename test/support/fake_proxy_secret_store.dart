import 'package:grablytic/core/storage/proxy_secret_store.dart';

class FakeProxySecretStore implements ProxySecretStore {
  FakeProxySecretStore({this.value});

  String? value;
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> readProxy() async {
    if (failReads) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> writeProxy(String? proxy) async {
    if (failWrites) throw StateError('write failed');
    value = proxy;
  }
}
