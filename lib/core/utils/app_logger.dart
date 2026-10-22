import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_buffer.dart';
import 'log_entry.dart';
import 'log_rotation.dart';

class AppLogger {
  static String? _logsDirPath;
  static SharedPreferences? _prefs;
  static bool _loggingEnabled = true;
  static LogBuffer? _buffer;

  static const String _keyEnabled = 'logging_enabled';

  // ── Persistent buffer (STEP 3A: time-buffered disk flush) ──────────────
  /// Lines waiting to be flushed to disk. Appended synchronously (cheap),
  /// drained by [_flushTimer] every [_flushInterval] or instantly on fatal.
  static final List<String> _pending = [];
  static Timer? _flushTimer;
  static Future<void> _flushChain = Future.value();
  static bool _flushInProgress = false;
  static const Duration _flushInterval = Duration(seconds: 30);
  static const String _appLogFileName = 'app_logs.txt';
  static const int _maxSealedChunks = 5;
  // IDs of video sessions with logs in flight (begin at enqueue/start,
  // end at finished/error/cancelled; interrupted keeps its session).
  static final Set<String> _activeSessions = <String>{};
  static Future<void> Function(Object error, StackTrace stack)? _fatalHook;

  /// Initialize the logger with the application directory and shared preferences.
  static Future<void> init(String appDirPath, SharedPreferences prefs) async {
    _logsDirPath = '$appDirPath/logs';
    _prefs = prefs;

    // Load user settings
    _loggingEnabled = prefs.getBool(_keyEnabled) ?? true;

    if (_loggingEnabled) {
      try {
        final logsDir = Directory(_logsDirPath!);
        if (!await logsDir.exists()) {
          await logsDir.create(recursive: true);
        }
      } catch (e) {
        // Fallback or print in debug
        // ignore: avoid_print
        print('Logger init failed: $e');
      }
    }
    startFlushWorker();
  }

  /// Wire up a LogBuffer for in-memory log buffering.
  static void initBuffer(LogBuffer buffer) {
    _buffer = buffer;
  }

  static bool get isEnabled => _loggingEnabled;

  /// Mark a video session's logs in flight; rotation defers past 1 MB
  /// until every session ends (4 MB force valve).
  static void beginLogSession(String id) => _activeSessions.add(id);

  /// Close a video session when the job reaches a terminal state.
  static void endLogSession(String id) => _activeSessions.remove(id);

  /// Enable or disable logging.
  static Future<void> setEnabled(bool enabled) async {
    _loggingEnabled = enabled;
    await _prefs?.setBool(_keyEnabled, enabled);
    info('Logging ${enabled ? "enabled" : "disabled"}');
  }

  /// Write a log entry.
  ///
  /// Hot path: formatting + in-memory buffer push are synchronous and cheap.
  /// Disk I/O is batched — lines go to [_pending] and are flushed every 30s
  /// by the background worker, or instantly for ERROR/FATAL.
  /// The in-memory buffer still receives entries when logging is disabled;
  /// console output requires enabled logging and a debug build.
  static void log(
    String level,
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = _buildEntry(level, message, tag: tag, error: error);
    _buffer?.add(entry);

    final now = DateTime.now();
    final timeStr =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    final safeMessage = _redact(message);
    final safeError = error != null ? _redact(error.toString()) : null;
    var logLine =
        '[$timeStr] [$level]${tag != null ? " [$tag]" : ""}: $safeMessage${safeError != null ? "\nError: $safeError" : ""}';
    if (stackTrace != null) {
      final st = stackTrace.toString();
      logLine +=
          '\nStackTrace:\n${st.length > 4000 ? st.substring(0, 4000) : st}';
    }
    logLine += '\n';

    // Logging disabled is disabled: the console mirror used to run BEFORE
    // this check, so `setEnabled(false)` only silenced the file and every
    // message kept going to stdout (and to logcat in release builds).
    if (!_loggingEnabled) return;

    // The console mirror is a developer affordance. Debug builds only, so
    // a release binary does not stream titles, URLs and paths into logcat,
    // where the buffer is shared and rotates fast.
    if (kDebugMode) {
      // ignore: avoid_print
      print(logLine.trim());
    }

    if (_logsDirPath == null) return;

    // Buffer for batched disk write — no await, no fsync on UI thread.
    _pending.add(logLine);
    // Bound memory: drop oldest if producer vastly outruns the 30s worker.
    if (_pending.length > 10000) {
      _pending.removeRange(0, _pending.length - 10000);
    }

    // Instant flush on unhandled-severity entries so crashes never lose logs.
    final upper = level.toUpperCase();
    if (upper == 'ERROR' || upper == 'FATAL') {
      // Fire-and-forget; chain serializes with the periodic worker (no lock).
      unawaited(flushNow());
    }
  }

  // ── Background flush worker ────────────────────────────────────────────

  /// Starts the rolling 30s flush worker. Idempotent; called from [init].
  static void startFlushWorker() {
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer.periodic(_flushInterval, (_) {
      if (_pending.isNotEmpty) unawaited(flushNow());
    });
  }

  /// Stops the flush worker. Call on app detach for clean shutdown.
  static void stopFlushWorker() {
    _flushTimer?.cancel();
    _flushTimer = null;
  }

  /// Drains [_pending] to `log_YYYY-MM-DD.txt` + rolling `app_logs.txt`.
  ///
  /// Serialized through [_flushChain] so the periodic timer and instant
  /// fatal flushes can never interleave writes (no write-lock corruption).
  /// A single batched append per cycle avoids per-log fsync jank.
  static Future<void> flushNow() {
    if (_logsDirPath == null || _pending.isEmpty) return Future.value();
    _flushChain = _flushChain.then((_) => _drainPending());
    return _flushChain;
  }

  /// Append pending lines to daily and rolling logs, rotating as needed.
  ///
  /// On failure, re-queue the batch up to the 10,000-line cap unless
  /// [_isPermanentWriteFailure] classifies it for disposal. A partial write
  /// can cause duplicate lines on retry. Write errors are caught.
  static Future<void> _drainPending() async {
    if (_pending.isEmpty || _flushInProgress) return;
    if (_logsDirPath == null) return;
    _flushInProgress = true;
    final batch = List<String>.of(_pending);
    _pending.clear();
    try {
      final now = DateTime.now();
      final dayStr =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final blob = batch.join();
      final dayFile = File('$_logsDirPath/log_$dayStr.txt');
      await dayFile.writeAsString(blob, mode: FileMode.append);
      final appFile = File('$_logsDirPath/$_appLogFileName');
      // Rotate app logs into 1 MB chunks on the serialized flush chain (async,
      // never UI-blocking). Sealed chunks keep newest-first listing order.
      // Avoid cutting a video's log mid-session by deferring rotation while any
      // session is active; 4 MB force valve seals with a (continued) header.
      final incoming = blob.length;
      var current = await appFile.exists() ? await appFile.length() : 0;
      final hasActive = _activeSessions.isNotEmpty;
      var continued = false;
      if (await appFile.exists() &&
          LogRotation.shouldRotate(current, incoming)) {
        if (LogRotation.shouldDefer(
          current,
          incoming,
          hasActiveSessions: hasActive,
        )) {
          // Defer: append past the cap; next flush re-evaluates at session end.
        } else {
          continued = hasActive;
          await _sealChunk(appFile);
          current = 0;
        }
      }
      if (current == 0) {
        await appFile.writeAsString(
          continued
              ? LogRotation.continuedHeader(now)
              : LogRotation.header(now),
          mode: FileMode.append,
        );
      }
      await appFile.writeAsString(blob, mode: FileMode.append);
      await _pruneSealedChunks();
    } catch (e) {
      // The batch was detached from `_pending` before this block ran, so a
      // failure used to DROP it — up to 10,000 lines, including the
      // ERROR/FATAL that triggered the flush, lost at the exact moment
      // (full disk, locked file, flaky storage) a crash report needs them.
      // Put it back unless the failure is permanent; the usual cap still
      // applies, so a permanently broken disk cannot loop or grow.
      final permanent = _isPermanentWriteFailure(e);
      if (!permanent) {
        _pending.insertAll(0, batch);
        if (_pending.length > 10000) {
          _pending.removeRange(0, _pending.length - 10000);
        }
      }
      AppLogger.warn(
        'Log batch flush failed (${batch.length} lines, '
        '${permanent ? "dropped" : "re-queued"}): $e',
        tag: 'logger',
      );
    } finally {
      _flushInProgress = false;
    }
  }

  /// True for write failures that retrying cannot fix.
  ///
  /// ENOSPC (28), EACCES (13) and EIO (5) are the three that turn a retry
  /// loop into a battery drain. Everything else (a transiently locked file
  /// on Windows, a reader holding the handle) is worth one more attempt.
  static bool _isPermanentWriteFailure(Object error) {
    if (error is! FileSystemException) return false;
    final code = error.osError?.errorCode;
    return code == 28 || code == 13 || code == 5;
  }

  /// Seals the full active chunk to `app_logs-YYYY-MM-DD-HH-mm-ss.txt`.
  static Future<void> _sealChunk(File appFile) async {
    try {
      final sealed = File('${appFile.parent.path}/${LogRotation.sealedName()}');
      if (await sealed.exists()) {
        await sealed.delete();
      }
      await appFile.rename(sealed.path);
    } catch (_) {
      // Best-effort; next flush retries (append may briefly exceed cap).
    }
  }

  /// Keeps only the newest [_maxSealedChunks] sealed chunks to bound disk
  /// use without requiring a day-based retention preference.
  static Future<void> _pruneSealedChunks() async {
    try {
      final dir = Directory(_logsDirPath!);
      final sealed = await dir
          .list()
          .where(
            (e) =>
                e is File &&
                LogRotation.isSealedChunk(
                  e.path.split(Platform.pathSeparator).last,
                ),
          )
          .cast<File>()
          .toList();
      if (sealed.length <= _maxSealedChunks) return;
      sealed.sort((a, b) => a.path.compareTo(b.path));
      for (var i = 0; i < sealed.length - _maxSealedChunks; i++) {
        try {
          await sealed[i].delete();
        } catch (_) {}
      }
    } catch (_) {
      // Pruning is best-effort; never crash the app over logs.
    }
  }

  /// Masks likely secrets before they hit disk / console / GitHub.
  ///
  /// Public so the engine-log ingester (a different library) redacts
  /// engine-origin entries with identical rules — one pattern list,
  /// every sink covered.
  static String redact(String input) => _redact(input);

  static String _redact(String input) {
    var out = input;
    // Header lines first: "Authorization: Bearer eyJ..." and "Cookie: SID=..."
    // are not key/value pairs, so the patterns below never saw them — the
    // report body carries these lines verbatim from the log tail.
    out = out.replaceAllMapped(
      RegExp(
        r"^\s*(authorization|proxy-authorization|cookie|set-cookie|x-api-key|x-auth-token)\s*:\s*.*$",
        multiLine: true,
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}: ***REDACTED***',
    );
    // Query-string / JSON tokens, cookies, auth headers, proxy creds.
    // The sig family covers signed-URL params (?sig=, &lsig=, signature=)
    // that YouTube and other hosts embed in share/clipboard URLs — without
    // these, pasted URLs leak signing secrets into logs and reports.
    const patterns = [
      r"""(token\s*[:=]\s*["']?)([^"'\s,}]+)""",
      r"""(api[_-]?key\s*[:=]\s*["']?)([^"'\s,}]+)""",
      // The cookie value runs to the end of the line: SID and friends are
      // space-separated "a=b; c=d" pairs, and stopping at the first space
      // left every cookie after the first one in the log.
      r"""(cookie\s*[:=]\s*["']?)([^"'\r\n]+)""",
      r"""(password\s*[:=]\s*["']?)([^"'\s,}]+)""",
      r"""(po[_-]?token\s*[:=]\s*["']?)([^"'\s,}]+)""",
      r"""((?:lsig|sig|signature)\s*[:=]\s*["']?)([^"'\s,};&]+)""",
      // CDN URLs sign the expiry with the rest of the token: ?expire=1700000
      // is as good as a password while it lasts.
      r"""((?:expire|expires)\s*[:=]\s*["']?)([^&"'\s,}]+)""",
      // Bare credentials: "Bearer eyJ..." with no header line around it,
      // which is what exception messages and curl echoes look like.
      r"""\b(bearer|basic)\s+([A-Za-z0-9._~+/=-]{8,})""",
      // URL userinfo passwords (proxy creds): scheme://user:PASS@host.
      // Mirrors the engine sanitize() userinfo mask — same secret class.
      r"""([A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:)([^@\s/]+)(@)""",
      // A cookie-jar repr, which is what a Python traceback formats:
      // Cookie(version=0, name='SID', value='…'). No ':' or '=' follows the
      // word "Cookie", so the header rules above never saw it, and the session
      // cookie reached public issue bodies verbatim (SEC-001).
      r"""(\bCookie\([^\r\n]*?\bvalue\s*=\s*["'])([^"'\r\n]*)(["'])""",
      // str(jar entry): <Cookie SID=… for .youtube.com/>. A second spelling of
      // the same secret, which the repr rule does not cover.
      r"""(<Cookie\s+[^\s=>]+=)([^>\s]*)(\s+for\s)""",
      // A Netscape cookies.txt row: domain\tTRUE\t/\tTRUE\t0\tSID\t….
      // Anchored on the tab layout rather than on ^/$ because Dart RegExp has no
      // inline (?m); the loop already compiles every pattern case-insensitively.
      r"""(\t(?:TRUE|FALSE)\t[^\t\r\n]*\t(?:TRUE|FALSE)\t\d+\t[^\t\r\n]+\t)[^\t\r\n]*""",
    ];
    for (final p in patterns) {
      out = out.replaceAllMapped(RegExp(p, caseSensitive: false), (m) {
        // Userinfo pattern keeps scheme/user + host: only the password goes.
        if (m.groupCount == 3) {
          return '${m.group(1)}***REDACTED***${m.group(3)}';
        }
        return '${m.group(1)}***REDACTED***';
      });
    }
    return out;
  }

  // ── Global error boundaries (STEP 3A) ──────────────────────────────────

  /// Lets the root `runZonedGuarded` boundary use the same opt-in reporter.
  /// The zone may receive unhandled Future errors that bypass the platform
  /// dispatcher callback; keep this hook best-effort and non-throwing.
  static void reportUncaught(Object error, StackTrace stack) {
    final hook = _fatalHook;
    if (hook == null) return;
    unawaited(Future<void>.sync(() => hook(error, stack)).catchError((_) {}));
  }

  /// Installs `FlutterError.onError` + `PlatformDispatcher.instance.onError`.
  ///
  /// Both funnel into [AppLogger.error] + instant [flushNow], then invoke
  /// [onFatal] (the GitHub auto-reporter hook). Returns true from the
  /// dispatcher handler so the engine considers the error handled.
  /// Safe to call once from `main()` after `WidgetsFlutterBinding`.
  static void installGlobalErrorHandlers({
    Future<void> Function(Object error, StackTrace stack)? onFatal,
  }) {
    _fatalHook = onFatal;
    FlutterError.onError = (details) {
      try {
        log(
          'FATAL',
          'Unhandled Flutter framework error: ${details.exceptionAsString()}',
          tag: 'global',
          error: details.exception,
          stackTrace: details.stack,
        );
        unawaited(
          flushNow()
              .then((_) {
                if (_fatalHook != null) {
                  return _fatalHook!(
                    details.exception,
                    details.stack ?? StackTrace.empty,
                  );
                }
              })
              .catchError((_) {}),
        );
      } catch (_) {
        // Logger must never throw inside the error handler itself.
      }
      // Preserve default console dumping in debug.
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      try {
        log(
          'FATAL',
          'Unhandled async/platform error: $error',
          tag: 'global',
          error: error,
          stackTrace: stack,
        );
        unawaited(
          flushNow()
              .then((_) {
                if (_fatalHook != null) return _fatalHook!(error, stack);
              })
              .catchError((_) {}),
        );
      } catch (_) {}
      return true;
    };
  }

  static LogEntry _buildEntry(
    String level,
    String message, {
    String? tag,
    Object? error,
  }) {
    // Buffer entries feed the live viewer + clipboard/file exports, so they
    // get the same redaction as disk lines (SEC-02). Search still matches
    // the non-secret remainder of the message.
    return LogEntry(
      timestamp: DateTime.now(),
      level: _parseLogLevel(level),
      logger: tag ?? 'app',
      message: _redact(message),
      exception: error != null ? _redact(error.toString()) : null,
      source: 'ui',
    );
  }

  static LogLevel _parseLogLevel(String level) {
    switch (level.toUpperCase()) {
      case 'DEBUG':
        return LogLevel.debug;
      case 'INFO':
        return LogLevel.info;
      case 'WARN':
        return LogLevel.warn;
      case 'ERROR':
        return LogLevel.error;
      case 'FATAL':
        return LogLevel.fatal;
      default:
        return LogLevel.info;
    }
  }

  static void debug(String message, {String? tag}) =>
      log('DEBUG', message, tag: tag);
  static void info(String message, {String? tag}) =>
      log('INFO', message, tag: tag);
  static void warn(String message, {String? tag, Object? error}) =>
      log('WARN', message, tag: tag, error: error);
  static void error(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) => log('ERROR', message, tag: tag, error: error, stackTrace: stackTrace);
  static void fatal(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
  }) => log('FATAL', message, tag: tag, error: error, stackTrace: stackTrace);

  /// Measures how long a synchronous or asynchronous action takes and logs it.
  static Future<T> trace<T>(
    String label,
    Future<T> Function() action, {
    String? tag,
  }) async {
    final stopwatch = Stopwatch()..start();
    info('START: $label', tag: tag);
    try {
      final result = await action();
      stopwatch.stop();
      info(
        'END: $label — took ${stopwatch.elapsed.inMilliseconds}ms',
        tag: tag,
      );
      return result;
    } catch (e) {
      stopwatch.stop();
      error(
        'FAILED: $label — took ${stopwatch.elapsed.inMilliseconds}ms',
        tag: tag,
        error: e,
      );
      rethrow;
    }
  }

  /// Measures how long a synchronous action takes and logs it.
  static T traceSync<T>(String label, T Function() action, {String? tag}) {
    final stopwatch = Stopwatch()..start();
    info('START: $label', tag: tag);
    try {
      final result = action();
      stopwatch.stop();
      info(
        'END: $label — took ${stopwatch.elapsed.inMilliseconds}ms',
        tag: tag,
      );
      return result;
    } catch (e) {
      stopwatch.stop();
      error(
        'FAILED: $label — took ${stopwatch.elapsed.inMilliseconds}ms',
        tag: tag,
        error: e,
      );
      rethrow;
    }
  }

  /// Retrieves list of all available log files.
  ///
  /// Includes daily `log_*.txt` files, 1 MB sealed `app_logs-*.txt` chunks,
  /// engine `engine_*.txt` mirrors (if any),
  /// `server_logs.log` + its RotatingFileHandler backups (`server_logs.log.1`
  /// … — previously invisible because they don't end with `.log`), and the
  /// active `app_logs.txt` chunk flush target. Newest first, with
  /// `app_logs.txt` pinned first for the reporter's convenience.
  static Future<List<File>> getLogFiles() async {
    if (_logsDirPath == null) return [];
    try {
      final logsDir = Directory(_logsDirPath!);
      if (!await logsDir.exists()) return [];

      final files = await logsDir.list().toList();
      final logFiles = files.whereType<File>().where(_isLogFile).toList();
      // Sort in reverse chronological order (newest first)
      logFiles.sort((a, b) => b.path.compareTo(a.path));
      // Pin app_logs.txt first — it is the consolidated crash-report source.
      logFiles.sort((a, b) {
        final aIsApp = a.path.endsWith(_appLogFileName) ? 0 : 1;
        final bIsApp = b.path.endsWith(_appLogFileName) ? 0 : 1;
        if (aIsApp != bIsApp) return aIsApp - bIsApp;
        return b.path.compareTo(a.path);
      });
      return logFiles;
    } catch (e) {
      return [];
    }
  }

  /// Returns the rolling `app_logs.txt` file handle, if initialized.
  static File? get appLogsFile {
    if (_logsDirPath == null) return null;
    return File('$_logsDirPath/$_appLogFileName');
  }

  /// True for every file the Diagnostics screen should list.
  ///
  /// `.txt`/`.log` cover daily/engine/rolling logs; the extra branch covers
  /// RotatingFileHandler backups (`server_logs.log.1` …) which carry the
  /// newest engine history after a rollover but don't end with `.log`.
  /// Pure helper (no I/O) so unit tests can pin the contract.
  static bool isLogFilePath(String path) => _isLogFile(File(path));

  static bool _isLogFile(File f) {
    final name = f.path.split('/').last.split('\\').last;
    if (name.isEmpty) return false;
    if (name.endsWith('.txt') || name.endsWith('.log')) return true;
    if (name == 'server_logs.log') return true;
    if (name.startsWith('server_logs.log.')) {
      final tail = name.substring('server_logs.log.'.length);
      if (tail.isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(tail)) return true;
    }
    return false;
  }

  /// Reads the last [maxBytes] of [file] and decodes them as UTF-8.
  ///
  /// `String.fromCharCodes` maps each BYTE to one UTF-16 unit, so every
  /// multi-byte sequence (a Hindi, Japanese or emoji title) came out as
  /// mojibake in crash reports, exports and the log viewer's search. The
  /// file is UTF-8 everywhere else; this is the one place that disagreed.
  /// `allowMalformed` covers a seek that lands mid-codepoint.
  /// [len] is the file length in bytes and must be at least [maxBytes].
  /// Drops text through the first newline if it occurs before character 4096.
  /// File open, seek, read, and close errors propagate to the caller.
  static Future<String> _readTailUtf8(
    File file, {
    required int len,
    required int maxBytes,
  }) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(len - maxBytes);
      final bytes = await raf.read(maxBytes);
      var text = utf8.decode(bytes, allowMalformed: true);
      // Drop the partially cut first line when it is close to the start of
      // the window; a whole-line cut is what makes tails readable.
      final nl = text.indexOf('\n');
      if (nl >= 0 && nl < 4096) text = text.substring(nl + 1);
      return text;
    } finally {
      await raf.close();
    }
  }

  /// Reads the tail of `app_logs.txt` (or newest daily log as fallback),
  /// capped at [maxBytes]. Used by the GitHub reporter — never loads the
  /// whole file into memory on low-end devices.
  /// Flushes pending logs first. A capped tail includes a truncation banner;
  /// no file or a read failure returns an explanatory string.
  static Future<String> readLogTail({int maxBytes = 100 * 1024}) async {
    try {
      await flushNow(); // ensure the crash line itself is on disk first
      File? target = appLogsFile;
      if (target == null || !await target.exists()) {
        final files = await getLogFiles();
        if (files.isEmpty) return 'No logs recorded yet.';
        target = files.first;
      }
      final len = await target.length();
      if (len <= maxBytes) return await target.readAsString();
      final text = await _readTailUtf8(target, len: len, maxBytes: maxBytes);
      return '... [TRUNCATED — showing last ${maxBytes ~/ 1024}KB of ${len ~/ 1024}KB] ...\n$text';
    } catch (e) {
      return 'Failed to read log tail: $e';
    }
  }

  /// Reads the tail of an arbitrary log [file] without loading it all.
  ///
  /// Returns a record with the decoded tail [text] (NO header baked in —
  /// the caller renders its own banner from [fileBytes]/[shownBytes]),
  /// whether head bytes/lines were dropped ([truncated]), the full [fileBytes]
  /// length, the [shownBytes] the returned text came from
  /// (`utf8.encode(text).length`; equals [fileBytes] when nothing is cut),
  /// and a null [error] on success. Never throws and never calls `flushNow()`
  /// (generic `File` helper — the caller flushes if it needs to).
  static Future<
    ({
      String text,
      bool truncated,
      int fileBytes,
      int shownBytes,
      String? error,
    })
  >
  readLogTailText(
    File file, {
    int maxBytes = 100 * 1024,
    int maxLines = 1000,
  }) async {
    try {
      final capBytes = maxBytes < 0 ? 0 : maxBytes;
      final capLines = maxLines < 0 ? 0 : maxLines;
      final len = await file.length();
      if (len <= capBytes) {
        final full = await file.readAsString();
        if (full.isEmpty) {
          return (
            text: '',
            truncated: false,
            fileBytes: len,
            shownBytes: len,
            error: null,
          );
        }
        final endsWithNewline = full.endsWith('\n');
        final lines = full.split('\n');
        final contentLineCount = endsWithNewline
            ? lines.length - 1
            : lines.length;
        if (contentLineCount <= capLines) {
          return (
            text: full,
            truncated: false,
            fileBytes: len,
            shownBytes: len,
            error: null,
          );
        }
        if (capLines == 0) {
          return (
            text: '',
            truncated: true,
            fileBytes: len,
            shownBytes: 0,
            error: null,
          );
        }
        final contentLines = endsWithNewline
            ? lines.sublist(0, lines.length - 1)
            : lines;
        final kept = contentLines.sublist(contentLines.length - capLines);
        final keptText = kept.join('\n') + (endsWithNewline ? '\n' : '');
        return (
          text: keptText,
          truncated: true,
          fileBytes: len,
          shownBytes: utf8.encode(keptText).length,
          error: null,
        );
      }
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(len - capBytes);
        final window = await raf.read(capBytes);
        var text = utf8.decode(window, allowMalformed: true);
        final nl = text.indexOf('\n');
        if (nl >= 0 && nl < 4096) {
          text = text.substring(nl + 1);
        }
        if (text.isNotEmpty) {
          final endsWithNewline = text.endsWith('\n');
          final lines = text.split('\n');
          final contentLines = endsWithNewline
              ? lines.sublist(0, lines.length - 1)
              : lines;
          if (contentLines.length > capLines) {
            if (capLines == 0) {
              text = '';
            } else {
              final kept = contentLines.sublist(contentLines.length - capLines);
              text = kept.join('\n') + (endsWithNewline ? '\n' : '');
            }
          }
        }
        return (
          text: text,
          truncated: true,
          fileBytes: len,
          shownBytes: utf8.encode(text).length,
          error: null,
        );
      } finally {
        try {
          await raf.close();
        } catch (_) {}
      }
    } on FileSystemException catch (e) {
      return (
        text: '',
        truncated: false,
        fileBytes: 0,
        shownBytes: 0,
        error: e.message,
      );
    } on RangeError catch (e) {
      return (
        text: '',
        truncated: false,
        fileBytes: 0,
        shownBytes: 0,
        error: e.toString(),
      );
    } catch (e) {
      return (
        text: '',
        truncated: false,
        fileBytes: 0,
        shownBytes: 0,
        error: e.toString(),
      );
    }
  }

  /// Append a pre-formatted line to the disk batch WITHOUT touching the
  /// in-memory buffer or console. Single-owner ingestion (LogIngester) uses
  /// this so engine logs persist to `app_logs.txt` exactly once — the buffer
  /// entry is created separately from the structured event.
  static void appendFileLine(String line) {
    if (!_loggingEnabled || _logsDirPath == null) return;
    _pending.add(line.endsWith('\n') ? line : '$line\n');
    if (_pending.length > 10000) {
      _pending.removeRange(0, _pending.length - 10000);
    }
  }

  /// Delete all log files.
  static Future<void> deleteAllLogs() async {
    if (_logsDirPath == null) return;
    try {
      _pending.clear();
      final logsDir = Directory(_logsDirPath!);
      if (await logsDir.exists()) {
        await logsDir.delete(recursive: true);
        await logsDir.create(recursive: true);
      }
      info('All logs deleted');
      await flushNow();
    } catch (e) {
      // ignore: avoid_print
      print('Failed deleting logs: $e');
    }
  }

  /// Reads the FULL `app_logs.txt` (or newest daily log as fallback),
  /// capped at [maxBytes] (default 512KB). Used when the user opts into
  /// "full log" reports/exports — the default tail stays small for AI
  /// context limits and GitHub body limits.
  /// Flushes pending logs first. Above the cap, returns a UTF-8 tail with a
  /// truncation banner. No file or a read failure returns an explanatory string.
  static Future<String> readFullLog({int maxBytes = 512 * 1024}) async {
    try {
      await flushNow();
      File? target = appLogsFile;
      if (target == null || !await target.exists()) {
        final files = await getLogFiles();
        if (files.isEmpty) return 'No logs recorded yet.';
        target = files.first;
      }
      final len = await target.length();
      if (len <= maxBytes) return await target.readAsString();
      final text = await _readTailUtf8(target, len: len, maxBytes: maxBytes);
      return '... [TRUNCATED — showing last ${maxBytes ~/ 1024}KB of ${len ~/ 1024}KB] ...\n$text';
    } catch (e) {
      return 'Failed to read full log: $e';
    }
  }

  /// Builds a timestamped Downloads export filename; colons are illegal in
  /// MediaStore display names on some launchers/MTP, so time uses dashes.
  /// Example: `grablytic logs - 2026-10-02 03-45-12.log`.
  static String exportFileName([DateTime? at]) {
    final now = at ?? DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    String four(int n) => n.toString().padLeft(4, '0');
    return 'grablytic logs - ${four(now.year)}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}-${two(now.minute)}-${two(now.second)}.log';
  }

  /// Fallback when the default Downloads export through MediaStore
  /// ([engine.exportLogToDownloads]) is unavailable. This app-directory copy
  /// runs only when MediaStore cannot save the file.
  ///
  /// Android: app-specific external dir, e.g.
  /// `.../Android/data/APP_ID/files/log-exports/` — writable with NO
  /// (scoped storage forbids raw writes to public Download on API 30+).
  /// Desktop: `~/Downloads/Grablytic-logs/`. Never throws — returns an
  /// error description string starting with `ERROR:` on failure.
  static Future<String> exportLogFile(File src) async {
    try {
      if (!await src.exists()) return 'ERROR: log file no longer exists.';
      Directory base;
      String sub;
      if (Platform.isAndroid) {
        final ext = await getExternalStorageDirectory();
        if (ext == null) return 'ERROR: external storage unavailable.';
        base = ext;
        sub = 'log-exports';
      } else {
        final dl = await getDownloadsDirectory();
        base = dl ?? Directory(_logsDirPath ?? '.');
        sub = 'Grablytic-logs';
      }
      final destDir = Directory('${base.path}/$sub');
      await destDir.create(recursive: true);
      final baseName = exportFileName().replaceFirst('.log', '');
      // 1s timestamp resolution → same-second exports must not overwrite.
      var dest = File('${destDir.path}/$baseName.log');
      var n = 1;
      while (await dest.exists()) {
        n++;
        dest = File('${destDir.path}/$baseName-$n.log');
      }
      await src.copy(dest.path);
      return dest.path;
    } catch (e) {
      return 'ERROR: export failed: $e';
    }
  }

  /// Read the full contents of a specific log file.
  static Future<String> readLogFile(File file) async {
    try {
      return await file.readAsString();
    } catch (e) {
      return 'Failed to read log: $e';
    }
  }
}
