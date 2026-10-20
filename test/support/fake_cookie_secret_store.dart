import 'package:grablytic/core/storage/cookie_secret_store.dart';

/// In-memory cookie secret store for unit tests.
class FakeCookieSecretStore implements CookieSecretStore {
  FakeCookieSecretStore({Map<String, List<String>>? seed})
      : stored = {...?seed};

  final Map<String, List<String>> stored;
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<Map<String, List<String>>> readAll() async {
    if (failReads) throw StateError('read failed');
    return {
      for (final entry in stored.entries) entry.key: [...entry.value],
    };
  }

  @override
  Future<void> write(String id, List<String> lines) async {
    if (failWrites) throw StateError('write failed');
    stored[id] = [...lines];
  }

  @override
  Future<void> delete(String id) async {
    stored.remove(id);
  }

  @override
  Future<void> clear() async {
    stored.clear();
  }
}
