import 'dart:async';

/// In-memory cache and in-flight request deduplicator for extraction results (T01).
///
/// Ensures exactly one extraction is performed per URL within [defaultTtl].
/// Results are cached and shared across FormatPickerScreen, Share Intent (T04),
/// auto-download (T02), and in-app preview (T08).
class ExtractionCache {
  ExtractionCache._();
  static final ExtractionCache instance = ExtractionCache._();

  static const Duration defaultTtl = Duration(minutes: 30);

  final Map<String, _CachedExtraction> _cache = {};
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};

  /// Retrieves cached extraction data for [url] if present and not expired.
  Map<String, dynamic>? get(String url) {
    final entry = _cache[url];
    if (entry == null) return null;
    if (DateTime.now().isAfter(entry.expiresAt)) {
      _cache.remove(url);
      return null;
    }
    return entry.data;
  }

  /// Stores extraction data for [url] with an expiration [ttl].
  void put(String url, Map<String, dynamic> data, [Duration ttl = defaultTtl]) {
    _cache[url] = _CachedExtraction(
      data: data,
      expiresAt: DateTime.now().add(ttl),
    );
  }

  /// Returns true if [url] has an active, unexpired cache entry.
  bool has(String url) => get(url) != null;

  /// Fetches extraction data for [url], reusing an unexpired cache entry or
  /// joining an in-flight future if already in progress.
  Future<Map<String, dynamic>> getOrFetch(
    String url,
    Future<Map<String, dynamic>> Function() fetcher, {
    Duration ttl = defaultTtl,
  }) async {
    final cached = get(url);
    if (cached != null) return cached;

    final existingFuture = _inFlight[url];
    if (existingFuture != null) {
      return existingFuture;
    }

    final future = fetcher();
    _inFlight[url] = future;

    try {
      final result = await future;
      if (result['success'] == true) {
        put(url, result, ttl);
      }
      return result;
    } finally {
      _inFlight.remove(url);
    }
  }

  /// Explicitly evicts [url] from the cache.
  void remove(String url) {
    _cache.remove(url);
    _inFlight.remove(url);
  }

  /// Clears all cached extraction data and in-flight tracking.
  void clear() {
    _cache.clear();
    _inFlight.clear();
  }
}

class _CachedExtraction {
  final Map<String, dynamic> data;
  final DateTime expiresAt;

  _CachedExtraction({required this.data, required this.expiresAt});
}
