import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:truestream/core/utils/log_entry.dart';
import 'package:truestream/core/utils/log_buffer.dart';

LogEntry _entry({
  DateTime? timestamp,
  LogLevel level = LogLevel.info,
  String logger = 'test',
  String message = 'test message',
  String source = 'ui',
  String? exception,
}) {
  return LogEntry(
    timestamp: timestamp ?? DateTime(2026, 7, 6),
    level: level,
    logger: logger,
    message: message,
    source: source,
    exception: exception,
  );
}

void main() {
  group('LogBuffer basics', () {
    test('starts empty', () {
      final buffer = LogBuffer();
      expect(buffer.entries, isEmpty);
    });

    test('adding log entries stores them', () {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'first'));
      buffer.add(_entry(message: 'second'));

      expect(buffer.entries, hasLength(2));
      expect(buffer.entries[0].message, 'first');
      expect(buffer.entries[1].message, 'second');
    });

    test('entries getter returns an unmodifiable list', () {
      final buffer = LogBuffer();
      buffer.add(_entry());

      expect(() => buffer.entries.add(_entry()), throwsUnsupportedError);
      expect(() => buffer.entries.removeAt(0), throwsUnsupportedError);
    });

    test('stream emits each added entry', () async {
      final buffer = LogBuffer();
      final emitted = <LogEntry>[];

      buffer.stream.listen(emitted.add);
      buffer.add(_entry(message: 'a'));
      buffer.add(_entry(message: 'b'));

      // Pump microtasks so the broadcast stream delivers synchronously.
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(2));
      expect(emitted[0].message, 'a');
      expect(emitted[1].message, 'b');
    });
  });

  group('circular buffer eviction', () {
    test('removes oldest entry when maxEntries is exceeded', () {
      final buffer = LogBuffer(maxEntries: 3);
      buffer.add(_entry(message: '1'));
      buffer.add(_entry(message: '2'));
      buffer.add(_entry(message: '3'));
      expect(buffer.entries, hasLength(3));

      buffer.add(_entry(message: '4'));
      expect(buffer.entries, hasLength(3));
      expect(buffer.entries.map((e) => e.message).toList(), equals(['2', '3', '4']));
    });

    test('evicts multiple entries when many are added', () {
      final buffer = LogBuffer(maxEntries: 5);
      for (var i = 1; i <= 10; i++) {
        buffer.add(_entry(message: '$i'));
      }

      expect(buffer.entries, hasLength(5));
      expect(buffer.entries.first.message, '6');
      expect(buffer.entries.last.message, '10');
    });
  });

  group('setMinLevel filter', () {
    test('allows entries at or above the minimum level', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.warn);

      buffer.add(_entry(level: LogLevel.debug, message: 'debug'));
      buffer.add(_entry(level: LogLevel.info, message: 'info'));
      buffer.add(_entry(level: LogLevel.warn, message: 'warn'));
      buffer.add(_entry(level: LogLevel.error, message: 'error'));
      buffer.add(_entry(level: LogLevel.fatal, message: 'fatal'));

      expect(buffer.entries, hasLength(3));
      expect(buffer.entries.map((e) => e.message).toList(),
          equals(['warn', 'error', 'fatal']));
    });

    test('allows all levels at LogLevel.debug', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.debug);

      buffer.add(_entry(level: LogLevel.debug));
      buffer.add(_entry(level: LogLevel.fatal));

      expect(buffer.entries, hasLength(2));
    });

    test('does not store entries below min level', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.error);

      buffer.add(_entry(level: LogLevel.info));
      buffer.add(_entry(level: LogLevel.error));
      buffer.add(_entry(level: LogLevel.fatal));

      expect(buffer.entries, hasLength(2));
    });
  });

  group('setTagFilter', () {
    test('stores only entries whose logger contains the tag', () {
      final buffer = LogBuffer();
      buffer.setTagFilter('http');

      buffer.add(_entry(logger: 'http.client', message: 'req'));
      buffer.add(_entry(logger: 'http.server', message: 'resp'));
      buffer.add(_entry(logger: 'db.conn', message: 'query'));

      expect(buffer.entries, hasLength(2));
      expect(buffer.entries.every((e) => e.logger.contains('http')), isTrue);
    });

    test('setting tag to null disables filtering', () {
      final buffer = LogBuffer();
      buffer.setTagFilter('http');
      buffer.add(_entry(logger: 'db.conn', message: 'query'));
      expect(buffer.entries, isEmpty);

      buffer.setTagFilter(null);
      buffer.add(_entry(logger: 'db.conn', message: 'query'));
      expect(buffer.entries, hasLength(1));
    });
  });

  group('setSearchFilter', () {
    test('stores only entries whose message contains the query (case-insensitive)', () {
      final buffer = LogBuffer();
      buffer.setSearchFilter('timeout');

      buffer.add(_entry(message: 'request timeout after 30s'));
      buffer.add(_entry(message: 'connection closed'));
      buffer.add(_entry(message: 'TimEOut occurred'));

      expect(buffer.entries, hasLength(2));
    });

    test('setting search to null disables filtering', () {
      final buffer = LogBuffer();
      buffer.setSearchFilter('error');
      buffer.add(_entry(message: 'hello'));
      expect(buffer.entries, isEmpty);

      buffer.setSearchFilter(null);
      buffer.add(_entry(message: 'hello'));
      expect(buffer.entries, hasLength(1));
    });
  });

  group('setSourceFilter', () {
    test('stores only entries matching the source', () {
      final buffer = LogBuffer();
      buffer.setSourceFilter('engine');

      buffer.add(_entry(source: 'engine', message: 'e1'));
      buffer.add(_entry(source: 'ui', message: 'u1'));
      buffer.add(_entry(source: 'engine', message: 'e2'));
      buffer.add(_entry(source: 'ui', message: 'u2'));

      expect(buffer.entries, hasLength(2));
      expect(buffer.entries.every((e) => e.source == 'engine'), isTrue);
    });

    test('setting source to null disables filtering', () {
      final buffer = LogBuffer();
      buffer.setSourceFilter('engine');
      buffer.add(_entry(source: 'ui'));
      expect(buffer.entries, isEmpty);

      buffer.setSourceFilter(null);
      buffer.add(_entry(source: 'ui'));
      expect(buffer.entries, hasLength(1));
    });
  });

  group('combined add-time filters', () {
    test('applies minLevel, tag, search, and source simultaneously', () {
      final buffer = LogBuffer();
      buffer.setMinLevel(LogLevel.warn);
      buffer.setTagFilter('http');
      buffer.setSearchFilter('fail');
      buffer.setSourceFilter('engine');

      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'request failed', source: 'engine'));
      buffer.add(_entry(level: LogLevel.info, logger: 'http.client',
          message: 'request failed', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'db',
          message: 'connection failed', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'success', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'request failed', source: 'ui'));

      expect(buffer.entries, hasLength(1));
      expect(buffer.entries.single.message, 'request failed');
    });
  });

  group('filtered()', () {
    late LogBuffer buffer;

    setUp(() {
      buffer = LogBuffer(maxEntries: 100);
      buffer.add(_entry(level: LogLevel.debug, logger: 'http.client',
          message: 'starting request', source: 'engine'));
      buffer.add(_entry(level: LogLevel.info, logger: 'http.client',
          message: '200 OK', source: 'engine'));
      buffer.add(_entry(level: LogLevel.warn, logger: 'http.client',
          message: 'slow response', source: 'engine'));
      buffer.add(_entry(level: LogLevel.error, logger: 'http.client',
          message: 'connection timeout', source: 'engine'));
      buffer.add(_entry(level: LogLevel.info, logger: 'ui',
          message: 'paint finished', source: 'ui'));
      buffer.add(_entry(level: LogLevel.error, logger: 'ui',
          message: 'widget build failed', source: 'ui'));
    });

    test('returns all entries when no filters are applied', () {
      expect(buffer.filtered(), hasLength(6));
    });

    test('filters by minLevel', () {
      expect(buffer.filtered(minLevel: LogLevel.warn), hasLength(3));
      expect(buffer.filtered(minLevel: LogLevel.error), hasLength(2));
      expect(buffer.filtered(minLevel: LogLevel.fatal), isEmpty);
    });

    test('filters by tag (logger contains)', () {
      expect(buffer.filtered(tag: 'ui'), hasLength(2));
      expect(buffer.filtered(tag: 'http'), hasLength(4));
      expect(buffer.filtered(tag: 'nonexistent'), isEmpty);
    });

    test('filters by search (message contains, case-insensitive)', () {
      expect(buffer.filtered(search: 'timeout'), hasLength(1));
      expect(buffer.filtered(search: 'failed'), hasLength(1));
      expect(buffer.filtered(search: 'STARTING'), hasLength(1));
    });

    test('filters by source', () {
      expect(buffer.filtered(source: 'engine'), hasLength(4));
      expect(buffer.filtered(source: 'ui'), hasLength(2));
    });

    test('combines minLevel and source filter', () {
      final result = buffer.filtered(minLevel: LogLevel.warn, source: 'engine');
      expect(result, hasLength(2));
      expect(result.every((e) => e.source == 'engine'), isTrue);
      expect(result.every((e) => e.level.index >= LogLevel.warn.index), isTrue);
    });

    test('combines all filter parameters', () {
      final result = buffer.filtered(
        minLevel: LogLevel.info,
        tag: 'http',
        search: 'response',
        source: 'engine',
      );
      expect(result, hasLength(1));
      expect(result.single.message, 'slow response');
    });

    test('limit returns at most N entries from the end', () {
      expect(buffer.filtered(limit: 3), hasLength(3));
      expect(buffer.filtered(limit: 3).last.message, 'widget build failed');

      // limit larger than result returns all
      expect(buffer.filtered(limit: 100), hasLength(6));
    });

    test('limit combined with filters', () {
      final result = buffer.filtered(minLevel: LogLevel.error, limit: 1);
      expect(result, hasLength(1));
      expect(result.single.message, 'widget build failed');
    });

    test('filtered returns entries despite add-time filter settings', () {
      // setMinLevel on the buffer itself — entries already in buffer
      // were added before the filter change, so they remain.
      buffer.setMinLevel(LogLevel.warn);

      // filtered() should still see all 6 stored entries, applying its own
      // minLevel parameter (not the buffer's _minLevel).
      expect(buffer.filtered(minLevel: LogLevel.debug), hasLength(6));
    });
  });

  group('clear', () {
    test('empties the entries list', () {
      final buffer = LogBuffer();
      buffer.add(_entry());
      buffer.add(_entry());
      expect(buffer.entries, isNotEmpty);

      buffer.clear();
      expect(buffer.entries, isEmpty);
    });

    test('does not close the stream', () async {
      final buffer = LogBuffer();
      buffer.add(_entry(message: 'before'));
      buffer.clear();

      var gotNewEntry = false;
      buffer.stream.listen((_) => gotNewEntry = true);
      buffer.add(_entry(message: 'after'));

      await Future<void>.delayed(Duration.zero);
      expect(gotNewEntry, isTrue);
    });
  });

  group('dispose', () {
    test('closes the stream', () async {
      final buffer = LogBuffer();
      buffer.dispose();

      expect(
        () => buffer.add(_entry()),
        throwsA(isA<Error>()),
      );
    });

    test('multiple dispose calls do not throw', () {
      final buffer = LogBuffer();
      buffer.dispose();
      expect(() => buffer.dispose(), returnsNormally);
    });
  });
}
