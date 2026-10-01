import 'dart:io' show Directory, File, HttpClient;

/// App-private thumbnail prefetch cache (T07).
///
/// Independent of the save-thumbnail setting: at job creation the provider
/// fire-and-forgets one fetch of [thumbnailUrl] into
/// `<docs>/thumbnails/<id>.jpg` and records the path on the item/DB.
/// UI renders [FileImage] (ImageCache-backed, no per-rebuild fetch) with
/// network/placeholder fallbacks. Never throws; never blocks the UI.
class ThumbnailCache {
  /// Subdirectory under the app documents dir.
  static const String subdir = 'thumbnails';

  /// Max accepted payload (2 MB); larger bodies are abandoned.
  static const int maxBytes = 2 * 1024 * 1024;

  /// Filesystem-safe cache file name for a download id.
  static String fileNameFor(String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final trimmed = safe.isEmpty ? 'thumb' : safe;
    final capped = trimmed.length > 64 ? trimmed.substring(0, 64) : trimmed;
    return '$capped.jpg';
  }

  /// Fetch [url] into the cache dir for [id]; returns the file path or null.
  /// Fire-and-forget from the provider via [unawaited] (async IO only).
  static Future<String?> fetchToCache({
    required String cacheDir,
    required String id,
    required String url,
  }) async {
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }
    HttpClient? client;
    try {
      final dir = Directory(cacheDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final dest = File('${dir.path}/${fileNameFor(id)}');
      if (await dest.exists()) return dest.path;
      client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      final mime = res.headers.contentType?.mimeType ?? '';
      if (mime.isNotEmpty && !mime.startsWith('image/')) return null;
      if (res.contentLength > maxBytes) return null;
      final sink = dest.openWrite();
      var bytes = 0;
      var tooBig = false;
      await for (final chunk in res) {
        bytes += chunk.length;
        if (bytes > maxBytes) {
          tooBig = true;
          break;
        }
        sink.add(chunk);
      }
      await sink.close();
      if (tooBig) {
        try {
          await dest.delete();
        } catch (_) {}
        return null;
      }
      return dest.path;
    } catch (_) {
      return null;
    } finally {
      try {
        client?.close(force: true);
      } catch (_) {}
    }
  }
}
