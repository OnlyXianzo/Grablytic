import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/utils/log_entry.dart';

void main() {
  group('LogLevel', () {
    test('index values are ordered by severity', () {
      expect(LogLevel.debug.index, equals(0));
      expect(LogLevel.info.index, equals(1));
      expect(LogLevel.warn.index, equals(2));
      expect(LogLevel.error.index, equals(3));
      expect(LogLevel.fatal.index, equals(4));
    });
  });

  group('LogEntry constructor', () {
    test('sets all required fields correctly', () {
      final ts = DateTime(2026, 7, 6, 14, 30, 15, 123);

      final entry = LogEntry(
        timestamp: ts,
        level: LogLevel.warn,
        logger: 'test.logger',
        message: 'something happened',
        context: {'user': 'abc'},
        extra: {'retry': 3},
        traceId: 'trace-001',
        durationMs: 450,
        exception: 'TimeoutException',
        source: 'engine',
      );

      expect(entry.timestamp, same(ts));
      expect(entry.level, LogLevel.warn);
      expect(entry.logger, 'test.logger');
      expect(entry.message, 'something happened');
      expect(entry.context, {'user': 'abc'});
      expect(entry.extra, {'retry': 3});
      expect(entry.traceId, 'trace-001');
      expect(entry.durationMs, 450);
      expect(entry.exception, 'TimeoutException');
      expect(entry.source, 'engine');
    });

    test('applies defaults when optional fields are omitted', () {
      final ts = DateTime(2026, 7, 6);

      final entry = LogEntry(
        timestamp: ts,
        level: LogLevel.info,
        logger: 'defaults',
        message: 'test',
      );

      expect(entry.context, isEmpty);
      expect(entry.extra, isEmpty);
      expect(entry.traceId, isNull);
      expect(entry.durationMs, isNull);
      expect(entry.exception, isNull);
      expect(entry.source, equals('ui'));
    });
  });

  group('LogEntry.fromEngineJson', () {
    test('parses a complete engine JSON map correctly', () {
      final json = <String, dynamic>{
        'ts': '2026-07-06T14:30:15.123',
        'level': 'WARN',
        'logger': 'downloader',
        'message': 'retry attempt 2',
        'context': {'url': 'https://example.com/video.mp4', 'attempt': 2},
        'extra': {'fragment': 7},
        'trace_id': 'tr-42',
        'duration_ms': 1200,
        'exception': 'Connection reset',
      };

      final entry = LogEntry.fromEngineJson(json);

      expect(entry.timestamp, DateTime(2026, 7, 6, 14, 30, 15, 123));
      expect(entry.level, LogLevel.warn);
      expect(entry.logger, 'downloader');
      expect(entry.message, 'retry attempt 2');
      expect(entry.context, {'url': 'https://example.com/video.mp4', 'attempt': 2});
      expect(entry.extra, {'fragment': 7});
      expect(entry.traceId, 'tr-42');
      expect(entry.durationMs, 1200);
      expect(entry.exception, 'Connection reset');
      expect(entry.source, 'engine');
    });

    test('provides defaults for missing optional fields', () {
      final json = <String, dynamic>{
        'ts': '2026-07-06T00:00:00',
        'message': 'hello',
      };

      final entry = LogEntry.fromEngineJson(json);

      expect(entry.timestamp, DateTime(2026, 7, 6));
      expect(entry.level, LogLevel.info);
      expect(entry.logger, 'engine');
      expect(entry.message, 'hello');
      expect(entry.context, isEmpty);
      expect(entry.extra, isEmpty);
      expect(entry.traceId, isNull);
      expect(entry.durationMs, isNull);
      expect(entry.exception, isNull);
      expect(entry.source, 'engine');
    });

    test('defaults to INFO level when level field is missing', () {
      final json = <String, dynamic>{
        'ts': '2026-07-06T00:00:00',
        'message': 'no level',
      };

      final entry = LogEntry.fromEngineJson(json);

      expect(entry.level, LogLevel.info);
    });
  });

  group('_parseLevel (via fromEngineJson)', () {
    test('maps all five level strings case-insensitively', () {
      final base = <String, dynamic>{
        'ts': '2026-01-01T00:00:00',
        'message': 'x',
      };

      expect(
        LogEntry.fromEngineJson({...base, 'level': 'debug'}).level,
        LogLevel.debug,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'DEBUG'}).level,
        LogLevel.debug,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'info'}).level,
        LogLevel.info,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'INFO'}).level,
        LogLevel.info,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'warn'}).level,
        LogLevel.warn,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'WARN'}).level,
        LogLevel.warn,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'error'}).level,
        LogLevel.error,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'ERROR'}).level,
        LogLevel.error,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'fatal'}).level,
        LogLevel.fatal,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'FATAL'}).level,
        LogLevel.fatal,
      );
    });

    test('defaults to INFO for unknown level strings', () {
      final base = <String, dynamic>{
        'ts': '2026-01-01T00:00:00',
        'message': 'x',
      };

      expect(
        LogEntry.fromEngineJson({...base, 'level': 'TRACE'}).level,
        LogLevel.info,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': 'CRITICAL'}).level,
        LogLevel.info,
      );
      expect(
        LogEntry.fromEngineJson({...base, 'level': ''}).level,
        LogLevel.info,
      );
    });
  });

  group('formattedTimestamp', () {
    test('formats as YYYY-MM-DD HH:MM:SS.mmm', () {
      final entry = LogEntry(
        timestamp: DateTime(2026, 7, 6, 8, 5, 3, 42),
        level: LogLevel.info,
        logger: 't',
        message: 'm',
      );

      expect(entry.formattedTimestamp, equals('2026-07-06 08:05:03.042'));
    });

    test('pads single-digit month, day, hour, minute, second, millisecond', () {
      final entry = LogEntry(
        timestamp: DateTime(2026, 1, 2, 3, 4, 5, 6),
        level: LogLevel.info,
        logger: 't',
        message: 'm',
      );

      expect(entry.formattedTimestamp, equals('2026-01-02 03:04:05.006'));
    });
  });

  group('formattedLine', () {
    test('includes timestamp, level, logger, and message', () {
      final entry = LogEntry(
        timestamp: DateTime(2026, 7, 6, 14, 30, 15, 123),
        level: LogLevel.error,
        logger: 'http.client',
        message: 'connection refused',
      );

      expect(
        entry.formattedLine,
        equals(
          '[2026-07-06 14:30:15.123] [ERROR] [http.client]: connection refused',
        ),
      );
    });

    test('appends exception when present', () {
      final entry = LogEntry(
        timestamp: DateTime(2026, 7, 6, 14, 30, 15, 123),
        level: LogLevel.fatal,
        logger: 'engine',
        message: 'out of memory',
        exception: 'OOMError: cannot allocate 2GB',
      );

      expect(
        entry.formattedLine,
        contains(
          '\n  ⚠ OOMError: cannot allocate 2GB',
        ),
      );
    });

    test('omits exception line when exception is null', () {
      final entry = LogEntry(
        timestamp: DateTime(2026, 7, 6, 14, 30, 15, 123),
        level: LogLevel.info,
        logger: 'test',
        message: 'all good',
      );

      expect(entry.formattedLine, isNot(contains('⚠')));
    });
  });

  group('toJson', () {
    test('produces correct map with all fields', () {
      final entry = LogEntry(
        timestamp: DateTime.utc(2026, 7, 6, 14, 30, 15, 123),
        level: LogLevel.error,
        logger: 'auth',
        message: 'token expired',
        context: {'user_id': 42},
        extra: {'renewed': false},
        traceId: 'tr-99',
        durationMs: 3400,
        exception: 'JwtExpired',
        source: 'engine',
      );

      final json = entry.toJson();

      expect(json['type'], equals('log'));
      expect(json['level'], equals('ERROR'));
      expect(json['ts'], equals('2026-07-06T14:30:15.123Z'));
      expect(json['logger'], equals('auth'));
      expect(json['message'], equals('token expired'));
      expect(json['context'], equals({'user_id': 42}));
      expect(json['extra'], equals({'renewed': false}));
      expect(json['trace_id'], equals('tr-99'));
      expect(json['duration_ms'], equals(3400));
      expect(json['exception'], equals('JwtExpired'));
      expect(json['source'], equals('engine'));
    });

    test('includes null trace_id, duration_ms, and exception when absent', () {
      final entry = LogEntry(
        timestamp: DateTime(2026, 7, 6),
        level: LogLevel.info,
        logger: 'sys',
        message: 'startup',
      );

      final json = entry.toJson();

      expect(json['trace_id'], isNull);
      expect(json['duration_ms'], isNull);
      expect(json['exception'], isNull);
    });
  });
}
