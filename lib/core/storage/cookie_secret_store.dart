import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
/// The jar now lives in an app-private file, written atomically (temp
/// file + fsync + rename), with owner-only permissions applied where the
/// platform actually allows it. SharedPreferences keeps only the profile
/// METADATA (id, url, description, enabled flag); the content never
/// touches it.
///
/// A note on those permissions: on Android there is no `chmod` binary on
/// `PATH`, so the 0600 flag cannot be applied from Dart. The protection
/// there is the app sandbox (`/data/data/<pkg>` is 0700 and no other app
/// can traverse it), which is the stronger control anyway. On desktop the
/// `chmod` call is real, and a failure is logged rather than swallowed —
/// a security claim that silently does nothing is worse than no claim.
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

  /// File names are a REVERSIBLE encoding of the profile id.
  ///
  /// The first version sanitised the id (`a.b` became `a_b`), which is
  /// lossy: `readAll()` returned the sanitised name, the settings layer
  /// looked the ORIGINAL id up, found nothing and hydrated the profile
  /// with an empty jar — which the next write then persisted, destroying
  /// the cookies. Two different ids could also collide on one file.
  /// Base64url is reversible, cannot collide, and cannot escape the
  /// profile directory (the alphabet is `A-Za-z0-9-_`).
  static const String _encodingPrefix = 'v1-';

  static String _encodeName(String id) {
    final encoded = base64Url.encode(utf8.encode(id)).replaceAll('=', '');
    return '$_encodingPrefix$encoded';
  }

  static String _decodeName(String name) {
    if (!name.startsWith(_encodingPrefix)) {
      // A file written by the first version of this store: its name was
      // the sanitised id, so the best that can be done is to return it.
      return name;
    }
    final raw = name.substring(_encodingPrefix.length);
    try {
      final padded = raw.padRight((raw.length + 3) ~/ 4 * 4, '=');
      return utf8.decode(base64Url.decode(padded));
    } catch (_) {
      return name;
    }
  }

  Future<File> _fileFor(String id) async {
    final dir = await _baseDir();
    return File(p.join(dir.path, '${_encodeName(id)}.txt'));
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
          result[_decodeName(name)] = lines;
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
    File? tmp;
    try {
      final file = await _fileFor(id);
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
        await _restrictToOwner(parent.path);
      }
      // Atomic replace. `writeAsString` on the target truncates first, so
      // a process kill between truncate and flush left a PARTIAL jar that
      // `readAll()` handed back as if it were complete: the next session
      // logged in half-way, and the next write persisted the damaged
      // version. Write a sibling temp file, fsync it, then rename: the
      // rename is atomic within a directory, so a reader sees the old jar
      // or the new one and never a mixture.
      tmp = File('${file.path}.tmp');
      await tmp.writeAsString('${lines.join('\n')}\n', flush: true);
      await _restrictToOwner(tmp.path);
      await tmp.rename(file.path);
      tmp = null;
    } catch (_) {
      // A failed write means the cookie jar is not persisted. The
      // in-memory state still holds it for this session.
    } finally {
      if (tmp != null) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {
          // Best effort: a stray .tmp is harmless (readAll ignores it).
        }
      }
    }
  }

  /// Applies owner-only permissions where the platform has a `chmod`.
  ///
  /// Android has none: spawning `chmod` there always fails, which is why
  /// the previous version silently did nothing while the class
  /// documentation claimed 0600. The sandbox is the real control on
  /// Android, so the call is skipped explicitly rather than attempted and
  /// swallowed. On desktop a failure is logged — the file does contain a
  /// bearer credential there.
  static Future<void> _restrictToOwner(String path) async {
    if (Platform.isWindows || Platform.isAndroid) return;
    try {
      final result = await Process.run('chmod', ['0600', path]);
      if (result.exitCode != 0) {
        _warn('chmod 0600 failed on $path: ${result.stderr}');
      }
    } catch (error) {
      _warn('chmod unavailable for $path: $error');
    }
  }

  /// Diagnostics for a permission failure.
  ///
  /// `debugPrint` rather than `AppLogger`: this file is a storage
  /// primitive, and importing the logging stack (which touches
  /// SharedPreferences and the file system) would couple the two in a
  /// cycle. One line about a failed `chmod` does not need the pipeline.
  static void _warn(String message) => debugPrint('[cookies] $message');

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
