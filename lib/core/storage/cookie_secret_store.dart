import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Storage boundary for cookie-jar CONTENTS.
///
/// A cookie jar is a bearer credential: whoever holds the `SID` cookie
/// holds the session. The jar used to live in SharedPreferences as
/// plaintext JSON, next to the app's ordinary settings, in a file that
/// any process with the app's uid (a debuggable build, a rooted device,
/// a vendor ROM that syncs the app's data directory) can read.
///
/// The jar now lives in an app-private file with 0600 permissions —
/// the same pattern the WebView login flow already uses for
/// `cookies.txt`. SharedPreferences keeps only the profile METADATA
/// (id, url, description, enabled flag); the content never touches it.
///
/// Implementations must never throw for a missing directory or a
/// missing profile: an unavailable store means "no content", not a
/// crash in the settings screen.
abstract interface class CookieSecretStore {
  /// Every stored profile, keyed by profile id.
  Future<Map<String, List<String>>> readAll();

  /// Stores (or replaces) one profile's cookie lines.
  Future<void> write(String id, List<String> lines);

  /// Removes one profile.
  Future<void> delete(String id);

  /// Removes every profile.
  Future<void> clear();
}

/// File-backed store under the app's private documents directory.
class FileCookieSecretStore implements CookieSecretStore {
  FileCookieSecretStore({Future<Directory> Function()? baseDir})
      : _baseDir = baseDir ?? _defaultBaseDir;

  final Future<Directory> Function() _baseDir;

  static Future<Directory> _defaultBaseDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'cookies', 'profiles'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Profile ids come from the app, but they are used as file names.
  /// Anything outside this alphabet is replaced so a crafted id can
  /// never escape the profile directory.
  static String _safeName(String id) {
    final cleaned = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return cleaned.isEmpty ? 'profile' : cleaned;
  }

  Future<File> _fileFor(String id) async {
    final dir = await _baseDir();
    return File(p.join(dir.path, '${_safeName(id)}.txt'));
  }

  @override
  Future<Map<String, List<String>>> readAll() async {
    final result = <String, List<String>>{};
    try {
      final dir = await _baseDir();
      if (!await dir.exists()) return result;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.txt')) continue;
        final name = p.basenameWithoutExtension(entity.path);
        try {
          final lines = await entity.readAsLines();
          result[name] = lines;
        } catch (_) {
          // Unreadable profile: skip it.
        }
      }
    } catch (_) {
      return result;
    }
    return result;
  }

  @override
  Future<void> write(String id, List<String> lines) async {
    try {
      final file = await _fileFor(id);
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      await file.writeAsString(lines.join('\n'));
      if (!Platform.isWindows) {
        try {
          await Process.run('chmod', ['0600', file.path]);
        } catch (_) {
          // chmod is unavailable on some platforms; the app-private
          // directory is the primary protection.
        }
      }
    } catch (_) {
      // A failed write means the cookie jar is not persisted. The
      // in-memory state still holds it for this session.
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      final file = await _fileFor(id);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      final dir = await _baseDir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.txt')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
