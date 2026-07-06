import 'dart:io';
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
  static void log(String level, String message, {String? tag, Object? error}) async {
    if (!_loggingEnabled || _logsDirPath == null) {
      // ignore: avoid_print
      print('[$level]${tag != null ? " [$tag]" : ""}: $message');
      _buffer?.add(_buildEntry(level, message, tag: tag, error: error));
      return;
    }

    final now = DateTime.now();
    final timeStr = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    final dayStr = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final logLine = '[$timeStr] [$level]${tag != null ? " [$tag]" : ""}: $message${error != null ? "\nError: $error" : ""}\n';

    // Print to console for debug
    // ignore: avoid_print
    print(logLine.trim());

    try {
      final file = File('$_logsDirPath/log_$dayStr.txt');
      await file.writeAsString(logLine, mode: FileMode.append, flush: true);
    } catch (e) {
      // ignore: avoid_print
      print('Failed writing to log file: $e');
    }

    _buffer?.add(_buildEntry(level, message, tag: tag, error: error));
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

  static void info(String message, {String? tag}) => log('INFO', message, tag: tag);
  static void warn(String message, {String? tag, Object? error}) => log('WARN', message, tag: tag, error: error);
  static void error(String message, {String? tag, Object? error}) => log('ERROR', message, tag: tag, error: error);

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
  static Future<List<File>> getLogFiles() async {
    if (_logsDirPath == null) return [];
    try {
      final logsDir = Directory(_logsDirPath!);
      if (!await logsDir.exists()) return [];

      final files = await logsDir.list().toList();
      final logFiles = files.whereType<File>().where((f) => f.path.endsWith('.txt')).toList();
      // Sort in reverse chronological order (newest first)
      logFiles.sort((a, b) => b.path.compareTo(a.path));
      return logFiles;
    } catch (e) {
      return [];
    }
  }

  /// Delete all log files.
  static Future<void> deleteAllLogs() async {
    if (_logsDirPath == null) return;
    try {
      final logsDir = Directory(_logsDirPath!);
      if (await logsDir.exists()) {
        await logsDir.delete(recursive: true);
        await logsDir.create(recursive: true);
      }
      info('All logs deleted');
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
