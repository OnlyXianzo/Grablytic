enum LogLevel { debug, info, warn, error, fatal }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String logger;
  final String message;
  final Map<String, dynamic> context;
  final Map<String, dynamic> extra;
  final String? traceId;
  final int? durationMs;
  final String? exception;
  final String source; // 'engine' or 'ui'
  final String? _downloadId;

  String? get downloadId =>
      _downloadId ??
      (context['download_id'] as String?) ??
      (extra['download_id'] as String?);

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.logger,
    required this.message,
    this.context = const {},
    this.extra = const {},
    this.traceId,
    this.durationMs,
    this.exception,
    this.source = 'ui',
    String? downloadId,
  }) : _downloadId = downloadId;

  factory LogEntry.fromEngineJson(Map<String, dynamic> json) {
    final contextMap = (json['context'] as Map<String, dynamic>?) ?? {};
    final extraMap = (json['extra'] as Map<String, dynamic>?) ?? {};
    final dlId = json['download_id']?.toString() ??
        contextMap['download_id']?.toString() ??
        extraMap['download_id']?.toString();

    return LogEntry(
      timestamp: DateTime.parse(json['ts'] as String),
      level: _parseLevel(json['level'] as String? ?? 'INFO'),
      logger: json['logger'] as String? ?? 'engine',
      message: json['message'] as String? ?? '',
      context: contextMap,
      extra: extraMap,
      traceId: json['trace_id'] as String?,
      durationMs: json['duration_ms'] as int?,
      exception: json['exception'] as String?,
      source: 'engine',
      downloadId: dlId,
    );
  }

  static LogLevel _parseLevel(String level) {
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

  String get formattedTimestamp {
    final d = timestamp;
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}.${d.millisecond.toString().padLeft(3, '0')}';
  }

  String get formattedLine =>
      '[$formattedTimestamp] [${level.name.toUpperCase()}] [$logger]: $message${exception != null ? "\n  ⚠ $exception" : ""}';

  Map<String, dynamic> toJson() => {
        'type': 'log',
        'level': level.name.toUpperCase(),
        'ts': timestamp.toUtc().toIso8601String(),
        'logger': logger,
        'message': message,
        'context': context,
        'extra': extra,
        'trace_id': traceId,
        'duration_ms': durationMs,
        'exception': exception,
        'source': source,
        'download_id': downloadId,
      };
}
