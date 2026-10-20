import 'dart:io'
    show
        Directory,
        File,
        FileStat,
        FileSystemException,
        HttpClient,
        RandomAccessFile;

import 'package:flutter/foundation.dart' show debugPrint;

/// App-private thumbnail prefetch cache.
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
  ///
  /// Reuses an existing destination without validating it. New downloads must
  /// use HTTP(S), return status 200, fit within [maxBytes], and start with a
  /// JPEG header. A supplied content type must be an image type. Writes to a
  /// sibling `.part` file before renaming; returns null on rejection or error.
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

      // Write to a sibling temp file, validate, THEN promote. Writing the
      // final path directly meant a stream error or a killed isolate left
      // a truncated JPEG behind — and the next call's `dest.exists()`
      // check returned that fragment as a cache hit, for ever. A 200-byte
      // piece of a 40 KB thumbnail is indistinguishable from the real
      // thing once it is named `.jpg`.
      final tmp = File('${dest.path}.part');
      final sink = tmp.openWrite();
      var bytes = 0;
      var tooBig = false;
      var failed = false;
      try {
        await for (final chunk in res) {
          bytes += chunk.length;
          if (bytes > maxBytes) {
            tooBig = true;
            break;
          }
          sink.add(chunk);
        }
        await sink.flush();
      } on Object catch (error) {
        // Deliberately broad: the body awaits a socket AND a file, so a
        // failure can be SocketException, HttpException, TimeoutException
        // or FileSystemException. Any of them means "no thumbnail".
        debugPrint('[thumbnails] fetch failed: $error');
        failed = true;
      } finally {
        try {
          await sink.close();
        } on FileSystemException {
          // Already in the failure path; a close error must not mask it.
        }
      }

      if (failed || tooBig || bytes == 0) {
        await _deleteQuietly(tmp);
        return null;
      }
      if (!await _looksLikeJpeg(tmp)) {
        await _deleteQuietly(tmp);
        return null;
      }
      try {
        await tmp.rename(dest.path);
      } on FileSystemException {
        await _deleteQuietly(tmp);
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

  /// True when [file] starts with the JPEG SOI marker.
  ///
  /// Checks only the first three bytes, not whether the image is complete
  /// or decodable. Returns false for unreadable files and non-JPEG headers.
  static Future<bool> _looksLikeJpeg(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final magic = await raf.read(3);
      return magic.length == 3 &&
          magic[0] == 0xFF &&
          magic[1] == 0xD8 &&
          magic[2] == 0xFF;
    } on FileSystemException {
      // Unreadable is the same outcome as truncated: no thumbnail.
      return false;
    } finally {
      try {
        await raf?.close();
      } on FileSystemException {
        // Handle already released by the OS.
      }
    }
  }

  /// Delete [file] if present, suppressing filesystem errors.
  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort: a file another process still holds is retried next
      // prune, and there is nothing useful to do with the error here.
    }
  }

  /// Prune `.jpg` files in [cacheDir], ignoring subdirectories and other files.
  ///
  /// Retain names whose stem is in [liveIds], then evict by oldest modification
  /// time toward [maxTotalBytes] (default 64 MiB). Stems are compared directly,
  /// so IDs must match the sanitized, capped names produced by [fileNameFor].
  ///
  /// Returns the number of deletion attempts, including suppressed failures.
  /// Unreadable files and failed deletions can leave the cache above budget.
  /// A missing directory returns zero; errors return the count reached so far.
  static Future<int> prune({
    required String cacheDir,
    required Set<String> liveIds,
    int maxTotalBytes = 64 * 1024 * 1024,
  }) async {
    var removed = 0;
    try {
      final dir = Directory(cacheDir);
      if (!await dir.exists()) return 0;

      final kept = <String, FileStat>{};
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.jpg')) continue;
        final name = entity.uri.pathSegments.last;
        final id = name.substring(0, name.length - '.jpg'.length);
        if (!liveIds.contains(id)) {
          await _deleteQuietly(entity);
          removed++;
          continue;
        }
        try {
          kept[entity.path] = await entity.stat();
        } on FileSystemException {
          // A file we cannot stat is a file we cannot budget for; leave it.
        }
      }

      var total = kept.values.fold<int>(0, (sum, stat) => sum + stat.size);
      if (total <= maxTotalBytes) return removed;

      final oldestFirst = kept.entries.toList()
        ..sort((a, b) => a.value.modified.compareTo(b.value.modified));
      for (final entry in oldestFirst) {
        if (total <= maxTotalBytes) break;
        await _deleteQuietly(File(entry.key));
        total -= entry.value.size;
        removed++;
      }
    } catch (error) {
      debugPrint('[thumbnails] prune failed: $error');
    }
    return removed;
  }
}
