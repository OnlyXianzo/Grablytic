import 'dart:async';
import 'app_logger.dart';
import 'log_entry.dart';
import 'log_buffer.dart';

class LogIngester {
  final LogBuffer _buffer;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  LogIngester(this._buffer);

  void start(Stream<Map<String, dynamic>> engineLogStream) {
    _subscription = engineLogStream.listen(_handleLogEvent);
  }

  /// Single ingestion point for engine `type:log` events on ALL platforms.
  /// Buffer entry (structured) + file line (via appendFileLine, no console,
  /// no second buffer entry) — exactly-once on desktop and Android alike.
  ///
  /// Loop-1 hang fix: DEBUG entries are file-only, never buffered. The
  /// engine already gates DEBUG off the UI bridge (bridge floor INFO), but
  /// desktop/older engines still deliver DEBUG over the queue→stdout path;
  /// buffering tens-of-Hz yt-dlp DEBUG rebuilt every overlay/sheet/list at
  /// log rate (field sessions: 63k lines/7.5MB). The file log keeps every
  /// byte, so Diagnostics → File Logs loses nothing.
  void _handleLogEvent(Map<String, dynamic> data) {
    if (data['type'] != 'log') return;
    try {
      final raw = LogEntry.fromEngineJson(data);
      // Engine strings bypass AppLogger.log(), so redact here: buffer,
      // file line and GitHub reports all derive from this entry.
      final entry = LogEntry(
        timestamp: raw.timestamp,
        level: raw.level,
        logger: raw.logger,
        message: AppLogger.redact(raw.message),
        context: raw.context,
        extra: raw.extra,
        traceId: raw.traceId,
        durationMs: raw.durationMs,
        exception:
            raw.exception != null ? AppLogger.redact(raw.exception!) : null,
        source: raw.source,
        downloadId: raw.downloadId,
      );
      AppLogger.appendFileLine(entry.formattedLine);
      if (entry.level == LogLevel.debug) return;
      _buffer.add(entry);
    } catch (_) {
      // ignore malformed log entries
    }
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }
}
