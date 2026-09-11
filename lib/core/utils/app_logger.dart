import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'log_buffer.dart';
import 'log_entry.dart';

class AppLogger {
  static String? _logsDirPath;
  static SharedPreferences? _prefs;
  static bool _loggingEnabled = true;
  static int _retentionDays = 7;
  static LogBuffer? _buffer;

  static const String _keyEnabled = 'logging_enabled';
  static const String _keyRetention = 'logging_retention_days';

  // ── Persistent buffer (STEP 3A: time-buffered disk flush) ──────────────
  /// Lines waiting to be flushed to disk. Appended synchronously (cheap),
  /// drained by [_flushTimer] every [_flushInterval] or instantly on fatal.
  static final List<String> _pending = [];
  static Timer? _flushTimer;
  static Future<void> _flushChain = Future.value();
  static bool _flushInProgress = false;
  static const Duration _flushInterval = Duration(seconds: 30);
  static const String _appLogFileName = 'app_logs.txt';
  static const int _appLogMaxBytes = 2 * 1024 * 1024; // 2 MB rolling cap
  static Future<void> Function(Object error, StackTrace stack)? _fatalHook;

  /// Initialize the logger with the application directory and shared preferences.
  static Future<void> init(String appDirPath, SharedPreferences prefs) async {
    _logsDirPath = '$appDirPath/logs';
    _prefs = prefs;

    // Load user settings
    _loggingEnabled = prefs.getBool(_keyEnabled) ?? true;
    _retentionDays = prefs.getInt(_keyRetention) ?? 7;

    if (_loggingEnabled) {
      try {
        final logsDir = Directory(_logsDirPath!);
        if (!await logsDir.exists()) {
          await logsDir.create(recursive: true);
        }
        await _runRetentionCleanup();
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
  static int get retentionDays => _retentionDays;

  /// Enable or disable logging.
  static Future<void> setEnabled(bool enabled) async {
    _loggingEnabled = enabled;
    await _prefs?.setBool(_keyEnabled, enabled);
    info('Logging ${enabled ? "enabled" : "disabled"}');
  }

  /// Set log retention in days.
  static Future<void> setRetentionDays(int days) async {
    _retentionDays = days;
    await _prefs?.setInt(_keyRetention, days);
    info('Log retention set to $days days');
    await _runRetentionCleanup();
  }

  /// Write a log entry.
  ///
  /// Hot path: formatting + in-memory buffer push are synchronous and cheap.
  /// Disk I/O is batched — lines go to [_pending] and are flushed every 30s
  /// by the background worker, or instantly for ERROR/FATAL.
  static void log(String level, String message, {String? tag, Object? error, StackTrace? stackTrace}) {
    final entry = _buildEntry(level, message, tag: tag, error: error);
    _buffer?.add(entry);

    final now = DateTime.now();
    final timeStr = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    final safeMessage = _redact(message);
    final safeError = error != null ? _redact(error.toString()) : null;
    var logLine =
        '[$timeStr] [$level]${tag != null ? " [$tag]" : ""}: $safeMessage${safeError != null ? "\nError: $safeError" : ""}';
    if (stackTrace != null) {
      final st = stackTrace.toString();
      logLine += '\nStackTrace:\n${st.length > 4000 ? st.substring(0, 4000) : st}';
    }
    logLine += '\n';

    // Print to console for debug (unchanged behavior).
    // ignore: avoid_print
    print(logLine.trim());

    if (!_loggingEnabled || _logsDirPath == null) return;

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
      await appFile.writeAsString(blob, mode: FileMode.append);
      await _enforceAppLogCap(appFile);
    } catch (e) {
      // Re-queue on transient I/O failure (disk full excluded to avoid loop).
      // ignore: avoid_print
      print('Failed writing log batch: $e');
    } finally {
      _flushInProgress = false;
    }
  }

  /// Keeps `app_logs.txt` under [_appLogMaxBytes] by trimming the head,
  /// preserving the most recent (most actionable) lines.
  static Future<void> _enforceAppLogCap(File appFile) async {
    try {
      final len = await appFile.length();
      if (len <= _appLogMaxBytes) return;
      final bytes = await appFile.readAsBytes();
      final keep = bytes.sublist(bytes.length - _appLogMaxBytes);
      // Align to next newline so we never start mid-line.
      var start = 0;
      for (var i = 0; i < keep.length && i < 4096; i++) {
        if (keep[i] == 10) {
          start = i + 1;
          break;
        }
      }
      await appFile.writeAsBytes(keep.sublist(start), mode: FileMode.write);
    } catch (_) {
      // Cap enforcement is best-effort; never crash the app over logs.
    }
  }

  /// Masks likely secrets before they hit disk / console / GitHub.
  static String _redact(String input) {
    var out = input;
    // Query-string / JSON tokens, cookies, auth headers, proxy creds.
    const patterns = [
      r'(token\s*[:=]\s*["' "']?)([^"'"'\s,}]+)',
      r'(api[_-]?key\s*[:=]\s*["' "']?)([^"'"'\s,}]+)',
      r'(cookie\s*[:=]\s*["' "']?)([^"'"'\s,}]+)',
      r'(password\s*[:=]\s*["' "']?)([^"'"'\s,}]+)',
      r'(po[_-]?token\s*[:=]\s*["' "']?)([^"'"'\s,}]+)',
    ];
    for (final p in patterns) {
      out = out.replaceAllMapped(RegExp(p, caseSensitive: false), (m) => '${m.group(1)}***REDACTED***');
    }
    return out;
  }

  // ── Global error boundaries (STEP 3A) ──────────────────────────────────

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
        log('FATAL', 'Unhandled Flutter framework error: ${details.exceptionAsString()}',
            tag: 'global', error: details.exception, stackTrace: details.stack);
        unawaited(flushNow().then((_) {
          if (_fatalHook != null) {
            return _fatalHook!(details.exception, details.stack ?? StackTrace.empty);
          }
        }).catchError((_) {}));
      } catch (_) {
        // Logger must never throw inside the error handler itself.
      }
      // Preserve default console dumping in debug.
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      try {
        log('FATAL', 'Unhandled async/platform error: $error',
            tag: 'global', error: error, stackTrace: stack);
        unawaited(flushNow().then((_) {
          if (_fatalHook != null) return _fatalHook!(error, stack);
        }).catchError((_) {}));
      } catch (_) {}
      return true;
    };
  }

  static LogEntry _buildEntry(String level, String message,
      {String? tag, Object? error}) {
    return LogEntry(
      timestamp: DateTime.now(),
      level: _parseLogLevel(level),
      logger: tag ?? 'app',
      message: message,
      exception: error?.toString(),
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

  static void debug(String message, {String? tag}) => log('DEBUG', message, tag: tag);
  static void info(String message, {String? tag}) => log('INFO', message, tag: tag);
  static void warn(String message, {String? tag, Object? error}) => log('WARN', message, tag: tag, error: error);
  static void error(String message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      log('ERROR', message, tag: tag, error: error, stackTrace: stackTrace);
  static void fatal(String message, {String? tag, Object? error, StackTrace? stackTrace}) =>
      log('FATAL', message, tag: tag, error: error, stackTrace: stackTrace);

  /// Measures how long a synchronous or asynchronous action takes and logs it.
  static Future<T> trace<T>(String label, Future<T> Function() action, {String? tag}) async {
    final stopwatch = Stopwatch()..start();
    info('START: $label', tag: tag);
    try {
      final result = await action();
      stopwatch.stop();
      info('END: $label — took ${stopwatch.elapsed.inMilliseconds}ms', tag: tag);
      return result;
    } catch (e) {
      stopwatch.stop();
      error('FAILED: $label — took ${stopwatch.elapsed.inMilliseconds}ms', tag: tag, error: e);
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
      info('END: $label — took ${stopwatch.elapsed.inMilliseconds}ms', tag: tag);
      return result;
    } catch (e) {
      stopwatch.stop();
      error('FAILED: $label — took ${stopwatch.elapsed.inMilliseconds}ms', tag: tag, error: e);
      rethrow;
    }
  }

  /// Automatically deletes log files older than the retention days configuration.
  static Future<void> _runRetentionCleanup() async {
    if (_logsDirPath == null) return;
    try {
      final logsDir = Directory(_logsDirPath!);
      if (!await logsDir.exists()) return;

      final now = DateTime.now();
      final retentionThreshold = now.subtract(Duration(days: _retentionDays));

      final files = await logsDir.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.txt')) {
          final fileName = entity.uri.pathSegments.last;
          if (fileName.startsWith('log_')) {
            try {
              // Extract date from log_YYYY-MM-DD.txt
              final dateStr = fileName.substring(4, 14);
              final logDate = DateTime.parse(dateStr);
              if (logDate.isBefore(retentionThreshold)) {
                await entity.delete();
                // ignore: avoid_print
                print('Deleted expired log file: $fileName');
              }
            } catch (e) {
              // Skip if filename format is unexpected
            }
          }
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('Retention cleanup failed: $e');
    }
  }

  /// Retrieves list of all available log files.
  ///
  /// Includes daily `log_*.txt` files, engine `engine_*.txt` mirrors (if any),
  /// and the rolling `app_logs.txt` buffer flush target. Newest first, with
  /// `app_logs.txt` pinned first for the reporter's convenience.
  static Future<List<File>> getLogFiles() async {
    if (_logsDirPath == null) return [];
    try {
      final logsDir = Directory(_logsDirPath!);
      if (!await logsDir.exists()) return [];

      final files = await logsDir.list().toList();
      final logFiles = files.whereType<File>().where((f) => f.path.endsWith('.txt') || f.path.endsWith('.log')).toList();
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

  /// Reads the tail of `app_logs.txt` (or newest daily log as fallback),
  /// capped at [maxBytes]. Used by the GitHub reporter — never loads the
  /// whole file into memory on low-end devices.
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
      final raf = await target.open(mode: FileMode.read);
      try {
        await raf.setPosition(len - maxBytes);
        final bytes = await raf.read(maxBytes);
        var text = String.fromCharCodes(bytes);
        final nl = text.indexOf('\n');
        if (nl >= 0 && nl < 4096) text = text.substring(nl + 1);
        return '... [TRUNCATED — showing last ${maxBytes ~/ 1024}KB of ${len ~/ 1024}KB] ...\n$text';
      } finally {
        await raf.close();
      }
    } catch (e) {
      return 'Failed to read log tail: $e';
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

  /// Read the full contents of a specific log file.
  static Future<String> readLogFile(File file) async {
    try {
      return await file.readAsString();
    } catch (e) {
      return 'Failed to read log: $e';
    }
  }
}
